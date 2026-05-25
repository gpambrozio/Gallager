#if os(macOS)
    import ClaudeCodePluginCore
    import Dependencies
    import Foundation
    import GallagerPluginProtocol
    import Logging

    // `ClaudeSpyNetworking` and `GallagerPluginProtocol` both declare
    // `JSONRPCRequest`/`JSONRPCResponse`/`JSONRPCError`. We narrow the
    // import to the value types we actually need so the JSON-RPC envelope
    // references unambiguously resolve to `GallagerPluginProtocol`'s.
    import struct ClaudeSpyNetworking.AgentProject
    import enum ClaudeSpyNetworking.AgentResponse
    import enum ClaudeSpyNetworking.AgentResponseRequest
    import enum ClaudeSpyNetworking.JSONValue

    // MARK: - ClaudeCodeSidecar

    /// Top-level Claude Code sidecar orchestrator (Spec §6).
    ///
    /// Owns the JSON-RPC loop bound to stdin/stdout, the ingress socket
    /// server for hook bridge scripts, the FSEvents-backed project
    /// watcher, the event translator, the keystroke builder, and the
    /// per-session request store. `run()` exits cleanly on `shutdown` RPC
    /// or stdin EOF.
    ///
    /// Concurrency note: the orchestrator is `@MainActor` because the
    /// state transitions (registering handlers, mounting per-session
    /// state, tearing down the watcher on shutdown) only need a single
    /// serial executor and we'd rather route everything through one actor
    /// than coordinate three. Heavy work (project scans, RPC handler
    /// closures) hops to detached tasks when needed.
    @MainActor
    final class ClaudeCodeSidecar {
        // MARK: - State

        private let logger: Logger
        private let dispatcher: RPCDispatcher
        private let translator: ClaudeCodeEventTranslator
        private let keystrokeBuilder: ClaudeCodeKeystrokeBuilder
        private let requestStore: PluginRequestStore
        private let stdin: FileHandle
        private let stdout: FileHandle
        private let writeQueue: WriteQueue
        private let encoder: JSONEncoder
        private let decoder: JSONDecoder

        private var pluginRoot: URL?
        private var stateDir: URL?
        private var appVersion: String?

        private var ingressServer: IngressSocketServer?
        private var ingressTask: Task<Void, Never>?
        private var ingressErrorTask: Task<Void, Never>?
        private var projectWatcher: FSEventsProjectWatcher?
        private var shouldShutdown = false

        // MARK: - Init

        init(
            stdin: FileHandle = .standardInput,
            stdout: FileHandle = .standardOutput,
            logger: Logger? = nil
        ) {
            let logger = logger ?? Logger(label: "claude-code.sidecar")
            self.logger = logger
            self.stdin = stdin
            self.stdout = stdout
            self.writeQueue = WriteQueue(handle: stdout, logger: logger)
            self.dispatcher = RPCDispatcher(logger: logger)
            self.translator = ClaudeCodeEventTranslator(logger: logger)
            self.keystrokeBuilder = ClaudeCodeKeystrokeBuilder()
            self.requestStore = PluginRequestStore()

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            self.encoder = encoder

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            self.decoder = decoder
        }

        // MARK: - Entry point

        /// Register the RPC handler table, start the inbound loop, and run
        /// until stdin EOF or a `shutdown` RPC arrives.
        func run() async throws {
            await registerHandlers()
            try await readLoop()
            await tearDown()
        }

        // MARK: - Handler registration

        private func registerHandlers() async {
            // Lift each handler out into a typed closure so the dispatcher
            // table stays readable. Each handler is responsible for its
            // own decoding/encoding of params/result.

            await dispatcher.register(PluginRPCMethod.AppToSidecar.initialize.rawValue) { [weak self] params in
                guard let self else { return nil }
                return try await self.handleInitialize(params: params)
            }

            await dispatcher.register(PluginRPCMethod.AppToSidecar.shutdown.rawValue) { [weak self] _ in
                guard let self else { return nil }
                await self.handleShutdown()
                return .object([:])
            }

            await dispatcher.register(PluginRPCMethod.AppToSidecar.refreshProjects.rawValue) { [weak self] _ in
                guard let self else { return nil }
                await self.scanAndPushProjects()
                return .null
            }

            await dispatcher.register(PluginRPCMethod.AppToSidecar.install.rawValue) { [weak self] params in
                guard let self else { return nil }
                return try await self.handleInstall(params: params)
            }

            await dispatcher.register(PluginRPCMethod.AppToSidecar.uninstall.rawValue) { [weak self] params in
                guard let self else { return nil }
                return try await self.handleUninstall(params: params)
            }

            await dispatcher.register(PluginRPCMethod.AppToSidecar.isInstalled.rawValue) { [weak self] params in
                guard let self else { return nil }
                return try await self.handleIsInstalled(params: params)
            }

            await dispatcher.register(PluginRPCMethod.AppToSidecar.translateEvent.rawValue) { [weak self] params in
                guard let self else { return nil }
                return try await self.handleTranslateEvent(params: params)
            }

            await dispatcher.register(PluginRPCMethod.AppToSidecar.deliverResponse.rawValue) { [weak self] params in
                guard let self else { return nil }
                try await self.handleDeliverResponse(params: params)
                return .null
            }

            await dispatcher.register(PluginRPCMethod.AppToSidecar.getSettingsSchema.rawValue) { [weak self] _ in
                guard let self else { return nil }
                return try await self.handleGetSettingsSchema()
            }

            await dispatcher.register(PluginRPCMethod.AppToSidecar.applySettings.rawValue) { [weak self] params in
                guard let self else { return nil }
                return try await self.handleApplySettings(params: params)
            }

            await dispatcher.register(PluginRPCMethod.AppToSidecar.commandForLaunch.rawValue) { [weak self] params in
                guard let self else { return nil }
                return try await self.handleCommandForLaunch(params: params)
            }

            await dispatcher.register(PluginRPCMethod.AppToSidecar.health.rawValue) { _ in
                .object(["ok": .bool(true)])
            }
        }

        // MARK: - Read loop

        private func readLoop() async throws {
            // `FileHandle.AsyncBytes` (the stdlib `.bytes` property) doesn't
            // deliver pipe bytes until the writer closes. The sidecar talks
            // to the Mac across a live pipe, so we use the
            // readabilityHandler-based stream instead.
            let bytes = stdin.makeAsyncByteStream()
            while !shouldShutdown {
                let body: Data
                do {
                    body = try await JSONRPCFramer.read(from: bytes)
                } catch {
                    // EOF or framing error — exit the loop cleanly.
                    logger.info("stdin closed: \(error)")
                    break
                }

                let message: JSONRPCMessage
                do {
                    message = try decoder.decode(JSONRPCMessage.self, from: body)
                } catch {
                    logger.warning("malformed JSON-RPC body: \(error)")
                    continue
                }

                switch message {
                case let .request(request):
                    let response = await dispatcher.handle(request)
                    await writeMessage(.response(response))
                case .notification,
                     .response:
                    // The app currently never sends notifications or
                    // responses to the sidecar; log and drop.
                    logger.debug("unexpected inbound message kind: \(message)")
                }
            }
        }

        private func tearDown() async {
            ingressTask?.cancel()
            ingressErrorTask?.cancel()
            ingressTask = nil
            ingressErrorTask = nil
            await ingressServer?.stop()
            ingressServer = nil
            await projectWatcher?.stop()
            projectWatcher = nil
        }

        // MARK: - Handlers

        private func handleInitialize(params: JSONValue?) async throws -> JSONValue {
            struct InitParams: Decodable {
                let pluginRoot: String
                let stateDir: String
                let appVersion: String?
            }

            guard let params else {
                throw RPCDispatcherError.invalidParams("initialize requires params")
            }
            let decoded = try decode(params, as: InitParams.self)

            let pluginRootURL = URL(fileURLWithPath: decoded.pluginRoot, isDirectory: true)
            let stateDirURL = URL(fileURLWithPath: decoded.stateDir, isDirectory: true)

            try FileManager.default.createDirectory(
                at: stateDirURL,
                withIntermediateDirectories: true
            )

            pluginRoot = pluginRootURL
            stateDir = stateDirURL
            appVersion = decoded.appVersion

            // Start the ingress socket + project watcher inside initialize
            // so the Mac knows the sidecar is fully ready by the time the
            // response lands.
            try await startIngress(stateDir: stateDirURL)
            await startProjectWatcher()

            // Kick an initial scan so the Mac gets a fresh `set_projects`
            // promptly, without having to wait for the first FSEvent fire.
            Task { @MainActor [weak self] in
                await self?.scanAndPushProjects()
            }

            // Per Spec §6.1: return `{ capabilities, schemas }`. The
            // capabilities mirror the manifest's declared bits — the Mac
            // can use whichever source of truth it prefers. `schemas` is
            // reserved for future plugin-supplied JSON schemas; the
            // bundled Claude plugin doesn't add any beyond the settings
            // form served via `get_settings_schema`.
            let capabilities = JSONValue.object([
                "pushes_projects": .bool(true),
                "translate_event": .bool(true),
                "install": .bool(true),
                "detect_pane": .bool(false),
                "settings_schema": .string("ui/settings.json"),
                "requires_rich_detection": .bool(false),
            ])
            return .object([
                "capabilities": capabilities,
                "schemas": .object([:]),
            ])
        }

        private func handleShutdown() async {
            shouldShutdown = true
        }

        private func handleInstall(params: JSONValue?) async throws -> JSONValue {
            struct InstallParams: Decodable {
                let claudeBin: String?
                let pluginRoot: String?
            }

            let decoded: InstallParams? = params.flatMap { try? decode($0, as: InstallParams.self) }
            let pluginRoot = decoded?.pluginRoot
                .map { URL(fileURLWithPath: $0) }
                ?? self.pluginRoot

            guard let pluginRoot else {
                throw RPCDispatcherError.invalidParams("install requires a known plugin_root")
            }

            let claudeBin = try await resolveClaudeBin(override: decoded?.claudeBin)
            @Dependency(ClaudeCodeInstaller.self) var installer
            let status = try await installer.install(pluginRoot, claudeBin, nil)
            switch status {
            case .ok:
                return .object([
                    "status": .string("ok"),
                ])
            case let .failed(message):
                return .object([
                    "status": .string("failed"),
                    "message": .string(message),
                ])
            }
        }

        private func handleUninstall(params: JSONValue?) async throws -> JSONValue {
            struct UninstallParams: Decodable {
                let claudeBin: String?
            }
            let decoded: UninstallParams? = params.flatMap {
                try? decode($0, as: UninstallParams.self)
            }
            let claudeBin = try await resolveClaudeBin(override: decoded?.claudeBin)
            @Dependency(ClaudeCodeInstaller.self) var installer
            let status = try await installer.uninstall(claudeBin, nil)
            switch status {
            case .ok:
                return .object([
                    "status": .string("ok"),
                ])
            case let .failed(message):
                return .object([
                    "status": .string("failed"),
                    "message": .string(message),
                ])
            }
        }

        private func handleIsInstalled(params: JSONValue?) async throws -> JSONValue {
            struct IsInstalledParams: Decodable {
                let claudeConfigDir: String?
            }
            let decoded: IsInstalledParams? = params.flatMap {
                try? decode($0, as: IsInstalledParams.self)
            }
            let configDir = decoded?.claudeConfigDir.map { URL(fileURLWithPath: $0) }
            @Dependency(ClaudeCodeInstaller.self) var installer
            let installed = await installer.isInstalled(configDir)
            return .object(["installed": .bool(installed)])
        }

        private func handleTranslateEvent(params: JSONValue?) async throws -> JSONValue {
            struct TranslateParams: Decodable {
                let context: [String: String]
                let payload: JSONValue
            }
            guard let params else {
                throw RPCDispatcherError.invalidParams("translate_event requires params")
            }
            let decoded = try decode(params, as: TranslateParams.self)
            let ctx = IngressContext(envMap: decoded.context)
            guard
                let event = try await translator.translate(
                    rawPayload: decoded.payload,
                    context: ctx,
                    requestStore: requestStore
                ) else {
                return .null
            }
            return try encodeAsJSONValue(event)
        }

        private func handleDeliverResponse(params: JSONValue?) async throws {
            struct DeliverParams: Decodable {
                let sessionId: String
                let requestId: String
                let response: AgentResponse
            }
            guard let params else {
                throw RPCDispatcherError.invalidParams("deliver_response requires params")
            }
            let decoded = try decode(params, as: DeliverParams.self)

            let original = await requestStore.consume(requestID: decoded.requestId)
            let steps = buildKeystrokes(
                response: decoded.response,
                request: original
            )
            for step in steps {
                await emitKeystroke(step: step, sessionID: decoded.sessionId)
            }
        }

        private func handleGetSettingsSchema() async throws -> JSONValue {
            guard let pluginRoot else {
                throw RPCDispatcherError.invalidParams("initialize must run before get_settings_schema")
            }
            let schemaURL = pluginRoot
                .appendingPathComponent("ui")
                .appendingPathComponent("settings.json")
            guard FileManager.default.fileExists(atPath: schemaURL.path) else {
                throw RPCDispatcherError.internalError("settings.json not found at \(schemaURL.path)")
            }
            do {
                let data = try Data(contentsOf: schemaURL)
                return try decoder.decode(JSONValue.self, from: data)
            } catch {
                throw RPCDispatcherError.internalError("settings.json: \(error)")
            }
        }

        private func handleApplySettings(params: JSONValue?) async throws -> JSONValue {
            struct ApplyParams: Decodable {
                let settings: JSONValue
            }
            guard let params else {
                throw RPCDispatcherError.invalidParams("apply_settings requires params")
            }
            let decoded = try decode(params, as: ApplyParams.self)
            let settings: ClaudeCodeSettings
            do {
                settings = try ClaudeCodeSettings.decode(from: decoded.settings)
            } catch {
                return .object([
                    "status": .string("error"),
                    "message": .string("invalid settings: \(error)"),
                ])
            }
            if let validation = settings.validate() {
                return .object([
                    "status": .string("error"),
                    "message": .string(String(describing: validation)),
                ])
            }
            guard let stateDir else {
                throw RPCDispatcherError.invalidParams("initialize must run before apply_settings")
            }
            do {
                let settingsURL = stateDir.appendingPathComponent("settings.json")
                let encoded = try encoder.encode(settings)
                try encoded.write(to: settingsURL, options: .atomic)
            } catch {
                return .object([
                    "status": .string("error"),
                    "message": .string("write failed: \(error)"),
                ])
            }
            return .object(["status": .string("ok")])
        }

        private func handleCommandForLaunch(params: JSONValue?) async throws -> JSONValue {
            struct CommandParams: Decodable {
                let projectPath: String?
                let claudeConfigDir: String?
            }
            let decoded: CommandParams? = params.flatMap {
                try? decode($0, as: CommandParams.self)
            }
            let settings = loadSettings()
            let resolver = ClaudeCodeLaunchCommandResolver()
            do {
                let command = try await resolver.resolve(
                    settings: settings,
                    projectPath: decoded?.projectPath,
                    claudeConfigDir: decoded?.claudeConfigDir
                )
                let env = command.env.mapValues { JSONValue.string($0) }
                return .object([
                    "command": .string(command.command),
                    "args": .array(command.args.map(JSONValue.string)),
                    "env": .object(env),
                ])
            } catch {
                throw RPCDispatcherError.internalError(String(describing: error))
            }
        }

        // MARK: - Ingress

        private func startIngress(stateDir: URL) async throws {
            let socketURL = stateDir.appendingPathComponent("ingress.sock")
            let server = IngressSocketServer(socketURL: socketURL)
            ingressServer = server
            let frames = try await server.start()
            let errors = await server.parseErrors()

            ingressTask = Task { [weak self] in
                for await frame in frames {
                    await self?.handleIngressFrame(frame)
                }
            }
            let errorLogger = logger
            ingressErrorTask = Task {
                for await error in errors {
                    errorLogger.warning("ingress parse error (dropping frame): \(error)")
                }
            }
            logger.info("ingress socket listening at \(socketURL.path)")
        }

        private func handleIngressFrame(_ frame: IngressFrame) async {
            let ctx = IngressContext(envMap: frame.context)
            do {
                guard
                    let event = try await translator.translate(
                        rawPayload: frame.payload,
                        context: ctx,
                        requestStore: requestStore
                    ) else { return }
                await emitEvent(event)
            } catch {
                logger.warning("ingress translate failed: \(error)")
            }
        }

        // MARK: - Project watcher

        private func startProjectWatcher() async {
            let watchPaths = projectWatchPaths()
            let watcher = FSEventsProjectWatcher(
                paths: watchPaths,
                dispatchQueueLabel: "gallager.plugin.claude.fsevents",
                logger: logger
            )
            projectWatcher = watcher
            do {
                try await watcher.start { [weak self] in
                    await self?.scanAndPushProjects()
                }
            } catch {
                logger.warning("fsevents watcher failed (continuing without): \(error)")
            }
        }

        /// Directories whose changes should trigger a project re-scan.
        /// The default `~/.claude/projects/` plus any additional
        /// Claude folders the user configured.
        private func projectWatchPaths() -> [URL] {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return [
                home.appendingPathComponent(".claude")
                    .appendingPathComponent("projects"),
            ]
        }

        private func scanAndPushProjects() async {
            @Dependency(ClaudeProjectScanner.self) var scanner
            let projects = await scanner.scanProjects()
            do {
                let projectsValue = try encodeAsJSONValue(projects)
                let params = JSONValue.object([
                    "projects": projectsValue,
                ])
                await emit(method: PluginRPCMethod.SidecarToApp.setProjects.rawValue, params: params)
            } catch {
                logger.warning("set_projects encode failed: \(error)")
            }
        }

        // MARK: - Outbound notifications

        private func emitEvent(_ event: PluginEvent) async {
            do {
                let params = try encodeAsJSONValue(event)
                await emit(method: PluginRPCMethod.SidecarToApp.emitEvent.rawValue, params: params)
            } catch {
                logger.warning("emit_event encode failed: \(error)")
            }
        }

        private func emit(method: String, params: JSONValue) async {
            let notification = JSONRPCNotification(
                jsonrpc: "2.0",
                method: method,
                params: params
            )
            await writeMessage(.notification(notification))
        }

        private func writeMessage(_ message: JSONRPCMessage) async {
            do {
                let body = try encoder.encode(message)
                let frame = JSONRPCFramer.encode(body)
                await writeQueue.write(frame)
            } catch {
                logger.warning("encode outbound message failed: \(error)")
            }
        }

        // MARK: - Keystrokes

        private func buildKeystrokes(
            response: AgentResponse,
            request: AgentResponseRequest?
        ) -> [KeystrokeStep] {
            switch response {
            case let .prompt(body):
                return keystrokeBuilder.keystrokes(forText: body.text)
            case let .replyAfterStop(body):
                return keystrokeBuilder.keystrokes(forText: body.text)
            case let .permission(body):
                guard case let .permission(req) = request else {
                    // No remembered original — fall back to a bare allow/deny.
                    return keystrokeBuilder.keystrokes(
                        for: body,
                        matching: .init(
                            toolName: nil,
                            description: "",
                            suggestions: [],
                            isAutoApprovable: false
                        )
                    )
                }
                return keystrokeBuilder.keystrokes(for: body, matching: req)
            case let .askUserQuestion(body):
                guard case let .askUserQuestion(req) = request else {
                    return []
                }
                return keystrokeBuilder.keystrokes(for: body, matching: req)
            case let .approvePlan(body):
                guard case let .approvePlan(req) = request else {
                    return keystrokeBuilder.keystrokes(
                        for: body,
                        matching: .init(plan: "", allowEdit: false)
                    )
                }
                return keystrokeBuilder.keystrokes(for: body, matching: req)
            }
        }

        private func emitKeystroke(step: KeystrokeStep, sessionID: String) async {
            switch step {
            case let .keys(keys):
                let keysArray = JSONValue.array(keys.map { JSONValue.string($0.rawValue) })
                await emit(
                    method: PluginRPCMethod.SidecarToApp.sendKeys.rawValue,
                    params: .object([
                        "session_id": .string(sessionID),
                        "keys": keysArray,
                    ])
                )
            case let .text(text):
                await emit(
                    method: PluginRPCMethod.SidecarToApp.sendText.rawValue,
                    params: .object([
                        "session_id": .string(sessionID),
                        "text": .string(text),
                    ])
                )
            case let .wait(duration):
                let ms = Int(
                    Double(duration.components.seconds) * 1_000
                        + Double(duration.components.attoseconds) / 1E15
                )
                try? await Task.sleep(for: .milliseconds(ms))
            }
        }

        // MARK: - Settings helpers

        private func loadSettings() -> ClaudeCodeSettings {
            guard
                let stateDir,
                let data = try? Data(contentsOf: stateDir.appendingPathComponent("settings.json")),
                let settings = try? JSONDecoder().decode(ClaudeCodeSettings.self, from: data)
            else {
                return ClaudeCodeSettings()
            }
            return settings
        }

        private func resolveClaudeBin(override: String?) async throws -> URL {
            if let override, !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            @Dependency(ClaudeBinaryLocator.self) var locator
            if let found = await locator.find() {
                return URL(fileURLWithPath: found)
            }
            throw RPCDispatcherError.internalError("claude binary not found on PATH or common locations")
        }

        // MARK: - JSONValue bridge

        private func decode<T: Decodable>(_ value: JSONValue, as: T.Type) throws -> T {
            let data = try encoder.encode(value)
            return try decoder.decode(T.self, from: data)
        }

        private func encodeAsJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
            let data = try encoder.encode(value)
            return try decoder.decode(JSONValue.self, from: data)
        }
    }

    // MARK: - WriteQueue

    /// Serial writer for stdout. `FileHandle.write` is blocking and not
    /// safe to call from multiple tasks concurrently — the sidecar emits
    /// notifications from a variety of places (ingress task, FSEvents
    /// task, RPC handlers), and a serial queue keeps frames from
    /// interleaving on the wire.
    actor WriteQueue {
        private let handle: FileHandle
        private let logger: Logger

        init(handle: FileHandle, logger: Logger) {
            self.handle = handle
            self.logger = logger
        }

        func write(_ data: Data) {
            do {
                try handle.write(contentsOf: data)
            } catch {
                logger.warning("stdout write failed: \(error)")
            }
        }
    }
#endif
