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

        // MARK: - Test support

        /// Await completion of any scheduled check/apply run (tests only).
        func waitForPendingRuns() async {
            await currentRun?.value
        }
    }
#endif
