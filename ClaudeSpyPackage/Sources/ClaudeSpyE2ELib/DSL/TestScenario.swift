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

/// An individual test step that the orchestrator executes
public enum TestStep: Sendable {
    // MARK: - Server

    /// Start the in-process Vapor server
    case startServer(port: Int = 8_765)
    /// Verify the server is healthy
    case verifyServerHealth
    /// Verify the number of active pairings
    case verifyServerHasPairings(count: Int)
    /// Stop the server
    case stopServer

    // MARK: - iOS Simulator

    /// Launch the iOS app in the simulator
    case launchIOSApp(arguments: [String] = [])
    /// Terminate the iOS app
    case terminateIOSApp
    /// Wait for an iOS UI element to appear
    case iosWaitForElement(ElementQuery, timeout: TimeInterval = 10)
    /// Tap an iOS UI element
    case iosTap(ElementQuery)
    /// Tap at raw iOS coordinates
    case iosTapCoordinate(x: CGFloat, y: CGFloat)
    /// Type text into the iOS app
    case iosType(text: String)
    /// Take an iOS screenshot
    case iosScreenshot(label: String)

    // MARK: - macOS App

    /// Launch the macOS app
    case launchMacApp(arguments: [String] = [])
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
    /// Read the clipboard and store in context
    case macReadClipboard(storeAs: String)
    /// Take a macOS screenshot
    case macScreenshot(label: String)

    // MARK: - General

    /// Wait for a duration
    case wait(seconds: TimeInterval)
    /// Store a literal value in the execution context
    case storeValue(key: String, value: String)
    /// Log a message
    case log(String)
}
