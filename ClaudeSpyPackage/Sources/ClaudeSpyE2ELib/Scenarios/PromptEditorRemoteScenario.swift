import Foundation

/// E2E scenario: Ctrl-G prompt editor overlay (host + remote viewer)
///
/// Verifies the prompt editor feature on both host and viewer:
/// 1. Pairs two Mac apps (host + viewer), creates tmux session
/// 2. Triggers editor on host, verifies overlay appears on both host and viewer
/// 3. Cancels on host, verifies overlay disappears on both
/// 4. Triggers again, edits text on the VIEWER, submits from viewer
/// 5. Verifies the file on the host was updated with the viewer's edited content
public enum PromptEditorRemoteScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Prompt Editor Remote",
        tags: ["macos-only", "editor"]
    ) {
        // 1. Pair two Mac apps (host = instance 0, viewer = instance 1)
        Shortcut.twoMacPairing

        // 2. Close Settings windows so Panes window becomes key when activated
        TestStep.macCloseWindow(titled: "Remote Access")
        TestStep.macCloseWindow(titled: "Remote Hosts", instance: 1)
        TestStep.wait(seconds: 1)

        // 3. Create tmux session on host
        TestStep.tmuxCreateSession(name: "editor-test", width: 100, height: 30)
        TestStep.wait(seconds: 3)

        // 4. Open Panes windows on both host and viewer, select the pane
        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "editor-test", timeout: 10)
        TestStep.macClickButton(titled: "editor-test")
        TestStep.wait(seconds: 2)

        Shortcut.openPanesWindow(instance: 1)
        TestStep.macWaitForElement(titled: "editor-test", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "editor-test", instance: 1)
        TestStep.wait(seconds: 2)

        // 5. Inject trigger script and create prompt file
        TestStep.injectScript(name: "editor_trigger.py")

        Shortcut.tmuxRunCommand(
            target: "editor-test:0",
            command: "echo 'Help me write a sorting function' > /tmp/e2e-editor-test.txt"
        )
        TestStep.wait(seconds: 1)

        // 6. Trigger editor — verify overlay appears on BOTH host and viewer
        Shortcut.tmuxRunCommand(
            target: "editor-test:0",
            command: "python3 $TMPDIR/editor_trigger.py %0 /tmp/e2e-editor-test.txt &"
        )
        TestStep.wait(seconds: 3)

        TestStep.macWaitForElement(titled: "Edit Prompt", timeout: 10)
        TestStep.macScreenshot(label: "host-editor-overlay-visible")

        TestStep.macWaitForElement(titled: "Edit Prompt", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-editor-overlay-visible", instance: 1)

        // 7. Cancel on host — verify overlay disappears on BOTH
        TestStep.macClickButton(titled: "Cancel Editing")
        TestStep.wait(seconds: 2)

        TestStep.macWaitForElementToDisappear(titled: "Edit Prompt", timeout: 5)
        TestStep.macScreenshot(label: "host-editor-overlay-dismissed")

        TestStep.macWaitForElementToDisappear(titled: "Edit Prompt", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-editor-overlay-dismissed", instance: 1)

        // 8. Trigger again — edit and submit from the VIEWER
        Shortcut.tmuxRunCommand(
            target: "editor-test:0",
            command: "echo 'Original prompt for viewer edit' > /tmp/e2e-editor-viewer.txt"
        )
        TestStep.wait(seconds: 1)

        Shortcut.tmuxRunCommand(
            target: "editor-test:0",
            command: "python3 $TMPDIR/editor_trigger.py %0 /tmp/e2e-editor-viewer.txt &"
        )
        TestStep.wait(seconds: 3)

        // Verify overlay appears on viewer
        TestStep.macWaitForElement(titled: "Edit Prompt", timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-editor-overlay-for-edit", instance: 1)

        // Click on the TextEditor to give it keyboard focus, then select all and type
        TestStep.macFocusElement(titled: "Original prompt for viewer edit", instance: 1)
        TestStep.wait(seconds: 0.5)
        TestStep.macSelectAll(instance: 1)
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "Viewer edited: add error handling", instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "viewer-editor-overlay-edited", instance: 1)

        TestStep.macClickButton(titled: "Submit Edited Prompt", instance: 1)
        TestStep.wait(seconds: 2)

        // Verify overlay dismissed on both
        TestStep.macWaitForElementToDisappear(titled: "Edit Prompt", timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-editor-after-submit", instance: 1)

        TestStep.macWaitForElementToDisappear(titled: "Edit Prompt", timeout: 5)
        TestStep.macScreenshot(label: "host-editor-after-viewer-submit")

        // 9. Verify the file on host has the VIEWER's edited content
        TestStep.readFile(path: "/tmp/e2e-editor-viewer.txt", storeAs: "viewerEditedContent")
        TestStep.assertStoredContains(key: "viewerEditedContent", substring: "Viewer edited: add error handling")
    }
}
