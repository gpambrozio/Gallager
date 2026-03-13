import Foundation

// swiftlint:disable function_body_length

/// E2E scenario: Emoji table rendering regression test
///
/// Verifies that tables containing emoji characters render correctly in
/// both macOS and iOS mirror terminals. This catches regressions in:
/// - Emoji display width (2-column characters)
/// - Box-drawing character alignment alongside emoji
/// - Table border integrity when emoji are present
/// - Color/SGR state after wide characters
///
/// The scenario:
/// 1. Pairs macOS and iOS devices via the relay
/// 2. Creates a tmux session (80×35) and renders three tables using a Python script:
///    - Table 1: Simple emoji-only table (varying emoji counts per row)
///    - Table 2: Mixed text and emoji with colored status indicators
///    - Table 3: Dense emoji grid (4×4) to stress-test rendering
/// 3. Takes screenshots on both macOS and iOS for each table
/// 4. Forces a re-capture and takes final screenshots to verify
///    capture-pane correctly preserves emoji positioning
public enum EmojiTableRenderingScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Emoji Table Rendering",
        tags: ["rendering"]
    ) {
        // -- Pair devices --------------------------------------------------

        FreshPairingScenario.scenario

        // -- Setup ---------------------------------------------------------

        TestStep.log("Creating tmux sessions for emoji table rendering test")
        TestStep.tmuxCreateSession(name: "emoji-tbl", width: 80, height: 35)
        TestStep.tmuxCreateSession(name: "emoji-helper", width: 80, height: 24)

        TestStep.tmuxSendKeys(
            target: "emoji-tbl:0",
            keys: #"export PS1='$ '"#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "emoji-tbl:0", keys: "Enter")
        TestStep.tmuxSendKeys(target: "emoji-tbl:0", keys: "clear", literal: true)
        TestStep.tmuxSendKeys(target: "emoji-tbl:0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // -- Create the Python script that draws all three tables ----------
        //
        // Uses UTF-8 box-drawing characters directly (not DEC line-drawing)
        // so we test the emoji rendering path specifically, not the SO/SI
        // translation tested by TableRenderingScenario.

        TestStep.log("Creating emoji table rendering script")
        TestStep.tmuxSendKeys(
            target: "emoji-helper:0",
            keys: #"""
            cat > $TMPDIR/emoji_tables.py << 'PYEOF'
            import sys
            E="\033";C=E+"["
            def o(s):sys.stdout.write(s);sys.stdout.flush()

            def dw(s):
                """Display width of a string (emoji=2 cols, others=1)."""
                v=0
                for ch in s:
                    if ord(ch)>=0x1f000 or ord(ch) in (0x26bd,0x26be):v+=2
                    else:v+=1
                return v

            def table1():
                """Simple emoji table with varying counts per row."""
                o(f"{C}1;36mTable 1: Emoji counts{C}0m\n\n")
                rows=[
                    ("1","\U0001f355"),
                    ("2","\U0001f389 \U0001f31f"),
                    ("3","\U0001f436 \U0001f98a \U0001f438"),
                    ("4","\U0001f34e \U0001f34b \U0001f347 \U0001f353"),
                ]
                w1,w2=5,20
                H="\u2500"
                h1=H*w1;h2=H*w2
                o(f"\u250c\u2500{h1}\u252c\u2500{h2}\u2510\n")
                o(f"\u2502 {'#':<{w1}}\u2502 {'Item':<{w2}}\u2502\n")
                o(f"\u251c\u2500{h1}\u253c\u2500{h2}\u2524\n")
                for n,emojis in rows:
                    pad=w2-dw(emojis)
                    o(f"\u2502 {n:<{w1}}\u2502 {emojis}{' '*pad}\u2502\n")
                o(f"\u2514\u2500{h1}\u2534\u2500{h2}\u2518\n")

            def table2():
                """Mixed text and emoji with colored headers."""
                o(f"\n{C}1;33mTable 2: Status board{C}0m\n\n")
                hdr=[("ID",4),("Name",10),("Status",12),("Notes",16)]
                # top border
                o("\u250c")
                for i,(h,w) in enumerate(hdr):
                    o("\u2500"*(w+2))
                    o("\u252c" if i<len(hdr)-1 else "\u2510")
                o("\n")
                # header row
                o("\u2502")
                for h,w in hdr:
                    o(f" {C}1;37m{h:<{w}}{C}0m \u2502")
                o("\n")
                # separator
                o("\u251c")
                for i,(h,w) in enumerate(hdr):
                    o("\u2500"*(w+2))
                    o("\u253c" if i<len(hdr)-1 else "\u2524")
                o("\n")
                # data rows
                data=[
                    ("1","Alice",f"Active {C}32m\U0001f7e2{C}0m","Top performer"),
                    ("2","Bob",f"Away {C}31m\U0001f534{C}0m","On vacation"),
                    ("3","Charlie",f"Active {C}32m\U0001f7e2{C}0m","New hire"),
                    ("4","Diana",f"Busy {C}33m\U0001f7e1{C}0m",f"Team lead \U0001f451"),
                ]
                for row in data:
                    o("\u2502")
                    for (val,(_,w)) in zip(row,hdr):
                        # Pad with spaces — emoji take 2 columns so we need to
                        # account for that in the padding.
                        # For simplicity, just write the value and pad with
                        # enough spaces (terminal will handle alignment)
                        o(f" {val}")
                        # Calculate visible width
                        import re
                        vis=re.sub(r'\033\[[0-9;]*m','',val)
                        vw=dw(vis)
                        pad=w-vw+1
                        if pad>0:o(" "*pad)
                        else:o(" ")
                        o("\u2502")
                    o("\n")
                # bottom border
                o("\u2514")
                for i,(h,w) in enumerate(hdr):
                    o("\u2500"*(w+2))
                    o("\u2534" if i<len(hdr)-1 else "\u2518")
                o("\n")

            def table3():
                """Dense emoji grid to stress-test rendering."""
                o(f"\n{C}1;35mTable 3: Emoji grid{C}0m\n\n")
                grid=[
                    ["\U0001f600","\U0001f60e","\U0001f914","\U0001f631"],
                    ["\U0001f525","\U0001f4a7","\U0001f338","\U0001f340"],
                    ["\U0001f680","\U0001f682","\U0001f681","\U0001f6f8"],
                    ["\u26bd","\U0001f3c0","\U0001f3be","\U0001f3c8"],
                ]
                w=4
                ncols=len(grid[0])
                # top
                o("\u250c")
                for i in range(ncols):
                    o("\u2500"*(w+2))
                    o("\u252c" if i<ncols-1 else "\u2510")
                o("\n")
                for row in grid:
                    o("\u2502")
                    for em in row:
                        ew=dw(em)
                        # cell content = w+2 display cols (matching border)
                        # 1 leading space + emoji(ew) + remaining spaces
                        pad=w+2-1-ew
                        o(f" {em}{' '*pad}\u2502")
                    o("\n")
                # bottom
                o("\u2514")
                for i in range(ncols):
                    o("\u2500"*(w+2))
                    o("\u2534" if i<ncols-1 else "\u2518")
                o("\n")

            o(f"{C}2J{C}H")
            table1()
            table2()
            table3()
            o(f"\n{C}1;32mDone.{C}0m\n")
            PYEOF
            """#,
            literal: true
        )
        TestStep.tmuxSendKeys(target: "emoji-helper:0", keys: "Enter")
        TestStep.wait(seconds: 1)

        // -- Run the script ------------------------------------------------

        TestStep.log("Running emoji table script")
        TestStep.tmuxSendKeys(
            target: "emoji-tbl:0",
            keys: "python3 $TMPDIR/emoji_tables.py",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "emoji-tbl:0", keys: "Enter")
        TestStep.wait(seconds: 3)

        // -- Select the pane on macOS --------------------------------------

        TestStep.macOpenPanesWindow()
        TestStep.macWaitForWindow(titled: "Available Windows", timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.macMoveWindow(x: 10, y: 10)
        TestStep.macResizeWindow(width: 1_100, height: 700)
        TestStep.macSetSidebarWidth(200)
        TestStep.wait(seconds: 1)

        TestStep.macClickButton(titled: "emoji-tbl:0")
        TestStep.wait(seconds: 3)

        // Screenshot: all three emoji tables on macOS
        TestStep.macScreenshot(label: "emoji-tables-mac")

        // -- Navigate to pane on iOS ---------------------------------------

        TestStep.log("Opening terminal pane on iOS mirror")
        TestStep.iosWaitForElement(.labelContains("emoji-tbl"), timeout: 15)
        TestStep.iosTap(.labelContains("emoji-tbl"))
        TestStep.wait(seconds: 3)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting"), timeout: 15)
        TestStep.wait(seconds: 3)

        // Screenshot: all three emoji tables on iOS
        TestStep.iosScreenshot(label: "emoji-tables-ios")

        // -- Re-capture: de-select and re-select ---------------------------
        //
        // Forces a new capture-pane cycle to verify that extractActiveSGR
        // and filterToColorCodesOnly correctly handle wide characters
        // during re-capture.

        TestStep.log("Forcing re-capture via pane re-selection")
        TestStep.macClickButton(titled: "emoji-helper:0")
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Sessions"))
        TestStep.wait(seconds: 2)
        TestStep.macClickButton(titled: "emoji-tbl:0")
        TestStep.wait(seconds: 3)

        // Screenshot: tables should still render correctly after re-capture
        TestStep.macScreenshot(label: "emoji-tables-recapture-mac")

        TestStep.iosTap(.labelContains("emoji-tbl"))
        TestStep.wait(seconds: 3)
        TestStep.iosWaitForElementToDisappear(.labelContains("Connecting"), timeout: 15)
        TestStep.wait(seconds: 3)
        TestStep.iosScreenshot(label: "emoji-tables-recapture-ios")

        // -- Cleanup -------------------------------------------------------

        TestStep.tmuxSendKeys(
            target: "emoji-tbl:0",
            keys: "rm $TMPDIR/emoji_tables.py",
            literal: true
        )
        TestStep.tmuxSendKeys(target: "emoji-tbl:0", keys: "Enter")
    }
}

// swiftlint:enable function_body_length
