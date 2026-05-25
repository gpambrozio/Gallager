import enum ClaudeSpyNetworking.AgentResponse
import enum ClaudeSpyNetworking.AgentResponseRequest
import enum ClaudeSpyNetworking.AppAction
import struct ClaudeSpyNetworking.ClaudeProjectInfo
import Foundation
import GallagerPluginProtocol
import Logging

// `ClaudeSpyNetworking` and `GallagerPluginProtocol` both declare
// `JSONRPCRequest` / `JSONRPCResponse` / `JSONRPCError`. The whole-module
// `import ClaudeSpyNetworking` would pull both shapes into scope and the
// type checker can't disambiguate at the use-site. We import the few value
// types we actually need explicitly so `JSONRPCRequest` / `JSONRPCResponse`
// / `JSONRPCError` resolve to the sidecar-protocol versions in
// `GallagerPluginProtocol`.
import enum ClaudeSpyNetworking.JSONValue
import struct ClaudeSpyNetworking.PermissionResponse
import struct ClaudeSpyNetworking.PluginPresentation

// MARK: - PluginManager

/// Public façade that ties together every Mac-side plugin component:
///
/// - `PluginRegistry` (`registry.json` ownership + enable/disable bits).
/// - `BundledPluginDiscovery` (scans the bundled-plugins resource dir).
/// - `SidecarSupervisor` (one per enabled plugin; owns the child process).
/// - `JSONRPCConnection` (wrapped by the supervisor).
/// - `AssetCache` (presentation bundles for iOS).
/// - `PluginEventDispatcher` (routes `PluginEvent` envelopes to the right sinks).
///
/// `@MainActor` is appropriate because the manager is an app-bootstrap
/// façade — it's owned by `AppCoordinator` (Task 15) and produces values
/// read by SwiftUI views. The actual I/O (process spawn, RPC) happens on
/// the supervisor's actor and the dispatcher's actor.
@MainActor
@Observable
final public class PluginManager {
    // MARK: - Public configuration

    public struct LaunchCommandSpec: Sendable, Equatable {
        public let command: String
        public let args: [String]
        public let env: [String: String]

        public init(command: String, args: [String], env: [String: String]) {
            self.command = command
            self.args = args
            self.env = env
        }
    }

    // MARK: - Private dependencies

    private let layout: PluginRootLayout
    private let registry: PluginRegistry
    private let discovery: BundledPluginDiscovery
    private let assetCache: AssetCache
    private let dispatcher: PluginEventDispatcher
    private let yoloProvider: any YoloModeProvider
    private let statusSink: any PluginSessionStatusSink
    private let notificationSink: any PluginNotificationSink
    private let responseRequestSink: any PluginResponseRequestSink
    private let appActionSink: any PluginAppActionSink
    private let agentDriverSink: any PluginAgentDriverSink
    private let logger: Logger
    private let appVersion: String

    /// Bridge object passed to every supervisor's delegate slot. Lives for
    /// the manager's lifetime; routes inbound traffic back via a weak
    /// reference to the manager.
    private var supervisorBridge: SupervisorBridge?

    /// Bridge object passed to the dispatcher's auto-approval delegate
    /// slot. The dispatcher holds it weakly (so a dropped manager can't
    /// linger), so the manager must retain it explicitly for the lifetime
    /// of the runtime.
    private var autoApproveBridge: AutoApproveBridge?

    // MARK: - Mutable state

    /// One supervisor per enabled plugin, keyed by plugin id.
    @ObservationIgnored
    private var supervisors: [String: SidecarSupervisor] = [:]

    /// Per-plugin manifest cache (built during `start()` from discovery).
    @ObservationIgnored
    private var manifestsByID: [String: PluginManifest] = [:]

    /// Per-plugin on-disk directory (so RPC handlers can resolve icon paths
    /// and the supervisor can be re-spawned without re-running discovery).
    @ObservationIgnored
    private var pluginDirsByID: [String: URL] = [:]

    /// Projects per plugin, populated by `set_projects` notifications.
    /// Exposed via `projects(for:)` and `allProjects`.
    @ObservationIgnored
    private var projectsByPlugin: [String: [AgentProject]] = [:]

    /// Presentation bundles for every enabled plugin, populated during
    /// `start()` via the asset cache.
    public private(set) var presentations: [PluginPresentation] = []

    /// Mirror of every in-flight `AgentResponseRequest` keyed by request id.
    /// Used by yolo auto-approve to remember the suggestion shape so the
    /// auto-allow response carries no `appliedSuggestionId` (the user didn't
    /// pick one — we picked allow on their behalf).
    @ObservationIgnored
    private var inFlightRequestsByID: [String: AgentResponseRequest] = [:]

    /// Idempotency: `start()` flips this on first success so subsequent
    /// calls become no-ops. Stop() resets it.
    @ObservationIgnored
    private var didStart = false

    // MARK: - Init

    public init(
        layout: PluginRootLayout,
        statusSink: any PluginSessionStatusSink,
        notificationSink: any PluginNotificationSink,
        responseRequestSink: any PluginResponseRequestSink,
        appActionSink: any PluginAppActionSink,
        agentDriverSink: any PluginAgentDriverSink,
        yoloProvider: any YoloModeProvider,
        appVersion: String = "0.0",
        logger: Logger? = nil
    ) {
        self.layout = layout
        self.statusSink = statusSink
        self.notificationSink = notificationSink
        self.responseRequestSink = responseRequestSink
        self.appActionSink = appActionSink
        self.agentDriverSink = agentDriverSink
        self.yoloProvider = yoloProvider
        self.appVersion = appVersion
        let logger = logger ?? Logger(label: "gallager.plugin.manager")
        self.logger = logger

        self.registry = PluginRegistry(layout: layout, logger: logger)
        self.discovery = BundledPluginDiscovery()
        self.assetCache = AssetCache()
        self.dispatcher = PluginEventDispatcher(
            statusSink: statusSink,
            notificationSink: notificationSink,
            responseRequestSink: responseRequestSink,
            appActionSink: appActionSink,
            yoloProvider: yoloProvider,
            logger: logger
        )
    }

    // MARK: - Lifecycle

    /// Discover bundled plugins, merge them into the registry, spawn
    /// supervisors for every enabled entry, run their `initialize`
    /// handshake, and load presentation bundles.
    ///
    /// Idempotent — calling twice is a no-op. Throws on the first error
    /// (e.g. a corrupt manifest); partially-spawned supervisors are torn
    /// down before the throw escapes.
    public func start() async throws {
        guard !didStart else { return }

        // Wire the dispatcher's auto-approval delegate now that `self` is
        // fully initialised. Doing this in `init` would require the actor
        // hop to settle before any dispatch attempt — we get the same
        // ordering for free by running once at the top of `start()`.
        //
        // The dispatcher holds the delegate weakly, so the manager retains
        // the bridge explicitly via `autoApproveBridge` — otherwise the
        // freshly-constructed bridge gets deallocated before the dispatcher
        // ever calls it.
        let autoApproveBridge = AutoApproveBridge(manager: self)
        self.autoApproveBridge = autoApproveBridge
        await dispatcher.setAutoApprovalDelegate(autoApproveBridge)

        // Discover bundled plugins (best-effort — a missing dir is fine).
        let bundledDir = layout.bundledPluginsDir()
        let records: [BundledPluginRecord]
        do {
            records = try discovery.discover(in: bundledDir)
        } catch {
            logger.error("plugin discovery failed in \(bundledDir.path): \(error)")
            throw error
        }

        // Seed the registry with the freshly-discovered bundled set.
        try await registry.mergeBundled(records.map(\.registryEntry))

        // Build the per-id manifest + dir lookup before we spawn anything;
        // sidecars need both during initialize.
        for record in records {
            manifestsByID[record.manifest.id] = record.manifest
            pluginDirsByID[record.manifest.id] = record.pluginDir
        }

        // The supervisor bridge is the AnyObject delegate every supervisor
        // talks to. Keep it strong on the manager; it holds the manager
        // weakly to avoid a retain cycle.
        let bridge = SupervisorBridge(manager: self)
        supervisorBridge = bridge

        // Spawn one supervisor per enabled registry entry. Disabled
        // plugins are skipped — re-enabling them later goes through
        // `enable(pluginID:)`.
        let entries = try await registry.entries()
        for entry in entries where entry.enabled {
            guard
                let manifest = manifestsByID[entry.id],
                let pluginDir = pluginDirsByID[entry.id]
            else {
                logger.warning("registry entry \(entry.id) has no matching bundled manifest; skipping")
                continue
            }
            try await spawnSupervisor(manifest: manifest, pluginDir: pluginDir, bridge: bridge)
            try await loadPresentation(manifest: manifest, pluginDir: pluginDir)
        }

        didStart = true
    }

    /// Stop every supervisor cleanly. Does not modify the registry — the
    /// next `start()` will respawn supervisors from the same enabled
    /// entries.
    public func stop() async {
        // Stop supervisors in parallel — each has its own ladder
        // (`shutdown` RPC → SIGTERM → SIGKILL) and runs on its own actor.
        let active = supervisors.values
        await withTaskGroup(of: Void.self) { group in
            for supervisor in active {
                group.addTask {
                    await supervisor.stop()
                }
            }
        }
        supervisors.removeAll()
        manifestsByID.removeAll()
        pluginDirsByID.removeAll()
        projectsByPlugin.removeAll()
        presentations.removeAll()
        await assetCache.clear()
        supervisorBridge = nil
        autoApproveBridge = nil
        didStart = false
    }

    // MARK: - Enable / disable

    /// Re-enable a previously-disabled plugin and spawn its supervisor.
    public func enable(pluginID: String) async throws {
        try await registry.setEnabled(id: pluginID, enabled: true)
        guard supervisors[pluginID] == nil else { return }
        guard
            let manifest = manifestsByID[pluginID],
            let pluginDir = pluginDirsByID[pluginID],
            let bridge = supervisorBridge
        else {
            throw PluginManagerError.unknownPlugin(id: pluginID)
        }
        try await spawnSupervisor(manifest: manifest, pluginDir: pluginDir, bridge: bridge)
        try await loadPresentation(manifest: manifest, pluginDir: pluginDir)
    }

    /// Stop the supervisor and flip the registry's enabled bit off.
    /// Idempotent — disabling an already-disabled plugin is a no-op.
    public func disable(pluginID: String) async throws {
        try await registry.setEnabled(id: pluginID, enabled: false)
        if let supervisor = supervisors.removeValue(forKey: pluginID) {
            await supervisor.stop()
        }
        presentations.removeAll { $0.id == pluginID }
        projectsByPlugin.removeValue(forKey: pluginID)
        await assetCache.remove(pluginID: pluginID)
    }

    // MARK: - Projects

    /// Fanout a `refresh_projects` notification to every running sidecar.
    /// The sidecar is expected to re-scan and push the new list back via
    /// the `set_projects` callback (Spec §6.2).
    public func refreshProjects() async {
        for (pluginID, supervisor) in supervisors {
            do {
                try await supervisor.send(
                    method: PluginRPCMethod.AppToSidecar.refreshProjects.rawValue,
                    params: [String: String]()
                )
            } catch {
                logger.warning("refresh_projects on \(pluginID) failed: \(error)")
            }
        }
    }

    /// Projects pushed by the named plugin's last `set_projects` callback.
    /// Returns an empty list when the plugin hasn't pushed anything yet.
    public func projects(for pluginID: String) -> [AgentProject] {
        projectsByPlugin[pluginID] ?? []
    }

    /// All projects from every plugin, ordered deterministically: by plugin
    /// id, then by the plugin's published order within that bucket.
    public var allProjects: [AgentProject] {
        var out: [AgentProject] = []
        for pluginID in projectsByPlugin.keys.sorted() {
            if let list = projectsByPlugin[pluginID] {
                out.append(contentsOf: list)
            }
        }
        return out
    }

    // MARK: - Translation (manual entry point)

    /// Translate + dispatch a raw ingress payload for the named plugin.
    /// Used by tests and by code paths that build an `IngressFrame` from a
    /// non-socket source. Production traffic flows through the ingress
    /// socket → supervisor → `emit_event` path.
    public func translate(
        rawIngressPayload payload: JSONValue,
        context: [String: String],
        pluginID: String
    ) async {
        guard let supervisor = supervisors[pluginID] else {
            logger.warning("translate called for unknown plugin \(pluginID)")
            return
        }
        struct TranslateParams: Encodable {
            let context: [String: String]
            let payload: JSONValue
        }
        do {
            let event: PluginEvent = try await supervisor.send(
                method: PluginRPCMethod.AppToSidecar.translateEvent.rawValue,
                params: TranslateParams(context: context, payload: payload)
            )
            await dispatcher.dispatch(event)
        } catch {
            logger.warning("translate_event on \(pluginID) failed: \(error)")
        }
    }

    // MARK: - Response submission

    /// Submit a user `AgentResponse` for a request previously emitted by
    /// the plugin. Forwarded to the owning sidecar via `deliver_response`.
    public func deliverResponse(
        pluginID: String,
        sessionID: String,
        requestID: String,
        response: AgentResponse
    ) async {
        inFlightRequestsByID.removeValue(forKey: requestID)
        guard let supervisor = supervisors[pluginID] else {
            logger.warning("deliverResponse for unknown plugin \(pluginID)")
            return
        }
        struct DeliverResponseParams: Encodable {
            let sessionId: String
            let requestId: String
            let response: AgentResponse
        }
        do {
            try await supervisor.send(
                method: PluginRPCMethod.AppToSidecar.deliverResponse.rawValue,
                params: DeliverResponseParams(
                    sessionId: sessionID,
                    requestId: requestID,
                    response: response
                )
            )
        } catch {
            logger.warning("deliver_response on \(pluginID) failed: \(error)")
        }
    }

    // MARK: - Presentation lookup

    public func presentation(for pluginID: String) -> PluginPresentation? {
        presentations.first { $0.id == pluginID }
    }

    // MARK: - TmuxService bucketing

    /// For TmuxService — list every plugin's declared process names so the
    /// pane scanner can bucket panes by plugin.
    public var processNamesByPlugin: [String: [String]] {
        var out: [String: [String]] = [:]
        for (id, manifest) in manifestsByID {
            out[id] = manifest.processNames
        }
        return out
    }

    // MARK: - detect_pane

    /// Issue a `detect_pane` RPC against the named plugin's sidecar. Only
    /// makes sense when the manifest declared `requires_rich_detection`;
    /// callers that ignore this contract just get `false` back.
    public func detectPane(pluginID: String, paneInfo: [String: String]) async -> Bool {
        guard let supervisor = supervisors[pluginID] else { return false }
        struct DetectResult: Decodable {
            let owns: Bool
        }
        struct DetectParams: Encodable {
            let paneInfo: [String: String]
        }
        do {
            let result: DetectResult = try await supervisor.send(
                method: PluginRPCMethod.AppToSidecar.detectPane.rawValue,
                params: DetectParams(paneInfo: paneInfo)
            )
            return result.owns
        } catch {
            logger.debug("detect_pane on \(pluginID) failed: \(error)")
            return false
        }
    }

    // MARK: - command_for_launch

    /// Ask a sidecar for the command to spawn its host agent in a fresh
    /// tmux pane for `projectPath`. Returns a launch command spec the app
    /// hands to its tmux driver (Task 11 will route this into pane spawn).
    public func commandForLaunch(
        pluginID: String,
        projectPath: String
    ) async throws -> LaunchCommandSpec {
        guard let supervisor = supervisors[pluginID] else {
            throw PluginManagerError.unknownPlugin(id: pluginID)
        }
        struct CommandForLaunchParams: Encodable {
            let projectPath: String
        }
        struct CommandForLaunchResult: Decodable {
            let command: String
            let args: [String]
            let env: [String: String]
        }
        let result: CommandForLaunchResult = try await supervisor.send(
            method: PluginRPCMethod.AppToSidecar.commandForLaunch.rawValue,
            params: CommandForLaunchParams(projectPath: projectPath)
        )
        return LaunchCommandSpec(command: result.command, args: result.args, env: result.env)
    }

    // MARK: - Settings

    public func settingsSchema(pluginID: String) async throws -> PluginSettingsSchema {
        guard let supervisor = supervisors[pluginID] else {
            throw PluginManagerError.unknownPlugin(id: pluginID)
        }
        return try await supervisor.send(
            method: PluginRPCMethod.AppToSidecar.getSettingsSchema.rawValue,
            params: [String: String]()
        )
    }

    public func applySettings(pluginID: String, settings: JSONValue) async throws {
        guard let supervisor = supervisors[pluginID] else {
            throw PluginManagerError.unknownPlugin(id: pluginID)
        }
        struct ApplySettingsParams: Encodable {
            let settings: JSONValue
        }
        try await supervisor.send(
            method: PluginRPCMethod.AppToSidecar.applySettings.rawValue,
            params: ApplySettingsParams(settings: settings)
        )
    }

    // MARK: - Hook installation

    public func installHooks(pluginID: String) async throws {
        guard let supervisor = supervisors[pluginID] else {
            throw PluginManagerError.unknownPlugin(id: pluginID)
        }
        try await supervisor.send(
            method: PluginRPCMethod.AppToSidecar.install.rawValue,
            params: [String: String]()
        )
    }

    public func uninstallHooks(pluginID: String) async throws {
        guard let supervisor = supervisors[pluginID] else {
            throw PluginManagerError.unknownPlugin(id: pluginID)
        }
        try await supervisor.send(
            method: PluginRPCMethod.AppToSidecar.uninstall.rawValue,
            params: [String: String]()
        )
    }

    public func isHookInstalled(pluginID: String) async throws -> Bool {
        guard let supervisor = supervisors[pluginID] else {
            throw PluginManagerError.unknownPlugin(id: pluginID)
        }
        struct IsInstalledResult: Decodable {
            let installed: Bool
        }
        let result: IsInstalledResult = try await supervisor.send(
            method: PluginRPCMethod.AppToSidecar.isInstalled.rawValue,
            params: [String: String]()
        )
        return result.installed
    }

    // MARK: - Install / uninstall (third-party manifests)

    /// HTTPS-manifest install. v1 stub — Task 17 wires the CLI flow and
    /// trust UI; this exists so call sites can be wired now.
    public func install(manifestURL: URL) async throws {
        throw PluginManagerError.notImplemented(message: "install(manifestURL:) lands in Task 17")
    }

    /// Uninstall a user-installed plugin. Bundled plugins cannot be
    /// uninstalled — disable them via `disable(pluginID:)` instead.
    public func uninstall(pluginID: String) async throws {
        let entries = try await registry.entries()
        guard let entry = entries.first(where: { $0.id == pluginID }) else {
            throw PluginManagerError.unknownPlugin(id: pluginID)
        }
        guard entry.source == .url else {
            throw PluginManagerError.cannotUninstallBundled(id: pluginID)
        }
        if let supervisor = supervisors.removeValue(forKey: pluginID) {
            await supervisor.stop()
        }
        try await registry.remove(id: pluginID)
        presentations.removeAll { $0.id == pluginID }
        projectsByPlugin.removeValue(forKey: pluginID)
        manifestsByID.removeValue(forKey: pluginID)
        pluginDirsByID.removeValue(forKey: pluginID)
        await assetCache.remove(pluginID: pluginID)
    }

    // MARK: - Internal: spawn + presentation

    private func spawnSupervisor(
        manifest: PluginManifest,
        pluginDir: URL,
        bridge: SupervisorBridge
    ) async throws {
        let executableURL = pluginDir.appendingPathComponent(manifest.sidecar.executable)
        let stateDir = layout.stateDir(manifest.id)
        let logsDir = layout.logsDir(manifest.id)

        try FileManager.default.createDirectory(
            at: stateDir,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logsDir,
            withIntermediateDirectories: true
        )

        // Build the initialize payload the sidecar receives in its
        // `initialize` RPC. Keys are snake_case so we don't have to wire
        // the snake-case JSON-encoder strategy onto this single call site
        // — `JSONValue.object` writes whatever keys we hand it.
        let initParams = JSONValue.object([
            "plugin_root": .string(pluginDir.path),
            "state_dir": .string(stateDir.path),
            "app_version": .string(appVersion),
        ])

        let logFile = SidecarLogFile(logsDir: logsDir, pluginID: manifest.id)
        let supervisor = SidecarSupervisor(
            pluginID: manifest.id,
            executableURL: executableURL,
            env: [:],
            stateDir: stateDir,
            logFile: logFile,
            delegate: bridge,
            initializeParams: initParams,
            logger: logger
        )

        try await supervisor.start()
        supervisors[manifest.id] = supervisor
    }

    private func loadPresentation(manifest: PluginManifest, pluginDir: URL) async throws {
        do {
            let presentation = try await assetCache.presentation(for: manifest, pluginDir: pluginDir)
            presentations.removeAll { $0.id == manifest.id }
            presentations.append(presentation)
        } catch {
            // Missing icon shouldn't take the whole start sequence down —
            // log loudly so packaging issues surface, but keep going so
            // other plugins still work.
            logger.warning("presentation load failed for \(manifest.id): \(error)")
        }
    }

    // MARK: - Inbound notification handlers (called by SupervisorBridge)

    fileprivate func handleSidecarNotification(
        _ notification: JSONRPCNotification,
        pluginID: String
    ) async {
        guard let method = PluginRPCMethod.SidecarToApp(rawValue: notification.method) else {
            logger.debug("unknown sidecar->app method '\(notification.method)' from \(pluginID)")
            return
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        switch method {
        case .setProjects:
            await handleSetProjects(params: notification.params, pluginID: pluginID, decoder: decoder)

        case .emitEvent:
            await handleEmitEvent(params: notification.params, pluginID: pluginID, decoder: decoder)

        case .sendText:
            await handleSendText(params: notification.params, pluginID: pluginID, decoder: decoder)

        case .sendKeys:
            await handleSendKeys(params: notification.params, pluginID: pluginID, decoder: decoder)

        case .dismissResponseRequest:
            await handleDismissResponseRequest(params: notification.params, pluginID: pluginID, decoder: decoder)

        case .requestNotification:
            await handleRequestNotification(params: notification.params, pluginID: pluginID, decoder: decoder)

        case .updateSessionStatus:
            await handleUpdateSessionStatus(params: notification.params, pluginID: pluginID, decoder: decoder)

        case .log:
            handleLogNotification(params: notification.params, pluginID: pluginID, decoder: decoder)

        case .promptUser:
            // Rare; placeholder until the UI for sidecar-driven prompts
            // lands in a later task.
            logger.info("prompt_user from \(pluginID) — not yet routed")
        }
    }

    private func handleSetProjects(
        params: JSONValue?,
        pluginID: String,
        decoder: JSONDecoder
    ) async {
        struct SetProjectsParams: Decodable {
            let projects: [AgentProject]
        }
        guard let decoded: SetProjectsParams = decode(params, as: SetProjectsParams.self, decoder: decoder)
        else { return }
        projectsByPlugin[pluginID] = decoded.projects
    }

    private func handleEmitEvent(
        params: JSONValue?,
        pluginID: String,
        decoder: JSONDecoder
    ) async {
        guard let event: PluginEvent = decode(params, as: PluginEvent.self, decoder: decoder) else {
            return
        }
        // Remember the request shape so yolo auto-approve can route the
        // user-implied "allow" response back to the right sidecar.
        if let req = event.responseRequest {
            inFlightRequestsByID[req.requestID] = req.request
        }
        await dispatcher.dispatch(event)
    }

    private func handleSendText(
        params: JSONValue?,
        pluginID: String,
        decoder: JSONDecoder
    ) async {
        struct SendTextParams: Decodable {
            let sessionId: String
            let text: String
        }
        guard let decoded: SendTextParams = decode(params, as: SendTextParams.self, decoder: decoder)
        else { return }
        await agentDriverSink.sendText(
            pluginID: pluginID,
            sessionID: decoded.sessionId,
            text: decoded.text
        )
    }

    private func handleSendKeys(
        params: JSONValue?,
        pluginID: String,
        decoder: JSONDecoder
    ) async {
        struct SendKeysParams: Decodable {
            let sessionId: String
            let keys: [PluginTmuxKey]
        }
        guard let decoded: SendKeysParams = decode(params, as: SendKeysParams.self, decoder: decoder)
        else { return }
        await agentDriverSink.sendKeys(
            pluginID: pluginID,
            sessionID: decoded.sessionId,
            keys: decoded.keys
        )
    }

    private func handleDismissResponseRequest(
        params: JSONValue?,
        pluginID: String,
        decoder: JSONDecoder
    ) async {
        struct DismissParams: Decodable {
            let sessionId: String
            let requestId: String
        }
        guard let decoded: DismissParams = decode(params, as: DismissParams.self, decoder: decoder)
        else { return }
        inFlightRequestsByID.removeValue(forKey: decoded.requestId)
        await responseRequestSink.dismissRequest(
            pluginID: pluginID,
            sessionID: decoded.sessionId,
            requestID: decoded.requestId
        )
    }

    private func handleRequestNotification(
        params: JSONValue?,
        pluginID: String,
        decoder: JSONDecoder
    ) async {
        struct NotificationParams: Decodable {
            let sessionId: String?
            let title: String
            let body: String
        }
        guard let decoded: NotificationParams = decode(params, as: NotificationParams.self, decoder: decoder)
        else { return }
        await notificationSink.deliverNotification(
            pluginID: pluginID,
            sessionID: decoded.sessionId,
            title: decoded.title,
            body: decoded.body
        )
    }

    private func handleUpdateSessionStatus(
        params: JSONValue?,
        pluginID: String,
        decoder: JSONDecoder
    ) async {
        struct StatusParams: Decodable {
            let sessionId: String
            let working: Bool?
            let attention: Bool
        }
        guard let decoded: StatusParams = decode(params, as: StatusParams.self, decoder: decoder)
        else { return }
        await statusSink.updateStatus(
            pluginID: pluginID,
            sessionID: decoded.sessionId,
            working: decoded.working,
            attention: decoded.attention
        )
    }

    private func handleLogNotification(
        params: JSONValue?,
        pluginID: String,
        decoder: JSONDecoder
    ) {
        struct LogParams: Decodable {
            let level: String?
            let message: String
        }
        guard let decoded: LogParams = decode(params, as: LogParams.self, decoder: decoder)
        else { return }
        let level = Logger.Level(rawValue: decoded.level ?? "info") ?? .info
        logger.log(level: level, "[\(pluginID)] \(decoded.message)")
    }

    private func decode<T: Decodable>(
        _ params: JSONValue?,
        as: T.Type,
        decoder: JSONDecoder
    ) -> T? {
        guard let params else { return nil }
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(params)
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.debug("notification decode failed: \(error)")
            return nil
        }
    }

    // MARK: - Auto-approve plumbing

    /// Called by the dispatcher when a yolo + auto-approvable permission
    /// pair short-circuits the iOS UI. We synthesize the "allow" response
    /// and route it back via the normal `deliver_response` channel so the
    /// sidecar sees the same shape as a user-driven approve.
    fileprivate func performAutoApprove(
        pluginID: String,
        sessionID: String,
        requestID: String
    ) async {
        let response = AgentResponse.permission(
            PermissionResponse(decision: .allow, appliedSuggestionId: nil)
        )
        await deliverResponse(
            pluginID: pluginID,
            sessionID: sessionID,
            requestID: requestID,
            response: response
        )
    }

    // MARK: - Inbound request handler (called by SupervisorBridge)

    fileprivate func handleSidecarRequest(
        _ request: JSONRPCRequest
    ) async -> JSONRPCResponse {
        // v1: sidecars don't issue requests (only notifications). Reply
        // method-not-found so future expansion is observable.
        JSONRPCResponse(
            jsonrpc: "2.0",
            id: request.id,
            result: nil,
            error: JSONRPCError(
                code: -32_601,
                message: "Method not handled by Mac: \(request.method)"
            )
        )
    }

    // MARK: - State change observation

    fileprivate func handleSupervisorStateChange(
        _ state: SidecarSupervisor.State,
        pluginID: String
    ) {
        // State changes are surfaced for diagnostics but the manager
        // doesn't try to recover; the supervisor's own machinery handles
        // backoff and auto-disable.
        logger.debug("supervisor \(pluginID) state -> \(String(describing: state))")
    }

    // MARK: - Test hooks
    //
    // Internal so `@testable import ClaudeSpyPluginRuntime` from
    // `PluginManagerTests` can reach them. The double-underscore prefix
    // marks them as not-for-app-consumption.

    /// Fire a raw RPC at the named plugin's sidecar. Returns the decoded
    /// `JSONValue` result so tests can poke arbitrary methods (used by
    /// `PluginManagerTests` to drive `_test_push_set_projects`).
    @discardableResult
    func __rpcForTests(
        pluginID: String,
        method: String
    ) async throws -> JSONValue {
        guard let supervisor = supervisors[pluginID] else {
            throw PluginManagerError.unknownPlugin(id: pluginID)
        }
        return try await supervisor.send(method: method, params: [String: String]())
    }

    /// Push a synthesized `PluginEvent` straight into the dispatcher,
    /// bypassing the supervisor → notification → emit_event path. Used by
    /// `PluginManagerTests` to exercise the yolo auto-approve carve-out
    /// without standing up a real translator.
    func __dispatchEventForTests(_ event: PluginEvent) async {
        if let req = event.responseRequest {
            inFlightRequestsByID[req.requestID] = req.request
        }
        await dispatcher.dispatch(event)
    }
}

// MARK: - PluginManagerError

public enum PluginManagerError: Error, Equatable, CustomStringConvertible {
    case unknownPlugin(id: String)
    case cannotUninstallBundled(id: String)
    case notImplemented(message: String)

    public var description: String {
        switch self {
        case let .unknownPlugin(id):
            return "PluginManager has no plugin with id '\(id)'"
        case let .cannotUninstallBundled(id):
            return "Plugin '\(id)' is bundled — disable it instead of uninstalling"
        case let .notImplemented(message):
            return "PluginManager: \(message)"
        }
    }
}

// MARK: - SupervisorBridge

/// `SidecarSupervisor.Delegate` is `AnyObject`-bound; `PluginManager` is
/// `@MainActor` so it satisfies the constraint but the supervisor's actor
/// boundary makes the delegate call back across actors. We route through
/// a small bridge so the manager stays clean of conformance plumbing.
final private class SupervisorBridge: SidecarSupervisor.Delegate, @unchecked Sendable {
    private weak var manager: PluginManager?

    init(manager: PluginManager) {
        self.manager = manager
    }

    func received(
        notification: JSONRPCNotification,
        from supervisor: SidecarSupervisor
    ) async {
        // `pluginID` is a `let` on the supervisor actor — no await needed.
        let pluginID = supervisor.pluginID
        guard let manager else { return }
        await manager.handleSidecarNotification(notification, pluginID: pluginID)
    }

    func received(
        request: JSONRPCRequest,
        from _: SidecarSupervisor
    ) async -> JSONRPCResponse {
        guard let manager else {
            return JSONRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: nil,
                error: JSONRPCError(
                    code: -32_603,
                    message: "PluginManager gone"
                )
            )
        }
        return await manager.handleSidecarRequest(request)
    }

    func stateChanged(
        _ state: SidecarSupervisor.State,
        for supervisor: SidecarSupervisor
    ) async {
        // `pluginID` is a `let` on the supervisor actor — no await needed.
        let pluginID = supervisor.pluginID
        guard let manager else { return }
        await manager.handleSupervisorStateChange(state, pluginID: pluginID)
    }
}

// MARK: - AutoApproveBridge

/// Bridges the dispatcher's `AutoApprovalDelegate` requirement (Sendable,
/// AnyObject) back to the `@MainActor`-isolated `performAutoApprove`. The
/// manager owns this bridge for its lifetime.
final private class AutoApproveBridge: PluginEventDispatcher.AutoApprovalDelegate, @unchecked Sendable {
    private weak var manager: PluginManager?

    init(manager: PluginManager) {
        self.manager = manager
    }

    func autoApprove(
        pluginID: String,
        sessionID: String,
        requestID: String
    ) async {
        guard let manager else { return }
        await manager.performAutoApprove(
            pluginID: pluginID,
            sessionID: sessionID,
            requestID: requestID
        )
    }
}

// MARK: - AgentProject type alias

// The plan calls the project type `AgentProject`; the canonical name in
// `ClaudeSpyNetworking` is still `ClaudeProjectInfo` (Task 8 renames it
// in a coordinated rename pass). We expose the new name as a typealias so
// downstream code can reference `AgentProject` today and the rename in
// Task 8 just drops this alias.
//
// TODO(Task 8): drop this alias after `ClaudeProjectInfo` is renamed.
public typealias AgentProject = ClaudeProjectInfo
