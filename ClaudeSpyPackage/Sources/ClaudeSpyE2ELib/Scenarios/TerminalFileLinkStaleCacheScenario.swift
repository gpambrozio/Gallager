import Foundation

/// E2E scenario: reproduces the user-reported "click anywhere on the
/// terminal opens the file" bug.
///
/// **Setup:** emits a single OSC 8 `file://` sequence whose start is at the
/// top of the screen and whose close arrives only after the cursor has been
/// moved to the bottom-right. SwiftTerm's OSC 8 close handler iterates
/// every row between the open position and the cursor's current position
/// and marks each cell with the link's payload — even cells that never
/// received a visible glyph. This is the exact shape of Claude Code's TUI
/// behaviour: an OSC 8 link is opened, the TUI repositions the cursor
/// while drawing the rest of its frame, then the link is closed, and
/// every cell touched in between inherits the link.
///
/// The scenario then runs `clear`, which resets SwiftTerm's visible cells
/// to default but does NOT invalidate `cachedPayloads` — those entries
/// stay live because no character or attribute changed (default ➜
/// default). A subsequent click on a row that is now visually empty:
///
/// * On main, hits a cached OSC 8 payload via `urlAt`'s direct
///   per-cell check and opens `hello.txt`.
/// * On this branch, `urlAt` routes through `detectURLs`, which trims the
///   payload range to the trimmed line text. The cleared rows have empty
///   line text, so no `DetectedURL` is produced and the click falls
///   through harmlessly.
public enum TerminalFileLinkStaleCacheScenario {
    /// Coordinates assume the standard `Shortcut.macOnlySetup` placement
    /// (window at 10,10, sidebar 250) overridden to 1_200×700.
    ///
    /// Terminal content area starts ~270 pt from the screen origin. SF
    /// Mono 12 cells are ~10 pt wide and ~14 pt tall.

    /// Click point on a row well below where the OSC 8 link was visible.
    /// The cell here was inside the OSC 8 region but never received a
    /// visible character, and was cleared by `clear` before the click.
    private static let emptyClickX: Double = 600
    private static let emptyClickY: Double = 280

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Terminal File Link Click Anywhere Does Not Open Tab",
        tags: ["terminal", "links", "file-browser", "macos-only"]
    ) {
        // ── Setup ────────────────────────────────────────────────
        TestStep.log("Setup: tmux session with a clean prompt")
        TestStep.tmuxCreateSession(name: "termlinkany", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "termlinkany:0")
        TestStep.wait(seconds: 1)

        // ── Launch app and attach to the pane BEFORE emitting OSC 8 ──
        // Live updates come over `pipe-pane`, which preserves the OSC 8
        // sequence shape (open ➜ cursor move ➜ close). We need the Mac
        // app to process those bytes in that order so SwiftTerm's close
        // handler marks every cell in the range with the payload.
        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)

        TestStep.macWaitForElement(titled: "termlinkany", timeout: 5)
        TestStep.macClickButton(titled: "termlinkany")
        TestStep.wait(seconds: 1)

        // ── Emit a sprawling OSC 8 region, then clear the screen ──
        // `\e]8;;file:///tmp/hello.txt\a` opens the hyperlink at the
        // current cursor (the row after the echoed printf command).
        // `\e[30;100H ` jumps to the bottom-right cell and writes a
        // single space so the cursor is positioned at the very end of
        // the buffer. `\e]8;;\a` closes the hyperlink — SwiftTerm's
        // `oscHyperlink` then walks every row from the open position to
        // the cursor's row and marks every cell with the payload.
        // `&& clear` finally erases the screen so the link is no
        // longer visible to the user, but the cached payloads remain.
        TestStep.log("Emit a multi-row OSC 8 region, then clear the screen")
        Shortcut.tmuxRunCommand(
            target: "termlinkany:0",
            command: #"printf '\e]8;;file:///tmp/hello.txt\a\e[30;100H \e]8;;\a' && clear"#
        )
        TestStep.wait(seconds: 2)

        TestStep.macScreenshot(label: "mac-cleared-screen-with-stale-cache")

        // ── Click on a visually empty row, far from any link text ──
        // On main, the cached OSC 8 payload at this cell still resolves
        // through `urlAt` and the file tab opens. On this branch,
        // `urlAt` routes through `detectURLs` which trims the payload
        // run to the (empty) line text, so no DetectedURL is produced
        // and the click falls through with no side effect.
        TestStep.log("Click on a visually empty cell — must NOT open the file")
        TestStep.macClickAtPoint(x: emptyClickX, y: emptyClickY)
        TestStep.macWaitForElementToDisappear(titled: "File tab: hello.txt", timeout: 3)
        TestStep.macScreenshot(label: "mac-no-tab-from-empty-cell-click")
    }
}
