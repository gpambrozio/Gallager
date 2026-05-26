import ClaudeSpyNetworking
import Foundation

// MARK: - PluginEvent

/// The envelope sidecars emit on `translate_event` (or push via `emit_event`).
/// Defined in Spec §6.3.
///
/// Wire-format requirement: serialization MUST use a `JSONEncoder` with
/// `keyEncodingStrategy = .convertToSnakeCase` (and decoder with
/// `keyDecodingStrategy = .convertFromSnakeCase`). All field names are
/// camelCase here and map to snake_case on the wire via the strategy.
public struct PluginEvent: Codable, Sendable, Equatable {
    /// Plugin id that originated this event. Matches `PluginManifest.id`.
    public let pluginID: String

    /// Session id the event is scoped to.
    public let sessionID: String

    /// Whether the agent is actively working. `nil` means "no opinion —
    /// leave the current state alone."
    public let working: Bool?

    /// Whether the agent needs the user's attention (waiting on input,
    /// errored, etc.).
    public let attention: Bool

    /// Optional title + body to surface as a Mac notification AND push to
    /// iOS. The sidecar formats the strings; the app does not reshape them.
    public let notification: NotificationSpec?

    /// When set, iOS should surface a response form. The Mac correlates
    /// `request_id` so the eventual `AgentResponse` is routed back to the
    /// originating sidecar via `deliver_response`.
    public let responseRequest: ResponseRequestPayload?

    /// Discrete Mac-side feature triggers (file suggestions, pane close, …).
    /// Defaults to `[]`. The enum is intentionally small and agent-blind;
    /// see `AppAction` in `ClaudeSpyNetworking`.
    public let appActions: [AppAction]

    /// tmux pane id (e.g. `"%42"`) the originating sidecar observed for
    /// this event. Sourced from `IngressContext.tmuxPane` (the `TMUX_PANE`
    /// env var the bridge forwards). The Mac uses this to bootstrap an
    /// `AgentSession` when the sidecar's session id hasn't been mapped to
    /// a pane yet — process-name detection covers the common case, but
    /// non-bundled plugins and stubbed-out E2E scenarios depend on this
    /// fallback. Optional + `decodeIfPresent` so older peers omitting the
    /// field still parse.
    public let tmuxPane: String?

    /// Project path the originating sidecar observed for this event.
    /// Sourced from `IngressContext.projectPath` (the agent's project-dir
    /// env var the bridge forwards). The Mac uses this when bootstrapping
    /// an `AgentSession` so the sidebar can render the project name even
    /// before any tmux refresh tick picks up the pane's working dir.
    public let projectPath: String?

    public init(
        pluginID: String,
        sessionID: String,
        working: Bool?,
        attention: Bool,
        notification: NotificationSpec?,
        responseRequest: ResponseRequestPayload?,
        appActions: [AppAction] = [],
        tmuxPane: String? = nil,
        projectPath: String? = nil
    ) {
        self.pluginID = pluginID
        self.sessionID = sessionID
        self.working = working
        self.attention = attention
        self.notification = notification
        self.responseRequest = responseRequest
        self.appActions = appActions
        self.tmuxPane = tmuxPane
        self.projectPath = projectPath
    }

    // Mac/iOS snake-case-strategy emits `plugin_i_d` for `pluginID` and
    // `session_i_d` for `sessionID` by default. Custom keys keep the wire
    // representation aligned with Spec §6.3 (`plugin_id`, `session_id`).
    private enum CodingKeys: String, CodingKey {
        case pluginID = "pluginId"
        case sessionID = "sessionId"
        case working
        case attention
        case notification
        case responseRequest
        case appActions
        case tmuxPane
        case projectPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pluginID = try container.decode(String.self, forKey: .pluginID)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.working = try container.decodeIfPresent(Bool.self, forKey: .working)
        self.attention = try container.decode(Bool.self, forKey: .attention)
        self.notification = try container.decodeIfPresent(
            NotificationSpec.self,
            forKey: .notification
        )
        self.responseRequest = try container.decodeIfPresent(
            ResponseRequestPayload.self,
            forKey: .responseRequest
        )
        self.appActions =
            try container.decodeIfPresent([AppAction].self, forKey: .appActions) ?? []
        // `tmuxPane` is new in this build — older peers / sidecars omit it
        // entirely, which `decodeIfPresent` already accepts. No fallback
        // needed since there's no legacy key shape.
        self.tmuxPane = try container.decodeIfPresent(String.self, forKey: .tmuxPane)
        self.projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pluginID, forKey: .pluginID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(working, forKey: .working)
        try container.encode(attention, forKey: .attention)
        try container.encodeIfPresent(notification, forKey: .notification)
        try container.encodeIfPresent(responseRequest, forKey: .responseRequest)
        // `appActions` defaults to `[]` on decode so emitting an empty
        // array keeps the wire shape stable; omitting it would change the
        // serialized form across versions.
        try container.encode(appActions, forKey: .appActions)
        try container.encodeIfPresent(tmuxPane, forKey: .tmuxPane)
        try container.encodeIfPresent(projectPath, forKey: .projectPath)
    }

    // MARK: - Convenience

    /// Returns a copy of this event with `tmuxPane` overwritten. Event
    /// translators use this to stamp the pane id from `IngressContext` onto
    /// every emitted envelope without threading the value through each
    /// per-action helper.
    public func withTmuxPane(_ tmuxPane: String?) -> PluginEvent {
        PluginEvent(
            pluginID: pluginID,
            sessionID: sessionID,
            working: working,
            attention: attention,
            notification: notification,
            responseRequest: responseRequest,
            appActions: appActions,
            tmuxPane: tmuxPane,
            projectPath: projectPath
        )
    }

    /// Returns a copy of this event with `projectPath` overwritten. Mirrors
    /// `withTmuxPane` so translators can stamp both ingress-context fields
    /// onto every emitted envelope via chained calls.
    public func withProjectPath(_ projectPath: String?) -> PluginEvent {
        PluginEvent(
            pluginID: pluginID,
            sessionID: sessionID,
            working: working,
            attention: attention,
            notification: notification,
            responseRequest: responseRequest,
            appActions: appActions,
            tmuxPane: tmuxPane,
            projectPath: projectPath
        )
    }

    // MARK: - NotificationSpec

    /// Title + body for a notification surfaced by the Mac and pushed to iOS.
    public struct NotificationSpec: Codable, Sendable, Equatable {
        public let title: String
        public let body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    // MARK: - ResponseRequestPayload

    /// Wrapper that pairs an `AgentResponseRequest` with an opaque
    /// `request_id` the sidecar tracks. The Mac echoes `request_id` back on
    /// `deliver_response` so the sidecar can correlate the submission to its
    /// original event.
    public struct ResponseRequestPayload: Codable, Sendable, Equatable {
        public let requestID: String
        public let request: AgentResponseRequest

        public init(requestID: String, request: AgentResponseRequest) {
            self.requestID = requestID
            self.request = request
        }

        private enum CodingKeys: String, CodingKey {
            case requestID = "requestId"
            case request
        }
    }
}
