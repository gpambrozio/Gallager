import Foundation

/// Progress signal extracted from `OSC 9;4` (ConEmu / Windows-Terminal style),
/// also emitted by Claude Code, Ghostty, Kitty, WezTerm, etc.
/// Format: `ESC ] 9 ; 4 ; <state> ; <progress> BEL/ST`
///
/// Lives in `ClaudeSpyNetworking` because it travels in `PaneState` over the
/// relay so iOS and Mac-as-viewer can render the sidebar bar from the same
/// source of truth as the host.
public enum TerminalProgressState: Codable, Sendable, Equatable {
    /// State 0 — clear any active progress.
    case removed
    /// State 1 — determinate progress (0–100%).
    case normal(Int)
    /// State 2 — error (red).
    case error
    /// State 3 — indeterminate (spinner / scanner).
    case indeterminate
    /// State 4 — warning (yellow).
    case warning

    /// Human-readable summary used as the bar's `.accessibilityValue` and
    /// mirrored into the parent row's hidden AX label so e2e queries and
    /// VoiceOver report the same string from either element.
    public var accessibilityValueString: String {
        switch self {
        case let .normal(percent): "\(percent)%"
        case .error: "error"
        case .warning: "warning"
        case .indeterminate: "in progress"
        case .removed: ""
        }
    }
}
