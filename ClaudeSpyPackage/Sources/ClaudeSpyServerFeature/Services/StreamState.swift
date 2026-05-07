#if os(macOS)
    import Foundation

    /// View-side connection state for a pane subscription.
    ///
    /// `PaneStreamManager` owns the actual reader lifecycle now; this enum is
    /// just what mirror/terminal views need to render their own loading,
    /// connected, and error UI.
    enum StreamState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case error(String)

        var isActive: Bool {
            self == .connected
        }
    }
#endif
