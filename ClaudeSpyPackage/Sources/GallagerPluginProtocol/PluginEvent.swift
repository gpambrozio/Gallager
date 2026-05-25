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

    public init(
        pluginID: String,
        sessionID: String,
        working: Bool?,
        attention: Bool,
        notification: NotificationSpec?,
        responseRequest: ResponseRequestPayload?,
        appActions: [AppAction] = []
    ) {
        self.pluginID = pluginID
        self.sessionID = sessionID
        self.working = working
        self.attention = attention
        self.notification = notification
        self.responseRequest = responseRequest
        self.appActions = appActions
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
