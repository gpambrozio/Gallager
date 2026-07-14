import Foundation

// MARK: - Notification Names

public extension Notification.Name {
    static let refreshPaneList = Notification.Name("refreshPaneList")
    static let openPanesWindow = Notification.Name("openPanesWindow")
    static let openContentSearch = Notification.Name("openContentSearch")
    /// Posted when `EditorClient.openFile` returns `false`. `userInfo` carries
    /// a human-readable message under ``editorLaunchFailedMessageKey`` so
    /// `MainView` can surface the failure through its shared alert state.
    static let editorLaunchFailed = Notification.Name("editorLaunchFailed")
    /// Posted by the "Previous Tab" menu item (⌘⇧[). `MainView` walks the
    /// active session's tab strip and selects the tab to the left of the
    /// currently-selected one, wrapping at the leading edge.
    static let selectPreviousTab = Notification.Name("selectPreviousTab")
    /// Posted by the "Next Tab" menu item (⌘⇧]). `MainView` walks the active
    /// session's tab strip and selects the tab to the right of the
    /// currently-selected one, wrapping at the trailing edge.
    static let selectNextTab = Notification.Name("selectNextTab")
    /// Posted by the "Previous Session" menu item (⌘⇧`). `MainView` walks the
    /// sidebar's combined session order — local sessions then each remote
    /// host's — and selects the one before the current selection, wrapping at
    /// the leading edge.
    static let selectPreviousSession = Notification.Name("selectPreviousSession")
    /// Posted by the "Next Session" menu item (⌘`). `MainView` walks the
    /// sidebar's combined session order — local sessions then each remote
    /// host's — and selects the one after the current selection, wrapping at
    /// the trailing edge.
    static let selectNextSession = Notification.Name("selectNextSession")
    /// Posted by the "New Session" menu item (⌘N). `MainView` opens the Local
    /// section's new-session popover, which auto-focuses its search field.
    static let newLocalSession = Notification.Name("newLocalSession")
}

/// `userInfo` key used by ``Notification.Name/editorLaunchFailed`` to carry
/// the alert message.
public let editorLaunchFailedMessageKey = "message"
