import Foundation

/// Returns the display label for a tmux window tab.
/// Shared between `WindowTabBar` (local) and `RemoteWindowTabBar` (remote) so
/// fallback to the window index when no name is set stays consistent.
func windowTabLabel(windowName: String, windowIndex: Int) -> String {
    if !windowName.isEmpty {
        return windowName
    }
    return "\(windowIndex)"
}
