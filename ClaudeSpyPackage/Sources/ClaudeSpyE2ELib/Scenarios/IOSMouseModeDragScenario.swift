import Foundation

/// E2E scenario: Verify iOS drag gestures while the host has tmux mouse mode on.
///
/// This is a regression guard for two intertwined behaviors:
/// 1. **Vertical drag** on the iOS terminal must synthesize SGR scroll-wheel
///    events (`ESC[<64;col;rowM` / `ESC[<65;col;rowM`) and forward them to the
///    host so apps like `less`/`man`/`htop` scroll their content remotely.
/// 2. **Horizontal drag** on the iOS terminal must NOT be sent as mouse events
///    — the remote terminal can't scroll horizontally — and must instead fall
///    through to the iOS outer scroll view so wide terminals can be panned to
///    reveal content beyond the screen.
///
/// The Python `mouse_test.py` (run with `--wide`) listens for SGR sequences
/// and exposes counters via tmux pane content (`SCROLL:N`, `CLICK:N`,
/// `DRAG:N`) plus a wide ruler line (`WIDE>0123456789|...|<END`) that makes
/// horizontal scroll position obvious in screenshots.
public enum IOSMouseModeDragScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "iOS Mouse Mode Drag",
        tags: ["terminal", "interactive", "ios"]
    ) {
        // ── Pair Mac + iOS ───────────────────────────────────────
        FreshPairingScenario.scenario

        // ── Create a wide tmux session on the host ───────────────
        // 200 cols guarantees the iOS terminal overflows even the
        // largest current iPhone simulator screen, so horizontal
        // scrolling is meaningful.
        TestStep.log("Creating wide tmux session for iOS mouse-mode drag test")
        TestStep.tmuxCreateSession(name: "ios-mouse-drag", width: 200, height: 24)
        Shortcut.tmuxClearAndSetPrompt(target: "ios-mouse-drag:0")

        // ── Run the wide variant of mouse_test.py ────────────────
        TestStep.log("Injecting and starting mouse_test.py --wide")
        TestStep.injectScript(name: "mouse_test.py")
        Shortcut.tmuxRunCommand(target: "ios-mouse-drag:0", command: "python3 $TMPDIR/mouse_test.py --wide")
        TestStep.wait(seconds: 2)

        // Verify mouse mode is on and the app rendered the wide ruler
        TestStep.tmuxCapturePaneContent(target: "ios-mouse-drag:0", storeAs: "initialContent")
        TestStep.assertStoredContains(key: "initialContent", substring: "STATUS:READY")
        TestStep.assertStoredContains(key: "initialContent", substring: "SCROLL:0")
        TestStep.assertStoredContains(key: "initialContent", substring: "CLICK:0")
        TestStep.assertStoredContains(key: "initialContent", substring: "DRAG:0")
        TestStep.assertStoredContains(key: "initialContent", substring: "WIDE>")
        TestStep.assertStoredContains(key: "initialContent", substring: "<END")
        TestStep.tmuxStoreDisplayMessage(
            target: "ios-mouse-drag:0",
            format: "#{mouse_any_flag}",
            storeAs: "mouseAnyFlag"
        )
        TestStep.assertStoredContains(key: "mouseAnyFlag", substring: "1")

        // ── Connect iOS to the session ───────────────────────────
        Shortcut.iosConnectToSession(sessionName: "ios-mouse-drag")
        TestStep.wait(seconds: 3)

        // Baseline screenshot — terminal at horizontal offset 0,
        // so 'WIDE>0123456789|0123...' is visible at the left.
        TestStep.iosScreenshot(label: "ios-connected-baseline")

        // ── Phase 1: vertical drag should fire wheel events ──────
        // Drag finger down from upper-middle to lower-middle of the
        // terminal area. With our cell-height threshold (~16pt), a
        // ~300pt drop should produce ≥10 SGR scroll-up events
        // (button 64 → SCROLL counter increases).
        TestStep.log("Vertical drag down (should send wheel-up events)")
        TestStep.iosSwipe(fromX: 200, fromY: 300, toX: 200, toY: 600, duration: 0.3)
        TestStep.wait(seconds: 2)

        TestStep.tmuxCapturePaneContent(target: "ios-mouse-drag:0", storeAs: "afterVertical")
        // SCROLL must have advanced from 0. The literal substring "SCROLL:0"
        // only appears when the counter is exactly zero (e.g. "SCROLL:10" or
        // "SCROLL:100" don't contain the string "SCROLL:0").
        TestStep.assertStoredNotContains(key: "afterVertical", substring: "SCROLL:0")
        // No spurious click/drag events from the vertical pan
        TestStep.assertStoredContains(key: "afterVertical", substring: "CLICK:0")
        TestStep.assertStoredContains(key: "afterVertical", substring: "DRAG:0")
        TestStep.iosScreenshot(label: "ios-after-vertical-drag")

        // ── Phase 2: horizontal drag should NOT fire mouse events ──
        TestStep.log("Horizontal drag left (should scroll outer view, NOT fire events)")
        // Drag right-to-left so the terminal scrolls right (revealing
        // the '<END' marker on the right of the wide ruler).
        TestStep.iosSwipe(fromX: 380, fromY: 450, toX: 30, toY: 450, duration: 0.4)
        TestStep.wait(seconds: 2)

        TestStep.tmuxCapturePaneContent(target: "ios-mouse-drag:0", storeAs: "afterHorizontal")
        // Strong regression guard: SwiftTerm's `panMouseGesture` (added by
        // mouse mode) would fire button-press + motion SGR events for any
        // drag direction. If horizontal pans got through to it, the CLICK
        // and DRAG counters would have advanced past zero.
        TestStep.assertStoredContains(key: "afterHorizontal", substring: "CLICK:0")
        TestStep.assertStoredContains(key: "afterHorizontal", substring: "DRAG:0")

        // The screenshot is the strongest signal: the wide ruler
        // should have shifted left (its right edge '<END' visible),
        // proving the outer scroll view actually moved.
        TestStep.iosScreenshot(label: "ios-after-horizontal-drag")

        // ── Cleanup ──────────────────────────────────────────────
        TestStep.tmuxSendKeys(target: "ios-mouse-drag:0", keys: "C-c")
        TestStep.wait(seconds: 1)
    }
}
