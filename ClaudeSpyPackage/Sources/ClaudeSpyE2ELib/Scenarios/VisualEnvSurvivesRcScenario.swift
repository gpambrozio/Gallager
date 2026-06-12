import Foundation

/// E2E scenario: `$VISUAL` survives a user rc that exports its own VISUAL
/// (issue #589).
///
/// Reproduces the reported bug and proves the fix. tmux sets
/// `VISUAL=<…>/GallagerCLI edit` on every app session via `-e`, but the pane
/// runs a *login* shell that then sources the user's `~/.zshrc`. A user with
/// `export VISUAL=<their editor>` there used to clobber our value, sending
/// Ctrl-G in Claude Code / Codex to the wrong app.
///
/// The fix redirects zsh's startup through a Gallager `ZDOTDIR` whose `.zshenv`
/// re-asserts `VISUAL` from a `precmd` hook *after* the user's rc files run.
///
/// How this scenario forces the bug condition on CI (where the CI user's
/// `~/.zshrc` doesn't touch VISUAL): it installs a custom `ZDOTDIR` on the tmux
/// *global* environment (the same mechanism `installClaudeStub` uses) whose
/// `.zshrc` sources the real `~/.zshrc` and then `export VISUAL="e2e-user-editor"`.
/// Every app session created afterwards inherits it — so without the fix the new
/// session's `$VISUAL` would be `e2e-user-editor`. We then create a fresh app
/// session via the CLI and assert its shell's `$VISUAL` still resolves to
/// `GallagerCLI edit` (basename, so the assertion is independent of the
/// machine-specific bundle path and never wraps).
public enum VisualEnvSurvivesRcScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Visual Env Survives Rc",
        tags: ["terminal", "editor", "macos-only"]
    ) {
        // 1. Harness session + app launch. This pane is just a driver: we run
        //    tmux + gallager commands from it.
        TestStep.tmuxCreateSession(name: "visual-driver", width: 100, height: 30)

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)

        TestStep.macWaitForElement(titled: "visual-driver", timeout: 5)
        TestStep.macClickButton(titled: "visual-driver")
        TestStep.wait(seconds: 2)

        // 2. Wire up CLI access from the driver pane (the app exports
        //    GALLAGER_SOCKET on its own sessions; the harness pane needs it set).
        Shortcut.tmuxClearAndSetPrompt(target: "visual-driver:0")
        Shortcut.tmuxRunCommand(
            target: "visual-driver:0",
            command: #"export GALLAGER_SOCKET="$TMPDIR/gallager-e2e.sock""#
        )
        Shortcut.tmuxRunCommand(
            target: "visual-driver:0",
            command: #"gallager() { "${macOSAppPath}/Contents/MacOS/GallagerCLI" "$@"; }"#
        )

        // 3. Reproduce the bug condition: a user ZDOTDIR whose .zshrc sources the
        //    real ~/.zshrc and then hijacks VISUAL. Installed on the tmux global
        //    environment so the *next* app session inherits it.
        Shortcut.tmuxRunCommand(
            target: "visual-driver:0",
            command: #"D="$TMPDIR/e2e-visual-zdotdir"; mkdir -p "$D"; printf '[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"\nexport VISUAL="e2e-user-editor"\n' > "$D/.zshrc"; tmux set-environment -g ZDOTDIR "$D""#
        )
        TestStep.wait(seconds: 1)

        // 4. Create a brand-new app session via the CLI. It goes through
        //    TmuxService.createSession (so it gets `-e VISUAL=…GallagerCLI edit`
        //    and the default-command wrapper) and inherits the hijacking ZDOTDIR.
        Shortcut.tmuxRunCommand(
            target: "visual-driver:0",
            command: #"gallager new-session --name visualcheck > /tmp/e2e-visual-newsession.txt 2>&1"#
        )
        TestStep.macWaitForElement(titled: "visualcheck", timeout: 5)
        TestStep.wait(seconds: 3)
        TestStep.macCGClick(titled: "visualcheck")
        TestStep.wait(seconds: 2)

        // 5. Print VISUAL's basename in the new session's shell. With the fix the
        //    precmd hook has restored it to `GallagerCLI edit`; without the fix it
        //    would still be `e2e-user-editor` from the hijacking .zshrc.
        Shortcut.tmuxRunCommand(
            target: "visualcheck:0",
            command: #"echo "VISUAL_BASENAME=[${VISUAL##*/}]""#
        )
        TestStep.wait(seconds: 1)
        // Re-assert the foreground tab right before capturing: the echo above
        // goes through tmux (not the UI), and the earlier click can race the
        // CLI-created session's own foreground switch, leaving the driver pane
        // visible at screenshot time.
        TestStep.macCGClick(titled: "visualcheck")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-visual-survives-rc")

        // 6. Assert against the captured pane content (robust for text checks).
        TestStep.tmuxCapturePaneContent(target: "visualcheck:0", storeAs: "visualOut")
        TestStep.assertStoredContains(key: "visualOut", substring: "VISUAL_BASENAME=[GallagerCLI edit]")
        TestStep.assertStoredNotContains(key: "visualOut", substring: "e2e-user-editor")
    }
}
