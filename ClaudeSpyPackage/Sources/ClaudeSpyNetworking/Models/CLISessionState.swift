import Foundation

/// User-driven session state override set via the gallager CLI.
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
