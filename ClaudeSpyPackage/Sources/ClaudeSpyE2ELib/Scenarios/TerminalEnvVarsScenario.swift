import Foundation

/// E2E scenario: Verify env vars set on shells spawned via the macOS app's
/// "New Terminal" button.
///
/// Exercises every var Gallager injects into app-created panes:
/// 1. `TERM_PROGRAM=iTerm.app` / `TERM_PROGRAM_VERSION=3.6.6` — installed via
///    tmux's `default-command` wrapper to spoof iTerm so Claude Code emits
///    OSC 9;4 progress sequences (#477). tmux 3.2+ overrides `-e TERM_PROGRAM`
///    at shell-spawn time, so this path is the only one that works.
/// 2. `TERM=screen-256color` — pinned via the server `default-terminal` option
///    (assigned at shell-spawn time like TERM_PROGRAM, so `-e TERM` wouldn't
///    stick) so the mirror gets a 256-color-capable terminal instead of tmux's
///    build default.
/// 3. `CLAUDE_CODE_NO_FLICKER=1`, `COLORTERM=truecolor`,
///    `CLAUDE_CODE_ACCESSIBILITY=1`, `LANG=<utf8>`, `DISABLE_AUTO_UPDATE=true`,
///    `DISABLE_UPDATE_PROMPT=true` — set via tmux `new-session -e` flags
///    (`baseEnvironmentVars`), which tmux honors for vars it doesn't
///    hardcode-overwrite.
/// 4. `ZDOTDIR=<shim>` history suppression — e2e shells source their zsh
///    startup files from the orchestrator's shim dir, which delegates to the
///    user's real dotfiles and then unsets `HISTFILE` so scenario-typed
///    commands never land in `~/.zsh_history`. Verified on BOTH spawn paths:
///    the app-created pane (`--zdotdir` → `TmuxService.zdotDirOverride`) and
///    an orchestrator-created session (`tmuxCreateSession`'s `new-session -e`).
///
/// The terminal is created via the app's "New Terminal" button rather than
/// `tmuxCreateSession` so the test exercises the same `TmuxService.createSession`
/// code path users hit, including the chained `set-option ; new-session` that
/// makes the wrapper and `default-terminal` apply to the very first pane in a
/// fresh tmux server.
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
        //    path that hits TmuxService.createSession with our wrapper +
        //    default-terminal chained.
        TestStep.macClickButton(titled: "New Terminal")
        TestStep.macWaitForElement(titled: "terminal", timeout: 10)

        // 3. Capture the spawned pane's ID (stable across base-index configs)
        TestStep.tmuxStorePaneId(target: "terminal", storeAs: "envPane")
        Shortcut.tmuxClearAndSetPrompt(target: "${envPane}")

        // 4. Print the env vars we care about, grouped for a readable screenshot.
        //    Assumes zsh (macOS default and the shell our wrapper resolves on
        //    CI), where `export` without args prints raw `KEY=VALUE` lines —
        //    no quoting, no `export ` prefix — so the `^NAME=` anchors and the
        //    literal substring assertions below match directly. bash would emit
        //    `declare -x KEY="VALUE"` which would defeat both.
        Shortcut.tmuxRunCommand(
            target: "${envPane}",
            command: "export | grep -E '^(TERM|TERM_PROGRAM|TERM_PROGRAM_VERSION|COLORTERM)='"
        )
        TestStep.wait(seconds: 1)
        Shortcut.tmuxRunCommand(
            target: "${envPane}",
            command: "export | grep -E '^(CLAUDE_CODE_NO_FLICKER|CLAUDE_CODE_ACCESSIBILITY|DISABLE_AUTO_UPDATE|DISABLE_UPDATE_PROMPT|LANG)='"
        )
        TestStep.wait(seconds: 1)
        // OTEL telemetry vars (issue #597), also via the tmux `-e` path.
        Shortcut.tmuxRunCommand(
            target: "${envPane}",
            command: "export | grep -E 'CLAUDE_CODE_ENABLE_TELEMETRY|OTEL_'"
        )
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-env-vars-output")

        // 5. Capture the pane and verify each KEY=VALUE pair surfaced
        TestStep.tmuxCapturePaneContent(target: "${envPane}", storeAs: "envOutput")

        // TERM_PROGRAM* (default-command wrapper path)
        TestStep.assertStoredContains(key: "envOutput", substring: "TERM_PROGRAM=iTerm.app")
        TestStep.assertStoredContains(key: "envOutput", substring: "TERM_PROGRAM_VERSION=3.6.6")

        // TERM pinned to a 256-color entry via the `default-terminal` option
        TestStep.assertStoredContains(key: "envOutput", substring: "TERM=screen-256color")

        // baseEnvironmentVars (tmux `-e` path)
        TestStep.assertStoredContains(key: "envOutput", substring: "CLAUDE_CODE_NO_FLICKER=1")
        TestStep.assertStoredContains(key: "envOutput", substring: "COLORTERM=truecolor")
        TestStep.assertStoredContains(key: "envOutput", substring: "CLAUDE_CODE_ACCESSIBILITY=1")
        TestStep.assertStoredContains(key: "envOutput", substring: "DISABLE_AUTO_UPDATE=true")
        TestStep.assertStoredContains(key: "envOutput", substring: "DISABLE_UPDATE_PROMPT=true")

        // OTEL telemetry vars (issue #597) — proves Claude Code is pointed at the
        // Mac-local OTLP receiver with no content gates enabled.
        TestStep.assertStoredContains(key: "envOutput", substring: "CLAUDE_CODE_ENABLE_TELEMETRY=1")
        TestStep.assertStoredContains(key: "envOutput", substring: "OTEL_METRICS_EXPORTER=otlp")
        TestStep.assertStoredContains(key: "envOutput", substring: "OTEL_LOGS_EXPORTER=otlp")
        TestStep.assertStoredContains(key: "envOutput", substring: "OTEL_EXPORTER_OTLP_PROTOCOL=http/json")
        // Port-agnostic: E2E instances bind a per-instance `--otlp-port` (not
        // the production 24318), and the injected endpoint carries whatever
        // port the receiver ACTUALLY bound (it probes fallback candidates when
        // its preferred port is taken) — so assert only the loopback prefix. The
        // exact port is proven end-to-end by OTELTelemetryRenderScenario, where
        // the pane's curl POSTs to this same var and the meter renders.
        TestStep.assertStoredContains(
            key: "envOutput", substring: "OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:"
        )
        TestStep.assertStoredContains(key: "envOutput", substring: "OTEL_METRIC_EXPORT_INTERVAL=10000")

        // LANG is always a UTF-8 locale, but the exact value depends on what the
        // app inherited at launch (an already-UTF-8 locale is preserved, else the
        // en_US.UTF-8 fallback applies), so assert presence rather than an exact,
        // machine-dependent value.
        TestStep.assertStoredContains(key: "envOutput", substring: "LANG=")

        // 6. History suppression (ZDOTDIR shim): the typed line echoes literal
        //    `$HISTFILE`/`${ZDOTDIR:t}`, so only the shell's *expanded* output
        //    can match the assertions below. Probe lines are kept short (empty
        //    brackets, `:t` basename) because `capture-pane` without `-J`
        //    splits wrapped lines, which would break substring matching.
        //    First the app-created pane (`--zdotdir` → `zdotDirOverride`) …
        Shortcut.tmuxRunCommand(
            target: "${envPane}",
            command: #"echo "HISTCHECK=[$HISTFILE][$SAVEHIST]" && echo "ZDOTCHECK=${ZDOTDIR:t}""#
        )
        // The wait doubles as the ZDOTDIR assertion: `ZDOTCHECK=gallager-e2e-zdotdir`
        // only exists in the shell's expanded output, never in the typed line.
        TestStep.tmuxWaitForPaneContent(
            target: "${envPane}", contains: "ZDOTCHECK=gallager-e2e-zdotdir"
        )
        TestStep.tmuxCapturePaneContent(target: "${envPane}", storeAs: "appPaneHist")
        TestStep.assertStoredContains(key: "appPaneHist", substring: "HISTCHECK=[][0]")
        // Visual proof: empty HISTFILE brackets + the shim basename on screen.
        TestStep.macScreenshot(label: "mac-history-suppressed")

        // 7. … then an orchestrator-created session, whose initial shell gets
        //    the shim via `tmuxCreateSession`'s own `new-session -e ZDOTDIR`.
        TestStep.tmuxCreateSession(name: "histcheck", width: 120, height: 30)
        TestStep.tmuxStorePaneId(target: "histcheck", storeAs: "histPane")
        Shortcut.tmuxRunCommand(
            target: "${histPane}",
            command: #"echo "HISTCHECK=[$HISTFILE][$SAVEHIST]" && echo "ZDOTCHECK=${ZDOTDIR:t}""#
        )
        TestStep.tmuxWaitForPaneContent(
            target: "${histPane}", contains: "ZDOTCHECK=gallager-e2e-zdotdir"
        )
        TestStep.tmuxCapturePaneContent(target: "${histPane}", storeAs: "orchPaneHist")
        TestStep.assertStoredContains(key: "orchPaneHist", substring: "HISTCHECK=[][0]")
    }
}
