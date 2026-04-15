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
    ]

    /// Live implementation that routes JSON-RPC methods to service calls.
    ///
    /// Service dependencies are injected via callbacks set by AppCoordinator,
    /// since the router needs access to @MainActor services (TmuxService, MirrorWindowManager).
    final public class LiveAPIRequestRouter: Sendable {
        private let logger = Logger(label: "com.claudespy.apirouter")

        // Service callbacks set by AppCoordinator
        nonisolated(unsafe) var onSessionList: (@Sendable () async -> [[String: JSONValue]])?
        nonisolated(unsafe) var onSessionCreate: (@Sendable (String?) async throws -> [String: JSONValue])?
        nonisolated(unsafe) var onSessionSelect: (@Sendable (String) async throws -> Void)?
        nonisolated(unsafe) var onSessionCurrent: (@Sendable () async -> [String: JSONValue]?)?
        nonisolated(unsafe) var onSessionClose: (@Sendable (String) async throws -> Void)?

        nonisolated(unsafe) var onWindowList: (@Sendable (String?) async -> [[String: JSONValue]])?
        nonisolated(unsafe) var onWindowCreate: (@Sendable (String?) async throws -> [String: JSONValue])?
        nonisolated(unsafe) var onWindowSelect: (@Sendable (String) async throws -> Void)?
        nonisolated(unsafe) var onWindowClose: (@Sendable (String) async throws -> Void)?

        nonisolated(unsafe) var onPaneList: (@Sendable (String?) async -> [[String: JSONValue]])?
        nonisolated(unsafe) var onPaneSplit: (@Sendable (String?, String) async throws -> [String: JSONValue])?
        nonisolated(unsafe) var onPaneSelect: (@Sendable (String) async throws -> Void)?

        nonisolated(unsafe) var onSendText: (@Sendable (String, String?) async throws -> Void)?
        nonisolated(unsafe) var onSendKey: (@Sendable (String, String?) async throws -> Void)?

        nonisolated(unsafe) var onNotify: (@Sendable (String, String, String?, String?) async -> Void)?

        nonisolated(unsafe) var onEditorOpen: (@Sendable (String, String) async -> Void)?

        nonisolated(unsafe) var onIdentify: (@Sendable (String?) async -> [String: JSONValue])?

        public init() { }

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
                    if let info = await onIdentify?(paneId) {
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
                    if let result = try await onSessionCreate?(name) {
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
                    if let result = try await onWindowCreate?(sessionId) {
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
                    if let result = try await onPaneSplit?(paneId, direction) {
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

                default:
                    return .methodNotFound(id: id, request.method)
                }
            } catch {
                return .internalError(id: id, error.localizedDescription)
            }
        }
    }
#endif
