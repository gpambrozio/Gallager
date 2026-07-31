import Foundation

/// E2E scenario: Verify that OSC-11 background-color probes from inside-pane
/// apps get answered when the pane is opened via ClaudeSpy's new-session
/// flow — the regression guard for `TmuxService.defaultCommandWrapper`.
///
/// ## What this guards against
///
/// `defaultCommandWrapper` is the command tmux invokes for every shell it
/// spawns. It was extended to prepend a `printf` of OSC 10 / OSC 11
/// *setter* sequences before exec'ing the user's shell, so tmux's display
/// parser sees the setters and caches the pane's fg/bg up front. Without
/// that warming, tmux 3.6a doesn't reliably forward OSC-11 *queries* from
/// inside-pane apps to the outer terminal — see [tmux/tmux#4846](https://github.com/tmux/tmux/issues/4846),
/// [openai/codex#22761](https://github.com/openai/codex/issues/22761),
/// [openai/codex#23489](https://github.com/openai/codex/issues/23489).
/// Codex's startup probe (`codex-rs/tui/src/terminal_probe.rs`,
/// `DEFAULT_TIMEOUT = 100 ms`) then times out and Codex falls back to
/// hardcoded colors — including bold + RGB(0,0,0) for the
/// `● Working (… esc to interrupt)` status line, which collapses to
/// invisible on the dark mirror theme.
///
/// ## How the test works
///
/// 1. Start from the empty state (no pre-existing tmux session).
/// 2. Click **New Terminal** in the empty-state panel — this routes through
///    `MainView.createNewSession`, which calls `TmuxService.createSession`,
///    which installs `defaultCommandWrapper` as the server's
///    `default-command`. The first shell spawned in the new pane runs the
///    OSC 10/11 setter printf before the shell takes over.
/// 3. Run `osc_bg_probe.py`. The probe sends `\e]11;?\a`, waits 100 ms for
///    a reply, and renders one of two **dramatically different** screens
///    depending on the outcome:
///    - **OK**: bright green "OK" ASCII banner, a colored bar in the
///      detected bg, four light-grey "● Working" lines.
///    - **FAILED**: bright red "FAILED" ASCII banner, a black-on-black bar
///      (invisible), four bold pure-black "● Working" lines (Codex's
///      actual fallback).
/// 4. Screenshot the mirror. The baseline captures the OK rendering. Any
///    regression (wrapper revert, tmux change, SwiftTerm OSC-handling
///    breakage) flips the script to FAILED — and the screenshot diff lights
///    up across the entire visible pane, not just a one-line label change.
///
/// Companion text assertion: capture the pane content via tmux and verify
/// the literal strings `REGRESSION GUARD INTACT` and `OSC 11 probe
/// succeeded` are present. This catches the regression even if a future
/// SwiftTerm change altered rendering enough to confuse the screenshot
/// diff threshold.
public enum OSCBackgroundProbeScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "OSC Background Probe",
        tags: ["rendering", "macos-only"]
    ) {
        // ── Setup ─────────────────────────────────────────────────────
        //
        // Do NOT pre-create a tmux session — we want to click "New Terminal"
        // from the empty state so the session goes through ClaudeSpy's
        // `TmuxService.createSession` (which installs `defaultCommandWrapper`
        // as `default-command`). A pre-existing `tmuxCreateSession`-test-step
        // session bypasses our code path and wouldn't exercise the wrapper.

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_000, height: 700)

        // ── Create the session via the UI ─────────────────────────────

        TestStep.macWaitForElement(titled: "No Sessions", timeout: 10)
        TestStep.log("Clicking New Terminal to create a session through TmuxService")
        TestStep.macClickButton(titled: "New Terminal")

        // Wait for the empty state to clear — confirms the session was
        // created and the mirror is attached.
        TestStep.macWaitForElementToDisappear(titled: "No Sessions", timeout: 15)
        TestStep.macWaitForElement(titled: "terminal", timeout: 10)

        // Capture the spawned pane's ID rather than guessing a
        // `session:window.pane` target. Pane IDs (`%N`) are stable
        // regardless of the user's `base-index` / `pane-base-index`
        // settings; tmux resolves `target: "terminal"` to the active
        // pane in that session.
        TestStep.tmuxStorePaneId(target: "terminal", storeAs: "probePane")

        // The login-shell pipeline goes:
        //   tmux fork → `/bin/sh -c <defaultCommandWrapper>` (printf + exec)
        //   → zsh -l → sources .zshrc → first prompt → starts reading stdin.
        // Wait until tmux sees `zsh` as the pane's current foreground
        // process before sending anything — otherwise `send-keys` can land
        // in the pty before the shell is consuming input and the commands
        // get queued in a state where Enter doesn't trigger execution.
        TestStep.waitForTmuxDisplayMessage(
            target: "${probePane}",
            format: "#{pane_current_command}",
            contains: "zsh",
            timeout: 10
        )
        // Tiny extra beat so the shell finishes drawing its first prompt
        // before we type at it (waitForTmuxDisplayMessage above only
        // confirms the process is running, not that it's at a prompt).
        TestStep.wait(seconds: 1)

        // ── Stabilize the screen for a deterministic baseline ─────────

        Shortcut.tmuxClearAndSetPrompt(target: "${probePane}")

        // ── Inject and run the probe ──────────────────────────────────

        TestStep.log("Injecting OSC 11 probe script")
        TestStep.injectScript(name: "osc_bg_probe.py")

        TestStep.log("Running OSC 11 probe in pane")
        Shortcut.tmuxRunCommand(
            target: "${probePane}",
            command: "python3 $TMPDIR/osc_bg_probe.py"
        )
        // Probe + render is fast (well under a second), but give the mirror
        // a beat to settle before screenshotting.
        TestStep.wait(seconds: 2)

        // ── Visual baseline + text assertion (defense in depth) ───────

        TestStep.macScreenshot(label: "mac-osc-probe-ok")

        TestStep.tmuxCapturePaneContent(target: "${probePane}", storeAs: "probeOutput")
        TestStep.assertStoredContains(key: "probeOutput", substring: "REGRESSION GUARD INTACT")
        TestStep.assertStoredContains(key: "probeOutput", substring: "OSC 11 probe succeeded")
        TestStep.assertStoredNotContains(key: "probeOutput", substring: "REGRESSION DETECTED")
    }
}
