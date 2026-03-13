import Foundation

/// E2E scenario: Window description synchronization across devices
///
/// Verifies that custom window descriptions can be set via context menu on the
/// macOS host and sync correctly to the macOS viewer:
/// 1. Host adds a description via right-click context menu
/// 2. Description appears on both host and viewer
/// 3. Host edits the description via context menu
/// 4. Updated description syncs to both
/// 5. Host removes the description via context menu
/// 6. Description disappears from both
public enum WindowDescriptionSyncScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Window Description Sync",
        tags: ["description", "sync"]
    ) {
        // ── Phase 1: Setup two Mac apps paired ──────────────────────────

        TwoMacPairingScenario.scenario

        // Send a SessionStart hook so pane becomes a Claude session
        TestStep.tmuxStorePaneId(target: "e2e-mac-pair:0.0", storeAs: "paneId")

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

        // ── Phase 2: Verify both apps see the session ───────────────────

        TestStep.macWaitForElement(titled: "e2e-mac-pair:0", timeout: 10)
        TestStep.macWaitForElement(titled: "e2e-mac-pair:0", timeout: 10, instance: 1)

        TestStep.macScreenshot(label: "host-before-description")
        TestStep.macScreenshot(label: "viewer-before-description", instance: 1)

        // ── Phase 3: Add description via context menu on host ───────────

        TestStep.log("Adding description on host via context menu")

        // Right-click the window row and select "Add Description"
        TestStep.macContextMenuClick(elementTitle: "e2e-mac-pair:0", menuItem: "Add Description")

        // The alert appears with a text field — type the description
        TestStep.macWaitForElement(titled: "Window Description", timeout: 5)
        TestStep.macType(text: "My Test Description", pressReturn: false)
        TestStep.macClickButton(titled: "Save")
        TestStep.wait(seconds: 2)

        // ── Phase 4: Verify description on host and viewer ──────────────

        TestStep.log("Verifying description visible on both apps")

        // Host should show the custom description
        TestStep.macWaitForElement(titled: "My Test Description", timeout: 5)
        TestStep.macScreenshot(label: "host-after-add-description")

        // Viewer should also show it (synced via session state)
        TestStep.macWaitForElement(titled: "My Test Description", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-after-add-description", instance: 1)

        // ── Phase 5: Edit description via context menu on host ──────────

        TestStep.log("Editing description on host via context menu")

        // Right-click and select "Edit Description" (now it says Edit, not Add)
        TestStep.macContextMenuClick(elementTitle: "My Test Description", menuItem: "Edit Description")

        // Clear the field and type new description
        TestStep.macWaitForElement(titled: "Window Description", timeout: 5)
        // Select all existing text and replace it
        TestStep.macType(text: "Updated Description", pressReturn: false)
        TestStep.macClickButton(titled: "Save")
        TestStep.wait(seconds: 2)

        // ── Phase 6: Verify updated description on both ─────────────────

        TestStep.log("Verifying updated description on both apps")

        TestStep.macWaitForElement(titled: "Updated Description", timeout: 5)
        TestStep.macScreenshot(label: "host-after-edit-description")

        TestStep.macWaitForElement(titled: "Updated Description", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-after-edit-description", instance: 1)

        // ── Phase 7: Remove description via context menu ────────────────

        TestStep.log("Removing description on host via context menu")

        TestStep.macContextMenuClick(elementTitle: "Updated Description", menuItem: "Remove Description")
        TestStep.wait(seconds: 2)

        // ── Phase 8: Verify description removed on both ─────────────────

        TestStep.log("Verifying description removed on both apps")

        // The custom description should be gone, window ID should be back
        TestStep.macWaitForElementToDisappear(titled: "Updated Description", timeout: 5)
        TestStep.macScreenshot(label: "host-after-remove-description")

        TestStep.macWaitForElementToDisappear(titled: "Updated Description", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-after-remove-description", instance: 1)
    }
}
