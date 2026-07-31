import Foundation

/// E2E scenario: Markdown write open suggestion (#396)
///
/// Verifies the "Want to open <file>?" prompt that appears in the window tab
/// bar when Claude writes a markdown file:
/// 1. Sending a `PostToolUse` hook for a `Write` tool with a `.md` file shows
///    the suggestion bar with the file name to the right of the last tab.
/// 2. Clicking "Yes" opens the file as a new tab using the same renderer the
///    file explorer uses (file content visible in the tab).
/// 2.5. Closing that tab returns the user to the originating terminal, not the
///    file browser tree (#700 — the accept path now records a terminal origin).
/// 3. After the file is open, the suggestion bar is gone.
/// 4. A second markdown write replaces the suggestion with the new file name.
/// 5. Clicking "No" dismisses the suggestion without opening anything.
/// 6. A plan-style path (`.../plans/<random>.md`) shows a generic "Want to
///    open the plan?" label instead of the random file name.
/// 7. Accepting the suggestion while the window's Git tab is active records a
///    Git-tab origin, so closing the opened tab reselects the Git tab (#700 —
///    the other routing branch of `openSuggestionOrigin`).
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

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PostToolUse",
                "session_id": "writehook-session",
                "timestamp": "2026-04-25T10:00:00.000000Z",
                "tool_name": "Write",
                "tool_input": {
                    "file_path": "/Users/test/MyProject/README.md",
                    "content": "# Fake README"
                },
                "tool_response": {}
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/MyProject"
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

        // ── Phase 2.5: Closing the opened tab returns to the terminal ─
        // Regression guard for issue #700: a file tab opened from the markdown
        // suggestion while viewing the terminal must record that terminal as
        // its origin, so closing it lands the user back on the originating
        // terminal — not the file browser tree (the pre-fix fallback, which
        // happened because the accept path passed no origin).
        TestStep.log("Phase 2.5: Close the opened file tab and verify the terminal is reselected")
        TestStep.macClickButton(titled: "Close file tab: README.md")
        TestStep.macWaitForElementToDisappear(titled: "File tab: README.md", timeout: 5)

        // The terminal must be the active view again. The terminal-<paneId>
        // element is only mounted when the terminal pane is visible
        // (FileBrowserView and the pane layout are mutually exclusive in
        // MainView), so finding the setup marker text under that identifier
        // proves we landed on the terminal rather than on the file tree.
        TestStep.macWaitForElementQuery(
            .allOf([.identifier("terminal-${paneId}"), .valueContains("WRITE HOOK TEST")]),
            timeout: 5
        )
        // Negative assertion: the file browser tree's search field is gone.
        // Only the tree renders this label, so its absence rules out the
        // pre-#700 fallback that left the tree visible after closing the tab.
        TestStep.macWaitForElementToDisappear(titled: "Search files", timeout: 5)
        TestStep.macScreenshot(label: "mac-terminal-after-suggestion-tab-closed")

        // ── Phase 3: A second write replaces the suggestion ──────
        TestStep.log("Phase 3: A new Write hook replaces the previous suggestion")

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PostToolUse",
                "session_id": "writehook-session",
                "timestamp": "2026-04-25T10:01:00.000000Z",
                "tool_name": "Write",
                "tool_input": {
                    "file_path": "/Users/test/MyProject/docs/guide.md",
                    "content": "# Guide"
                },
                "tool_response": {}
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/MyProject"
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

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PostToolUse",
                "session_id": "writehook-session",
                "timestamp": "2026-04-25T10:02:00.000000Z",
                "tool_name": "Write",
                "tool_input": {
                    "file_path": "\(NSTemporaryDirectory())plans/8f3c2d.md",
                    "content": "# Plan"
                },
                "tool_response": {}
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/MyProject"
        )

        TestStep.macWaitForElement(titled: "Want to open the plan?", timeout: 5)
        TestStep.macWaitForElementToDisappear(titled: "Want to open 8f3c2d.md?", timeout: 3)
        TestStep.macScreenshot(label: "mac-suggestion-bar-plan-label")

        // Dismiss to leave the bar in a clean state for cleanup.
        TestStep.macClickButton(titled: "Open suggested file: No")
        TestStep.wait(seconds: 1)

        // ── Phase 6: Non-markdown writes do NOT show the bar ─────
        TestStep.log("Phase 6: Write of a non-markdown file does not show a suggestion")

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PostToolUse",
                "session_id": "writehook-session",
                "timestamp": "2026-04-25T10:03:00.000000Z",
                "tool_name": "Write",
                "tool_input": {
                    "file_path": "/Users/test/MyProject/notes.txt",
                    "content": "plain text"
                },
                "tool_response": {}
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/MyProject"
        )

        // No bar should appear for .txt files.
        TestStep.macWaitForElementToDisappear(titled: "Want to open notes.txt?", timeout: 3)
        TestStep.macScreenshot(label: "mac-no-suggestion-for-txt")

        // ── Phase 7: Git-tab origin — closing returns to the Git tab ─
        // The other routing branch of #700: accepting the suggestion while the
        // window's Git tab is active records a `.gitTab` origin, so closing the
        // opened file tab must reselect the Git tab — not the terminal, not the
        // file browser tree.
        TestStep.log("Phase 7: Accepting on the Git tab returns there when the tab closes")

        // Activate the Git tab. In e2e mode the workbench is backed by the
        // deterministic MockGitProvider, so the fixture repo name "aurora-cli"
        // renders if and only if the Git tab is the active view.
        TestStep.macClickButton(titled: "Git")
        TestStep.macWaitForElement(titled: "aurora-cli", timeout: 10)

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "PostToolUse",
                "session_id": "writehook-session",
                "timestamp": "2026-04-25T10:04:00.000000Z",
                "tool_name": "Write",
                "tool_input": {
                    "file_path": "/Users/test/MyProject/CHANGELOG.md",
                    "content": "# Changelog"
                },
                "tool_response": {}
            }
            """,
            tmuxPane: "${paneId}",
            projectPath: "/Users/test/MyProject"
        )

        TestStep.macWaitForElement(titled: "Want to open CHANGELOG.md?", timeout: 5)
        TestStep.macClickButton(titled: "Open suggested file: Yes")
        // Opening the tab leaves git mode; the new file tab is the active view.
        TestStep.macWaitForElement(titled: "File tab: CHANGELOG.md", timeout: 5)
        TestStep.macScreenshot(label: "mac-file-tab-opened-from-git-tab")

        TestStep.macClickButton(titled: "Close file tab: CHANGELOG.md")
        TestStep.macWaitForElementToDisappear(titled: "File tab: CHANGELOG.md", timeout: 5)
        // The mock workbench is visible again, proving the recorded `.gitTab`
        // origin routed the close back to the Git tab.
        TestStep.macWaitForElement(titled: "aurora-cli", timeout: 5)
        // Negative assertion: the file browser tree's search field never
        // appeared, ruling out the pre-#700 return-to-tree fallback.
        TestStep.macWaitForElementToDisappear(titled: "Search files", timeout: 5)
        TestStep.macScreenshot(label: "mac-git-tab-after-suggestion-tab-closed")

        // Tear down the tmux session.
        Shortcut.tmuxRunCommand(target: "writehook:0.0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
