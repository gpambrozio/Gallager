import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation

/// One outstanding plugin-driven response request that the iOS UI is presenting
/// (or about to present). Wraps the wire `AgentResponseRequest` alongside the
/// routing fields the views need to ship the user's answer back via the
/// command channel.
///
/// Identified by the `requestId` from the originating
/// `AgentResponseRequestMessage`, so a `Set`/`Dictionary` keyed by `id`
/// deduplicates retries and `ForEach`/sheet presentation can use the same id.
public struct OpenResponseRequest: Sendable, Equatable, Identifiable {
    /// `requestId` from the originating `AgentResponseRequestMessage`.
    /// Round-trips back to the sidecar on the matching `AgentResponseSubmission`.
    public let id: String

    /// Pair id of the host that pushed the request. Used to route the
    /// submission back to the correct WebSocket.
    public let hostID: String

    /// Agent session this request belongs to.
    public let sessionID: String

    /// Plugin id that owns the session. Matches `PluginPresentation.id`.
    public let pluginID: String

    /// The structured request to render.
    public let request: AgentResponseRequest

    /// When iOS first received this request. Used for sorting if multiple
    /// requests pile up on the same session.
    public let receivedAt: Date

    public init(
        id: String,
        hostID: String,
        sessionID: String,
        pluginID: String,
        request: AgentResponseRequest,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.hostID = hostID
        self.sessionID = sessionID
        self.pluginID = pluginID
        self.request = request
        self.receivedAt = receivedAt
    }

    /// Bridge initializer from the wire envelope stored on `SessionStore`.
    public init(entry: ResponseRequestEntry, receivedAt: Date = Date()) {
        self.id = entry.requestId
        self.hostID = entry.hostId
        self.sessionID = entry.sessionId
        self.pluginID = entry.pluginId
        self.request = entry.request
        self.receivedAt = receivedAt
    }
}
