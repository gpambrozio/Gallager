#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging

    @DependencyClient
    public struct APIRequestRouter: Sendable {
        public var handleRequest: @Sendable (JSONRPCRequest) async -> JSONRPCResponse = { request in
            .methodNotFound(id: request.id, request.method)
        }
    }

    extension APIRequestRouter: DependencyKey {
        public static var previewValue: APIRequestRouter {
            APIRequestRouter()
        }

        public static var liveValue: APIRequestRouter {
            let router = LiveAPIRequestRouter()
            return APIRequestRouter(
                handleRequest: { request in
                    await router.handleRequest(request)
                }
            )
        }
    }

    /// All supported API methods.
    private let allMethods: [String] = [
        "system.ping",
        "system.capabilities",
        "system.identify",
        "session.list",
        "session.create",
        "session.select",
        "session.current",
        "session.close",
        "window.list",
        "window.create",
        "window.select",
        "window.close",
        "pane.list",
        "pane.split",
        "pane.select",
        "input.send_text",
        "input.send_key",
        "notification.create",
        "editor.open",
        "project.list",
        "project.start",
    ]

    /// Live implementation that routes JSON-RPC methods to service calls.
    ///
    /// Service dependencies are injected via callbacks provided at init by AppCoordinator,
    /// since the router needs access to @MainActor services (TmuxService, MirrorWindowManager).
    final public class LiveAPIRequestRouter: Sendable {
        private let logger = Logger(label: "com.claudespy.apirouter")

        // Service callbacks injected at init by AppCoordinator
        let onSessionList: (@Sendable () async -> [[String: JSONValue]])?
        let onSessionCreate: (@Sendable (String?, String?) async throws -> [String: JSONValue])?
        let onSessionSelect: (@Sendable (String) async throws -> Void)?
        let onSessionCurrent: (@Sendable () async -> [String: JSONValue]?)?
        let onSessionClose: (@Sendable (String) async throws -> Void)?

        let onWindowList: (@Sendable (String?) async -> [[String: JSONValue]])?
        let onWindowCreate: (@Sendable (String?, String?) async throws -> [String: JSONValue])?
        let onWindowSelect: (@Sendable (String) async throws -> Void)?
        let onWindowClose: (@Sendable (String) async throws -> Void)?

        let onPaneList: (@Sendable (String?) async -> [[String: JSONValue]])?
        let onPaneSplit: (@Sendable (String?, String, String?) async throws -> [String: JSONValue])?
        let onPaneSelect: (@Sendable (String) async throws -> Void)?

        let onSendText: (@Sendable (String, String?) async throws -> Void)?
        let onSendKey: (@Sendable (String, String?) async throws -> Void)?

        let onNotify: (@Sendable (String, String, String?, String?) async -> Void)?

        let onEditorOpen: (@Sendable (String, String) async -> Void)?

        let onIdentify: (@Sendable (String?) async -> [String: JSONValue]?)?

        let onProjectList: (@Sendable () async -> [[String: JSONValue]])?
        let onProjectStart: (@Sendable (String, [String]) async throws -> [String: JSONValue])?

        public init(
            onSessionList: (@Sendable () async -> [[String: JSONValue]])? = nil,
            onSessionCreate: (@Sendable (String?, String?) async throws -> [String: JSONValue])? = nil,
            onSessionSelect: (@Sendable (String) async throws -> Void)? = nil,
            onSessionCurrent: (@Sendable () async -> [String: JSONValue]?)? = nil,
            onSessionClose: (@Sendable (String) async throws -> Void)? = nil,
            onWindowList: (@Sendable (String?) async -> [[String: JSONValue]])? = nil,
            onWindowCreate: (@Sendable (String?, String?) async throws -> [String: JSONValue])? = nil,
            onWindowSelect: (@Sendable (String) async throws -> Void)? = nil,
            onWindowClose: (@Sendable (String) async throws -> Void)? = nil,
            onPaneList: (@Sendable (String?) async -> [[String: JSONValue]])? = nil,
            onPaneSplit: (@Sendable (String?, String, String?) async throws -> [String: JSONValue])? = nil,
            onPaneSelect: (@Sendable (String) async throws -> Void)? = nil,
            onSendText: (@Sendable (String, String?) async throws -> Void)? = nil,
            onSendKey: (@Sendable (String, String?) async throws -> Void)? = nil,
            onNotify: (@Sendable (String, String, String?, String?) async -> Void)? = nil,
            onEditorOpen: (@Sendable (String, String) async -> Void)? = nil,
            onIdentify: (@Sendable (String?) async -> [String: JSONValue]?)? = nil,
            onProjectList: (@Sendable () async -> [[String: JSONValue]])? = nil,
            onProjectStart: (@Sendable (String, [String]) async throws -> [String: JSONValue])? = nil
        ) {
            self.onSessionList = onSessionList
            self.onSessionCreate = onSessionCreate
            self.onSessionSelect = onSessionSelect
            self.onSessionCurrent = onSessionCurrent
            self.onSessionClose = onSessionClose
            self.onWindowList = onWindowList
            self.onWindowCreate = onWindowCreate
            self.onWindowSelect = onWindowSelect
            self.onWindowClose = onWindowClose
            self.onPaneList = onPaneList
            self.onPaneSplit = onPaneSplit
            self.onPaneSelect = onPaneSelect
            self.onSendText = onSendText
            self.onSendKey = onSendKey
            self.onNotify = onNotify
            self.onEditorOpen = onEditorOpen
            self.onIdentify = onIdentify
            self.onProjectList = onProjectList
            self.onProjectStart = onProjectStart
        }

        public func handleRequest(_ request: JSONRPCRequest) async -> JSONRPCResponse {
            let id = request.id
            let params = request.params

            do {
                switch request.method {
                // MARK: - System

                case "system.ping":
                    return JSONRPCResponse(id: id, result: ["pong": .bool(true)])

                case "system.capabilities":
                    return JSONRPCResponse(id: id, result: [
                        "methods": .array(allMethods.map { .string($0) }),
                    ])

                case "system.identify":
                    let paneId = params["pane_id"]?.stringValue
                    if let callback = onIdentify, let info = await callback(paneId) {
                        return JSONRPCResponse(id: id, result: info)
                    }
                    return .internalError(id: id, "Identify not available")

                // MARK: - Sessions

                case "session.list":
                    let sessions = await onSessionList?() ?? []
                    return JSONRPCResponse(id: id, result: [
                        "sessions": .array(sessions.map { .object($0) }),
                    ])

                case "session.create":
                    let name = params["name"]?.stringValue
                    let path = params["path"]?.stringValue
                    if let result = try await onSessionCreate?(name, path) {
                        return JSONRPCResponse(id: id, result: result)
                    }
                    return .internalError(id: id, "Session create not available")

                case "session.select":
                    guard let sessionId = params["session_id"]?.stringValue else {
                        return .invalidParams(id: id, "session_id required")
                    }
                    try await onSessionSelect?(sessionId)
                    return .ok(id: id)

                case "session.current":
                    if let result = await onSessionCurrent?() {
                        return JSONRPCResponse(id: id, result: result)
                    }
                    return .notFound(id: id, "No active session")

                case "session.close":
                    guard let sessionId = params["session_id"]?.stringValue else {
                        return .invalidParams(id: id, "session_id required")
                    }
                    try await onSessionClose?(sessionId)
                    return .ok(id: id)

                // MARK: - Windows

                case "window.list":
                    let sessionId = params["session_id"]?.stringValue
                    let windows = await onWindowList?(sessionId) ?? []
                    return JSONRPCResponse(id: id, result: [
                        "windows": .array(windows.map { .object($0) }),
                    ])

                case "window.create":
                    let sessionId = params["session_id"]?.stringValue
                    let path = params["path"]?.stringValue
                    if let result = try await onWindowCreate?(sessionId, path) {
                        return JSONRPCResponse(id: id, result: result)
                    }
                    return .internalError(id: id, "Window create not available")

                case "window.select":
                    guard let windowId = params["window_id"]?.stringValue else {
                        return .invalidParams(id: id, "window_id required")
                    }
                    try await onWindowSelect?(windowId)
                    return .ok(id: id)

                case "window.close":
                    guard let windowId = params["window_id"]?.stringValue else {
                        return .invalidParams(id: id, "window_id required")
                    }
                    try await onWindowClose?(windowId)
                    return .ok(id: id)

                // MARK: - Panes

                case "pane.list":
                    let windowId = params["window_id"]?.stringValue
                    let panes = await onPaneList?(windowId) ?? []
                    return JSONRPCResponse(id: id, result: [
                        "panes": .array(panes.map { .object($0) }),
                    ])

                case "pane.split":
                    let direction = params["direction"]?.stringValue ?? "right"
                    let paneId = params["pane_id"]?.stringValue
                    let path = params["path"]?.stringValue
                    if let result = try await onPaneSplit?(paneId, direction, path) {
                        return JSONRPCResponse(id: id, result: result)
                    }
                    return .internalError(id: id, "Pane split not available")

                case "pane.select":
                    guard let paneId = params["pane_id"]?.stringValue else {
                        return .invalidParams(id: id, "pane_id required")
                    }
                    try await onPaneSelect?(paneId)
                    return .ok(id: id)

                // MARK: - Input

                case "input.send_text":
                    guard let text = params["text"]?.stringValue else {
                        return .invalidParams(id: id, "text required")
                    }
                    let paneId = params["pane_id"]?.stringValue
                    try await onSendText?(text, paneId)
                    return .ok(id: id)

                case "input.send_key":
                    guard let key = params["key"]?.stringValue else {
                        return .invalidParams(id: id, "key required")
                    }
                    let paneId = params["pane_id"]?.stringValue
                    try await onSendKey?(key, paneId)
                    return .ok(id: id)

                // MARK: - Notifications

                case "notification.create":
                    guard let title = params["title"]?.stringValue else {
                        return .invalidParams(id: id, "title required")
                    }
                    guard let body = params["body"]?.stringValue else {
                        return .invalidParams(id: id, "body required")
                    }
                    let subtitle = params["subtitle"]?.stringValue
                    let paneId = params["pane_id"]?.stringValue
                    await onNotify?(title, body, subtitle, paneId)
                    return .ok(id: id)

                // MARK: - Editor

                case "editor.open":
                    guard let paneId = params["pane_id"]?.stringValue else {
                        return .invalidParams(id: id, "pane_id required")
                    }
                    guard let filePath = params["file_path"]?.stringValue else {
                        return .invalidParams(id: id, "file_path required")
                    }
                    // This blocks until editing is done
                    await onEditorOpen?(paneId, filePath)
                    return .ok(id: id)

                // MARK: - Projects

                case "project.list":
                    let projects = await onProjectList?() ?? []
                    return JSONRPCResponse(id: id, result: [
                        "projects": .array(projects.map { .object($0) }),
                    ])

                case "project.start":
                    guard let path = params["path"]?.stringValue else {
                        return .invalidParams(id: id, "path required")
                    }
                    let args: [String]
                    if case let .array(values) = params["args"] {
                        args = values.compactMap { $0.stringValue }
                    } else {
                        args = []
                    }
                    if let result = try await onProjectStart?(path, args) {
                        return JSONRPCResponse(id: id, result: result)
                    }
                    return .internalError(id: id, "Project start not available")

                default:
                    return .methodNotFound(id: id, request.method)
                }
            } catch {
                return .internalError(id: id, error.localizedDescription)
            }
        }
    }
#endif
