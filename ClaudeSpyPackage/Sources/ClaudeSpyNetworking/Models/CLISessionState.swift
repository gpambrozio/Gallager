import Foundation

/// User-driven session state override, set via the gallager CLI (`session
/// set-state`) or the sidebar's "Set State" context menu (issue #695).
///
/// When a value is set on a `PaneState`, the sidebar shows the corresponding
/// indicator regardless of the underlying Claude session state. Receiving a
/// hook event that affects working/notification state on the host clears the
/// override so subsequent hook activity is reflected naturally.
public enum CLISessionState: String, Codable, Sendable, CaseIterable {
    case working
    case idle
    case waiting

    public var statusLabel: String {
        switch self {
        case .working: "Working"
        case .idle: "Idle"
        case .waiting: "Waiting for input"
        }
    }

    /// The state bucket currently *shown* on the sidebar for a session, given a
    /// manual override and the agent's own state. When an override is set it wins
    /// (matching `SessionStatusBadge`); otherwise the bucket is derived from the
    /// agent state. Returns `nil` when the session shows the plain terminal glyph
    /// (no override, no agent session). The "Set State" context menu uses this to
    /// check the item matching what the sidebar shows (issue #695).
    public static func displayed(override: CLISessionState?, agentState: AgentState?) -> CLISessionState? {
        if let override { return override }
        guard let agentState else { return nil }
        if agentState.isActiveWorking { return .working }
        if agentState.needsAttention { return .waiting }
        return .idle
    }

    /// Parses a CLI string into either a concrete state or an explicit clear.
    /// Accepts the raw value and a small set of aliases so the CLI matches the
    /// vocabulary users already see in the sidebar. Returns `nil` for inputs
    /// that don't match any known state or alias.
    public static func parse(_ raw: String) -> ParseResult? {
        switch raw.lowercased() {
        case "clear",
             "none":
            return .clear
        case CLISessionState.working.rawValue:
            return .set(.working)
        case CLISessionState.idle.rawValue:
            return .set(.idle)
        case CLISessionState.waiting.rawValue,
             "waiting-for-input",
             "attention":
            return .set(.waiting)
        default:
            return nil
        }
    }

    /// Result of parsing a CLI state argument.
    public enum ParseResult: Sendable, Equatable {
        case set(CLISessionState)
        case clear

        /// Canonical lowercased name for the parsed state, suitable for
        /// echoing back to the user.
        public var canonicalName: String {
            switch self {
            case let .set(state): state.rawValue
            case .clear: "clear"
            }
        }
    }
}
