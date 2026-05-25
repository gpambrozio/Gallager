import ClaudeSpyNetworking
import Foundation

// MARK: - PluginRequestStore

/// Tracks outstanding `AgentResponseRequest`s emitted by a translator so
/// the keystroke builder can later match a `deliver_response` back to the
/// original question shape (per Spec §7.5.1: "the sidecar may want to keep
/// some state per outstanding request_id — e.g., the original question
/// text so it can decide keystroke navigation").
///
/// The translator calls `remember(...)` whenever it emits a response_request.
/// The sidecar's `deliver_response` handler calls `consume(...)` to retrieve
/// (and remove) the saved request when the user submits their answer. If the
/// store is queried after the sidecar restarts, `consume(...)` returns `nil` —
/// the keystroke builder must then fall back to the simplest possible delivery
/// (typically just sending the free-text answer).
///
/// Agent-blind: both Claude and Codex translators use the same store.
public actor PluginRequestStore {
    private var entries: [String: AgentResponseRequest] = [:]

    public init() { }

    /// Record the original `AgentResponseRequest` keyed by `requestID`. The
    /// translator calls this every time it emits a response_request so the
    /// matching response can later be turned into keystrokes against the
    /// original question shape.
    public func remember(requestID: String, request: AgentResponseRequest) {
        entries[requestID] = request
    }

    /// Look up and remove the stored request matching `requestID`. Returns
    /// `nil` when no entry was recorded (e.g., sidecar restarted between
    /// emit and deliver).
    public func consume(requestID: String) -> AgentResponseRequest? {
        entries.removeValue(forKey: requestID)
    }

    /// Test seam: snapshot the current set of pending requests.
    public func pending() -> [String: AgentResponseRequest] {
        entries
    }
}
