import Foundation
import GallagerPluginProtocol
import Logging

// `ClaudeSpyNetworking` and `GallagerPluginProtocol` both declare
// `JSONRPCRequest`/`JSONRPCResponse`/`JSONRPCError`/`JSONRPCNotification`.
// Importing only the value types we need from `ClaudeSpyNetworking`
// keeps the JSON-RPC envelope references unambiguous — the
// `GallagerPluginProtocol` framing types win in this file. Mirrors the
// strategy used by `ClaudeCodePluginSidecar/ClaudeCodeSidecar.swift`.
import struct ClaudeSpyNetworking.AgentProject
import enum ClaudeSpyNetworking.AgentResponse
import enum ClaudeSpyNetworking.AgentResponseRequest
import enum ClaudeSpyNetworking.AppAction
import struct ClaudeSpyNetworking.ApprovePlanRequest
import struct ClaudeSpyNetworking.AskUserQuestionRequest
import enum ClaudeSpyNetworking.JSONValue
import struct ClaudeSpyNetworking.PermissionRequest

/// Programmable echo sidecar used by Task 25's plugin E2E scenarios
/// (Spec §15.5).
///
/// Behaviour summary:
///  - On `initialize`: opens an ingress socket at
///    `${state_dir}/ingress.sock`, decodes the `ECHO_PROJECTS_JSON` env var
///    (defaults to empty list), and pushes a `set_projects` callback.
///  - On `translate_event` (or any ingress-socket frame): inspects the
///    payload for a `_test` discriminator and emits the matching
///    `PluginEvent` (`set_status`, `notify`, `request_permission`,
///    `request_ask_user_question`, `request_approve_plan`,
///    `open_file_suggestion`, `set_projects`, `crash`). Without a `_test`
///    key the call is a no-op and `translate_event` returns null.
///  - On `deliver_response`: writes the JSON-encoded response to
///    `${state_dir}/responses/<request_id>.json` and replays an optional
///    `_delivery_script` array of `{type: "send_text" | "send_keys", ...}`
///    by issuing matching `send_text` / `send_keys` callbacks. The delivery
///    script is recorded on the original payload via `remember(...)`.
///  - On `refresh_projects`: re-sends the configured project list.
///  - On `install` / `uninstall`: writes/removes a marker file in
///    `${state_dir}` and returns `{ status: "ok" }`.
///  - On `is_installed`: always `true`.
///  - On `get_settings_schema`: reads `${plugin_root}/ui/settings.json`.
///  - On `apply_settings`: validates as JSON, persists to
///    `${state_dir}/settings.json`, returns `{ status: "ok" }`.
///  - On `command_for_launch`: returns a fixed `echo echo-fake-launch`
///    invocation so tests have a deterministic stub.
///  - On `health`: `{ ok: true }`.
///  - On `shutdown`: tears the ingress server down and exits the read
///    loop.
@MainActor
final class EchoSidecar {
    // MARK: - State

    private let pluginID = "echo"
    private let logger: Logger
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let writeQueue: WriteQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var pluginRoot: URL?
    private var stateDir: URL?

    /// Sequence number for response-request IDs the sidecar mints when a
    /// `_test: "request_*"` payload arrives.
    private var requestCounter = 0

    /// In-memory projects list pushed via `set_projects`. Updated by the
    /// `ECHO_PROJECTS_JSON` env var on `initialize` and by
    /// `_test: "set_projects"` payloads.
    private var projects: [AgentProject] = []

    /// Remembers the original `translate_event` payload (verbatim) keyed
    /// by the request id we minted. `deliver_response` reads
    /// `_delivery_script` off this remembered payload, since the Mac side
    /// only echoes back `request_id` + the user's `AgentResponse`.
    private var rememberedPayloads: [String: JSONValue] = [:]

    private var ingressServer: IngressSocketServer?
    private var ingressTask: Task<Void, Never>?
    private var ingressErrorTask: Task<Void, Never>?
    private var shouldShutdown = false

    // MARK: - Init

    init(
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput,
        logger: Logger? = nil
    ) {
        let logger = logger ?? Logger(label: "echo.sidecar")
        self.logger = logger
        self.stdin = stdin
        self.stdout = stdout
        self.writeQueue = WriteQueue(handle: stdout, logger: logger)

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

    func run() async throws {
        let bytes = stdin.makeAsyncByteStream()
        while !shouldShutdown {
            let body: Data
            do {
                body = try await JSONRPCFramer.read(from: bytes)
            } catch {
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
                await handleRequest(request)
            case .notification,
                 .response:
                // The app currently never sends notifications or responses
                // to the sidecar; log and drop.
                logger.debug("unexpected inbound message: \(message)")
            }
        }
        await tearDown()
    }

    // MARK: - Request dispatch

    private func handleRequest(_ request: JSONRPCRequest) async {
        let method = request.method
        do {
            let result = try await dispatch(method: method, params: request.params)
            await writeMessage(.response(JSONRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: result ?? .null,
                error: nil
            )))
        } catch let rpc as RPCError {
            await writeMessage(.response(JSONRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: nil,
                error: rpc.asRPCError()
            )))
        } catch {
            await writeMessage(.response(JSONRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: nil,
                error: JSONRPCError(
                    code: -32_603,
                    message: "Internal error: \(error)"
                )
            )))
        }
    }

    private func dispatch(method: String, params: JSONValue?) async throws -> JSONValue? {
        guard let rpc = PluginRPCMethod.AppToSidecar(rawValue: method) else {
            throw RPCError.custom(
                code: -32_601,
                message: "Method not found: \(method)"
            )
        }
        switch rpc {
        case .initialize:
            return try await handleInitialize(params: params)
        case .shutdown:
            await handleShutdown()
            return .object([:])
        case .refreshProjects:
            await scanAndPushProjects()
            return .null
        case .detectPane:
            return .null
        case .install:
            return try await handleInstall()
        case .uninstall:
            return try await handleUninstall()
        case .isInstalled:
            return .object(["installed": .bool(true)])
        case .translateEvent:
            return try await handleTranslateEvent(params: params)
        case .deliverResponse:
            try await handleDeliverResponse(params: params)
            return .null
        case .getSettingsSchema:
            return try await handleGetSettingsSchema()
        case .applySettings:
            return try await handleApplySettings(params: params)
        case .commandForLaunch:
            return handleCommandForLaunch()
        case .health:
            return .object(["ok": .bool(true)])
        }
    }

    // MARK: - Handlers

    private func handleInitialize(params: JSONValue?) async throws -> JSONValue {
        struct InitParams: Decodable {
            let pluginRoot: String
            let stateDir: String
            let appVersion: String?
        }
        guard let params else {
            throw RPCError.invalidParams("initialize requires params")
        }
        let decoded = try decode(params, as: InitParams.self)

        let pluginRootURL = URL(fileURLWithPath: decoded.pluginRoot, isDirectory: true)
        let stateDirURL = URL(fileURLWithPath: decoded.stateDir, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDirURL,
            withIntermediateDirectories: true
        )
        // Pre-create the responses bucket so `handleDeliverResponse` can
        // write straight into it without one of the early scenarios racing
        // a still-pending `createDirectory`.
        try FileManager.default.createDirectory(
            at: stateDirURL.appendingPathComponent("responses", isDirectory: true),
            withIntermediateDirectories: true
        )
        pluginRoot = pluginRootURL
        stateDir = stateDirURL

        // Load the initial project list from the env var. Scenarios use
        // this to pre-seed the projects mirror without going through the
        // _test/translate_event path first.
        if let raw = ProcessInfo.processInfo.environment["ECHO_PROJECTS_JSON"] {
            let data = Data(raw.utf8)
            do {
                let projects = try decoder.decode([AgentProject].self, from: data)
                self.projects = projects
            } catch {
                logger.warning("ECHO_PROJECTS_JSON decode failed: \(error)")
            }
        }

        try await startIngress(stateDir: stateDirURL)

        // Push the initial list before the initialize response lands so
        // the Mac has the projects ready as soon as it knows the plugin
        // is up.
        await scanAndPushProjects()

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

    private func handleInstall() async throws -> JSONValue {
        guard let stateDir else {
            throw RPCError.invalidParams("install requires initialize")
        }
        let marker = stateDir.appendingPathComponent("installed.marker")
        try Data().write(to: marker)
        return .object(["status": .string("ok")])
    }

    private func handleUninstall() async throws -> JSONValue {
        guard let stateDir else {
            throw RPCError.invalidParams("uninstall requires initialize")
        }
        let marker = stateDir.appendingPathComponent("installed.marker")
        try? FileManager.default.removeItem(at: marker)
        return .object(["status": .string("ok")])
    }

    private func handleTranslateEvent(params: JSONValue?) async throws -> JSONValue {
        struct TranslateParams: Decodable {
            let context: [String: String]
            let payload: JSONValue
        }
        guard let params else {
            throw RPCError.invalidParams("translate_event requires params")
        }
        let decoded = try decode(params, as: TranslateParams.self)
        guard
            let event = try processControlPayload(
                payload: decoded.payload,
                context: decoded.context
            ) else {
            return .null
        }
        return try encodeAsJSONValue(event)
    }

    /// Handle an ingress-socket frame the same way `translate_event` does.
    /// Ingress frames are an alternative way for the test harness to drive
    /// the sidecar (via the bridge-script socket); their semantics match
    /// `translate_event` so scenarios can mix and match.
    private func handleIngressFrame(_ frame: IngressFrame) async {
        do {
            guard
                let event = try processControlPayload(
                    payload: frame.payload,
                    context: frame.context
                ) else { return }
            await emitEvent(event)
        } catch {
            logger.warning("ingress translate failed: \(error)")
        }
    }

    /// Core `_test` dispatcher shared by `translate_event` and the ingress
    /// socket. Returns `nil` when the payload should not surface a
    /// `PluginEvent` (e.g. `_test: "set_projects"` only fires a callback).
    private func processControlPayload(
        payload: JSONValue,
        context: [String: String]
    ) throws -> PluginEvent? {
        guard case let .object(dict) = payload else { return nil }
        guard case let .string(testKey) = dict["_test"] ?? .null else {
            return nil
        }
        // The session id is either in the payload or, failing that, the
        // tmux pane id from the ingress context. Both fall back to a
        // synthetic "echo-session" so tests don't have to wire either.
        let sessionID: String = {
            if case let .string(value) = dict["session_id"] ?? .null {
                return value
            }
            return context["TMUX_PANE"] ?? "echo-session"
        }()
        // Every PluginEvent we emit carries the tmux pane from the bridge
        // context (when present). The Mac uses this to bootstrap an
        // `AgentSession` for non-bundled plugins where process-name
        // detection didn't fire.
        let tmuxPane: String? = {
            if let value = context["TMUX_PANE"], !value.isEmpty {
                return value
            }
            return nil
        }()

        switch testKey {
        case "set_status":
            var working: Bool?
            if case let .bool(value) = dict["working"] ?? .null {
                working = value
            }
            var attention = false
            if case let .bool(value) = dict["attention"] ?? .null {
                attention = value
            }
            return PluginEvent(
                pluginID: pluginID,
                sessionID: sessionID,
                working: working,
                attention: attention,
                notification: nil,
                responseRequest: nil,
                tmuxPane: tmuxPane
            )

        case "notify":
            let title = (dict["title"]?.stringValue) ?? ""
            let body = (dict["body"]?.stringValue) ?? ""
            return PluginEvent(
                pluginID: pluginID,
                sessionID: sessionID,
                working: nil,
                attention: true,
                notification: PluginEvent.NotificationSpec(title: title, body: body),
                responseRequest: nil,
                tmuxPane: tmuxPane
            )

        case "request_permission":
            let toolName = dict["tool_name"]?.stringValue
            let description = dict["description"]?.stringValue ?? "Echo permission"
            let isAutoApprovable = dict["is_auto_approvable"]?.boolValue ?? false
            let suggestions: [PermissionRequest.Suggestion] = {
                guard case let .array(items) = dict["suggestions"] ?? .null else { return [] }
                return items.compactMap { item -> PermissionRequest.Suggestion? in
                    guard case let .object(s) = item else { return nil }
                    guard
                        case let .string(id) = s["id"] ?? .null,
                        case let .string(label) = s["label"] ?? .null
                    else { return nil }
                    let badge = s["badge"]?.stringValue
                    return PermissionRequest.Suggestion(
                        id: id,
                        label: label,
                        badge: badge
                    )
                }
            }()
            let requestID = mintRequestID()
            rememberedPayloads[requestID] = payload
            let req = AgentResponseRequest.permission(
                PermissionRequest(
                    toolName: toolName,
                    description: description,
                    suggestions: suggestions,
                    isAutoApprovable: isAutoApprovable
                )
            )
            return PluginEvent(
                pluginID: pluginID,
                sessionID: sessionID,
                working: nil,
                attention: true,
                notification: nil,
                responseRequest: PluginEvent.ResponseRequestPayload(
                    requestID: requestID,
                    request: req
                ),
                tmuxPane: tmuxPane
            )

        case "request_ask_user_question":
            let questions = decodeQuestions(from: dict["questions"])
            let requestID = mintRequestID()
            rememberedPayloads[requestID] = payload
            let req = AgentResponseRequest.askUserQuestion(
                AskUserQuestionRequest(questions: questions)
            )
            return PluginEvent(
                pluginID: pluginID,
                sessionID: sessionID,
                working: nil,
                attention: true,
                notification: nil,
                responseRequest: PluginEvent.ResponseRequestPayload(
                    requestID: requestID,
                    request: req
                ),
                tmuxPane: tmuxPane
            )

        case "request_approve_plan":
            let plan = dict["plan"]?.stringValue ?? ""
            let allowEdit = dict["allow_edit"]?.boolValue ?? false
            let requestID = mintRequestID()
            rememberedPayloads[requestID] = payload
            let req = AgentResponseRequest.approvePlan(
                ApprovePlanRequest(plan: plan, allowEdit: allowEdit)
            )
            return PluginEvent(
                pluginID: pluginID,
                sessionID: sessionID,
                working: nil,
                attention: true,
                notification: nil,
                responseRequest: PluginEvent.ResponseRequestPayload(
                    requestID: requestID,
                    request: req
                ),
                tmuxPane: tmuxPane
            )

        case "open_file_suggestion":
            let path = dict["path"]?.stringValue ?? ""
            let displayName = dict["display_name"]?.stringValue
                ?? (URL(fileURLWithPath: path).lastPathComponent)
            let isPlan = dict["is_plan"]?.boolValue ?? false
            return PluginEvent(
                pluginID: pluginID,
                sessionID: sessionID,
                working: nil,
                attention: false,
                notification: nil,
                responseRequest: nil,
                appActions: [
                    .openFileSuggestion(
                        sessionId: sessionID,
                        path: path,
                        displayName: displayName,
                        isPlan: isPlan
                    ),
                ],
                tmuxPane: tmuxPane
            )

        case "set_projects":
            if case let .array(items) = dict["projects"] ?? .null {
                projects = items.compactMap(decodeProject)
            } else {
                projects = []
            }
            // Async pushes don't block the synchronous translate_event
            // return path: we kick a Task and return nil so the RPC
            // response is `null` (no PluginEvent emitted).
            Task { @MainActor [weak self] in
                await self?.scanAndPushProjects()
            }
            return nil

        case "crash":
            // Used by `PluginCrashRestartScenario` to verify the supervisor's
            // restart behaviour. Abort without flushing so the OS reports
            // the death promptly.
            abort()

        default:
            logger.warning("unknown _test discriminator: \(testKey)")
            return nil
        }
    }

    private func handleDeliverResponse(params: JSONValue?) async throws {
        struct DeliverParams: Decodable {
            let sessionId: String
            let requestId: String
            let response: AgentResponse
        }
        guard let params else {
            throw RPCError.invalidParams("deliver_response requires params")
        }
        let decoded = try decode(params, as: DeliverParams.self)

        // Persist the captured response so scenarios can read it back from
        // the per-test state root after the RPC completes.
        if let stateDir {
            let responseURL = stateDir
                .appendingPathComponent("responses", isDirectory: true)
                .appendingPathComponent("\(decoded.requestId).json")
            do {
                let data = try encoder.encode(decoded.response)
                try data.write(to: responseURL, options: .atomic)
            } catch {
                logger.warning("response persist failed: \(error)")
            }
        }

        // Replay any delivery script that was attached to the original
        // request payload — gives the keystroke-pipeline scenarios a way
        // to verify the agent-driver contract end-to-end.
        if let original = rememberedPayloads.removeValue(forKey: decoded.requestId) {
            try await runDeliveryScript(from: original, sessionID: decoded.sessionId)
        }
    }

    private func runDeliveryScript(
        from original: JSONValue,
        sessionID: String
    ) async throws {
        guard case let .object(dict) = original else { return }
        guard case let .array(steps) = dict["_delivery_script"] ?? .null else { return }
        for step in steps {
            guard case let .object(s) = step else { continue }
            guard case let .string(type) = s["type"] ?? .null else { continue }
            switch type {
            case "send_text":
                let text = s["text"]?.stringValue ?? ""
                await emit(
                    method: PluginRPCMethod.SidecarToApp.sendText.rawValue,
                    params: .object([
                        "session_id": .string(sessionID),
                        "text": .string(text),
                    ])
                )
            case "send_keys":
                let keys = (s["keys"]?.arrayValue ?? []).compactMap { $0.stringValue }
                await emit(
                    method: PluginRPCMethod.SidecarToApp.sendKeys.rawValue,
                    params: .object([
                        "session_id": .string(sessionID),
                        "keys": .array(keys.map { .string($0) }),
                    ])
                )
            default:
                logger.warning("unknown _delivery_script step: \(type)")
            }
        }
    }

    private func handleGetSettingsSchema() async throws -> JSONValue {
        guard let pluginRoot else {
            throw RPCError.invalidParams("initialize must run before get_settings_schema")
        }
        let schemaURL = pluginRoot
            .appendingPathComponent("ui")
            .appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: schemaURL.path) else {
            throw RPCError.internalError("settings.json not found at \(schemaURL.path)")
        }
        let data = try Data(contentsOf: schemaURL)
        return try decoder.decode(JSONValue.self, from: data)
    }

    private func handleApplySettings(params: JSONValue?) async throws -> JSONValue {
        struct ApplyParams: Decodable {
            let settings: JSONValue
        }
        guard let params else {
            throw RPCError.invalidParams("apply_settings requires params")
        }
        let decoded = try decode(params, as: ApplyParams.self)
        guard let stateDir else {
            throw RPCError.invalidParams("initialize must run before apply_settings")
        }
        do {
            let settingsURL = stateDir.appendingPathComponent("settings.json")
            let data = try encoder.encode(decoded.settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            return .object([
                "status": .string("error"),
                "message": .string("write failed: \(error)"),
            ])
        }
        return .object(["status": .string("ok")])
    }

    private func handleCommandForLaunch() -> JSONValue {
        .object([
            "command": .string("echo"),
            "args": .array([.string("echo-fake-launch")]),
            "env": .object([:]),
        ])
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
                errorLogger.warning("ingress parse error: \(error)")
            }
        }
        logger.info("ingress socket listening at \(socketURL.path)")
    }

    // MARK: - Projects

    private func scanAndPushProjects() async {
        do {
            let projectsValue = try encodeAsJSONValue(projects)
            await emit(
                method: PluginRPCMethod.SidecarToApp.setProjects.rawValue,
                params: .object(["projects": projectsValue])
            )
        } catch {
            logger.warning("set_projects encode failed: \(error)")
        }
    }

    private func decodeProject(_ value: JSONValue) -> AgentProject? {
        guard case .object = value else { return nil }
        do {
            let data = try encoder.encode(value)
            return try decoder.decode(AgentProject.self, from: data)
        } catch {
            logger.warning("decodeProject failed: \(error)")
            return nil
        }
    }

    private func decodeQuestions(from value: JSONValue?) -> [AskUserQuestionRequest.Question] {
        guard case let .array(items) = value ?? .null else { return [] }
        var out: [AskUserQuestionRequest.Question] = []
        for item in items {
            do {
                let data = try encoder.encode(item)
                let q = try decoder.decode(AskUserQuestionRequest.Question.self, from: data)
                out.append(q)
            } catch {
                logger.warning("decodeQuestions item failed: \(error)")
            }
        }
        return out
    }

    // MARK: - Outbound notifications

    private func emitEvent(_ event: PluginEvent) async {
        do {
            let params = try encodeAsJSONValue(event)
            await emit(
                method: PluginRPCMethod.SidecarToApp.emitEvent.rawValue,
                params: params
            )
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

    // MARK: - Teardown

    private func tearDown() async {
        ingressTask?.cancel()
        ingressErrorTask?.cancel()
        ingressTask = nil
        ingressErrorTask = nil
        await ingressServer?.stop()
        ingressServer = nil
    }

    // MARK: - Helpers

    private func mintRequestID() -> String {
        requestCounter += 1
        return "echo-req-\(requestCounter)"
    }

    private func decode<T: Decodable>(_ value: JSONValue, as: T.Type) throws -> T {
        let data = try encoder.encode(value)
        return try decoder.decode(T.self, from: data)
    }

    private func encodeAsJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try encoder.encode(value)
        return try decoder.decode(JSONValue.self, from: data)
    }
}

// MARK: - JSONValue helpers

private extension JSONValue {
    /// Convenience accessor for array values. `JSONValue` already ships
    /// `stringValue`, `boolValue`, and `intValue` — we only need to add
    /// `arrayValue` for the `_delivery_script` walker.
    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }
}

// MARK: - WriteQueue

/// Serial writer for stdout. Mirrors `ClaudeCodePluginSidecar`'s
/// `WriteQueue` — `FileHandle.write` is blocking and not safe to call
/// from concurrent tasks.
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

// MARK: - RPCError

/// Local error type translated into a JSON-RPC error response. We don't
/// share `RPCDispatcherError` from the Claude / Codex sidecars because the
/// fixture lives in a sibling target — defining a tiny local copy keeps
/// the dependency graph minimal.
enum RPCError: Error {
    case invalidParams(String)
    case internalError(String)
    case custom(code: Int, message: String)

    func asRPCError() -> JSONRPCError {
        switch self {
        case let .invalidParams(message):
            return JSONRPCError(code: -32_602, message: message)
        case let .internalError(message):
            return JSONRPCError(code: -32_603, message: message)
        case let .custom(code, message):
            return JSONRPCError(code: code, message: message)
        }
    }
}
