import Foundation

/// E2E scenario: Gallager CLI API
///
/// Verifies the gallager CLI can control the app via Unix socket by
/// exercising commands that produce visible UI changes:
/// 1. Create tmux session and launch app
/// 2. Set up CLI access (socket env var + gallager shell function)
/// 3. ping + list-sessions — verify basic connectivity
/// 4. Baseline screenshot — single session in sidebar
/// 5. new-session — verify new session appears in sidebar
/// 6. list-panes — find pane ID for explicit targeting
/// 7. split-pane — verify window splits into two panes
/// 8. send text — verify text appears in pane
/// 9. new-window — verify a new tab appears
/// 10. list-projects — verify mock projects from in-memory scanner are returned
/// 11. start-project — verify a session is created from a project path
/// 12. start-project with a non-existent path — verify error handling
/// 13. session-state working/waiting/idle/clear — verify sidebar icons switch
/// 14. hook event overrides CLI state — verify hook activity wins
/// 15. TMUX_PANE-based defaulting — when no `--pane`/`--session`/`--window`
///     flag is passed, commands target the calling pane (the cli-test pane)
///     instead of whatever pane is globally active in tmux. Also verifies
///     irrelevant flags (e.g. `--session` to `send`) do not suppress the
///     fallback.
///
/// Strategy: all CLI commands typed into `cli-test:0` via tmuxSendKeys.
/// Commands that need to target e2e-api use explicit pane IDs from list-panes.
/// Sidebar stays on e2e-api for screenshots.
public enum GallagerCLIScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Gallager CLI API",
        tags: ["macos-only", "cli-api"]
    ) {
        // 1. Create tmux session and launch app
        TestStep.tmuxCreateSession(name: "cli-test", width: 100, height: 30)

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)

        // Select the pane in the sidebar
        TestStep.macWaitForElement(titled: "cli-test", timeout: 5)
        TestStep.macClickButton(titled: "cli-test")
        TestStep.wait(seconds: 2)

        // 2. Set up CLI access
        Shortcut.tmuxClearAndSetPrompt(target: "cli-test:0")

        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"export GALLAGER_SOCKET="$TMPDIR/gallager-e2e.sock""#
        )
        TestStep.wait(seconds: 0.5)
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager() { "${macOSAppPath}/Contents/MacOS/GallagerCLI" "$@"; }"#
        )
        TestStep.wait(seconds: 0.5)
        Shortcut.tmuxRunCommand(target: "cli-test:0", command: "clear")
        TestStep.wait(seconds: 0.5)

        // 3. Verify basic connectivity
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager ping > /tmp/e2e-cli-ping.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-ping.txt", storeAs: "pingResult")
        TestStep.assertStoredContains(key: "pingResult", substring: "pong")

        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager list-sessions --json > /tmp/e2e-cli-sessions.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-sessions.txt", storeAs: "sessionsResult")
        TestStep.assertStoredContains(key: "sessionsResult", substring: "sessions")

        // 4. Screenshot: baseline — single session in sidebar
        TestStep.macScreenshot(label: "mac-baseline")

        // 5. Create a new session via CLI
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager new-session --name e2e-api > /tmp/e2e-cli-newsession.txt 2>&1"#
        )

        // Click e2e-api to view it — stay here for all subsequent screenshots
        TestStep.macWaitForElement(titled: "e2e-api", timeout: 5)
        TestStep.macClickButton(titled: "e2e-api")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-new-session-created")

        // 6. Get the pane ID of e2e-api's pane for explicit targeting.
        // Pane IDs are like %0, %1, etc. Extract from list-panes JSON.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"PANE_ID=$(gallager list-panes --window e2e-api:0 --json 2>/dev/null | grep -o '"id":"%[0-9]*"' | head -1 | cut -d'"' -f4)"#
        )
        TestStep.wait(seconds: 2)
        // Verify we got a pane ID
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"echo "PANE=$PANE_ID" > /tmp/e2e-cli-paneid.txt"#
        )
        TestStep.wait(seconds: 0.5)
        TestStep.readFile(path: "/tmp/e2e-cli-paneid.txt", storeAs: "paneIdResult")
        TestStep.assertStoredContains(key: "paneIdResult", substring: "PANE=%")

        // 7. Split the e2e-api pane using explicit pane ID, with an explicit --path.
        // The new pane should open in /tmp (not $HOME), proving --path is wired through.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager split-pane right --pane "$PANE_ID" --path /tmp --json > /tmp/e2e-cli-split.txt 2>&1"#
        )
        TestStep.wait(seconds: 3)
        TestStep.readFile(path: "/tmp/e2e-cli-split.txt", storeAs: "splitResult")
        // tmux resolves symlinks when reporting cwd; on macOS /tmp → /private/tmp.
        TestStep.assertStoredContains(key: "splitResult", substring: #""cwd":"\/private\/tmp""#)
        TestStep.macScreenshot(label: "mac-after-split-pane")

        // 8. Send text to e2e-api's pane using explicit pane ID
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager send 'echo hello-from-gallager-api' --pane "$PANE_ID" && gallager send-key enter --pane "$PANE_ID""#
        )
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-after-send-text")

        // 9. Create a new window in e2e-api — should show a tab bar
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager new-window --session e2e-api > /tmp/e2e-cli-newwin.txt 2>&1"#
        )
        TestStep.wait(seconds: 3)
        TestStep.readFile(path: "/tmp/e2e-cli-newwin.txt", storeAs: "newwinResult")
        TestStep.assertStoredContains(key: "newwinResult", substring: "Created window")
        TestStep.macScreenshot(label: "mac-after-new-window")

        // 10. list-projects — the in-memory scanner returns mock projects
        // (see ClaudeProjectScanner.inMemory(): AlphaProject, BetaProject, …)
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager list-projects --json > /tmp/e2e-cli-projects.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-projects.txt", storeAs: "projectsResult")
        TestStep.assertStoredContains(key: "projectsResult", substring: "AlphaProject")
        TestStep.assertStoredContains(key: "projectsResult", substring: "BetaProject")

        // 11. start-project — create a real directory under /tmp and start a
        // session there. The session should appear in the sidebar.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"mkdir -p /tmp/e2e-start-project && gallager start-project /tmp/e2e-start-project --json > /tmp/e2e-cli-start.txt 2>&1"#
        )
        TestStep.wait(seconds: 3)
        TestStep.readFile(path: "/tmp/e2e-cli-start.txt", storeAs: "startResult")
        TestStep.assertStoredContains(key: "startResult", substring: #""name":"e2e-start-project""#)
        TestStep.macWaitForElement(titled: "e2e-start-project", timeout: 5)
        TestStep.macScreenshot(label: "mac-after-start-project")

        // 12. start-project with a non-existent path — should return an error
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager start-project /tmp/e2e-missing-project-xyz > /tmp/e2e-cli-start-err.txt 2>&1; echo "exit=$?" >> /tmp/e2e-cli-start-err.txt"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-start-err.txt", storeAs: "startErrResult")
        TestStep.assertStoredContains(key: "startErrResult", substring: "Path does not exist")

        // 13. session-state — override the e2e-api session indicator from the CLI.
        // The session has no Claude attached, so the baseline shows the terminal
        // icon. After each set we wait for the matching status label to surface in
        // the accessibility tree (the row exposes statusLabel as hidden text).

        // Capture the original e2e-api pane ID so phase 14 can target it with a hook.
        TestStep.tmuxStorePaneId(target: "e2e-api:0.0", storeAs: "apiPaneId")

        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager session-state working --session e2e-api > /tmp/e2e-cli-state-working.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-state-working.txt", storeAs: "stateWorkingResult")
        TestStep.assertStoredContains(key: "stateWorkingResult", substring: "Set state 'working'")
        TestStep.macWaitForElement(titled: "Working", timeout: 10)
        TestStep.macScreenshot(label: "mac-state-working")

        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager session-state waiting --session e2e-api"#
        )
        TestStep.macWaitForElement(titled: "Waiting for input", timeout: 10)
        TestStep.macScreenshot(label: "mac-state-waiting")

        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager session-state idle --session e2e-api"#
        )
        TestStep.macWaitForElement(titled: "Idle", timeout: 10)
        TestStep.macScreenshot(label: "mac-state-idle")

        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager session-state clear --session e2e-api"#
        )
        // No status label in the row now — terminal icon returns. Confirm the
        // previous "Idle" hint is gone before snapping the cleared screenshot.
        TestStep.macWaitForElementToDisappear(titled: "Idle", timeout: 10)
        TestStep.macScreenshot(label: "mac-state-cleared")

        // 14. hook events override CLI state — re-set "idle" then deliver a
        // UserPromptSubmit. The hook flips the session to Working and clears
        // the CLI override.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager session-state idle --session e2e-api"#
        )
        TestStep.macWaitForElement(titled: "Idle", timeout: 10)

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-api-hook",
                "timestamp": "2026-04-28T10:00:00.000000Z",
                "prompt": "kick off a task"
            }
            """,
            tmuxPane: "${apiPaneId}",
            projectPath: "/tmp/e2e-api"
        )
        TestStep.macWaitForElement(titled: "Working", timeout: 10)
        TestStep.macScreenshot(label: "mac-hook-overrides-cli")

        // 15. TMUX_PANE-based defaulting. Every command up to here used an
        // explicit `--pane`/`--session` flag. The new behavior is that when
        // none of those flags is given, the CLI fills in `pane_id` from
        // `$TMUX_PANE` so the command targets the calling pane (cli-test:0)
        // instead of whatever pane is globally active in tmux.

        // 15a. session-state with no flags should mark cli-test:0's pane.
        // The CLI prints "Set state 'working' on N pane(s)." — applied_to=1
        // means it found exactly the calling pane via TMUX_PANE (not the
        // globally active pane, which would have been e2e-api or another).
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager session-state working > /tmp/e2e-cli-state-default.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-state-default.txt", storeAs: "stateDefaultResult")
        TestStep.assertStoredContains(
            key: "stateDefaultResult",
            substring: "Set state 'working' on 1 pane(s)."
        )

        // Clear via TMUX_PANE default too. "Cleared state on 1 pane(s)."
        // confirms the clear targeted the same single pane.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager session-state clear > /tmp/e2e-cli-state-default-clear.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(
            path: "/tmp/e2e-cli-state-default-clear.txt",
            storeAs: "stateDefaultClearResult"
        )
        TestStep.assertStoredContains(
            key: "stateDefaultClearResult",
            substring: "Cleared state on 1 pane(s)."
        )

        // 15b. list-windows with no flags resolves to the calling session's
        // windows only. cli-test has one window; e2e-api now has two; the
        // start-project session adds another. Filtering proves the pane→session
        // resolution worked.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager list-windows --json > /tmp/e2e-cli-windows-default.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(
            path: "/tmp/e2e-cli-windows-default.txt",
            storeAs: "windowsDefaultResult"
        )
        TestStep.assertStoredContains(
            key: "windowsDefaultResult",
            substring: #""session_id":"cli-test""#
        )
        TestStep.assertStoredNotContains(
            key: "windowsDefaultResult",
            substring: #""session_id":"e2e-api""#
        )
        TestStep.assertStoredNotContains(
            key: "windowsDefaultResult",
            substring: #""session_id":"e2e-start-project""#
        )

        // 15c. list-panes with no flags resolves to the calling window's
        // panes. cli-test:0 has one pane.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager list-panes --json > /tmp/e2e-cli-panes-default.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(
            path: "/tmp/e2e-cli-panes-default.txt",
            storeAs: "panesDefaultResult"
        )
        TestStep.assertStoredContains(
            key: "panesDefaultResult",
            substring: #""window_id":"cli-test:0""#
        )

        // 15d. Irrelevant flags must not suppress the TMUX_PANE fallback.
        // `send` and `send-key` only consume `--pane`. Passing
        // `--session`/`--window` should be silently ignored *without* falling
        // back to the globally active pane. Marker text must land in the
        // cli-test:0 pane (the caller).
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager send 'echo MARKER-DEFAULT-TMUX-PANE' --session does-not-exist && gallager send-key enter --window does-not-exist:0"#
        )
        TestStep.wait(seconds: 2)
        TestStep.tmuxCapturePaneContent(target: "cli-test:0", storeAs: "callerPaneContent")
        TestStep.assertStoredContains(
            key: "callerPaneContent",
            substring: "MARKER-DEFAULT-TMUX-PANE"
        )

        // 16. set-color — assigns a color to a session, persisted as the
        // tmux `@gallager-color` user option and rendered as a SessionColorBar
        // running along the leading edge of the sidebar row. Each platform
        // exposes the bar with `accessibilityLabel("<Name> color")`, so the
        // e2e test can find it by title.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager set-color blue --session e2e-api > /tmp/e2e-cli-color-blue.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-color-blue.txt", storeAs: "colorBlueResult")
        // The CLI canonicalises the color name to its capitalised displayName
        // (so "RED" still prints as "Red"), matching `SessionColor.displayName`.
        TestStep.assertStoredContains(key: "colorBlueResult", substring: "Set session color to Blue.")
        TestStep.macWaitForElement(titled: "Blue color", timeout: 10)
        TestStep.macScreenshot(label: "mac-color-blue")

        // 16b. Verify the option was actually persisted on the tmux server.
        // `display-message -p '#{@gallager-color}'` reads the user option back
        // for the session, so we know set-color hit tmux and not just the UI.
        TestStep.tmuxStoreDisplayMessage(
            target: "e2e-api",
            format: "#{@gallager-color}",
            storeAs: "tmuxColorOption"
        )
        TestStep.assertStoredContains(key: "tmuxColorOption", substring: "blue")

        // 16c. set-color none clears the color. The dot disappears and the
        // tmux option is unset (display-message returns the empty string).
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager set-color none --session e2e-api > /tmp/e2e-cli-color-clear.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-color-clear.txt", storeAs: "colorClearResult")
        TestStep.assertStoredContains(key: "colorClearResult", substring: "Cleared session color.")
        TestStep.macWaitForElementToDisappear(titled: "Blue color", timeout: 10)
        TestStep.macScreenshot(label: "mac-color-cleared")

        // 16d. Unknown color name is rejected so callers don't end up with a
        // session that silently lacks a dot. The CLI exits non-zero and the
        // error message lists the valid options.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager set-color magenta-not-real --session e2e-api > /tmp/e2e-cli-color-bad.txt 2>&1; echo "exit=$?" >> /tmp/e2e-cli-color-bad.txt"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-color-bad.txt", storeAs: "colorBadResult")
        TestStep.assertStoredContains(key: "colorBadResult", substring: "Unknown color")

        // 16e. set-emoji — assigns an emoji icon to a session, persisted as
        // the tmux `@gallager-emoji` user option and rendered as a small
        // emoji badge in the sidebar row. Each platform exposes the badge
        // with `accessibilityLabel("emoji <value>")`.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager set-emoji 🚀 --session e2e-api > /tmp/e2e-cli-emoji-set.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-emoji-set.txt", storeAs: "emojiSetResult")
        TestStep.assertStoredContains(key: "emojiSetResult", substring: "Set session emoji to 🚀.")
        TestStep.macWaitForElement(titled: "emoji 🚀", timeout: 10)
        TestStep.macScreenshot(label: "mac-emoji-set")

        // 16f. Verify the emoji option was actually persisted on the tmux
        // server. `display-message -p '#{@gallager-emoji}'` reads the user
        // option back for the session, so we know set-emoji hit tmux and not
        // just the UI.
        TestStep.tmuxStoreDisplayMessage(
            target: "e2e-api",
            format: "#{@gallager-emoji}",
            storeAs: "tmuxEmojiOption"
        )
        TestStep.assertStoredContains(key: "tmuxEmojiOption", substring: "🚀")

        // 16g. set-emoji also accepts a Unicode name or description instead of
        // a literal emoji character. The CLI resolves "bug" → 🐛 via
        // `Unicode.Scalar.Properties.name`, the success message echoes the
        // resolved name in parens, and the sidebar badge swaps to the new
        // glyph just as it would for a direct emoji argument.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager set-emoji bug --session e2e-api > /tmp/e2e-cli-emoji-by-name.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-emoji-by-name.txt", storeAs: "emojiByNameResult")
        TestStep.assertStoredContains(key: "emojiByNameResult", substring: "Set session emoji to 🐛 (bug).")
        TestStep.macWaitForElementToDisappear(titled: "emoji 🚀", timeout: 10)
        TestStep.macWaitForElement(titled: "emoji 🐛", timeout: 10)
        TestStep.macScreenshot(label: "mac-emoji-set-by-name")

        // Confirm the name-resolved emoji round-tripped to tmux as the literal
        // 🐛 character, not as the string "bug" — i.e. lookup happens CLI-side
        // and the relay/tmux only ever see the resolved glyph.
        TestStep.tmuxStoreDisplayMessage(
            target: "e2e-api",
            format: "#{@gallager-emoji}",
            storeAs: "tmuxEmojiOptionByName"
        )
        TestStep.assertStoredContains(key: "tmuxEmojiOptionByName", substring: "🐛")

        // 16h. find-emoji searches the Unicode emoji database by name. Running
        // it in the terminal must print "<glyph>  <lowercased name>" for every
        // match — an exact name match short-circuits to a single result, so
        // "rocket" is guaranteed to be the only line.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager find-emoji rocket > /tmp/e2e-cli-find-emoji.txt 2>&1; echo "exit=$?" >> /tmp/e2e-cli-find-emoji.txt"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-find-emoji.txt", storeAs: "findEmojiResult")
        TestStep.assertStoredContains(key: "findEmojiResult", substring: "🚀  rocket")
        TestStep.assertStoredContains(key: "findEmojiResult", substring: "exit=0")

        // 16i. set-emoji none clears the emoji. The badge disappears and the
        // tmux option is unset.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager set-emoji none --session e2e-api > /tmp/e2e-cli-emoji-clear.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-emoji-clear.txt", storeAs: "emojiClearResult")
        TestStep.assertStoredContains(key: "emojiClearResult", substring: "Cleared session emoji.")
        TestStep.macWaitForElementToDisappear(titled: "emoji 🐛", timeout: 10)
        TestStep.macScreenshot(label: "mac-emoji-cleared")

        // 17. new-session --color creates a session that opens with the color
        // already set, so the dot appears as soon as the row renders.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager new-session --name e2e-color --color purple > /tmp/e2e-cli-newcolor.txt 2>&1"#
        )
        TestStep.macWaitForElement(titled: "e2e-color", timeout: 10)
        TestStep.macWaitForElement(titled: "Purple color", timeout: 10)
        TestStep.macScreenshot(label: "mac-new-session-with-color")

        // 18. rename-window — the only window-scoped CLI mutation. Sets the
        // tmux window name (the tab label), which the host UI shows as the
        // tab title. We verify both the CLI confirmation and the tmux state.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager rename-window e2e-api:0 renamed-tab > /tmp/e2e-cli-rename.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-rename.txt", storeAs: "renameResult")
        TestStep.assertStoredContains(
            key: "renameResult",
            substring: "Renamed window e2e-api:0 to renamed-tab."
        )
        TestStep.tmuxStoreDisplayMessage(
            target: "e2e-api:0",
            format: "#W",
            storeAs: "tmuxWindowName"
        )
        TestStep.assertStoredContains(key: "tmuxWindowName", substring: "renamed-tab")

        // 18b. rename-window with an empty name is rejected so callers don't
        // end up with a blank tab they can't easily click on.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager rename-window e2e-api:0 "" > /tmp/e2e-cli-rename-bad.txt 2>&1; echo "exit=$?" >> /tmp/e2e-cli-rename-bad.txt"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-rename-bad.txt", storeAs: "renameBadResult")
        TestStep.assertStoredContains(key: "renameBadResult", substring: "name cannot be empty")

        // 19. set-progress — overrides the per-pane progress bar that the
        // host normally derives from `OSC 9;4` sequences. The override syncs
        // through the same `MirrorWindowManager.setPaneProgress` path used by
        // the OSC reader, so the e2e-api row's progress bar appears in the
        // sidebar exactly the same way as a sequence-driven update.

        // 19a. Use --pane to set progress on a pane of a different session.
        // $PANE_ID was captured back at step 6 — it points at e2e-api's pane.
        // The bar must show up on the e2e-api row, not on cli-test.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager set-progress 60 --pane "$PANE_ID" > /tmp/e2e-cli-progress-60.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-progress-60.txt", storeAs: "progress60Result")
        TestStep.assertStoredContains(key: "progress60Result", substring: "Set pane progress to 60%.")
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("Terminal progress"), .valueContains("60%")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-progress-60-other-session")

        // 19b. warning state — full yellow bar.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager set-progress warning --pane "$PANE_ID" > /tmp/e2e-cli-progress-warning.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(
            path: "/tmp/e2e-cli-progress-warning.txt",
            storeAs: "progressWarningResult"
        )
        TestStep.assertStoredContains(
            key: "progressWarningResult",
            substring: "Set pane progress to warning."
        )
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("Terminal progress"), .valueContains("warning")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-progress-warning-other-session")

        // 19c. clear — bar disappears from the e2e-api row.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager set-progress clear --pane "$PANE_ID" > /tmp/e2e-cli-progress-clear.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-progress-clear.txt", storeAs: "progressClearResult")
        TestStep.assertStoredContains(
            key: "progressClearResult",
            substring: "Cleared pane progress."
        )
        TestStep.macWaitForElementToDisappear(titled: "Terminal progress", timeout: 10)
        TestStep.macScreenshot(label: "mac-progress-cleared-other-session")

        // 19d. No --pane: TMUX_PANE-default targeting marks the calling
        // pane (cli-test:0). The bar must appear on the cli-test row, not
        // on e2e-api. We click cli-test in the sidebar so the screenshot
        // captures the row with its progress bar.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager set-progress error > /tmp/e2e-cli-progress-default.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(
            path: "/tmp/e2e-cli-progress-default.txt",
            storeAs: "progressDefaultResult"
        )
        TestStep.assertStoredContains(
            key: "progressDefaultResult",
            substring: "Set pane progress to error."
        )
        // Wait for the error bar to surface on cli-test's row (not e2e-api).
        // The row's combined AX value contains both the session name and the
        // bar's "error" value, so a query that requires both proves the bar
        // landed on the calling pane's session — not on e2e-api or any
        // other tracked pane.
        TestStep.macWaitForElementQuery(
            .allOf([
                .valueContains("cli-test"),
                .labelContains("Terminal progress"),
                .valueContains("error"),
            ]),
            timeout: 10
        )
        TestStep.macClickButton(titled: "cli-test")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-progress-error-calling-pane")

        // Cleanup: clear the bar so later scenarios don't observe a
        // lingering progress override on the calling pane.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager set-progress clear > /dev/null 2>&1"#
        )
        TestStep.macWaitForElementToDisappear(titled: "Terminal progress", timeout: 10)

        // 20. apply — build a tmux session from a declarative YAML. This
        // section exercises the full schema surface: session-level
        // `description`/`color`/`start_directory`/`environment`/
        // `suppress_history`, cold-start `before_script` + `on_create` +
        // always-run `on_apply` hooks, multi-window layout with `focus`,
        // multi-pane window with pane-level `start_directory` + `progress`.
        //
        // The pane-level `start_directory` on w1's *first* pane is the
        // regression case where it used to be silently dropped (only splits
        // cascaded), so the new window ended up at the YAML's directory
        // instead of /tmp.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"rm -f /tmp/e2e-apply-before.txt /tmp/e2e-apply-oncreate.txt /tmp/e2e-apply-onapply.txt"#
        )
        TestStep.wait(seconds: 0.5)
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"printf 'session_name: e2e-apply\ndescription: E2E apply scenario\ncolor: orange\nstart_directory: /tmp\nenvironment:\n  E2E_APPLY_VAR: from-yaml\nsuppress_history: true\nbefore_script: "echo before-script-ran > /tmp/e2e-apply-before.txt"\non_create:\n  - "echo on-create-ran > /tmp/e2e-apply-oncreate.txt"\non_apply:\n  - "echo on-apply-ran > /tmp/e2e-apply-onapply.txt"\nwindows:\n  - window_name: w0\n    panes:\n      - shell_command: echo w0 ready\n  - window_name: w1\n    start_directory: /var\n    layout: main-vertical\n    panes:\n      - start_directory: /tmp\n        shell_command: echo w1-p0 ready\n        progress: 75\n      - shell_command: echo w1-p1 ready\n  - window_name: w2\n    focus: true\n    panes:\n      - shell_command: echo w2 ready\n' > /tmp/e2e-apply.yaml"#
        )
        TestStep.wait(seconds: 1)

        // 20a. Dry-run first: planned actions must show w1's create line
        // landing at `path=/tmp` (not at the YAML dir or window-level
        // `/var`). This is the regression that proves pane > window > session
        // cascading for the first pane of a window.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager apply /tmp/e2e-apply.yaml --dry-run > /tmp/e2e-cli-apply-dry.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-apply-dry.txt", storeAs: "applyDryResult")
        TestStep.assertStoredContains(
            key: "applyDryResult",
            substring: "window.create name=w1"
        )
        TestStep.assertStoredContains(key: "applyDryResult", substring: "path=/tmp")
        // Dry-run also lists the hooks and the focus step so we can confirm
        // the parser routed the schema correctly even before tmux runs.
        TestStep.assertStoredContains(key: "applyDryResult", substring: "before_script: echo before-script-ran")
        TestStep.assertStoredContains(key: "applyDryResult", substring: "on_create: echo on-create-ran")
        TestStep.assertStoredContains(key: "applyDryResult", substring: "on_apply: echo on-apply-ran")
        TestStep.assertStoredContains(key: "applyDryResult", substring: "window.select e2e-apply:w2")
        TestStep.assertStoredContains(key: "applyDryResult", substring: "select_layout main-vertical")

        // 20b. Real apply: --detach keeps focus on cli-test so the sidebar
        // doesn't switch out from under the rest of the scenario.
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager apply /tmp/e2e-apply.yaml --detach --json > /tmp/e2e-cli-apply.txt 2>&1"#
        )
        TestStep.wait(seconds: 3)
        TestStep.readFile(path: "/tmp/e2e-cli-apply.txt", storeAs: "applyResult")
        TestStep.assertStoredContains(key: "applyResult", substring: #""session_name":"e2e-apply""#)
        TestStep.assertStoredContains(key: "applyResult", substring: #""created":true"#)

        // 20c. Sidebar reflects description + color from the YAML. The
        // description is shown as the session title (overriding the tmux
        // session name) and the color renders the dot badge.
        TestStep.macWaitForElement(titled: "E2E apply scenario", timeout: 10)
        TestStep.macWaitForElement(titled: "Orange color", timeout: 10)
        TestStep.macScreenshot(label: "mac-apply-session-created")

        // 20d. Pane cwds verify the start_directory cascade:
        //   - w1 pane 0 has pane.start_directory=/tmp → /private/tmp
        //   - w1 pane 1 (split) has no pane.start_directory and falls back
        //     to window.start_directory=/var → /private/var
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager list-panes --window e2e-apply:1 --json > /tmp/e2e-cli-apply-panes.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-apply-panes.txt", storeAs: "applyPanesResult")
        TestStep.assertStoredContains(
            key: "applyPanesResult",
            substring: #""cwd":"\/private\/tmp""#
        )
        TestStep.assertStoredContains(
            key: "applyPanesResult",
            substring: #""cwd":"\/private\/var""#
        )

        // 20e. focus: true on w2 should have driven the session's current
        // window to w2 even with --detach. list-windows confirms all three
        // windows exist; display-message resolves the session's active
        // window unambiguously (key order in the JSON dict isn't stable, so
        // grepping `"is_active":true` next to `"name":"w2"` would be flaky).
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"gallager list-windows --session e2e-apply --json > /tmp/e2e-cli-apply-windows.txt 2>&1"#
        )
        TestStep.wait(seconds: 2)
        TestStep.readFile(path: "/tmp/e2e-cli-apply-windows.txt", storeAs: "applyWindowsResult")
        TestStep.assertStoredContains(key: "applyWindowsResult", substring: #""name":"w0""#)
        TestStep.assertStoredContains(key: "applyWindowsResult", substring: #""name":"w1""#)
        TestStep.assertStoredContains(key: "applyWindowsResult", substring: #""name":"w2""#)
        TestStep.tmuxStoreDisplayMessage(
            target: "e2e-apply",
            format: "#W",
            storeAs: "applyActiveWindow"
        )
        TestStep.assertStoredContains(key: "applyActiveWindow", substring: "w2")

        // 20f. Hooks: bundle the three hook output files into one read so
        // we only pay one tmuxRunCommand round-trip. before_script runs
        // before tmux is touched; on_create runs after the session is built;
        // on_apply runs every apply (including warm-attach).
        Shortcut.tmuxRunCommand(
            target: "cli-test:0",
            command: #"{ echo BEFORE=$(cat /tmp/e2e-apply-before.txt 2>/dev/null); echo ONCREATE=$(cat /tmp/e2e-apply-oncreate.txt 2>/dev/null); echo ONAPPLY=$(cat /tmp/e2e-apply-onapply.txt 2>/dev/null); } > /tmp/e2e-cli-apply-hooks.txt"#
        )
        TestStep.wait(seconds: 1)
        TestStep.readFile(path: "/tmp/e2e-cli-apply-hooks.txt", storeAs: "applyHooksResult")
        TestStep.assertStoredContains(key: "applyHooksResult", substring: "BEFORE=before-script-ran")
        TestStep.assertStoredContains(key: "applyHooksResult", substring: "ONCREATE=on-create-ran")
        TestStep.assertStoredContains(key: "applyHooksResult", substring: "ONAPPLY=on-apply-ran")

        // 20g. progress: 75 on w1 pane 0 must surface as a sidebar progress
        // bar. The combined AX value includes the session name "E2E apply
        // scenario" (description) and the bar's value; requiring both
        // proves the bar landed on the right pane.
        TestStep.macWaitForElementQuery(
            .allOf([.labelContains("Terminal progress"), .valueContains("75%")]),
            timeout: 10
        )
        TestStep.macScreenshot(label: "mac-apply-progress-75")
    }
}
