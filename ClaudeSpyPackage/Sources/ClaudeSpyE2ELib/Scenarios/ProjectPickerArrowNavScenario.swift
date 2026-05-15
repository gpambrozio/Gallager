import Foundation

/// E2E test for keyboard navigation in the macOS new-session project picker:
/// arrow keys highlight rows (including "New Terminal"), wraparound works in
/// both directions, the list auto-scrolls to keep the highlighted row visible,
/// the highlight survives compatible search edits, and Return opens whichever
/// row is highlighted.
public enum ProjectPickerArrowNavScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Project Picker Arrow Navigation",
        tags: ["project-search", "macos-only"]
    ) {
        // ── Setup ──────────────────────────────────────────────────
        TestStep.log("Creating tmux session so sidebar shows + button")
        TestStep.tmuxCreateSession(name: "picker-nav", width: 80, height: 24)

        Shortcut.macOnlySetup

        // ── Open the new-session popover ─────────────────────────
        TestStep.log("Opening new session popover")
        TestStep.macClickButton(titled: "Create new session")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "AlphaProject", timeout: 5)
        TestStep.macScreenshot(label: "mac-popover-open")

        // ── Phase A: ↓ from empty highlights New Terminal ────────
        TestStep.log("Pressing Down: should highlight New Terminal (first item)")
        TestStep.macPressKey(.downArrow)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-down-selects-new-terminal")

        // ── Phase B: ↓ traverses into projects, lands on last ────
        // 12 mock projects: Alpha, Beta, Gamma, Delta, Epsilon, Iota,
        // Kappa, Mu, Nu, Sigma, Tau, Zeta. From New Terminal we need
        // 12 more downs to reach ZetaCore (the last project).
        TestStep.log("Pressing Down 12× to traverse all projects to the bottom (ZetaCore)")
        for _ in 0..<12 {
            TestStep.macPressKey(.downArrow)
        }
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-down-to-last-project")

        // ── Phase C: ↓ wraps to top (selection + scroll-to-top) ──
        TestStep.log("Pressing Down once more: wraps back to New Terminal and list scrolls to top")
        TestStep.macPressKey(.downArrow)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-wrap-down-to-new-terminal")

        // ── Phase D: ↑ wraps from New Terminal to last project ───
        TestStep.log("Pressing Up: wraps from New Terminal to last project (ZetaCore)")
        TestStep.macPressKey(.upArrow)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-wrap-up-to-last-project")

        // ── Phase E: typing auto-defaults to first match ─────────
        // ZetaCore is highlighted; "alp" filters to AlphaProject only
        // (none of the other 11 names contain the subsequence a-l-p).
        // Selection should auto-move to AlphaProject.
        //
        // Click the search field first to make the NSTextField the
        // AppKit first-responder: the prior arrow-press loop routed
        // through SwiftUI `.onKeyPress` (which only requires SwiftUI
        // @FocusState) and the popover-scroll triggered by selection
        // changes can desync that from AppKit's first-responder.
        //
        // Type the filter via `macType` (AppleScript keystroke via
        // System Events) rather than CGEvent `pressShortcut` — plain
        // CGEvent key posts don't reach a SwiftUI TextField hosted in
        // an NSPopover panel reliably, whereas System Events follows
        // the accessibility focus chain into the popover.
        TestStep.log("Re-focusing search field before typing (popover scroll can desync first-responder)")
        TestStep.macCGClick(titled: "Search projects")
        TestStep.wait(seconds: 0.3)
        TestStep.log("Typing 'alp': filters to AlphaProject and auto-selects it")
        TestStep.macType(text: "alp")
        TestStep.wait(seconds: 0.5)
        TestStep.macWaitForElementToDisappear(titled: "ZetaCore", timeout: 5)
        TestStep.macWaitForElement(titled: "AlphaProject", timeout: 5)
        TestStep.macScreenshot(label: "mac-filter-auto-selects-alpha")

        // ── Phase F: typing preserves selection if still in list ─
        // "alph" still matches AlphaProject — selection should stay.
        TestStep.log("Typing 'h' so search becomes 'alph' — AlphaProject still highlighted")
        TestStep.macType(text: "h")
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-filter-preserves-alpha")

        // ── Phase G: Return on highlighted project opens it ──────
        TestStep.log("Pressing Return: opens the highlighted AlphaProject session")
        TestStep.macPressKey(.return)
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElementToDisappear(titled: "Search projects", timeout: 5)
        // Re-pin the window — claude session loading can grow the window asynchronously.
        TestStep.macResizeWindow(width: 1_000, height: 600)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-alpha-session-created")

        // ── Phase H: Return on highlighted New Terminal opens it ─
        TestStep.log("Reopening popover to verify Return on highlighted New Terminal")
        TestStep.macClickButton(titled: "Create new session")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "New Terminal", timeout: 5)
        TestStep.macPressKey(.downArrow)
        TestStep.wait(seconds: 0.3)
        TestStep.macPressKey(.return)
        TestStep.wait(seconds: 3)
        TestStep.macWaitForElementToDisappear(titled: "Search projects", timeout: 5)
        // Same re-pin: a freshly opened terminal can also auto-grow the window.
        TestStep.macResizeWindow(width: 1_000, height: 600)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-new-terminal-via-keyboard")
    }
}
