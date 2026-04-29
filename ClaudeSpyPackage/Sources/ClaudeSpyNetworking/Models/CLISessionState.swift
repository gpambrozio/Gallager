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
    /// vocabulary users already see in the sidebar.
    public static func parse(_ raw: String) -> ParseResult? {
        switch raw.lowercased() {
        case "clear",
             "none":
            return ParseResult(value: nil)
        case CLISessionState.working.rawValue:
            return ParseResult(value: .working)
        case CLISessionState.idle.rawValue:
            return ParseResult(value: .idle)
        case CLISessionState.waiting.rawValue,
             "waiting-for-input",
             "attention":
            return ParseResult(value: .waiting)
        default:
            return nil
        }
    }

    /// Result of parsing a CLI state argument.
    /// `value == nil` means the caller asked to clear the override.
    public struct ParseResult: Sendable, Equatable {
        public let value: CLISessionState?

        public init(value: CLISessionState?) {
            self.value = value
        }
    }
}
