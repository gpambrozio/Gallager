import Foundation

// MARK: - Agent Response Request Message

/// Wire envelope sent from Mac → iOS to present (or dismiss) an
/// `AgentResponseRequest` on a specific session/pane.
///
/// Encoded with `keyEncodingStrategy = .convertToSnakeCase` as:
/// ```json
/// {
///   "type": "agent_response_request",
///   "session_id": "abc-123",
///   "plugin_id": "claude-code",
///   "request_id": "uuid-...",
///   "request": { "type": "permission", "body": { ... } }
/// }
/// ```
///
/// When `request` is `nil`, the receiver dismisses any open form whose
/// `requestId` matches — the plugin sidecar uses this to cancel a prompt
/// the user no longer needs to answer (e.g. permission auto-approved by
/// yolo mode, or the underlying tool call was interrupted).
public struct AgentResponseRequestMessage: Codable, Sendable, Equatable {
    /// Discriminator. Always `"agent_response_request"`. Stored so callers can
    /// switch on it after decoding; validated in `init(from:)` so decode
    /// rejects mismatched payloads instead of silently accepting them.
    public let type: String

    /// Agent session this request belongs to.
    public let sessionId: String

    /// Plugin id that owns the session. Matches `PluginPresentation.id`.
    public let pluginId: String

    /// Unique id for this prompt. iOS round-trips it on the matching
    /// `AgentResponseSubmission` so the sidecar can correlate the answer
    /// with the original ask.
    public let requestId: String

    /// The request to present. `nil` means "dismiss the open form whose
    /// `requestId` matches" — used when the underlying ask is no longer
    /// outstanding.
    public let request: AgentResponseRequest?

    public init(
        sessionId: String,
        pluginId: String,
        requestId: String,
        request: AgentResponseRequest?
    ) {
        self.type = Self.discriminator
        self.sessionId = sessionId
        self.pluginId = pluginId
        self.requestId = requestId
        self.request = request
    }

    /// The constant wire `type` value for this message.
    public static let discriminator = "agent_response_request"

    // MARK: - Codable

    // Discriminator-validation choice: keep `type` as a stored property and
    // verify it in `init(from:)` rather than dropping it from the encoded
    // payload. Stored form preserves a stable public API (callers can read
    // `message.type` after decode) while still rejecting wrong payloads.
    private enum CodingKeys: String, CodingKey {
        case type
        case sessionId
        case pluginId
        case requestId
        case request
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == Self.discriminator else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected discriminator '\(Self.discriminator)', got '\(type)'"
            )
        }
        self.type = type
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.pluginId = try container.decode(String.self, forKey: .pluginId)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.request = try container.decodeIfPresent(AgentResponseRequest.self, forKey: .request)
    }
}

// MARK: - Agent Response Submission

/// Wire envelope sent from iOS → Mac with the user's answer to an
/// `AgentResponseRequest`. The Mac hands the payload off to the plugin
/// sidecar identified by `pluginId`, which translates the structured
/// response into whatever its host agent expects (keystrokes, JSON-RPC,
/// HTTP, etc.).
///
/// Encoded with `keyEncodingStrategy = .convertToSnakeCase` as:
/// ```json
/// {
///   "type": "agent_response_submission",
///   "session_id": "abc-123",
///   "plugin_id": "claude-code",
///   "request_id": "uuid-...",
///   "response": { "type": "permission", "body": { ... } }
/// }
/// ```
public struct AgentResponseSubmission: Codable, Sendable, Equatable {
    /// Discriminator. Always `"agent_response_submission"`. Stored so callers
    /// can switch on it after decoding; validated in `init(from:)` so decode
    /// rejects mismatched payloads instead of silently accepting them.
    public let type: String

    /// Agent session this submission belongs to.
    public let sessionId: String

    /// Plugin id that owns the session. Matches the request envelope.
    public let pluginId: String

    /// Echoes the `requestId` from the originating `AgentResponseRequestMessage`
    /// so the sidecar can match the user's answer back to the open ask.
    public let requestId: String

    /// User-supplied response payload.
    public let response: AgentResponse

    public init(
        sessionId: String,
        pluginId: String,
        requestId: String,
        response: AgentResponse
    ) {
        self.type = Self.discriminator
        self.sessionId = sessionId
        self.pluginId = pluginId
        self.requestId = requestId
        self.response = response
    }

    /// The constant wire `type` value for this message.
    public static let discriminator = "agent_response_submission"

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case sessionId
        case pluginId
        case requestId
        case response
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == Self.discriminator else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Expected discriminator '\(Self.discriminator)', got '\(type)'"
            )
        }
        self.type = type
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.pluginId = try container.decode(String.self, forKey: .pluginId)
        self.requestId = try container.decode(String.self, forKey: .requestId)
        self.response = try container.decode(AgentResponse.self, forKey: .response)
    }
}
