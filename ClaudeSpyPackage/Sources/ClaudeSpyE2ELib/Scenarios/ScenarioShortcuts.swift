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
///
/// **Note:** Shortcuts use `tags: ["shortcut"]` but are **not** registered in
/// `allScenarios`, so the test runner will never execute them standalone.
public enum Shortcut {
    // MARK: - macOS Setup

    /// Open the Panes window and configure it with standard sizing.
    ///
    /// Expects the macOS app for the given instance is already running.
    ///
    /// **Provides:**
    /// - Panes window open, positioned at (10, 10), 1000×600, sidebar width 250
    ///
    /// **Override after** if you need a different size:
    /// ```swift
    /// Shortcut.openPanesWindow()
    /// TestStep.macResizeWindow(width: 1_200, height: 700)
    /// ```
    public static func openPanesWindow(instance: Int = 0) -> TestScenario {
        ClaudeSpyE2ELib.scenario(
            "Open Panes Window",
            tags: ["shortcut"]
        ) {
            TestStep.macOpenPanesWindow(instance: instance)
            TestStep.macWaitForWindow(titled: "Gallager", timeout: 5, instance: instance)
            TestStep.wait(seconds: 1)
            TestStep.macMoveWindow(x: 10, y: 10, instance: instance)
            TestStep.macResizeWindow(width: 1_000, height: 600, instance: instance)
            TestStep.macSetSidebarWidth(250, instance: instance)
            TestStep.wait(seconds: 1)
        }
    }

    /// Launch the macOS app and open the Panes window with standard sizing.
    ///
    /// Equivalent to `launchMacApp` + `openPanesWindow`.
    /// Used by macOS-only scenarios that don't need server, iOS, or pairing.
    ///
    /// **Provides:**
    /// - macOS app launched (instance 0)
    /// - Panes window open, positioned at (10, 10), 1000×600, sidebar width 250
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

        Shortcut.openPanesWindow()
    }

    // MARK: - Pairing

    /// Pair two Mac apps: host (instance 0) and viewer (instance 1).
    ///
    /// **Provides:**
    /// - Relay server started and healthy
    /// - Mac host (instance 0) launched and connected
    /// - Mac viewer (instance 1) launched and connected
    /// - Both showing "Connected" on their settings pages
    /// - Settings window visible for both instances
    /// - Context variable `twoMac.pairingCode` stored
    ///
    /// **Does not** create tmux sessions or open Panes windows — add those in your scenario.
    ///
    /// **Override after** to open Panes windows:
    /// ```swift
    /// Shortcut.twoMacPairing
    /// Shortcut.openPanesWindow()
    /// Shortcut.openPanesWindow(instance: 1)
    /// ```
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
        TestStep.macReadClipboard(storeAs: "twoMac.pairingCode")

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
        TestStep.macType(text: "${twoMac.pairingCode}", pressReturn: true, instance: 1)

        // Verify pairing succeeded
        TestStep.verifyServerHasPairings(count: 1)
        TestStep.waitForHostConnected(timeout: 15)
        TestStep.waitForViewerConnected(timeout: 15)
        TestStep.macWaitForElement(titled: "Viewer connected", timeout: 15)
        TestStep.macWaitForElement(titled: "Host connected", timeout: 15, instance: 1)
    }

    // MARK: - tmux Commands

    /// Run a command in a tmux pane (send keys + Enter).
    ///
    /// Combines the common two-step pattern of sending literal keys followed
    /// by pressing Enter into a single shortcut.
    ///
    /// **Example:**
    /// ```swift
    /// Shortcut.tmuxRunCommand(target: "my-session:0", command: "echo hello")
    /// ```
    public static func tmuxRunCommand(
        target: String,
        command: String,
        literal: Bool = true
    ) -> TestScenario {
        ClaudeSpyE2ELib.scenario(
            "tmux Run Command",
            tags: ["shortcut"]
        ) {
            TestStep.tmuxSendKeys(target: target, keys: command, literal: literal)
            TestStep.tmuxSendKeys(target: target, keys: "Enter")
        }
    }

    /// Set a plain prompt (`$ `) and clear the terminal screen.
    ///
    /// Useful when the test needs a clean screen without shell color codes
    /// interfering with rendering assertions.
    ///
    /// **Example:**
    /// ```swift
    /// Shortcut.tmuxClearAndSetPrompt(target: "my-session:0")
    /// ```
    public static func tmuxClearAndSetPrompt(target: String) -> TestScenario {
        ClaudeSpyE2ELib.scenario(
            "tmux Clear and Set Prompt",
            tags: ["shortcut"]
        ) {
            Shortcut.tmuxRunCommand(target: target, command: #"export PS1='$ '"#)
            Shortcut.tmuxRunCommand(target: target, command: "clear")
            TestStep.wait(seconds: 1)
        }
    }

    // MARK: - iOS Navigation

    /// Wait for an iOS session to appear, tap it, and wait for the terminal to connect.
    ///
    /// Encapsulates the common pattern of navigating to a terminal pane on iOS:
    /// wait for the session row, tap it, then wait for "Connecting" to disappear.
    ///
    /// **Example:**
    /// ```swift
    /// Shortcut.iosConnectToSession(sessionName: "my-session")
    /// ```
    public static func iosConnectToSession(sessionName: String) -> TestScenario {
        ClaudeSpyE2ELib.scenario(
            "iOS Connect to Session",
            tags: ["shortcut"]
        ) {
            TestStep.iosWaitForElement(.labelContains(sessionName), timeout: 15)
            TestStep.iosTap(.labelContains(sessionName))
            TestStep.iosWaitForElementToDisappear(.labelContains("Connecting"), timeout: 15)
        }
    }

    // MARK: - iOS Commands Menu

    /// Tap an item inside the iOS "Commands" toolbar menu.
    ///
    /// Opens the menu, waits for the item to appear, and taps it.
    /// The menu auto-dismisses after the tap.
    ///
    /// **Example:**
    /// ```swift
    /// Shortcut.iosTapCommandsMenuItem("Enable Yolo Mode")
    /// ```
    public static func iosTapCommandsMenuItem(
        _ label: String,
        timeout: TimeInterval = 5
    ) -> TestScenario {
        ClaudeSpyE2ELib.scenario(
            "iOS Tap Commands Menu Item",
            tags: ["shortcut"]
        ) {
            TestStep.iosTap(.labelContains("Commands"))
            TestStep.iosWaitForElement(.labelContains(label), timeout: timeout)
            TestStep.iosTap(.labelContains(label))
        }
    }

    /// Verify an item exists inside the iOS "Commands" toolbar menu.
    ///
    /// Opens the menu, waits for the item to appear, then dismisses
    /// the menu by tapping outside it.
    ///
    /// **Example:**
    /// ```swift
    /// Shortcut.iosVerifyCommandsMenuItem("Disable Yolo Mode", timeout: 10)
    /// ```
    public static func iosVerifyCommandsMenuItem(
        _ label: String,
        timeout: TimeInterval = 5
    ) -> TestScenario {
        ClaudeSpyE2ELib.scenario(
            "iOS Verify Commands Menu Item",
            tags: ["shortcut"]
        ) {
            TestStep.iosTap(.labelContains("Commands"))
            TestStep.iosWaitForElement(.labelContains(label), timeout: timeout)
            // Dismiss menu by tapping the terminal area
            TestStep.iosTapCoordinate(x: 200, y: 500)
            TestStep.wait(seconds: 0.5)
        }
    }

    // MARK: - Additional Pairing

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
        // Fail fast if Settings window isn't open for instance 0
        // After FreshPairingScenario, Settings is on "Remote Access" tab
        TestStep.macWaitForWindow(titled: "Remote Access", timeout: 5)
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

        TestStep.macWaitForElement(titled: "Host connected", timeout: 15, instance: 1)
    }
}
