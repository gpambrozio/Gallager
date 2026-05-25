import Foundation

// MARK: - KeystrokeStep

/// One step in the keystroke sequence the sidecar runs against an agent's
/// TUI to deliver an `AgentResponse`. The sidecar consumes these
/// sequentially, mapping `.keys` to `send_keys`, `.text` to `send_text`,
/// and `.wait` to a real-time delay between RPC calls.
///
/// Agent-blind — both Claude and Codex plugin builders produce the same
/// `[KeystrokeStep]` shape; only the per-agent key-mapping logic differs.
public enum KeystrokeStep: Sendable, Equatable {
    /// A run of special keys (arrow nav, enter, escape, space).
    case keys([PluginTmuxKey])

    /// Literal text to type into the TUI.
    case text(String)

    /// Delay before the next step. Used when an agent's TUI needs a beat to
    /// re-render between key events.
    case wait(Duration)
}
