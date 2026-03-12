import Foundation

// swiftlint:disable function_body_length

/// E2E scenario: Truecolor gradient rendering stress test
///
/// Regression test for the pipe-pane streaming rewrite (PR #179).
/// Runs 5 variants of a truecolor gradient animation, each with different
/// box dimensions, color palettes, and layout densities:
///
///   1. **Standard** — 6 boxes (50x5), baseline gradients
///   2. **Wide Warm** — 4 large boxes (55x7), warm-shifted palette
///   3. **Small Cool** — 9 small boxes (25x3, 3x3 grid), cool-shifted
///   4. **Full-Width Bars** — 6 bars (100x3), maximum horizontal span
///   5. **Dense Rainbow** — 12 tiny boxes (20x4, 4x3 grid), rapid animation
///
/// Each variant animates 40 frames using mode 2026 synchronized output,
/// then draws a final static frame. Screenshots are taken on both macOS
/// and iOS mirrors after each run to verify artifact-free rendering on
/// both platforms.
///
/// The Python script is created as a temp file via heredoc, run 5 times
/// with different `V=` env vars, then cleaned up — fully self-contained.
///
/// Screenshots are compared against baselines with default tolerance.
public enum TruecolorRenderingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Truecolor Rendering Stress",
        tags: ["rendering"]
    ) {
        // ── Pair devices ────────────────────────────────────────────
        // Pairing launches both apps and establishes the relay connection.
        // Do this before creating tmux sessions so the session survives
        // app restarts during the pairing flow.

        FreshPairingScenario.scenario

        // ── Setup ─────────────────────────────────────────────────────

        TestStep.log("Creating tmux session for truecolor stress test")
        TestStep.tmuxCreateSession(name: "truecolor-test", width: 120, height: 40)
        TestStep.wait(seconds: 3)

        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Panes", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(200)
        TestStep.wait(seconds: 1)

        TestStep.macClickButton(titled: "truecolor-test:0")
        TestStep.wait(seconds: 2)

        // ── Navigate to pane on iOS ─────────────────────────────────

        TestStep.log("Opening terminal pane on iOS mirror")
        TestStep.iosWaitForElement(.labelContains("truecolor-test"), timeout: 15)
        TestStep.iosTap(.labelContains("truecolor-test"))
        TestStep.wait(seconds: 3)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting"), timeout: 15)
        TestStep.wait(seconds: 3)

        // ── Create the parameterized Python script ───────────────────
        //
        // V=0..4 selects variant. Each variant has different:
        //   - Box dimensions (width x height)
        //   - Grid layout (columns x rows)
        //   - Animation speed (ms per frame)
        //   - Color palette shift (degrees)

        TestStep.log("Creating parameterized truecolor script")
        TestStep.tmuxSendKeys(
            target: "truecolor-test:0",
            keys: #"""
            cat > $TMPDIR/tc.py << 'PYEOF'
            import sys,math,time,os
            V=int(os.environ.get("V","0"))
            def o(s):
             sys.stdout.buffer.write(s.encode());sys.stdout.buffer.flush()
            E="\033";C=E+"["
            def cup(r,c):o(f"{C}{r};{c}H")
            def bg(r,g,b):return f"{C}48;2;{r};{g};{b}m"
            PI=math.pi
            CFG=[(50,5,2,3,30,0),(55,7,2,2,20,60),(25,3,3,3,40,120),(100,3,1,6,25,180),(20,4,4,3,15,240)]
            TT=["Standard Gradients","Wide Warm Boxes","Small Cool Grid","Full-Width Bars","Dense Rainbow Grid"]
            bw,bh,nc,nr,ms,cs=CFG[V]
            nb=nc*nr
            def grad(idx,t):
             ph=(idx*360/nb+cs)*PI/180
             return (int(128+127*math.sin(t*PI*2+ph)),int(128+127*math.sin(t*PI*2+ph+PI*2/3)),int(128+127*math.sin(t*PI*2+ph+PI*4/3)))
            bx=[]
            for ri in range(nr):
             for ci in range(nc):
              bx.append((3+ri*(bh+3),3+ci*(bw+3)))
            o(f"{C}?25l{C}2J{C}H")
            cup(1,3);o(f"{C}38;2;255;255;100m{TT[V]} (variant {V+1}/5){C}0m")
            for i,(tr,tc) in enumerate(bx):
             cup(tr,tc);o(f"{C}38;2;180;180;180m#{i+1}{C}0m")
            for fr in range(41):
             o(f"{C}?2026h")
             for i,(tr,tc) in enumerate(bx):
              for r in range(bh):
               cup(tr+1+r,tc);s=""
               for c in range(bw):
                t=((c+(0 if fr==40 else fr)*2)%bw)/bw
                t=(t+math.sin(r*.6+fr*.12)*.15)%1
                cr,cg,cb=grad(i,t);s+=bg(cr,cg,cb)+" "
               o(s+f"{C}0m")
             o(f"{C}?2026l")
             if fr<40:time.sleep(ms/1000)
            y=3+nr*(bh+3)+1
            cup(y,1);o(f"{C}?25h{C}0mDone.\n")
            PYEOF
            """#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "truecolor-test:0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // ── Variant 1: Standard gradients (6 boxes, 50x5) ───────────

        TestStep.log("Variant 1/5: Standard Gradients")
        TestStep.tmuxSendKeys(
            target: "truecolor-test:0",
            keys: "V=0 python3 $TMPDIR/tc.py",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "truecolor-test:0", keys: "Enter")
        TestStep.wait(seconds: 6)
        TestStep.macScreenshot(label: "v1-standard-gradients")
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "v1-standard-gradients-ios")

        // ── Variant 2: Wide warm boxes (4 boxes, 55x7) ──────────────

        TestStep.log("Variant 2/5: Wide Warm Boxes")
        TestStep.tmuxSendKeys(
            target: "truecolor-test:0",
            keys: "V=1 python3 $TMPDIR/tc.py",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "truecolor-test:0", keys: "Enter")
        TestStep.wait(seconds: 6)
        TestStep.macScreenshot(label: "v2-wide-warm-boxes")
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "v2-wide-warm-boxes-ios")

        // ── Variant 3: Small cool grid (9 boxes, 25x3) ──────────────

        TestStep.log("Variant 3/5: Small Cool Grid")
        TestStep.tmuxSendKeys(
            target: "truecolor-test:0",
            keys: "V=2 python3 $TMPDIR/tc.py",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "truecolor-test:0", keys: "Enter")
        TestStep.wait(seconds: 6)
        TestStep.macScreenshot(label: "v3-small-cool-grid")
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "v3-small-cool-grid-ios")

        // ── Variant 4: Full-width bars (6 bars, 100x3) ──────────────

        TestStep.log("Variant 4/5: Full-Width Bars")
        TestStep.tmuxSendKeys(
            target: "truecolor-test:0",
            keys: "V=3 python3 $TMPDIR/tc.py",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "truecolor-test:0", keys: "Enter")
        TestStep.wait(seconds: 6)
        TestStep.macScreenshot(label: "v4-full-width-bars")
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "v4-full-width-bars-ios")

        // ── Variant 5: Dense rainbow grid (12 boxes, 20x4) ──────────

        TestStep.log("Variant 5/5: Dense Rainbow Grid")
        TestStep.tmuxSendKeys(
            target: "truecolor-test:0",
            keys: "V=4 python3 $TMPDIR/tc.py",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "truecolor-test:0", keys: "Enter")
        TestStep.wait(seconds: 6)
        TestStep.macScreenshot(label: "v5-dense-rainbow-grid")
        TestStep.wait(seconds: 1)
        TestStep.iosScreenshot(label: "v5-dense-rainbow-grid-ios")

        // ── Cleanup ──────────────────────────────────────────────────

        TestStep.tmuxSendKeys(
            target: "truecolor-test:0",
            keys: "rm $TMPDIR/tc.py",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "truecolor-test:0", keys: "Enter")
    }
}

// swiftlint:enable function_body_length
