import Foundation

/// A named collection of test steps
public struct TestScenario: Sendable {
    public let name: String
    public let tags: [String]
    public let steps: [TestStep]

    public init(name: String, tags: [String] = [], steps: [TestStep]) {
        self.name = name
        self.tags = tags
        self.steps = steps
    }
}

/// Device type for E2E server-side operations
public enum E2EDeviceType: String, Sendable {
    case host
    case viewer
}

/// An individual test step that the orchestrator executes
public enum TestStep: Sendable {
    // MARK: - Server

    /// Start the in-process Vapor server
    case startServer
    /// Verify the server is healthy
    case verifyServerHealth
    /// Verify the number of active pairings
    case verifyServerHasPairings(count: Int)
    /// Wait for the macOS host to connect to the server via WebSocket
    case waitForHostConnected(timeout: TimeInterval = 15)
    /// Wait for the iOS viewer to connect to the server via WebSocket
    case waitForViewerConnected(timeout: TimeInterval = 15)
    /// Disconnect a device type's WebSocket connections on the server
    case serverDisconnectDevice(E2EDeviceType)
    /// Block a device type from connecting and disconnect existing connections.
    /// New WebSocket connections from this device type will be rejected until unblocked.
    case serverBlockDevice(E2EDeviceType)
    /// Unblock a device type, allowing connections again
    case serverUnblockDevice(E2EDeviceType)
    /// Wait until the server has no active pairings
    case waitForNoPairings(timeout: TimeInterval = 15)
    /// Stop the server
    case stopServer

    // MARK: - iOS Simulator

    /// Launch the iOS app in the simulator
    case launchIOSApp
    /// Terminate the iOS app
    case terminateIOSApp
    /// Uninstall the iOS app from the simulator
    case uninstallIOSApp
    /// Wait for an iOS UI element to appear
    case iosWaitForElement(ElementQuery, timeout: TimeInterval = 10)
    /// Tap an iOS UI element
    case iosTap(ElementQuery)
    /// Tap at raw iOS coordinates
    case iosTapCoordinate(x: CGFloat, y: CGFloat)
    /// Type text into the iOS app
    case iosType(text: String)
    /// Swipe left on an iOS UI element
    case iosSwipeLeft(ElementQuery)
    /// Wait for an iOS UI element to disappear
    case iosWaitForElementToDisappear(ElementQuery, timeout: TimeInterval = 10)
    /// Take an iOS screenshot, optionally comparing against a stored baseline
    case iosScreenshot(label: String, compare: Bool = true, tolerance: Double = 0.5, perPixelThreshold: Double = 0.3)
    /// Dump the iOS AX tree to the log (for debugging)
    case iosLogUI

    // MARK: - macOS App

    /// Launch the macOS app
    case launchMacApp
    /// Terminate the macOS app
    case terminateMacApp
    /// Open Settings window
    case macOpenSettings
    /// Wait for a macOS window
    case macWaitForWindow(titled: String, timeout: TimeInterval = 5)
    /// Select a Settings tab
    case macSelectSettingsTab(String)
    /// Click a button by title
    case macClickButton(titled: String)
    /// Click a menu trigger button then click a menu item
    case macClickMenuItem(menuButtonTitle: String, itemTitle: String)
    /// Trigger unpair on the first paired viewer via test HTTP endpoint
    case macUnpair
    /// Read the clipboard and store in context
    case macReadClipboard(storeAs: String)
    /// Wait for a text element to appear in the macOS app's accessibility tree
    case macWaitForElement(titled: String, timeout: TimeInterval = 10)
    /// Wait for a text element to disappear from the macOS app's accessibility tree
    case macWaitForElementToDisappear(titled: String, timeout: TimeInterval = 10)
    /// Open the Panes window via the status item menu
    case macOpenPanesWindow
    /// Move the macOS app window to a screen position
    case macMoveWindow(x: Int, y: Int)
    /// Resize the macOS app window
    case macResizeWindow(width: Int, height: Int)
    /// Set the sidebar width of the NavigationSplitView
    case macSetSidebarWidth(_ width: Int)
    /// Type text into the macOS app (via AppleScript keystroke)
    case macType(text: String, pressReturn: Bool = false)
    /// Take a macOS screenshot, optionally comparing against a stored baseline
    /// Default tolerance of 2% because sometimes the image needs to be normalized
    /// and in this case some pixels will differ.
    case macScreenshot(label: String, compare: Bool = true, tolerance: Double = 2, perPixelThreshold: Double = 0.02)

    // MARK: - Tmux

    /// Create a tmux session on the test socket
    case tmuxCreateSession(name: String, width: Int, height: Int)
    /// Query pane dimensions and store them in the execution context
    case tmuxStorePaneDimensions(target: String, widthKey: String, heightKey: String)
    /// Query the tmux pane ID (e.g. "%0") for a target and store it in the execution context
    case tmuxStorePaneId(target: String, storeAs: String)

    // MARK: - Hook Events

    /// Send a hook event to the macOS app's real hook server (`/api/hooks`) via HTTP POST.
    /// The `json` parameter is the raw JSON body (supports `${var}` interpolation).
    /// `tmuxPane` and `projectPath` are sent as query parameters.
    /// The server port is read from the orchestrator's `hookPortFile`.
    case macSendHookEvent(json: String, tmuxPane: String, projectPath: String? = nil)

    // MARK: - Assertions

    /// Assert two stored context values are equal
    case assertStoredEqual(key: String, otherKey: String)
    /// Assert two stored context values are NOT equal
    case assertStoredNotEqual(key: String, otherKey: String)

    // MARK: - General

    /// Wait for a duration
    case wait(seconds: TimeInterval)
    /// Store a literal value in the execution context
    case storeValue(key: String, value: String)
    /// Log a message
    case log(String)
}
