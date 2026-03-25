import Foundation

/// Reusable scenario building blocks that can be composed into full scenarios.
///
/// Usage in a scenario:
/// ```swift
/// Shortcut.macOnlySetup
/// // ... test-specific steps ...
/// ```
///
/// Shortcuts are `TestScenario` values that get flattened into the parent
/// scenario via `ScenarioBuilder.buildExpression(_: TestScenario)`.
public enum Shortcut {

    // MARK: - macOS Setup

    /// Open the Panes window and configure it with standard sizing.
    ///
    /// Expects the macOS app (instance 0) is already running.
    ///
    /// **Provides:**
    /// - Panes window open, positioned at (10, 10), 1000×600, sidebar width 200
    ///
    /// **Override after** if you need a different size:
    /// ```swift
    /// Shortcut.openPanesWindow
    /// TestStep.macResizeWindow(width: 1_200, height: 700)
    /// ```
    public static let openPanesWindow = ClaudeSpyE2ELib.scenario(
        "Open Panes Window",
        tags: ["shortcut"]
    ) {
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Available Windows", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_000, height: 600)
        TestStep.macSetSidebarWidth(200)
        TestStep.wait(seconds: 1)
    }

    /// Launch the macOS app and open the Panes window with standard sizing.
    ///
    /// Equivalent to `launchMacApp` + `openPanesWindow`.
    /// Used by macOS-only scenarios that don't need server, iOS, or pairing.
    ///
    /// **Provides:**
    /// - macOS app launched (instance 0)
    /// - Panes window open, positioned at (10, 10), 1000×600, sidebar width 200
    ///
    /// **Override after** if you need a different size:
    /// ```swift
    /// Shortcut.macOnlySetup
    /// TestStep.macResizeWindow(width: 1_200, height: 700)
    /// ```
    public static let macOnlySetup = ClaudeSpyE2ELib.scenario(
        "Mac-Only Setup",
        tags: ["shortcut"]
    ) {
        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        Shortcut.openPanesWindow
    }

    // MARK: - Pairing

    /// Pair two Mac apps: host (instance 0) and viewer (instance 1).
    ///
    /// **Provides:**
    /// - Relay server started and healthy
    /// - Mac host (instance 0) launched and connected
    /// - Mac viewer (instance 1) launched and connected
    /// - Both showing "Connected" on their settings pages
    /// - Context variable `pairingCode` stored
    ///
    /// Does **not** create tmux sessions — add those in your scenario.
    public static let twoMacPairing = ClaudeSpyE2ELib.scenario(
        "Two Mac Pairing Setup",
        tags: ["shortcut"]
    ) {
        TestStep.startServer
        TestStep.verifyServerHealth

        // Launch host and generate pairing code
        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)

        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Generate Pairing Code")
        TestStep.wait(seconds: 3)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "pairingCode")

        // Launch viewer and pair with host
        TestStep.launchMacApp(instance: 1)
        TestStep.wait(seconds: 3)

        TestStep.macOpenSettings(instance: 1)
        TestStep.macWaitForWindow(titled: "General", timeout: 5, instance: 1)
        TestStep.macSelectSettingsTab("Remote Hosts", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Add Host", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macFocusElement(titled: "Pairing Code", instance: 1)
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "${pairingCode}", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 5)

        // Verify pairing succeeded
        TestStep.verifyServerHasPairings(count: 1)
        TestStep.waitForHostConnected(timeout: 15)
        TestStep.waitForViewerConnected(timeout: 15)
        TestStep.macWaitForElement(titled: "Connected", timeout: 15)
        TestStep.macWaitForElement(titled: "Connected", timeout: 15, instance: 1)
    }

    /// After `FreshPairingScenario`, add a Mac viewer as instance 1.
    ///
    /// Expects `FreshPairingScenario` already ran (server running, host + iOS paired,
    /// Settings window still open).
    ///
    /// **Provides:**
    /// - Mac viewer (instance 1) launched, paired, and showing "Connected"
    /// - Context variable `viewerPairingCode` stored
    public static let addMacViewer = ClaudeSpyE2ELib.scenario(
        "Add Mac Viewer",
        tags: ["shortcut"]
    ) {
        TestStep.macSelectSettingsTab("Remote Access")
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Add Viewer")
        TestStep.wait(seconds: 3)
        TestStep.macClickButton(titled: "Copy Code")
        TestStep.wait(seconds: 0.5)
        TestStep.macReadClipboard(storeAs: "viewerPairingCode")

        TestStep.launchMacApp(instance: 1)
        TestStep.wait(seconds: 3)

        TestStep.macOpenSettings(instance: 1)
        TestStep.macWaitForWindow(titled: "General", timeout: 5, instance: 1)
        TestStep.macSelectSettingsTab("Remote Hosts", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "Add Host", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macFocusElement(titled: "Pairing Code", instance: 1)
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "${viewerPairingCode}", pressReturn: true, instance: 1)
        TestStep.wait(seconds: 5)

        TestStep.macWaitForElement(titled: "Connected", timeout: 15, instance: 1)
    }
}
