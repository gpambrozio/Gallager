import Foundation

/// E2E scenario: Multi-pane window layout (progressive splits)
///
/// Builds a multi-pane tmux window step-by-step, verifying at each stage:
/// 1. Single pane — sidebar shows the window, terminal renders output
/// 2. Vertical split — two panes side-by-side, each with unique content
/// 3. Horizontal split — three panes in an L-shaped layout, all visible
public enum MultiPaneWindowScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Multi Pane Window",
        tags: ["sidebar", "layout", "macos-only"]
    ) {
        // ── Stage 1: Single-pane session ────────────────────────

        TestStep.log("Stage 1: Create session with a single pane")
        TestStep.tmuxCreateSession(name: "multi-pane", width: 160, height: 50)
        Shortcut.tmuxClearAndSetPrompt(target: "multi-pane:0.0")

        // Produce some output so the terminal isn't empty
        Shortcut.tmuxRunCommand(target: "multi-pane:0.0", command: "echo '=== PRIMARY PANE ==='")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.0", command: "echo 'This is the original pane before any splits'")
        TestStep.wait(seconds: 1)

        // Launch macOS app and open Panes window
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        // Select the window and verify single-pane rendering
        TestStep.log("Verify sidebar shows 'multi-pane:0' and select it")
        TestStep.macWaitForElement(titled: "multi-pane", timeout: 5)
        TestStep.macClickButton(titled: "multi-pane")
        TestStep.wait(seconds: 3)
        TestStep.macScreenshot(label: "mac-single-pane")

        // ── Stage 2: Vertical split (left | right) ─────────────

        TestStep.log("Stage 2: Split vertically — creates left and right panes")
        // Drive splits through the orchestrator's tmux (which uses `-f /dev/null`)
        // instead of `tmux split-window` typed into the in-pane shell. The
        // in-pane invocation reads the user's `~/.tmux.conf`, which can apply
        // `set -g pane-base-index` to the server and shift pane indices off
        // the expected `0,1,2…` sequence the test asserts against.
        TestStep.tmuxCommand(arguments: ["split-window", "-h", "-t", "multi-pane:0.0"])
        TestStep.wait(seconds: 1)
        Shortcut.tmuxClearAndSetPrompt(target: "multi-pane:0.1")

        // Send content to the new right pane
        Shortcut.tmuxRunCommand(target: "multi-pane:0.1", command: "echo '=== RIGHT PANE ==='")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.1", command: "echo 'Created by vertical split'")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "mac-two-panes-vertical-split")

        // ── Stage 3: Horizontal split (right splits into top/bottom) ──

        TestStep.log("Stage 3: Split right pane horizontally — creates top-right and bottom-right")
        TestStep.tmuxCommand(arguments: ["split-window", "-v", "-t", "multi-pane:0.1"])
        TestStep.wait(seconds: 1)
        Shortcut.tmuxClearAndSetPrompt(target: "multi-pane:0.2")

        // Send content to the new bottom-right pane
        Shortcut.tmuxRunCommand(target: "multi-pane:0.2", command: "echo '=== BOTTOM-RIGHT PANE ==='")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.2", command: "echo 'Created by horizontal split of right pane'")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "mac-three-panes-final-layout")

        // ── Stage 3a: Verify clicking a pane mirrors focus to tmux ──
        //
        // App → tmux: clicking a pane in the mirror should call select-pane
        // on tmux so an external client attached to the same window sees the
        // same active pane.

        TestStep.log("Stage 3a: Verify clicking a pane in the mirror calls select-pane on tmux")

        // Drive each click through the pane's accessibility identifier
        // (`terminal-%N`) and let the AX layer find its on-screen centre.
        // Hard-coded screen coordinates were flaky: a 1-px boundary shift in
        // the horizontal split — which depends on the exact rendered window
        // height — sent the (995, 245) "top-right" click into the bottom-right
        // pane and broke `pane_active` for pane .1.
        //
        // The `wait(seconds: 1)` after each click gives the previous click's
        // responder transition (and the resulting `select-pane` round-trip
        // back to tmux) time to settle before the next click fires; clicking
        // back-to-back occasionally let the second click reach the AX tree
        // mid-focus-change.

        TestStep.macCGClickElement(query: .identifier("terminal-%0"))
        TestStep.wait(seconds: 1)
        TestStep.waitForTmuxDisplayMessage(
            target: "multi-pane:0.0",
            format: "#{pane_active}",
            contains: "1",
            timeout: 5
        )

        TestStep.macCGClickElement(query: .identifier("terminal-%1"))
        TestStep.wait(seconds: 1)
        TestStep.waitForTmuxDisplayMessage(
            target: "multi-pane:0.1",
            format: "#{pane_active}",
            contains: "1",
            timeout: 5
        )

        TestStep.macCGClickElement(query: .identifier("terminal-%2"))
        TestStep.wait(seconds: 1)
        TestStep.waitForTmuxDisplayMessage(
            target: "multi-pane:0.2",
            format: "#{pane_active}",
            contains: "1",
            timeout: 5
        )

        // ── Stage 3b: Verify the tmux-active pane auto-focuses on window load ──
        //
        // tmux → app: when a multi-pane window is selected, the pane that tmux
        // marks as active should grab keyboard focus instead of leaving the
        // user with no focused pane.

        TestStep.log("Stage 3b: Verify the tmux-active pane is auto-focused on window load")

        // Make pane .0 active in tmux without touching the app
        TestStep.tmuxCommand(arguments: ["select-pane", "-t", "multi-pane:0.0"])
        TestStep.wait(seconds: 1)

        // Force a layout rebuild by deselecting and re-selecting the multi-pane
        // window — uses the temp-session pattern from MultiWindowTabsScenario
        // to make the sidebar selection unambiguous.
        TestStep.tmuxCreateSession(name: "focus-temp", width: 80, height: 24)
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "focus-temp", timeout: 5)
        TestStep.macClickButton(titled: "focus-temp")
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "multi-pane")
        TestStep.wait(seconds: 3)

        // Type into the app — input should land in pane .0 (the tmux-active one).
        // If auto-focus regresses, no terminal has focus and the keystrokes
        // either land nowhere or in the wrong pane, failing the assertions.
        TestStep.macType(text: "echo FOCUS_LANDED_HERE", pressReturn: true)
        TestStep.wait(seconds: 2)

        TestStep.tmuxCapturePaneContent(target: "multi-pane:0.0", storeAs: "pane0FocusContent")
        TestStep.assertStoredContains(key: "pane0FocusContent", substring: "FOCUS_LANDED_HERE")

        TestStep.tmuxCapturePaneContent(target: "multi-pane:0.1", storeAs: "pane1FocusContent")
        TestStep.assertStoredNotContains(key: "pane1FocusContent", substring: "FOCUS_LANDED_HERE")

        TestStep.tmuxCapturePaneContent(target: "multi-pane:0.2", storeAs: "pane2FocusContent")
        TestStep.assertStoredNotContains(key: "pane2FocusContent", substring: "FOCUS_LANDED_HERE")

        // Clean up the temp session so the sidebar returns to a single entry
        Shortcut.tmuxRunCommand(target: "focus-temp:0.0", command: "exit")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementToDisappear(titled: "focus-temp", timeout: 5)

        // ── Stage 4: More content in all panes ──────────────────

        TestStep.log("Stage 4: Add more content to all panes")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.0", command: "echo 'Left pane still going strong'")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.1", command: "echo 'Top-right checking in'")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.2", command: "echo 'Bottom-right reporting for duty'")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "mac-all-panes-with-extra-content")

        // ── Stage 5: Exit left pane (original, 3 → 2 panes) ─────

        TestStep.log("Stage 5: Exit left pane (first created) — layout should collapse to two panes")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.0", command: "exit")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "mac-two-panes-after-exit")

        // ── Stage 6: Exit top-right pane (second created, 2 → 1 pane) ──

        TestStep.log("Stage 6: Exit top-right pane (second created) — layout should collapse to single pane")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.0", command: "exit")
        TestStep.wait(seconds: 3)

        TestStep.macScreenshot(label: "mac-single-pane-after-exits")

        // ── Stage 7: Exit last pane (third created) — window disappears ──

        TestStep.log("Stage 7: Exit last pane — window should disappear from sidebar")
        Shortcut.tmuxRunCommand(target: "multi-pane:0.0", command: "exit")
        TestStep.wait(seconds: 3)

        // The window entry should vanish from the sidebar
        TestStep.macWaitForElementToDisappear(titled: "multi-pane", timeout: 10)
        // With no panes left, the app shows the "New Session" empty state
        TestStep.macWaitForElement(titled: "New Session", timeout: 5)
        TestStep.macScreenshot(label: "mac-no-panes-empty-state")

        TestStep.macClickButton(titled: "New Terminal")
        TestStep.wait(seconds: 3)
        // The new session is auto-selected on creation — no need to click the sidebar entry.
        // Explicitly clicking it would risk hitting the "Terminals" section header via
        // substring matching, which can trigger outline disclosure collapse via AXPress.
        TestStep.macWaitForElement(titled: "terminal", timeout: 5)

        // Capture pane IDs after each split. The macOS app's "New Terminal" path
        // doesn't pass `-f /dev/null`, so window/pane indices follow the user's
        // tmux config (e.g., base-index 1) and `terminal:0.0` would not exist.
        // Pane IDs (`%N`) are stable regardless of base-index. Splits go through
        // the orchestrator's tmux (also `-f /dev/null`) for the same reason.
        TestStep.tmuxStorePaneId(target: "terminal", storeAs: "termPane0")
        Shortcut.tmuxClearAndSetPrompt(target: "${termPane0}")

        TestStep.tmuxCommand(arguments: ["split-window", "-h", "-t", "${termPane0}"])
        TestStep.wait(seconds: 3)
        // After split-window, the new pane becomes active.
        TestStep.tmuxStorePaneId(target: "terminal", storeAs: "termPane1")
        Shortcut.tmuxClearAndSetPrompt(target: "${termPane1}")

        TestStep.tmuxCommand(arguments: ["split-window", "-v", "-t", "${termPane1}"])
        TestStep.wait(seconds: 3)
        TestStep.tmuxStorePaneId(target: "terminal", storeAs: "termPane2")
        Shortcut.tmuxClearAndSetPrompt(target: "${termPane2}")
        TestStep.macScreenshot(label: "mac-three-panes-new-session")

        Shortcut.tmuxRunCommand(target: "${termPane2}", command: "exit")
        TestStep.wait(seconds: 3)

        Shortcut.tmuxRunCommand(target: "${termPane1}", command: "exit")
        TestStep.wait(seconds: 3)

        Shortcut.tmuxRunCommand(target: "${termPane0}", command: "echo 'Still here'")
        TestStep.wait(seconds: 3)
        TestStep.macScreenshot(label: "mac-last-should-have-echo")
    }
}
