import Foundation

/// E2E scenario: Window description synchronization across devices
///
/// Verifies that custom window descriptions can be set via context menu on the
/// macOS host and sync correctly to the iOS viewer:
/// 1. Host adds a description via right-click context menu
/// 2. Description appears on both host and iOS
/// 3. Host edits the description via context menu
/// 4. Updated description syncs to both
/// 5. Host removes the description via context menu
/// 6. Description disappears from both
public enum WindowDescriptionSyncScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Window Description Sync",
        tags: ["description", "sync"]
    ) {
        // ── Phase 1: Fresh pairing (macOS host + iOS viewer) ────────────

        FreshPairingScenario.scenario

        // Create tmux session and make it a Claude session via hook
        TestStep.tmuxCreateSession(name: "e2e-desc", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        TestStep.tmuxStorePaneId(target: "e2e-desc:0.0", storeAs: "paneId")

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-desc-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/DescProject"
        )
        TestStep.wait(seconds: 3)

        // ── Phase 2: Verify session visible on host and iOS ─────────────

        // Open the Panes window on the host to see sidebar rows
        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Available Windows", timeout: 5)
        TestStep.macWaitForElement(titled: "e2e-desc:0", timeout: 10)

        // iOS should show the session with the project name
        TestStep.iosWaitForElement(.labelContains("DescProject"), timeout: 15)

        TestStep.macScreenshot(label: "host-before-description")
        TestStep.iosScreenshot(label: "ios-before-description")

        // ── Phase 3: Add description via context menu on host ───────────

        TestStep.log("Adding description on host via context menu")

        // Right-click the window row and select "Add Description"
        TestStep.macContextMenuClick(elementTitle: "e2e-desc:0", menuItem: "Add Description")

        // Screenshot the alert to see its state
        TestStep.macWaitForElement(titled: "Window Description", timeout: 5)
        TestStep.macScreenshot(label: "host-alert-appeared", compare: false)

        // Press Tab to focus the text field, type, then Return to save
        TestStep.wait(seconds: 0.5)
        TestStep.macPressTab()
        TestStep.macType(text: "My Test Description", pressReturn: false)

        // Screenshot after typing but before saving
        TestStep.macScreenshot(label: "host-alert-text-typed", compare: false)

        TestStep.macClickButton(titled: "Save")
        TestStep.wait(seconds: 2)

        // ── Phase 4: Verify description on host and iOS ─────────────────

        TestStep.log("Verifying description visible on host and iOS")

        // Screenshot first to see what the sidebar looks like
        TestStep.macScreenshot(label: "host-after-save", compare: false)
        TestStep.iosScreenshot(label: "ios-after-save", compare: false)

        // Host should show the custom description
        TestStep.macWaitForElement(titled: "My Test Description", timeout: 10)
        TestStep.macScreenshot(label: "host-after-add-description")

        // iOS should also show it (synced via session state push)
        TestStep.iosWaitForElement(.labelContains("My Test Description"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-after-add-description")

        // ── Phase 5: Edit description via context menu on host ──────────

        TestStep.log("Editing description on host via context menu")

        // Right-click on the description text and select "Edit Description"
        TestStep.macContextMenuClick(elementTitle: "My Test Description", menuItem: "Edit Description")

        // Alert appears with pre-filled text — Tab to focus, type replacement, Return to save
        TestStep.macWaitForElement(titled: "Window Description", timeout: 5)
        TestStep.macScreenshot(label: "host-edit-alert-appeared", compare: false)
        TestStep.wait(seconds: 0.5)
        TestStep.macPressTab()
        TestStep.macType(text: "Updated Description", pressReturn: false)
        TestStep.macScreenshot(label: "host-edit-alert-text-typed", compare: false)
        TestStep.macClickButton(titled: "Save")
        TestStep.wait(seconds: 2)

        // ── Phase 6: Verify updated description on both ─────────────────

        TestStep.log("Verifying updated description on host and iOS")

        TestStep.macScreenshot(label: "host-after-edit-save", compare: false)

        TestStep.macWaitForElement(titled: "Updated Description", timeout: 5)
        TestStep.macScreenshot(label: "host-after-edit-description")

        TestStep.iosWaitForElement(.labelContains("Updated Description"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-after-edit-description")

        // ── Phase 7: Remove description via context menu ────────────────

        TestStep.log("Removing description on host via context menu")

        TestStep.macContextMenuClick(elementTitle: "Updated Description", menuItem: "Remove Description")
        TestStep.wait(seconds: 2)

        // ── Phase 8: Verify description removed on both ─────────────────

        TestStep.log("Verifying description removed on host and iOS")

        // Host: custom description gone, window ID should be visible again
        TestStep.macWaitForElementToDisappear(titled: "Updated Description", timeout: 5)
        TestStep.macWaitForElement(titled: "e2e-desc:0", timeout: 5)
        TestStep.macScreenshot(label: "host-after-remove-description")

        // iOS: description gone, project name should be back as primary label
        TestStep.iosWaitForElement(.labelContains("DescProject"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-after-remove-description")
    }
}
