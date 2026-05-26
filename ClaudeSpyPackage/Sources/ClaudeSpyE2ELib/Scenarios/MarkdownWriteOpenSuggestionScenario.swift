import ClaudeSpyNetworking
import Foundation

/// E2E scenario: Markdown write open suggestion (#396)
///
/// Verifies the "Want to open <file>?" prompt that appears in the window tab
/// bar when Claude writes a markdown file:
/// 1. Sending a `PostToolUse` hook for a `Write` tool with a `.md` file shows
///    the suggestion bar with the file name to the right of the last tab.
/// 2. Clicking "Yes" opens the file as a new tab using the same renderer the
///    file explorer uses (file content visible in the tab).
/// 3. After the file is open, the suggestion bar is gone.
/// 4. A second markdown write replaces the suggestion with the new file name.
/// 5. Clicking "No" dismisses the suggestion without opening anything.
/// 6. A plan-style path (`.../plans/<random>.md`) shows a generic "Want to
///    open the plan?" label instead of the random file name.
public enum MarkdownWriteOpenSuggestionScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Markdown Write Open Suggestion",
        tags: ["hooks", "file-browser", "macos-only"]
    ) {
        // ── Setup ────────────────────────────────────────────────
        TestStep.log("Setup: Create tmux session and launch macOS app")
        TestStep.tmuxCreateSession(name: "writehook", width: 160, height: 50)
        Shortcut.tmuxRunCommand(target: "writehook:0.0", command: "echo '=== WRITE HOOK TEST ==='")

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)

        TestStep.macWaitForElement(titled: "writehook", timeout: 5)
        TestStep.macClickButton(titled: "writehook")
        TestStep.wait(seconds: 3)

        // Capture the pane id so the hook can target this session.
        TestStep.tmuxStorePaneId(target: "writehook:0.0", storeAs: "paneId")

        // ── Phase 1: Write hook for a markdown file shows the bar ─
        TestStep.log("Phase 1: PostToolUse:Write for README.md surfaces the suggestion bar")

        Shortcut.macSendClaudeHook(
            [
                "hook_event_name": .string("PostToolUse"),
                "session_id": .string("writehook-session"),
                "timestamp": .string("2026-04-25T10:00:00.000000Z"),
                "tool_name": .string("Write"),
                "tool_input": .object([
                    "file_path": .string("/Users/test/MyProject/README.md"),
                    "content": .string("# Fake README"),
                ]),
                "tool_response": .object([:]),
            ],
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/MyProject",
            sessionID: "writehook-session"
        )

        // Bar appears with the filename.
        TestStep.macWaitForElement(titled: "Want to open README.md?", timeout: 5)
        TestStep.macScreenshot(label: "mac-suggestion-bar-shown")

        // ── Phase 2: Clicking "Yes" opens the file as a new tab ──
        TestStep.log("Phase 2: Yes button opens the file in a new tab")

        TestStep.macClickButton(titled: "Open suggested file: Yes")

        // The tab strip now has a "File tab: README.md" entry, and the
        // suggestion bar is gone since the user responded.
        TestStep.macWaitForElement(titled: "File tab: README.md", timeout: 5)
        TestStep.macWaitForElementToDisappear(titled: "Want to open README.md?", timeout: 5)
        TestStep.macScreenshot(label: "mac-file-tab-after-yes")

        // ── Phase 3: A second write replaces the suggestion ──────
        TestStep.log("Phase 3: A new Write hook replaces the previous suggestion")

        Shortcut.macSendClaudeHook(
            [
                "hook_event_name": .string("PostToolUse"),
                "session_id": .string("writehook-session"),
                "timestamp": .string("2026-04-25T10:01:00.000000Z"),
                "tool_name": .string("Write"),
                "tool_input": .object([
                    "file_path": .string("/Users/test/MyProject/docs/guide.md"),
                    "content": .string("# Guide"),
                ]),
                "tool_response": .object([:]),
            ],
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/MyProject",
            sessionID: "writehook-session"
        )

        TestStep.macWaitForElement(titled: "Want to open guide.md?", timeout: 5)
        TestStep.macScreenshot(label: "mac-suggestion-bar-replaced")

        // ── Phase 4: Clicking "No" dismisses without opening ─────
        TestStep.log("Phase 4: No button dismisses without opening a tab")

        TestStep.macClickButton(titled: "Open suggested file: No")

        TestStep.macWaitForElementToDisappear(titled: "Want to open guide.md?", timeout: 5)
        // No new file tab was created for guide.md.
        TestStep.macWaitForElementToDisappear(titled: "File tab: guide.md", timeout: 3)
        TestStep.macScreenshot(label: "mac-suggestion-bar-after-no")

        // ── Phase 5: Plan-style path shows generic label ─────────
        // Plans live OUTSIDE the project (typically a temp dir) with random
        // hash filenames, so the bar labels them "Want to open the plan?"
        // instead of the random name. A `plans/` folder *inside* the project
        // would be treated as project documentation and use its filename.
        TestStep.log("Phase 5: Plan-style path uses 'the plan' label, not the random filename")

        Shortcut.macSendClaudeHook(
            [
                "hook_event_name": .string("PostToolUse"),
                "session_id": .string("writehook-session"),
                "timestamp": .string("2026-04-25T10:02:00.000000Z"),
                "tool_name": .string("Write"),
                "tool_input": .object([
                    "file_path": .string("\(NSTemporaryDirectory())plans/8f3c2d.md"),
                    "content": .string("# Plan"),
                ]),
                "tool_response": .object([:]),
            ],
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/MyProject",
            sessionID: "writehook-session"
        )

        TestStep.macWaitForElement(titled: "Want to open the plan?", timeout: 5)
        TestStep.macWaitForElementToDisappear(titled: "Want to open 8f3c2d.md?", timeout: 3)
        TestStep.macScreenshot(label: "mac-suggestion-bar-plan-label")

        // Dismiss to leave the bar in a clean state for cleanup.
        TestStep.macClickButton(titled: "Open suggested file: No")
        TestStep.wait(seconds: 1)

        // ── Phase 6: Non-markdown writes do NOT show the bar ─────
        TestStep.log("Phase 6: Write of a non-markdown file does not show a suggestion")

        Shortcut.macSendClaudeHook(
            [
                "hook_event_name": .string("PostToolUse"),
                "session_id": .string("writehook-session"),
                "timestamp": .string("2026-04-25T10:03:00.000000Z"),
                "tool_name": .string("Write"),
                "tool_input": .object([
                    "file_path": .string("/Users/test/MyProject/notes.txt"),
                    "content": .string("plain text"),
                ]),
                "tool_response": .object([:]),
            ],
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/MyProject",
            sessionID: "writehook-session"
        )

        // No bar should appear for .txt files.
        TestStep.macWaitForElementToDisappear(titled: "Want to open notes.txt?", timeout: 3)
        TestStep.macScreenshot(label: "mac-no-suggestion-for-txt")

        // Tear down the tmux session.
        Shortcut.tmuxRunCommand(target: "writehook:0.0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
