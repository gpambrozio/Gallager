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
    /// Discriminator. Always `"agent_session_status"`.
    public let type: String

    /// The session this status update applies to.
    public let sessionId: String

    /// The plugin that owns this session.
    public let pluginID: String

    /// Whether the agent is currently working (processing, not waiting for
    /// input).
    public let working: Bool

    /// Whether the session needs user attention.
    public let attention: Bool

    /// When the status changed.
    public let timestamp: Date

    public init(
        sessionId: String,
        pluginID: String,
        working: Bool,
        attention: Bool,
        timestamp: Date
    ) {
        self.type = Self.discriminator
        self.sessionId = sessionId
        self.pluginID = pluginID
        self.working = working
        self.attention = attention
        self.timestamp = timestamp
    }

    /// The constant wire `type` value for this message.
    public static let discriminator = "agent_session_status"

    // MARK: - Codable

    // Swift's `convertFromSnakeCase` strategy collapses `plugin_id` to
    // `pluginId` (camelCase) on the way in, so the trailing "ID" on the Swift
    // property doesn't line up. Map explicitly so encoding and decoding
    // round-trip cleanly: the strategy then snake_cases `pluginId` to
    // `plugin_id` on the way out.
    private enum CodingKeys: String, CodingKey {
        case type
        case sessionId
        case pluginID = "pluginId"
        case working
        case attention
        case timestamp
    }
}
