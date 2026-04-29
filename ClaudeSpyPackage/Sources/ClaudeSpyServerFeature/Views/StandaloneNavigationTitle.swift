import SwiftUI

extension View {
    /// Applies `navigationTitle` only when `condition` is true.
    ///
    /// Used by views that are reused both as tiles inside a parent split view
    /// (where the parent's title must remain in effect) and as standalone
    /// mirror windows (where the view should set its own window title).
    @ViewBuilder
    func standaloneNavigationTitle(_ title: String, when condition: Bool) -> some View {
        if condition {
            navigationTitle(title)
        } else {
            self
        }
    }
}
