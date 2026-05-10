import Foundation

// MARK: - Notification Names

public extension Notification.Name {
    static let refreshPaneList = Notification.Name("refreshPaneList")
    static let openPanesWindow = Notification.Name("openPanesWindow")
    static let closeCurrentTab = Notification.Name("closeCurrentTab")
    static let openCurrentTabInEditor = Notification.Name("openCurrentTabInEditor")
    /// Posted when `EditorClient.openFile` returns `false`. `userInfo` carries
    /// a human-readable message under ``editorLaunchFailedMessageKey`` so
    /// `MainView` can surface the failure through its shared alert state.
    static let editorLaunchFailed = Notification.Name("editorLaunchFailed")
}

/// `userInfo` key used by ``Notification.Name/editorLaunchFailed`` to carry
/// the alert message.
public let editorLaunchFailedMessageKey = "message"
