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
        "system.set_env",
        "session.list",
        "session.create",
        "session.select",
        "session.current",
        "session.close",
        "session.set_state",
        "session.set_title",
        "session.set_color",
        "session.set_emoji",
        "window.list",
        "window.create",
        "window.select",
        "window.close",
        "window.set_name",
        "pane.list",
        "pane.split",
        "pane.select",
        "pane.capture",
        "pane.set_layout",
        "pane.set_progress",
        "input.send_text",
        "input.send_key",
        "notification.create",
        "editor.open",
        "project.list",
        "project.start",
        "layout.apply",
        "plugin.list",
        "plugin.info",
        "plugin.install",
        "plugin.remove",
        "plugin.enable",
        "plugin.disable",
        "plugin.update",
        "plugin.call",
        "plugin.logs",
    ]

    /// Live implementation that routes JSON-RPC methods to service calls.
    ///
    /// Service dependencies are injected via callbacks provided at init by AppCoordinator,
    /// since the router needs access to @MainActor services (TmuxService, MirrorWindowManager).
    final public class LiveAPIRequestRouter: Sendable {
        /// Result of `onSessionCreate`. `created` is `false` when `ifMissing` was
        /// set and the session already existed; in that case `info` describes the
        /// existing session and no new session was created.
        public struct SessionCreateResult: Sendable {
            public let info: [String: JSONValue]
            public let created: Bool

            public init(info: [String: JSONValue], created: Bool) {
                self.info = info
                self.created = created
            }
        }

        private let logger = Logger(label: "com.claudespy.apirouter")

        /// Service callbacks injected at init by AppCoordinator
        let onSessionList: (@Sendable () async -> [[String: JSONValue]])?
        /// Parameters: (name, path, title, color, ifMissing).
        let onSessionCreate: (
            @Sendable (String?, String?, String?, SessionColor?, Bool) async throws -> SessionCreateResult
        )?
        let onSessionSelect: (@Sendable (String) async throws -> Void)?
        let onSessionCurrent: (@Sendable () async -> [String: JSONValue]?)?
        let onSessionClose: (@Sendable (String) async throws -> Void)?
        let onSessionSetState: (@Sendable (String, String?, String?) async throws -> Int)?
        /// Parameters: (title, sessionId, paneId). `title` is `nil` to clear.
        /// Always applies at session scope; `paneId` is just used to look up
        /// the calling pane's session when no `sessionId` is given.
        let onSessionSetTitle: (@Sendable (String?, String?, String?) async throws -> Void)?
        /// Parameters: (color, sessionId, paneId). `color` is `nil` to clear.
        /// Always applies at session scope.
        let onSessionSetColor: (@Sendable (SessionColor?, String?, String?) async throws -> Void)?
        /// Parameters: (emoji, sessionId, paneId). `emoji` is `nil` to clear.
        /// Always applies at session scope.
        let onSessionSetEmoji: (@Sendable (String?, String?, String?) async throws -> Void)?

        let onWindowList: (@Sendable (String?, String?) async -> [[String: JSONValue]])?
        /// Parameters: (sessionId, path, paneId, name).
        /// `name` is the tmux window name (tab label) — when nil, the daemon
        /// auto-generates "terminal N".
        let onWindowCreate: (
            @Sendable (String?, String?, String?, String?) async throws -> [String: JSONValue]
        )?
        let onWindowSelect: (@Sendable (String) async throws -> Void)?
        let onWindowClose: (@Sendable (String) async throws -> Void)?
        /// Parameters: (windowId, name). Renames a tmux window via
        /// `rename-window`, which also disables tmux's automatic-rename so
        /// the tab stops tracking the running command.
        let onWindowSetName: (@Sendable (String, String) async throws -> Void)?

        let onPaneList: (@Sendable (String?, String?) async -> [[String: JSONValue]])?
        /// Parameters: (paneId, direction, path, shellCommand). When
        /// `shellCommand` is non-nil, it becomes the new pane's process
        /// (passed as the trailing positional to `tmux split-window`).
        let onPaneSplit: (
            @Sendable (String?, String, String?, String?) async throws -> [String: JSONValue]
        )?
        let onPaneSelect: (@Sendable (String) async throws -> Void)?
        let onPaneCapture: (@Sendable (String?, Bool) async throws -> String)?
        /// Parameters: (sessionId or window target, layout name or hex).
        let onPaneSetLayout: (@Sendable (String, String) async throws -> Void)?
        /// Parameters: (state, paneId). `state` is `nil` to clear the bar.
        /// `paneId` is `nil` to target the calling/active pane.
        let onPaneSetProgress: (
            @Sendable (TerminalProgressState?, String?) async throws -> Void
        )?

        let onSendText: (@Sendable (String, String?, Bool) async throws -> Void)?
        let onSendKey: (@Sendable (String, String?) async throws -> Void)?

        /// Parameters: (title, body, paneId, push). When `push` is true, the
        /// host also forwards an encrypted push notification to paired iOS
        /// viewers (delivered via APNs when the viewer is offline).
        let onNotify: (@Sendable (String, String, String?, Bool) async -> Void)?

        let onEditorOpen: (@Sendable (String, String) async -> Void)?

        let onIdentify: (@Sendable (String?) async -> [String: JSONValue]?)?

        let onProjectList: (@Sendable () async -> [[String: JSONValue]])?
        /// Parameters: (path, args, agent). `agent` defaults to `.claudeCode`
        /// when callers don't specify one over the wire.
        let onProjectStart: (@Sendable (String, [String], CodingAgent) async throws -> [String: JSONValue])?

        /// Parameters: (sessionId, [name: optional value]). `nil` value unsets.
        let onSetEnvironment: (@Sendable (String, [String: String?]) async throws -> Void)?

        /// Parameters: (config, rebuild, detach, dryRun, lenient, requireCreate, configPath).
        /// Returns the result envelope per spec §3 (sessionName, created, warnings, planned).
        let onLayoutApply: (
            @Sendable (JSONValue, Bool, Bool, Bool, Bool, Bool, String?) async throws -> [String: JSONValue]
        )?

        // MARK: - Plugin callbacks
        //
        // Each callback is a thin façade over `PluginManager`. The
        // coordinator wires them after the manager finishes `start()` so
        // the router doesn't reach into a half-initialized manager.
        let onPluginList: (@Sendable () async throws -> [PluginListEntry])?
        let onPluginInfo: (@Sendable (String) async throws -> PluginInfoResult)?
        /// Parameters: (manifestURL, yes). `yes` is currently unused on the
        /// app side — the CLI gates the confirmation, the app trusts the
        /// caller. Reserved for v2's trust prompt.
        let onPluginInstall: (@Sendable (URL, Bool) async throws -> Void)?
        /// Parameters: (id, deleteState). v1 always removes registry + files
        /// for url plugins; state-dir removal is gated on `deleteState`.
        let onPluginRemove: (@Sendable (String, Bool) async throws -> Void)?
        let onPluginEnable: (@Sendable (String) async throws -> Void)?
        let onPluginDisable: (@Sendable (String) async throws -> Void)?
        /// Parameters: (id?). v1 always returns an empty list; the closure
        /// hook exists so v2 can plug in a real updater without changing
        /// the route table.
        let onPluginUpdate: (@Sendable (String?) async throws -> [PluginUpdateResult])?
        /// Parameters: (id, method, params). Routes a raw RPC to the named
        /// sidecar and returns its result payload verbatim.
        let onPluginCall: (
            @Sendable (String, String, JSONValue?) async throws -> JSONValue
        )?
        /// Parameters: (id, lines). Returns the trailing N lines of the
        /// sidecar log (or an empty string when the log doesn't exist yet).
        let onPluginLogs: (@Sendable (String, Int) async throws -> String)?

        public init(
            onSessionList: (@Sendable () async -> [[String: JSONValue]])? = nil,
            onSessionCreate: (
                @Sendable (String?, String?, String?, SessionColor?, Bool) async throws -> SessionCreateResult
            )? = nil,
            onSessionSelect: (@Sendable (String) async throws -> Void)? = nil,
            onSessionCurrent: (@Sendable () async -> [String: JSONValue]?)? = nil,
            onSessionClose: (@Sendable (String) async throws -> Void)? = nil,
            onSessionSetState: (@Sendable (String, String?, String?) async throws -> Int)? = nil,
            onSessionSetTitle: (@Sendable (String?, String?, String?) async throws -> Void)? = nil,
            onSessionSetColor: (@Sendable (SessionColor?, String?, String?) async throws -> Void)? = nil,
            onSessionSetEmoji: (@Sendable (String?, String?, String?) async throws -> Void)? = nil,
            onWindowList: (@Sendable (String?, String?) async -> [[String: JSONValue]])? = nil,
            onWindowCreate: (
                @Sendable (String?, String?, String?, String?) async throws -> [String: JSONValue]
            )? = nil,
            onWindowSelect: (@Sendable (String) async throws -> Void)? = nil,
            onWindowClose: (@Sendable (String) async throws -> Void)? = nil,
            onWindowSetName: (@Sendable (String, String) async throws -> Void)? = nil,
            onPaneList: (@Sendable (String?, String?) async -> [[String: JSONValue]])? = nil,
            onPaneSplit: (
                @Sendable (String?, String, String?, String?) async throws -> [String: JSONValue]
            )? = nil,
            onPaneSelect: (@Sendable (String) async throws -> Void)? = nil,
            onPaneCapture: (@Sendable (String?, Bool) async throws -> String)? = nil,
            onPaneSetLayout: (@Sendable (String, String) async throws -> Void)? = nil,
            onPaneSetProgress: (
                @Sendable (TerminalProgressState?, String?) async throws -> Void
            )? = nil,
            onSendText: (@Sendable (String, String?, Bool) async throws -> Void)? = nil,
            onSendKey: (@Sendable (String, String?) async throws -> Void)? = nil,
            onNotify: (@Sendable (String, String, String?, Bool) async -> Void)? = nil,
            onEditorOpen: (@Sendable (String, String) async -> Void)? = nil,
            onIdentify: (@Sendable (String?) async -> [String: JSONValue]?)? = nil,
            onProjectList: (@Sendable () async -> [[String: JSONValue]])? = nil,
            onProjectStart: (@Sendable (String, [String], CodingAgent) async throws -> [String: JSONValue])? = nil,
            onSetEnvironment: (@Sendable (String, [String: String?]) async throws -> Void)? = nil,
            onLayoutApply: (
                @Sendable (JSONValue, Bool, Bool, Bool, Bool, Bool, String?) async throws -> [String: JSONValue]
            )? = nil,
            onPluginList: (@Sendable () async throws -> [PluginListEntry])? = nil,
            onPluginInfo: (@Sendable (String) async throws -> PluginInfoResult)? = nil,
            onPluginInstall: (@Sendable (URL, Bool) async throws -> Void)? = nil,
            onPluginRemove: (@Sendable (String, Bool) async throws -> Void)? = nil,
            onPluginEnable: (@Sendable (String) async throws -> Void)? = nil,
            onPluginDisable: (@Sendable (String) async throws -> Void)? = nil,
            onPluginUpdate: (@Sendable (String?) async throws -> [PluginUpdateResult])? = nil,
            onPluginCall: (
                @Sendable (String, String, JSONValue?) async throws -> JSONValue
            )? = nil,
            onPluginLogs: (@Sendable (String, Int) async throws -> String)? = nil
        ) {
            self.onSessionList = onSessionList
            self.onSessionCreate = onSessionCreate
            self.onSessionSelect = onSessionSelect
            self.onSessionCurrent = onSessionCurrent
            self.onSessionClose = onSessionClose
            self.onSessionSetState = onSessionSetState
            self.onSessionSetTitle = onSessionSetTitle
            self.onSessionSetColor = onSessionSetColor
            self.onSessionSetEmoji = onSessionSetEmoji
            self.onWindowList = onWindowList
            self.onWindowCreate = onWindowCreate
            self.onWindowSelect = onWindowSelect
            self.onWindowClose = onWindowClose
            self.onWindowSetName = onWindowSetName
            self.onPaneList = onPaneList
            self.onPaneSplit = onPaneSplit
            self.onPaneSelect = onPaneSelect
            self.onPaneCapture = onPaneCapture
            self.onPaneSetLayout = onPaneSetLayout
            self.onPaneSetProgress = onPaneSetProgress
            self.onSendText = onSendText
            self.onSendKey = onSendKey
            self.onNotify = onNotify
            self.onEditorOpen = onEditorOpen
            self.onIdentify = onIdentify
            self.onProjectList = onProjectList
            self.onProjectStart = onProjectStart
            self.onSetEnvironment = onSetEnvironment
            self.onLayoutApply = onLayoutApply
            self.onPluginList = onPluginList
            self.onPluginInfo = onPluginInfo
            self.onPluginInstall = onPluginInstall
            self.onPluginRemove = onPluginRemove
            self.onPluginEnable = onPluginEnable
            self.onPluginDisable = onPluginDisable
            self.onPluginUpdate = onPluginUpdate
            self.onPluginCall = onPluginCall
            self.onPluginLogs = onPluginLogs
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

                case "system.set_env":
                    guard let sessionId = params["session_id"]?.stringValue else {
                        return .invalidParams(id: id, "session_id required")
                    }
                    guard case let .object(rawVars) = params["vars"] ?? .null else {
                        return .invalidParams(id: id, "vars must be a {name: value} object")
                    }
                    var vars: [String: String?] = [:]
                    for (key, value) in rawVars {
                        switch value {
                        case let .string(s):
                            vars[key] = s
                        case .null:
                            // `updateValue(nil, ...)` keeps the key with a `.some(nil)`
                            // value, distinguishing "unset this var" from "absent
                            // from request"; `vars[key] = nil` would remove it.
                            vars.updateValue(nil, forKey: key)
                        default:
                            return .invalidParams(
                                id: id,
                                "vars.\(key) must be string or null (got \(value.typeName))"
                            )
                        }
                    }
                    guard let callback = onSetEnvironment else {
                        return .internalError(id: id, "Set env not available")
                    }
                    try await callback(sessionId, vars)
                    return .ok(id: id)

                // MARK: - Sessions

                case "session.list":
                    let sessions = await onSessionList?() ?? []
                    return JSONRPCResponse(id: id, result: [
                        "sessions": .array(sessions.map { .object($0) }),
                    ])

                case "session.create":
                    let name = params["name"]?.stringValue
                    let path = params["path"]?.stringValue
                    let title = params["title"]?.stringValue
                    let ifMissing = params["if_missing"]?.boolValue == true
                    let rawColor = params["color"]?.stringValue
                    let color: SessionColor?
                    if let rawColor, !rawColor.isEmpty {
                        guard let parsed = SessionColor.parse(rawColor) else {
                            let valid = SessionColor.allCases.map(\.rawValue).joined(separator: ", ")
                            return .invalidParams(
                                id: id,
                                "Unknown color '\(rawColor)'. Valid colors: \(valid)"
                            )
                        }
                        color = parsed
                    } else {
                        color = nil
                    }
                    if let result = try await onSessionCreate?(name, path, title, color, ifMissing) {
                        var info = result.info
                        info["created"] = .bool(result.created)
                        return JSONRPCResponse(id: id, result: info)
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

                case "session.set_state":
                    guard let state = params["state"]?.stringValue else {
                        return .invalidParams(id: id, "state required (working, idle, waiting, or clear)")
                    }
                    let paneId = params["pane_id"]?.stringValue
                    let sessionId = params["session_id"]?.stringValue
                    guard let callback = onSessionSetState else {
                        return .internalError(id: id, "Session set_state not available")
                    }
                    let appliedTo = try await callback(state, paneId, sessionId)
                    return JSONRPCResponse(id: id, result: [
                        "applied_to": .int(appliedTo),
                    ])

                case "session.set_title":
                    // `title` is optional; nil/empty clears the description.
                    // Window/pane targeting is intentionally not supported —
                    // titles always apply at session scope.
                    let title = params["title"]?.stringValue
                    let sessionId = params["session_id"]?.stringValue
                    let paneId = params["pane_id"]?.stringValue
                    guard let callback = onSessionSetTitle else {
                        return .internalError(id: id, "Session set_title not available")
                    }
                    try await callback(title, sessionId, paneId)
                    return .ok(id: id)

                case "session.set_color":
                    // `color` is optional; nil/empty clears the color. An
                    // unrecognised color name is rejected so the caller knows
                    // they typed something the app can't render. Always
                    // applies at session scope.
                    let rawColor = params["color"]?.stringValue
                    let color: SessionColor?
                    if let rawColor, !rawColor.isEmpty {
                        guard let parsed = SessionColor.parse(rawColor) else {
                            let valid = SessionColor.allCases.map(\.rawValue).joined(separator: ", ")
                            return .invalidParams(
                                id: id,
                                "Unknown color '\(rawColor)'. Valid colors: \(valid)"
                            )
                        }
                        color = parsed
                    } else {
                        color = nil
                    }
                    let sessionId = params["session_id"]?.stringValue
                    let paneId = params["pane_id"]?.stringValue
                    guard let callback = onSessionSetColor else {
                        return .internalError(id: id, "Session set_color not available")
                    }
                    try await callback(color, sessionId, paneId)
                    return .ok(id: id)

                case "session.set_emoji":
                    // `emoji` is optional; nil/empty clears the emoji. Free-
                    // form text so any platform-supported emoji works. Always
                    // applies at session scope.
                    let rawEmoji = params["emoji"]?.stringValue
                    let emoji: String? = (rawEmoji?.isEmpty == false) ? rawEmoji : nil
                    let sessionId = params["session_id"]?.stringValue
                    let paneId = params["pane_id"]?.stringValue
                    guard let callback = onSessionSetEmoji else {
                        return .internalError(id: id, "Session set_emoji not available")
                    }
                    try await callback(emoji, sessionId, paneId)
                    return .ok(id: id)

                // MARK: - Windows

                case "window.list":
                    let sessionId = params["session_id"]?.stringValue
                    let paneId = params["pane_id"]?.stringValue
                    let windows = await onWindowList?(sessionId, paneId) ?? []
                    return JSONRPCResponse(id: id, result: [
                        "windows": .array(windows.map { .object($0) }),
                    ])

                case "window.create":
                    let sessionId = params["session_id"]?.stringValue
                    let paneId = params["pane_id"]?.stringValue
                    let path = params["path"]?.stringValue
                    let name = params["name"]?.stringValue
                    if let result = try await onWindowCreate?(sessionId, path, paneId, name) {
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

                case "window.set_name":
                    guard let windowId = params["window_id"]?.stringValue else {
                        return .invalidParams(id: id, "window_id required")
                    }
                    guard let name = params["name"]?.stringValue else {
                        return .invalidParams(id: id, "name required")
                    }
                    guard let callback = onWindowSetName else {
                        return .internalError(id: id, "Window set_name not available")
                    }
                    try await callback(windowId, name)
                    return .ok(id: id)

                // MARK: - Panes

                case "pane.list":
                    let windowId = params["window_id"]?.stringValue
                    let paneId = params["pane_id"]?.stringValue
                    let panes = await onPaneList?(windowId, paneId) ?? []
                    return JSONRPCResponse(id: id, result: [
                        "panes": .array(panes.map { .object($0) }),
                    ])

                case "pane.split":
                    let direction = params["direction"]?.stringValue ?? "right"
                    let paneId = params["pane_id"]?.stringValue
                    let path = params["path"]?.stringValue
                    let shell = params["shell"]?.stringValue
                    if let result = try await onPaneSplit?(paneId, direction, path, shell) {
                        return JSONRPCResponse(id: id, result: result)
                    }
                    return .internalError(id: id, "Pane split not available")

                case "pane.set_layout":
                    guard let layout = params["layout"]?.stringValue else {
                        return .invalidParams(id: id, "layout required")
                    }
                    let target = params["target"]?.stringValue
                        ?? params["window_id"]?.stringValue
                    guard let target else {
                        return .invalidParams(id: id, "target or window_id required")
                    }
                    guard let callback = onPaneSetLayout else {
                        return .internalError(id: id, "Pane set_layout not available")
                    }
                    try await callback(target, layout)
                    return .ok(id: id)

                case "pane.select":
                    guard let paneId = params["pane_id"]?.stringValue else {
                        return .invalidParams(id: id, "pane_id required")
                    }
                    try await onPaneSelect?(paneId)
                    return .ok(id: id)

                case "pane.capture":
                    let paneId = params["pane_id"]?.stringValue
                    let scrollback = params["scrollback"]?.boolValue == true
                    guard let callback = onPaneCapture else {
                        return .internalError(id: id, "Pane capture not available")
                    }
                    let content = try await callback(paneId, scrollback)
                    return JSONRPCResponse(id: id, result: [
                        "content": .string(content),
                    ])

                case "pane.set_progress":
                    // `value` is required; pass an explicit clear sentinel
                    // ("clear" / "none" / "") to remove the bar. Otherwise it's
                    // a 0–100 number, "indeterminate", "warning", or "error".
                    // The server stores the resolved state on
                    // `PaneState.progress` exactly the same way `OSC 9;4`
                    // updates do — same source of truth, so CLI and OSC
                    // overrides last-write-wins each other.
                    guard let raw = params["value"]?.stringValue else {
                        return .invalidParams(
                            id: id,
                            "value required (0-100, 'indeterminate', 'warning', 'error', or 'clear')"
                        )
                    }
                    let parsedProgress: TerminalProgressState?
                    switch Self.parseProgressValue(raw) {
                    case let .success(state): parsedProgress = state
                    case let .failure(message): return .invalidParams(id: id, message)
                    }
                    let paneId = params["pane_id"]?.stringValue
                    guard let callback = onPaneSetProgress else {
                        return .internalError(id: id, "Pane set_progress not available")
                    }
                    try await callback(parsedProgress, paneId)
                    return .ok(id: id)

                // MARK: - Input

                case "input.send_text":
                    guard let text = params["text"]?.stringValue else {
                        return .invalidParams(id: id, "text required")
                    }
                    let paneId = params["pane_id"]?.stringValue
                    let appendEnter = params["enter"]?.boolValue == true
                    try await onSendText?(text, paneId, appendEnter)
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
                    let paneId = params["pane_id"]?.stringValue
                    let push = params["push"]?.boolValue == true
                    await onNotify?(title, body, paneId, push)
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
                    let agent: CodingAgent = (params["agent"]?.stringValue)
                        .flatMap(CodingAgent.init(rawValue:)) ?? .claudeCode
                    if let result = try await onProjectStart?(path, args, agent) {
                        return JSONRPCResponse(id: id, result: result)
                    }
                    return .internalError(id: id, "Project start not available")

                // MARK: - Plugins

                case "plugin.list":
                    guard let callback = onPluginList else {
                        return .internalError(id: id, "Plugin list not available")
                    }
                    let entries = try await callback()
                    return JSONRPCResponse(id: id, result: [
                        "plugins": .array(entries.map { entry in
                            .object([
                                "id": .string(entry.id),
                                "version": .string(entry.version),
                                "enabled": .bool(entry.enabled),
                                "source": .string(entry.source),
                            ])
                        }),
                    ])

                case "plugin.info":
                    guard let pluginId = params["id"]?.stringValue else {
                        return .invalidParams(id: id, "id required")
                    }
                    guard let callback = onPluginInfo else {
                        return .internalError(id: id, "Plugin info not available")
                    }
                    let info = try await callback(pluginId)
                    var result: [String: JSONValue] = [
                        "id": .string(info.id),
                        "version": .string(info.version),
                        "enabled": .bool(info.enabled),
                        "source": .string(info.source),
                        "state_dir": .string(info.stateDir),
                        "state_dir_size_bytes": .int(Int(info.stateDirSizeBytes)),
                        "log_file": .string(info.logFile),
                        "running": .bool(info.running),
                        "process_names": .array(info.processNames.map { .string($0) }),
                        "capabilities": .object(info.capabilities),
                    ]
                    if let installDir = info.installDir {
                        result["install_dir"] = .string(installDir)
                    }
                    if let displayName = info.displayName {
                        result["display_name"] = .string(displayName)
                    }
                    if let publisher = info.publisher {
                        result["publisher"] = .string(publisher)
                    }
                    return JSONRPCResponse(id: id, result: result)

                case "plugin.install":
                    guard
                        let urlString = params["manifest_url"]?.stringValue,
                        let url = URL(string: urlString)
                    else {
                        return .invalidParams(id: id, "manifest_url required (https URL)")
                    }
                    let yes = params["yes"]?.boolValue == true
                    guard let callback = onPluginInstall else {
                        return .internalError(id: id, "Plugin install not available")
                    }
                    try await callback(url, yes)
                    return .ok(id: id)

                case "plugin.remove":
                    guard let pluginId = params["id"]?.stringValue else {
                        return .invalidParams(id: id, "id required")
                    }
                    let deleteState = params["delete_state"]?.boolValue == true
                    guard let callback = onPluginRemove else {
                        return .internalError(id: id, "Plugin remove not available")
                    }
                    try await callback(pluginId, deleteState)
                    return .ok(id: id)

                case "plugin.enable":
                    guard let pluginId = params["id"]?.stringValue else {
                        return .invalidParams(id: id, "id required")
                    }
                    guard let callback = onPluginEnable else {
                        return .internalError(id: id, "Plugin enable not available")
                    }
                    try await callback(pluginId)
                    return .ok(id: id)

                case "plugin.disable":
                    guard let pluginId = params["id"]?.stringValue else {
                        return .invalidParams(id: id, "id required")
                    }
                    guard let callback = onPluginDisable else {
                        return .internalError(id: id, "Plugin disable not available")
                    }
                    try await callback(pluginId)
                    return .ok(id: id)

                case "plugin.update":
                    // `id` is optional — `nil` means "check every plugin".
                    let pluginId = params["id"]?.stringValue
                    guard let callback = onPluginUpdate else {
                        return .internalError(id: id, "Plugin update not available")
                    }
                    let updates = try await callback(pluginId)
                    return JSONRPCResponse(id: id, result: [
                        "updates": .array(updates.map { update in
                            .object([
                                "id": .string(update.id),
                                "current_version": .string(update.currentVersion),
                                "latest_version": .string(update.latestVersion),
                            ])
                        }),
                    ])

                case "plugin.call":
                    guard let pluginId = params["id"]?.stringValue else {
                        return .invalidParams(id: id, "id required")
                    }
                    guard let method = params["method"]?.stringValue else {
                        return .invalidParams(id: id, "method required")
                    }
                    let inner = params["params"]
                    guard let callback = onPluginCall else {
                        return .internalError(id: id, "Plugin call not available")
                    }
                    let value = try await callback(pluginId, method, inner)
                    // The sidecar's result is arbitrary JSON; wrap it so
                    // the JSONRPCResponse type (which requires an object
                    // result) can carry it without flattening.
                    return JSONRPCResponse(id: id, result: ["result": value])

                case "plugin.logs":
                    guard let pluginId = params["id"]?.stringValue else {
                        return .invalidParams(id: id, "id required")
                    }
                    let lines = params["lines"]?.intValue ?? 256
                    guard let callback = onPluginLogs else {
                        return .internalError(id: id, "Plugin logs not available")
                    }
                    let logs = try await callback(pluginId, lines)
                    return JSONRPCResponse(id: id, result: [
                        "content": .string(logs),
                    ])

                // MARK: - Layout

                case "layout.apply":
                    guard let config = params["config"] else {
                        return .invalidParams(id: id, "config required")
                    }
                    let rebuild = params["rebuild"]?.boolValue == true
                    let detach = params["detach"]?.boolValue == true
                    let dryRun = params["dry_run"]?.boolValue == true
                    let lenient = params["lenient"]?.boolValue == true
                    let requireCreate = params["require_create"]?.boolValue == true
                    let configPath = params["config_path"]?.stringValue
                    guard let callback = onLayoutApply else {
                        return .internalError(id: id, "Layout apply not available")
                    }
                    let result = try await callback(
                        config,
                        rebuild,
                        detach,
                        dryRun,
                        lenient,
                        requireCreate,
                        configPath
                    )
                    return JSONRPCResponse(id: id, result: result)

                default:
                    return .methodNotFound(id: id, request.method)
                }
            } catch let error as LayoutConfigError {
                // Validation errors map to a distinct code so CLI exit codes
                // can match the spec (`2` for invalid configuration).
                return JSONRPCResponse(
                    id: id,
                    error: JSONRPCError(code: "validation_error", message: error.localizedDescription)
                )
            } catch let error as LayoutDriver.DriverError {
                if case let .alreadyExists(name) = error {
                    return JSONRPCResponse(
                        id: id,
                        error: JSONRPCError(
                            code: "session_exists",
                            message: "Session '\(name)' already exists"
                        )
                    )
                }
                return .internalError(id: id, error.localizedDescription)
            } catch {
                return .internalError(id: id, error.localizedDescription)
            }
        }

        // MARK: - Plugin DTOs

        /// One row from `plugin.list` — kept narrow so the route table
        /// doesn't have to know about `PluginRegistryEntry`'s shape.
        public struct PluginListEntry: Sendable, Equatable {
            public let id: String
            public let version: String
            public let enabled: Bool
            public let source: String

            public init(id: String, version: String, enabled: Bool, source: String) {
                self.id = id
                self.version = version
                self.enabled = enabled
                self.source = source
            }
        }

        /// Aggregate response for `plugin.info`. Built by the coordinator
        /// callback from `PluginManager.info(pluginID:)` so the router
        /// stays free of `ClaudeSpyPluginRuntime` types.
        public struct PluginInfoResult: Sendable, Equatable {
            public let id: String
            public let version: String
            public let enabled: Bool
            public let source: String
            public let installDir: String?
            public let stateDir: String
            public let stateDirSizeBytes: Int64
            public let logFile: String
            public let running: Bool
            public let displayName: String?
            public let publisher: String?
            public let processNames: [String]
            public let capabilities: [String: JSONValue]

            public init(
                id: String,
                version: String,
                enabled: Bool,
                source: String,
                installDir: String?,
                stateDir: String,
                stateDirSizeBytes: Int64,
                logFile: String,
                running: Bool,
                displayName: String?,
                publisher: String?,
                processNames: [String],
                capabilities: [String: JSONValue]
            ) {
                self.id = id
                self.version = version
                self.enabled = enabled
                self.source = source
                self.installDir = installDir
                self.stateDir = stateDir
                self.stateDirSizeBytes = stateDirSizeBytes
                self.logFile = logFile
                self.running = running
                self.displayName = displayName
                self.publisher = publisher
                self.processNames = processNames
                self.capabilities = capabilities
            }
        }

        /// One row from `plugin.update`. v1 always returns an empty list;
        /// the type exists so v2 can populate it without changing the wire
        /// contract.
        public struct PluginUpdateResult: Sendable, Equatable {
            public let id: String
            public let currentVersion: String
            public let latestVersion: String

            public init(id: String, currentVersion: String, latestVersion: String) {
                self.id = id
                self.currentVersion = currentVersion
                self.latestVersion = latestVersion
            }
        }

        /// Parses a CLI progress value into a `TerminalProgressState?`.
        ///
        /// `nil` means the bar should be cleared. Recognised inputs:
        /// - `"clear"`, `"none"`, `""` → `nil` (clear)
        /// - `"indeterminate"` → `.indeterminate` (animated scanner — same as `OSC 9;4;3`)
        /// - `"warning"` → `.warning`
        /// - `"error"` → `.error`
        /// - integer in `0...100` → `.normal(value)`
        public enum ProgressParseResult: Sendable, Equatable {
            case success(TerminalProgressState?)
            case failure(String)
        }

        public static func parseProgressValue(_ raw: String) -> ProgressParseResult {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed.lowercased() {
            case "",
                 "clear",
                 "none":
                return .success(nil)
            case "indeterminate":
                return .success(.indeterminate)
            case "warning":
                return .success(.warning)
            case "error":
                return .success(.error)
            default:
                // Accept "50" or "50%" so users can copy values from a UI label.
                let stripped = trimmed.hasSuffix("%") ? String(trimmed.dropLast()) : trimmed
                guard let percent = Int(stripped) else {
                    return .failure(
                        "Unknown progress value '\(raw)'. Use 0-100, 'indeterminate', 'warning', 'error', or 'clear'."
                    )
                }
                guard (0...100).contains(percent) else {
                    return .failure("Progress percentage must be 0-100 (got \(percent)).")
                }
                return .success(.normal(percent))
            }
        }
    }
#endif
