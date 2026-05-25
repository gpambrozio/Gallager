import Foundation

// MARK: - Agent Session Status Update

/// High-frequency wire format sent by the Mac whenever a session's status
/// changes. iOS uses it to update sidebar badges.
///
/// Encoded with `keyEncodingStrategy = .convertToSnakeCase` as:
/// ```json
/// {
///   "type": "agent_session_status",
///   "session_id": "abc-123",
///   "plugin_id": "claude-code",
///   "working": true,
///   "attention": false,
///   "timestamp": "2026-05-24T18:32:11Z"
/// }
/// ```
public struct AgentSessionStatusUpdate: Codable, Sendable, Equatable {
    /// Discriminator. Always `"agent_session_status"`. Stored so callers can
    /// switch on it after decoding; validated in `init(from:)` so decode
    /// rejects mismatched payloads instead of silently accepting them.
    public let type: String

    /// The session this status update applies to.
    public let sessionId: String

    /// The plugin that owns this session. Property name uses lowercase `Id` so
    /// `convertToSnakeCase` produces `plugin_id` on the wire automatically (no
    /// explicit `CodingKeys` needed) — matches the casing in `HookEventMessage`,
    /// `SessionStateMessage`, `PaneState`, etc.
    public let pluginId: String

    /// Whether the agent is currently working (processing, not waiting for
    /// input).
    public let working: Bool

    /// Whether the session needs user attention.
    public let attention: Bool

    /// When the status changed.
    public let timestamp: Date

    public init(
        sessionId: String,
        pluginId: String,
        working: Bool,
        attention: Bool,
        timestamp: Date
    ) {
        self.type = Self.discriminator
        self.sessionId = sessionId
        self.pluginId = pluginId
        self.working = working
        self.attention = attention
        self.timestamp = timestamp
    }

    /// The constant wire `type` value for this message.
    public static let discriminator = "agent_session_status"

    // MARK: - Codable

    // Discriminator-validation choice: keep `type` as a stored property and
    // verify it in `init(from:)` rather than dropping it from the encoded
    // payload. Stored form preserves a stable public API (callers can read
    // `update.type` after decode) while still rejecting wrong payloads.
    private enum CodingKeys: String, CodingKey {
        case type
        case sessionId
        case pluginId
        case working
        case attention
        case timestamp
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
        self.working = try container.decode(Bool.self, forKey: .working)
        self.attention = try container.decode(Bool.self, forKey: .attention)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
    }
}
