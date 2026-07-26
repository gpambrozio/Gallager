#if os(macOS)
    import ClaudeSpyCommon
    import Dependencies
    import Foundation
    import GallagerPluginProtocol
    import Logging
    import Observation

    // MARK: - PluginUpdateInlineStatus

    /// Per-plugin inline status shown in the Agents settings "Updates" section.
    public enum PluginUpdateInlineStatus: Sendable, Equatable {
        case checking
        case upToDate
        case updated(version: String, needsAppRestart: Bool)
        case updateAvailableNewSource(version: String)
        case failed(String)
    }

    // MARK: - PluginRestartNotice

    /// One "restart to finish updating" line in the Agents settings banner.
    public struct PluginRestartNotice: Sendable, Equatable, Identifiable {
        public let pluginID: String
        public let displayName: String
        public let newVersion: String
        /// true when the sidecar could not be hot-swapped (plugin had active
        /// sessions), so restarting Gallager is required too.
        public let needsAppRestart: Bool
        public var id: String { pluginID }
    }

    // MARK: - PluginUpdateManager

    /// Orchestrates automatic + manual plugin update checks (spec
    /// 2026-07-25-plugin-auto-update-design). Owns the triggers, applies updates
    /// through the PluginInstaller pipeline, hot-restarts idle sidecars, refreshes
    /// agent-side bridges, and exposes banner/notice state to the settings UI.
    /// Init-injected callbacks (not @DependencyClient): @Observable class with
    /// many wired callbacks, per CLAUDE.md.
    @MainActor
    @Observable
    public final class PluginUpdateManager {
        // MARK: Types

        /// Outcome of applying one update (also consumed by the CLI apply path).
        public enum ApplyResult: Sendable, Equatable {
            case applied(needsAppRestart: Bool)
            case skippedSourceChanged
            case failed(String)
        }

        /// Wired callbacks into AppCoordinator / the install pipeline.
        public struct Callbacks {
            public var loadRegistry: @MainActor () -> PluginRegistryFile
            public var saveRegistry: @MainActor (PluginRegistryFile) -> Void
            /// Batch, best-effort check (automatic passes) — fetch errors skip
            /// the entry, matching PluginUpdateChecker.check.
            public var checkUpdates: @MainActor ([PluginRegistryEntry]) async -> [PluginUpdate]
            /// Single-entry check for the manual Check Now path. THROWS on fetch
            /// errors so the UI can surface them inline (spec: manual failures
            /// are visible; automatic ones stay silent).
            public var checkUpdate: @MainActor (PluginRegistryEntry) async throws -> PluginUpdate?
            public var installFromURL: @MainActor (URL) async -> Result<PluginInstaller.InstallOutcome, InstallError>
            public var hasActiveSessions: @MainActor (String) -> Bool
            public var disablePlugin: @MainActor (String) async -> Void
            public var enablePlugin: @MainActor (String) async -> Void
            public var installStatus: @MainActor (String, String?) async -> PluginInstallStatus
            public var installBridge: @MainActor (String, String?) async -> String?
            public var additionalConfigFolders: @MainActor (String) -> [String]
            public var displayName: @MainActor (String) -> String
            public var currentAppVersion: @MainActor () -> String
            public var notify: @MainActor (String) -> Void

            public init(
                loadRegistry: @escaping @MainActor () -> PluginRegistryFile,
                saveRegistry: @escaping @MainActor (PluginRegistryFile) -> Void,
                checkUpdates: @escaping @MainActor ([PluginRegistryEntry]) async -> [PluginUpdate],
                checkUpdate: @escaping @MainActor (PluginRegistryEntry) async throws -> PluginUpdate?,
                installFromURL: @escaping @MainActor (URL) async -> Result<PluginInstaller.InstallOutcome, InstallError>,
                hasActiveSessions: @escaping @MainActor (String) -> Bool,
                disablePlugin: @escaping @MainActor (String) async -> Void,
                enablePlugin: @escaping @MainActor (String) async -> Void,
                installStatus: @escaping @MainActor (String, String?) async -> PluginInstallStatus,
                installBridge: @escaping @MainActor (String, String?) async -> String?,
                additionalConfigFolders: @escaping @MainActor (String) -> [String],
                displayName: @escaping @MainActor (String) -> String,
                currentAppVersion: @escaping @MainActor () -> String,
                notify: @escaping @MainActor (String) -> Void
            ) {
                self.loadRegistry = loadRegistry
                self.saveRegistry = saveRegistry
                self.checkUpdates = checkUpdates
                self.checkUpdate = checkUpdate
                self.installFromURL = installFromURL
                self.hasActiveSessions = hasActiveSessions
                self.disablePlugin = disablePlugin
                self.enablePlugin = enablePlugin
                self.installStatus = installStatus
                self.installBridge = installBridge
                self.additionalConfigFolders = additionalConfigFolders
                self.displayName = displayName
                self.currentAppVersion = currentAppVersion
                self.notify = notify
            }
        }

        // MARK: Observable state

        public private(set) var restartNotices: [PluginRestartNotice] = []
        public private(set) var inlineStatus: [String: PluginUpdateInlineStatus] = [:]
        public private(set) var lastCheckDate: Date?

        // MARK: Private

        private let callbacks: Callbacks
        private let automaticTriggersEnabled: Bool
        private let logger = Logger(label: "com.claudespy.pluginupdatemanager")
        @ObservationIgnored @Dependency(PreferencesService.self) private var preferences
        @ObservationIgnored @Dependency(\.continuousClock) private var clock
        @ObservationIgnored @Dependency(\.date) private var date
        private var loopTask: Task<Void, Never>?
        /// Serializes check/apply work — a new request awaits the prior one.
        private var currentRun: Task<Void, Never>?

        static let checkInterval: TimeInterval = 24 * 60 * 60

        enum Keys {
            static let lastRunAppVersion = "pluginUpdateLastRunAppVersion"
            static let lastCheckAt = "pluginUpdateLastCheckAt"
        }

        public init(callbacks: Callbacks, automaticTriggersEnabled: Bool = true) {
            self.callbacks = callbacks
            self.automaticTriggersEnabled = automaticTriggersEnabled
            lastCheckDate = preferences
                .optionalDouble(Keys.lastCheckAt)
                .map(Date.init(timeIntervalSince1970:))
        }

        // MARK: - UI queries

        /// Whether the Updates section renders for `id`: URL-installed with a
        /// manifest URL (bundled and folder-dropped plugins can't update).
        public func isUpdatable(_ id: String) -> Bool {
            entry(id).map { $0.source == .url && $0.manifestURL != nil } ?? false
        }

        public func autoUpdateEnabled(_ id: String) -> Bool {
            entry(id)?.autoUpdate ?? true
        }

        public func setAutoUpdate(_ id: String, enabled: Bool) {
            mutateEntry(id) { $0.autoUpdate = enabled }
        }

        public func manifestURL(_ id: String) -> URL? {
            entry(id)?.manifestURL
        }

        // MARK: - Registry helpers

        private func entry(_ id: String) -> PluginRegistryEntry? {
            callbacks.loadRegistry().plugins.first { $0.id == id }
        }

        private func mutateEntry(_ id: String, _ change: (inout PluginRegistryEntry) -> Void) {
            var file = callbacks.loadRegistry()
            guard let index = file.plugins.firstIndex(where: { $0.id == id }) else { return }
            change(&file.plugins[index])
            callbacks.saveRegistry(file)
        }

        // MARK: - Apply

        /// Apply one update through the installer pipeline, then hot-restart the
        /// sidecar if the plugin is idle and refresh agent-side bridges. Records
        /// the restart notice + inline status. Also the CLI apply path's engine.
        public func applyUpdate(_ update: PluginUpdate) async -> ApplyResult {
            let result = await applyUpdateCore(update)
            switch result {
            case let .applied(needsAppRestart):
                let notice = PluginRestartNotice(
                    pluginID: update.id,
                    displayName: callbacks.displayName(update.id),
                    newVersion: update.newVersion,
                    needsAppRestart: needsAppRestart
                )
                restartNotices.removeAll { $0.pluginID == update.id }
                restartNotices.append(notice)
                inlineStatus[update.id] = .updated(version: update.newVersion, needsAppRestart: needsAppRestart)
            case .skippedSourceChanged:
                inlineStatus[update.id] = .updateAvailableNewSource(version: update.newVersion)
            case let .failed(message):
                inlineStatus[update.id] = .failed(message)
            }
            return result
        }

        private func applyUpdateCore(_ update: PluginUpdate) async -> ApplyResult {
            // A changed bundle host needs the manual trust flow — never auto-install.
            guard !update.sourceChanged else { return .skippedSourceChanged }
            guard let manifestURL = entry(update.id)?.manifestURL else {
                return .failed("no manifestURL in registry")
            }
            switch await callbacks.installFromURL(manifestURL) {
            case let .failure(error):
                logger.warning("Plugin update failed for '\(update.id)': \(error)")
                return .failed(String(describing: error))
            case .success(.needsTrust):
                // installFromURL is always called trustConfirmed on this path.
                return .failed("unexpected trust prompt")
            case .success(.installed):
                if callbacks.hasActiveSessions(update.id) {
                    // Live sessions would lose sidecar state on a hot swap; the
                    // old process keeps running and the bridge refresh happens on
                    // next launch (sweepPendingBridgeRefreshes).
                    mutateEntry(update.id) { $0.needsBridgeRefresh = true }
                    return .applied(needsAppRestart: true)
                }
                // Explicit disable-first: enable() early-returns for an active
                // core, so a bare enable would leave the old process running.
                await callbacks.disablePlugin(update.id)
                await callbacks.enablePlugin(update.id)
                await refreshBridges(update.id)
                return .applied(needsAppRestart: false)
            }
        }

        /// Re-run the sidecar's `install` RPC in every location whose bridge is
        /// currently installed (default root + additional config folders). Must
        /// only run while the NEW sidecar is up — the RPC writes the bridge
        /// template shipped in the bundle.
        private func refreshBridges(_ id: String) async {
            let roots: [String?] = [nil] + callbacks.additionalConfigFolders(id)
            for root in roots {
                if case .installed = await callbacks.installStatus(id, root) {
                    _ = await callbacks.installBridge(id, root)
                }
            }
        }

        /// Boot-time sweep: finish bridge refreshes deferred because the plugin
        /// was busy when its update landed. The app has restarted since, so the
        /// running sidecar is the new one.
        private func sweepPendingBridgeRefreshes() async {
            for entry in callbacks.loadRegistry().plugins where entry.needsBridgeRefresh {
                await refreshBridges(entry.id)
                mutateEntry(entry.id) { $0.needsBridgeRefresh = false }
            }
        }

        // MARK: - Checks

        /// Manual per-plugin check (the Check Now button). Ignores the
        /// autoUpdate toggle and applies any found update — the press is consent.
        public func checkNow(_ id: String) {
            inlineStatus[id] = .checking
            scheduleRun { [weak self] in
                await self?.runManualCheck(id)
            }
        }

        private func runManualCheck(_ id: String) async {
            guard let entry = entry(id) else {
                inlineStatus[id] = .failed("Plugin is not installed")
                return
            }
            let update: PluginUpdate?
            do {
                update = try await callbacks.checkUpdate(entry)
            } catch {
                stampLastCheck()
                inlineStatus[id] = .failed(String(describing: error))
                return
            }
            stampLastCheck()
            guard let update else {
                inlineStatus[id] = .upToDate
                return
            }
            if case .applied = await applyUpdate(update),
               let notice = restartNotices.first(where: { $0.pluginID == id }) {
                callbacks.notify(Self.notificationBody([notice]))
            }
        }

        static func notificationBody(_ notices: [PluginRestartNotice]) -> String {
            notices.map { notice in
                let action = notice.needsAppRestart
                    ? "restart Gallager and any \(notice.displayName) sessions"
                    : "restart your \(notice.displayName) sessions"
                return "\(notice.displayName) \(notice.newVersion) — \(action)"
            }
            .joined(separator: "; ")
        }

        private func stampLastCheck() {
            let now = date.now
            lastCheckDate = now
            preferences.setDouble(now.timeIntervalSince1970, Keys.lastCheckAt)
        }

        // MARK: - Triggers

        /// Called once at boot, after all plugins are enabled.
        public func start() {
            scheduleRun { await self.sweepPendingBridgeRefreshes() }
        }

        private func scheduleRun(_ op: @escaping @MainActor () async -> Void) {
            let prior = currentRun
            currentRun = Task {
                await prior?.value
                await op()
            }
        }

        // MARK: - Test support

        /// Await completion of any scheduled check/apply run (tests only).
        func waitForPendingRuns() async {
            await currentRun?.value
        }
    }
#endif
