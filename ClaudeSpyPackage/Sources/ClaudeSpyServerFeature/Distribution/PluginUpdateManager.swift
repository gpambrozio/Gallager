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
            /// the entry, matching PluginUpdateChecker.check. Also reports
            /// whether at least one manifest fetch actually completed, so an
            /// all-failed pass (offline) is distinguishable from "no updates".
            public var checkUpdates: @MainActor ([PluginRegistryEntry]) async
                -> (updates: [PluginUpdate], anyFetchSucceeded: Bool)
            /// Single-entry check for the manual Check Now path. THROWS on fetch
            /// errors so the UI can surface them inline (spec: manual failures
            /// are visible; automatic ones stay silent).
            public var checkUpdate: @MainActor (PluginRegistryEntry) async throws -> PluginUpdate?
            public var installFromURL: @MainActor (URL) async -> Result<PluginInstaller.InstallOutcome, InstallError>
            public var hasActiveSessions: @MainActor (String) -> Bool
            /// Live enabled state from the in-memory registry — NOT the persisted
            /// `enabled` field, which can lag a CLI `plugin disable` until the
            /// next boot rewrite.
            public var isPluginEnabled: @MainActor (String) -> Bool
            public var disablePlugin: @MainActor (String) async -> Void
            /// Returns whether the plugin ended up enabled (a new bundle whose
            /// sidecar fails `initialize` reports false).
            public var enablePlugin: @MainActor (String) async -> Bool
            public var installStatus: @MainActor (String, String?) async -> PluginInstallStatus
            public var installBridge: @MainActor (String, String?) async -> String?
            public var additionalConfigFolders: @MainActor (String) -> [String]
            public var displayName: @MainActor (String) -> String
            public var currentAppVersion: @MainActor () -> String
            public var notify: @MainActor (String) -> Void

            public init(
                loadRegistry: @escaping @MainActor () -> PluginRegistryFile,
                saveRegistry: @escaping @MainActor (PluginRegistryFile) -> Void,
                checkUpdates: @escaping @MainActor ([PluginRegistryEntry]) async
                    -> (updates: [PluginUpdate], anyFetchSucceeded: Bool),
                checkUpdate: @escaping @MainActor (PluginRegistryEntry) async throws -> PluginUpdate?,
                installFromURL: @escaping @MainActor (URL) async -> Result<PluginInstaller.InstallOutcome, InstallError>,
                hasActiveSessions: @escaping @MainActor (String) -> Bool,
                isPluginEnabled: @escaping @MainActor (String) -> Bool,
                disablePlugin: @escaping @MainActor (String) async -> Void,
                enablePlugin: @escaping @MainActor (String) async -> Bool,
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
                self.isPluginEnabled = isPluginEnabled
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
        /// the restart notice + inline status. Called from inside already-chained
        /// runs (`runManualCheck`, `runAutomaticCheck`) — never chain on
        /// `currentRun` here, or a call from within a chained run would deadlock
        /// waiting on itself. Out-of-band callers (the CLI) must go through
        /// `applyUpdateSerialized` instead.
        public func applyUpdate(_ update: PluginUpdate) async -> ApplyResult {
            let result = await applyUpdateCore(update)
            recordOutcome(id: update.id, newVersion: update.newVersion, result: result)
            return result
        }

        /// Update the banner/inline state for one apply (or reinstall) outcome.
        private func recordOutcome(id: String, newVersion: String, result: ApplyResult) {
            switch result {
            case let .applied(needsAppRestart):
                let notice = PluginRestartNotice(
                    pluginID: id,
                    displayName: callbacks.displayName(id),
                    newVersion: newVersion,
                    needsAppRestart: needsAppRestart
                )
                restartNotices.removeAll { $0.pluginID == id }
                restartNotices.append(notice)
                inlineStatus[id] = .updated(version: newVersion, needsAppRestart: needsAppRestart)
            case .skippedSourceChanged:
                inlineStatus[id] = .updateAvailableNewSource(version: newVersion)
            case let .failed(message):
                inlineStatus[id] = .failed(message)
            }
        }

        /// Out-of-band reinstall hook: called after an install that replaced an
        /// already-installed plugin OUTSIDE the manager's own apply flow — the
        /// source-changed Review… trust sheet, CLI `gallager plugin install`,
        /// the Add Plugin sheet, and zip installs. The installer has already
        /// committed the new bundle + registry entry, but it cannot swap a
        /// running sidecar (its enable step early-returns for an active plugin)
        /// or refresh agent-side bridges. Run the same post-install steps as an
        /// auto-applied update and record the same notice/inline status,
        /// serialized on the run queue with every check/apply.
        public func finishReinstall(_ id: String) {
            scheduleRun { [weak self] in
                await self?.runFinishReinstall(id)
            }
        }

        private func runFinishReinstall(_ id: String) async {
            guard let entry = entry(id) else { return }
            let result = await finishSwap(id)
            recordOutcome(id: id, newVersion: entry.version, result: result)
            if case .applied = result,
               let notice = restartNotices.first(where: { $0.pluginID == id }) {
                callbacks.notify(Self.notificationBody([notice]))
            }
        }

        /// Serialized entry point for out-of-band apply requests (the CLI path).
        /// Chains on the same run queue as every automatic/manual check so a CLI
        /// `gallager plugin update --apply` can never interleave with an
        /// in-flight check/apply — two concurrent `PluginInstaller.install` runs
        /// for one id would race on the shared deterministic staging dir.
        public func applyUpdateSerialized(_ update: PluginUpdate) async -> ApplyResult {
            let prior = currentRun
            let task = Task { [weak self] () -> ApplyResult in
                await prior?.value
                guard let self else { return .failed("Manager deallocated") }
                return await self.applyUpdate(update)
            }
            currentRun = Task { _ = await task.value }
            return await task.value
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
                return .failed(Self.userFacingMessage(for: error))
            case .success(.needsTrust):
                // installFromURL is always called trustConfirmed on this path.
                return .failed("unexpected trust prompt")
            case let .success(.installed(installedID)):
                // A manifest that redeclares its id would install plugin B while
                // every follow-up step (session check, restart, notices) names
                // plugin A — refuse the mismatch outright.
                guard installedID == update.id else {
                    return .failed("manifest id mismatch: expected '\(update.id)', got '\(installedID)'")
                }
                return await finishSwap(update.id)
            }
        }

        /// Post-install steps shared by every path that replaces an installed
        /// plugin's bundle (the manager's own applies and out-of-band
        /// reinstalls): hot-restart the sidecar when idle, then refresh
        /// bridges; otherwise defer both to the next launch.
        private func finishSwap(_ id: String) async -> ApplyResult {
            if callbacks.hasActiveSessions(id) || !callbacks.isPluginEnabled(id) {
                // Busy: live sessions would lose sidecar state on a hot
                // swap. Disabled: the enable step would respawn a plugin
                // the user turned off. Either way the running state stays
                // untouched and the bridge refresh happens on next launch
                // (sweepPendingBridgeRefreshes).
                mutateEntry(id) { $0.needsBridgeRefresh = true }
                return .applied(needsAppRestart: true)
            }
            // Explicit disable-first: enable() early-returns for an active
            // core, so a bare enable would leave the old process running.
            await callbacks.disablePlugin(id)
            guard await callbacks.enablePlugin(id) else {
                // The old process is already gone and the new bundle failed
                // to start — surface it instead of celebrating, and flag the
                // bridge refresh so the next successful enable (usually next
                // launch) finishes the job.
                mutateEntry(id) { $0.needsBridgeRefresh = true }
                return .failed("new version failed to start — restart Gallager to retry")
            }
            let bridgesRefreshed = await refreshBridges(id)
            if !bridgesRefreshed {
                // Sidecar is current but at least one agent-side bridge
                // re-install failed; keep it retryable at next launch
                // rather than stranding a stale bridge forever.
                mutateEntry(id) { $0.needsBridgeRefresh = true }
            }
            return .applied(needsAppRestart: false)
        }

        /// Re-run the sidecar's `install` RPC in every location whose bridge is
        /// currently installed (default root + additional config folders). Must
        /// only run while the NEW sidecar is up — the RPC writes the bridge
        /// template shipped in the bundle. Returns false when any attempted
        /// re-install reported an error.
        private func refreshBridges(_ id: String) async -> Bool {
            var allSucceeded = true
            let roots: [String?] = [nil] + callbacks.additionalConfigFolders(id)
            for root in roots {
                if case .installed = await callbacks.installStatus(id, root) {
                    if let error = await callbacks.installBridge(id, root) {
                        logger.warning("Bridge refresh failed for '\(id)' at \(root ?? "default"): \(error)")
                        allSucceeded = false
                    }
                }
            }
            return allSucceeded
        }

        /// Boot-time sweep: finish bridge refreshes deferred because the plugin
        /// was busy when its update landed. The app has restarted since, so the
        /// running sidecar is the new one. The flag clears only on success —
        /// clearing unconditionally would strand a stale bridge forever after
        /// one failed sweep.
        private func sweepPendingBridgeRefreshes() async {
            for entry in callbacks.loadRegistry().plugins where entry.needsBridgeRefresh {
                if await refreshBridges(entry.id) {
                    mutateEntry(entry.id) { $0.needsBridgeRefresh = false }
                }
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
                // A failed fetch is not a completed check — leaving
                // lastCheckDate alone keeps the launch staleness trigger armed.
                inlineStatus[id] = .failed(Self.userFacingMessage(for: error))
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

        /// Human-readable rendering of a check/install error for the Updates
        /// section (a raw `String(describing:)` would show NSError dumps).
        static func userFacingMessage(for error: any Error) -> String {
            if let installError = error as? InstallError {
                return installError.uiDescription
            }
            return (error as NSError).localizedDescription
        }

        static func notificationBody(_ notices: [PluginRestartNotice]) -> String {
            notices.map { notice in
                // needsAppRestart == false means the sidecar was hot-swapped
                // while the plugin had no active sessions — nothing is left to
                // restart, so no restart advice.
                notice.needsAppRestart
                    ? "\(notice.displayName) \(notice.newVersion) — restart Gallager and any \(notice.displayName) sessions"
                    : "\(notice.displayName) updated to \(notice.newVersion)"
            }
            .joined(separator: "; ")
        }

        private func stampLastCheck() {
            let now = date.now
            lastCheckDate = now
            preferences.setDouble(now.timeIntervalSince1970, Keys.lastCheckAt)
        }

        // MARK: - Triggers

        /// Called once at boot, after all plugins are enabled. Finishes any
        /// deferred bridge refreshes, then runs the automatic triggers:
        /// app-version change (plugin releases usually ride app releases),
        /// >24h-stale fallback, and a daily re-check loop while running.
        public func start() {
            scheduleRun { [weak self] in
                await self?.sweepPendingBridgeRefreshes()
            }
            guard automaticTriggersEnabled else { return }

            let current = callbacks.currentAppVersion()
            let lastRun = preferences.string(Keys.lastRunAppVersion)
            preferences.setString(current, Keys.lastRunAppVersion)
            let stale = lastCheckDate.map { date.now.timeIntervalSince($0) > Self.checkInterval } ?? true
            if lastRun != current || stale {
                scheduleRun { [weak self] in
                    await self?.runAutomaticCheck()
                }
            }

            loopTask = Task { [weak self] in
                while let clock = self?.clock {
                    try? await clock.sleep(for: .seconds(Self.checkInterval))
                    if Task.isCancelled { return }
                    self?.scheduleRun { [weak self] in
                        await self?.runAutomaticCheck()
                    }
                }
            }
        }

        /// Cancel the daily loop (tests / teardown).
        public func stop() {
            loopTask?.cancel()
            loopTask = nil
        }

        /// One automatic (best-effort, silent-on-error) pass over every
        /// autoUpdate-enabled, currently-enabled entry, with a single combined
        /// notification for everything that applied. Disabled plugins are
        /// skipped so the apply path's enable step can't respawn them.
        private func runAutomaticCheck() async {
            let entries = callbacks.loadRegistry().plugins.filter {
                $0.autoUpdate && callbacks.isPluginEnabled($0.id)
            }
            let (updates, anyFetchSucceeded) = await callbacks.checkUpdates(entries)
            // Stamp only when a fetch actually completed (or there was nothing
            // to fetch): an all-failed pass (offline) must not suppress the
            // staleness trigger for the next 24h.
            if anyFetchSucceeded || entries.isEmpty {
                stampLastCheck()
            }

            var applied: [PluginRestartNotice] = []
            for update in updates {
                if case .applied = await applyUpdate(update),
                   let notice = restartNotices.first(where: { $0.pluginID == update.id }) {
                    applied.append(notice)
                }
            }
            if !applied.isEmpty {
                callbacks.notify(Self.notificationBody(applied))
            }
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
