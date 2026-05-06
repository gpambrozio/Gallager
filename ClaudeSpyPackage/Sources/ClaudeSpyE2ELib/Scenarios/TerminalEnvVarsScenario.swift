import Foundation

/// E2E scenario: Verify env vars set on shells spawned via the macOS app's
/// "New Terminal" button.
///
/// Two paths are exercised:
/// 1. `TERM_PROGRAM=iTerm.app` / `TERM_PROGRAM_VERSION=3.6.6` — installed via
///    tmux's `default-command` wrapper to spoof iTerm so Claude Code emits
///    OSC 9;4 progress sequences (#477). tmux 3.2+ overrides `-e TERM_PROGRAM`
///    at shell-spawn time, so this path is the only one that works.
/// 2. `CLAUDE_CODE_NO_FLICKER=1`, `DISABLE_AUTO_UPDATE=true`,
///    `DISABLE_UPDATE_PROMPT=true` — set via tmux `new-session -e` flags
///    (`baseEnvironmentVars`), which tmux honors for vars it doesn't
///    hardcode-overwrite.
///
/// The terminal is created via the app's "New Terminal" button rather than
/// `tmuxCreateSession` so the test exercises the same `TmuxService.createSession`
/// code path users hit, including the chained `set-option ; new-session` that
/// makes the wrapper apply to the very first pane in a fresh tmux server.
public enum TerminalEnvVarsScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal Env Vars",
        tags: ["terminal", "macos-only"]
    ) {
        // 1. Empty state — no existing tmux sessions (clean slate per scenario)
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macWaitForElement(titled: "New Terminal", timeout: 5)

        // 2. Click "New Terminal" — this is the path users take, and the only
        //    path that hits TmuxService.createSession with our wrapper chained.
        TestStep.macClickButton(titled: "New Terminal")
        TestStep.wait(seconds: 3)
        TestStep.macWaitForElement(titled: "terminal", timeout: 10)

        // 3. Capture the spawned pane's ID (stable across base-index configs)
        TestStep.tmuxStorePaneId(target: "terminal", storeAs: "envPane")
        Shortcut.tmuxClearAndSetPrompt(target: "${envPane}")

        // 4. Print the env vars we care about — both groups, sequentially.
        //    Assumes zsh (macOS default and the shell our wrapper resolves on
        //    CI), where `export` without args prints raw `KEY=VALUE` lines —
        //    no quoting, no `export ` prefix — so literal substring matches
        //    work directly. bash would emit `declare -x KEY="VALUE"` which
        //    would defeat the literal assertions below.
        Shortcut.tmuxRunCommand(target: "${envPane}", command: "export | grep TERM_")
        TestStep.wait(seconds: 1)
        Shortcut.tmuxRunCommand(
            target: "${envPane}",
            command: "export | grep -E 'CLAUDE_CODE_NO_FLICKER|DISABLE_AUTO_UPDATE|DISABLE_UPDATE_PROMPT'"
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-env-vars-output")

        // 5. Capture the pane and verify all 5 KEY=VALUE pairs surfaced
        TestStep.tmuxCapturePaneContent(target: "${envPane}", storeAs: "envOutput")

        // TERM_PROGRAM* (default-command wrapper path)
        TestStep.assertStoredContains(key: "envOutput", substring: "TERM_PROGRAM=iTerm.app")
        TestStep.assertStoredContains(key: "envOutput", substring: "TERM_PROGRAM_VERSION=3.6.6")

        // baseEnvironmentVars (tmux `-e` path)
        TestStep.assertStoredContains(key: "envOutput", substring: "CLAUDE_CODE_NO_FLICKER=1")
        TestStep.assertStoredContains(key: "envOutput", substring: "DISABLE_AUTO_UPDATE=true")
        TestStep.assertStoredContains(key: "envOutput", substring: "DISABLE_UPDATE_PROMPT=true")
    }
}
