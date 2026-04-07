import Foundation

/// E2E scenario: Ctrl-G prompt editor overlay
///
/// Verifies the prompt editor feature that triggers when the GallagerEditor CLI
/// connects to the app's Unix domain socket. The scenario:
/// 1. Creates a tmux session and selects the pane
/// 2. Creates a temp file with prompt text
/// 3. Simulates the CLI connecting to the editor socket via a Python script
/// 4. Verifies the prompt editor overlay appears with the correct content
/// 5. Cancels the editor and verifies the overlay dismisses
/// 6. Re-triggers the editor and submits with modified content
/// 7. Verifies the file was updated with the submitted content
public enum PromptEditorScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Prompt Editor",
        tags: ["macos-only", "editor"]
    ) {
        // 1. Create tmux session
        TestStep.tmuxCreateSession(name: "editor-test", width: 100, height: 30)

        // 2. Launch macOS app and open Panes window
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_000, height: 600)
        TestStep.wait(seconds: 1)

        // Select the pane in the sidebar
        TestStep.macWaitForElement(titled: "editor-test", timeout: 5)
        TestStep.macClickButton(titled: "editor-test")
        TestStep.wait(seconds: 2)

        // 3. Inject the editor trigger script and create a temp file with prompt content
        TestStep.injectScript(name: "editor_trigger.py")

        // Create a temp file with prompt content via tmux
        Shortcut.tmuxRunCommand(
            target: "editor-test:0",
            command: "echo 'Help me write a function that sorts a list of integers' > /tmp/e2e-editor-test.txt"
        )
        TestStep.wait(seconds: 1)

        // 4. Trigger the editor overlay by running the Python script in the background
        //    The pane ID for the first pane is %0
        Shortcut.tmuxRunCommand(
            target: "editor-test:0",
            command: "python3 $TMPDIR/editor_trigger.py %0 /tmp/e2e-editor-test.txt &"
        )
        TestStep.wait(seconds: 3)

        // 5. Verify the editor overlay appeared
        TestStep.macWaitForElement(titled: "Edit Prompt", timeout: 10)
        TestStep.macScreenshot(label: "mac-editor-overlay-visible")

        // 6. Cancel the editor session
        TestStep.macClickButton(titled: "Cancel Editing")
        TestStep.wait(seconds: 2)

        // Verify overlay dismissed
        TestStep.macWaitForElementToDisappear(titled: "Edit Prompt", timeout: 5)
        TestStep.macScreenshot(label: "mac-editor-overlay-dismissed")

        // 7. Re-trigger the editor to test submit flow
        Shortcut.tmuxRunCommand(
            target: "editor-test:0",
            command: "echo 'Original prompt content for submit test' > /tmp/e2e-editor-test2.txt"
        )
        TestStep.wait(seconds: 1)

        Shortcut.tmuxRunCommand(
            target: "editor-test:0",
            command: "python3 $TMPDIR/editor_trigger.py %0 /tmp/e2e-editor-test2.txt &"
        )
        TestStep.wait(seconds: 3)

        // Verify the overlay appeared again
        TestStep.macWaitForElement(titled: "Edit Prompt", timeout: 10)
        TestStep.macScreenshot(label: "mac-editor-overlay-submit-ready")

        // Edit the content: select all and replace with new text
        TestStep.macSelectAll()
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "Edited prompt: please refactor this function")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-editor-overlay-edited")

        // Submit the editor (using the help text on the Submit button)
        TestStep.macClickButton(titled: "Submit Edited Prompt")
        TestStep.wait(seconds: 2)

        // Verify overlay dismissed after submit
        TestStep.macWaitForElementToDisappear(titled: "Edit Prompt", timeout: 5)
        TestStep.macScreenshot(label: "mac-editor-after-submit")

        // 8. Verify the file was updated with the edited content
        TestStep.readFile(path: "/tmp/e2e-editor-test2.txt", storeAs: "editedContent")
        TestStep.assertStoredContains(key: "editedContent", substring: "Edited prompt: please refactor this function")
    }
}
