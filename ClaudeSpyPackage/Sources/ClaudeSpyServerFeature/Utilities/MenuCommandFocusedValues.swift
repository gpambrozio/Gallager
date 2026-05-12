import SwiftUI

/// Focused-scene action for closing the currently-active tab in the panes
/// window. Set by `MainView.focusedSceneValue` so the global Cmd-W menu
/// item routes to the tab-close logic only when the panes scene is the
/// focused scene. Other scenes (Settings, About, CLI API Reference) don't
/// set this value, so the menu item falls back to `performClose:` against
/// the key window and closes them instead.
public struct CloseCurrentTabActionKey: FocusedValueKey {
    public typealias Value = @MainActor () -> Void
}

public extension FocusedValues {
    var closeCurrentTabAction: CloseCurrentTabActionKey.Value? {
        get { self[CloseCurrentTabActionKey.self] }
        set { self[CloseCurrentTabActionKey.self] = newValue }
    }
}
