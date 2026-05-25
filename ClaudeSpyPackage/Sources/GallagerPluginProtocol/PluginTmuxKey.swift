import Foundation

// MARK: - PluginTmuxKey

/// A simplified key descriptor the plugin protocol exposes for sidecar-driven
/// `send_keys` calls.
///
/// `ClaudeSpyServerFeature.TmuxKey` (the canonical key type used by the tmux
/// driver) lives outside this package's dep graph. We mirror the small closed
/// set the sidecars actually emit here and let the app adapter translate to
/// the production key type.
///
/// The raw values match what sidecars emit on the wire as `send_keys` params.
///
/// Lives in `GallagerPluginProtocol` (not `ClaudeSpyPluginRuntime`) so that
/// plugin-core packages — which produce these keys via their keystroke
/// builders — can depend on this type without pulling in the Mac runtime.
public enum PluginTmuxKey: String, Codable, Sendable, Equatable {
    case enter
    case escape
    case tab
    case backspace
    case space

    case up
    case down
    case left
    case right

    case home
    case end
    case pageUp = "page_up"
    case pageDown = "page_down"

    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    case ctrlC = "ctrl_c"
    case ctrlD = "ctrl_d"
    case ctrlZ = "ctrl_z"
}
