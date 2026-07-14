import Foundation

/// E2E scenario: prompt editor overlay resizing + type-to-grow (issue #656)
///
/// Verifies the Edit Prompt overlay's sizing behavior on the host:
/// 1. Opens the editor at its default 80% × 50% size
/// 2. Types long lines — the card grows its height to keep the content
///    visible, up to the full pane, after which the text scrolls
/// 3. Drags the bottom-right resize grip far up-left — the card clamps at
///    its minimum size (half the default in each dimension)
/// 4. Types again — the card re-grows to fit the (long) content
/// 5. Submits and verifies the edited content reached the file
public enum PromptEditorResizeScenario {
    /// ~300 chars, wraps to several display lines in the editor so a handful
    /// of typed lines overflow the default card height deterministically.
    private static let longLine = String(
        repeating: "the quick brown fox jumps over the lazy dog ",
        count: 7
    )

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Prompt Editor Resize",
        tags: ["macos-only", "editor", "resize"]
    ) {
        // 1. Create tmux session
        TestStep.tmuxCreateSession(name: "editor-resize", width: 100, height: 30)

        // 2. Launch macOS app and open Panes window
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_000, height: 600)

        // Select the pane in the sidebar
        TestStep.macWaitForElement(titled: "editor-resize", timeout: 5)
        TestStep.macClickButton(titled: "editor-resize")
        TestStep.wait(seconds: 2)

        // 3. Trigger the editor overlay with short content
        TestStep.injectScript(name: "editor_trigger.py")
        TestStep.tmuxStorePaneId(target: "editor-resize:0", storeAs: "editorPane")

        Shortcut.tmuxRunCommand(
            target: "editor-resize:0",
            command: "echo 'Short prompt' > /tmp/e2e-editor-resize.txt"
        )
        TestStep.wait(seconds: 1)

        Shortcut.tmuxRunCommand(
            target: "editor-resize:0",
            command: "python3 $TMPDIR/editor_trigger.py ${editorPane} /tmp/e2e-editor-resize.txt &"
        )

        TestStep.macWaitForElement(titled: "Edit Prompt", timeout: 10)
        TestStep.macScreenshot(label: "mac-editor-default-size")

        // 4. Replace the content with wrapped lines that overflow the default
        //    height — the card grows to keep them visible
        TestStep.macFocusElement(titled: "Short prompt")
        TestStep.wait(seconds: 0.5)
        TestStep.macPressKey(.character("a"), modifiers: .command)
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "grow 1 \(longLine)", pressReturn: true)
        TestStep.macType(text: "grow 2 \(longLine)", pressReturn: true)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-editor-grown-to-fit")

        // 5. Keep typing well past the pane's height — the card stops at the
        //    full pane and the text scrolls instead
        TestStep.macType(text: "grow 3 \(longLine)", pressReturn: true)
        TestStep.macType(text: "grow 4 \(longLine)", pressReturn: true)
        TestStep.macType(text: "grow 5 \(longLine)", pressReturn: true)
        TestStep.macType(text: "grow 6 \(longLine)", pressReturn: true)
        TestStep.macType(text: "grow 7 \(longLine)", pressReturn: false)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-editor-grown-to-max")

        // 6. Drag the bottom-right grip far up-left (onto the sidebar row) —
        //    the card clamps at its minimum size and the content scrolls
        TestStep.macWaitForElementQuery(.label("Resize Prompt Editor"), timeout: 5)
        TestStep.macDragElement(
            from: .label("Resize Prompt Editor"),
            to: .label("editor-resize")
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-editor-shrunk-to-min")

        // 7. Typing again re-grows the card to fit the long content
        TestStep.macFocusElement(titled: "grow 1")
        TestStep.wait(seconds: 0.5)
        TestStep.macType(text: "regrow", pressReturn: false)
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-editor-regrown-after-typing")

        // 8. Submit and verify the edited content reached the file
        TestStep.macClickButton(titled: "Submit Edited Prompt")
        TestStep.macWaitForElementToDisappear(titled: "Edit Prompt", timeout: 5)

        TestStep.readFile(path: "/tmp/e2e-editor-resize.txt", storeAs: "editedContent")
        TestStep.assertStoredContains(key: "editedContent", substring: "grow 7")
        TestStep.assertStoredContains(key: "editedContent", substring: "regrow")
    }
}
