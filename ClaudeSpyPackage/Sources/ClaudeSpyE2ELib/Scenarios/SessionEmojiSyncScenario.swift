import Foundation

/// E2E scenario: Session emoji synchronization across all three platforms.
///
/// Verifies that custom session emoji icons assigned via the right-click /
/// long-press menu sync between the macOS host, a macOS viewer, and an iOS
/// viewer for several sessions in the same sidebar — each platform must
/// render every session's badge with the right emoji, independently of the
/// others.
///
/// Three sessions named `e2e-emoji-a`, `e2e-emoji-b`, and `e2e-emoji-c` are
/// created on the host. The scenario:
///   1. Sets distinct emojis from the host's "Set Emoji" picker popover and
///      verifies all three platforms reflect every choice.
///   2. Edits one session's emoji from the host's "Emoji: <value>" entry to
///      prove edit (rather than fresh set) propagates everywhere.
///   3. From the **Mac viewer**, edits a different session's emoji and
///      verifies host + iOS pick it up — the viewer-to-host command path is
///      otherwise untested.
///   4. From the **iOS viewer**, drives the half-detent emoji picker sheet
///      to change a session's emoji (search → tap glyph) — exercises the
///      iOS-to-host command path on the *set* side.
///   5. From the **iOS viewer**, long-presses a session row and clears its
///      emoji via the "Clear Emoji" entry — same iOS-to-host path on the
///      *clear* side.
///   6. Clears the remaining two so all three sessions end up bare.
///   7. Re-adds an emoji and restarts the host to verify it's persisted as
///      the tmux `@gallager-emoji` user option (host only — viewer pairings
///      are in-memory under `--e2e-test`).
///
/// All emoji mutations go through the right-click / long-press context menu
/// on whichever platform is initiating — never `tmux set-option` — so the
/// full menu wiring is exercised end-to-end. Each platform exposes the
/// rendered emoji with `accessibilityLabel("emoji <value>")`, so the same
/// `emoji <value>` element query works on host, Mac viewer, and iOS viewer
/// alike.
public enum SessionEmojiSyncScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Session Emoji Sync",
        tags: ["emoji", "sync"]
    ) {
        // ── Phase 1: Pair host with iOS viewer + Mac viewer ─────────────

        FreshPairingScenario.scenario
        Shortcut.addMacViewer

        // ── Phase 2: Create three Claude sessions on the host ───────────

        TestStep.tmuxCreateSession(name: "e2e-emoji-a", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "e2e-emoji-b", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "e2e-emoji-c", width: 80, height: 24)
        TestStep.wait(seconds: 3)

        TestStep.tmuxStorePaneId(target: "e2e-emoji-a:0.0", storeAs: "paneIdA")
        TestStep.tmuxStorePaneId(target: "e2e-emoji-b:0.0", storeAs: "paneIdB")
        TestStep.tmuxStorePaneId(target: "e2e-emoji-c:0.0", storeAs: "paneIdC")

        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-emoji-a-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneIdA}",
            projectPath: "/Users/test/AlphaProject"
        )
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-emoji-b-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneIdB}",
            projectPath: "/Users/test/BravoProject"
        )
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-emoji-c-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneIdC}",
            projectPath: "/Users/test/CharlieProject"
        )
        TestStep.wait(seconds: 3)

        // ── Phase 3: Open the Panes window on host + viewer ─────────────

        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "AlphaProject", timeout: 30)
        TestStep.macWaitForElement(titled: "BravoProject", timeout: 30)
        TestStep.macWaitForElement(titled: "CharlieProject", timeout: 30)

        TestStep.wait(seconds: 3)
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macWaitForElement(titled: "AlphaProject", timeout: 30, instance: 1)
        TestStep.macWaitForElement(titled: "BravoProject", timeout: 30, instance: 1)
        TestStep.macWaitForElement(titled: "CharlieProject", timeout: 30, instance: 1)

        TestStep.iosWaitForElement(.labelContains("AlphaProject"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("BravoProject"), timeout: 15)
        TestStep.iosWaitForElement(.labelContains("CharlieProject"), timeout: 15)

        TestStep.macScreenshot(label: "host-before-emoji")
        TestStep.macScreenshot(label: "viewer-before-emoji", instance: 1)
        TestStep.iosScreenshot(label: "ios-before-emoji")

        // ── Phase 4: Set distinct emojis via the SwiftEmojiPicker popover ──
        //
        // Each pick is done through the host's right-click → "Set Emoji"
        // entry, which opens a popover anchored to the row carrying the
        // SwiftEmojiPicker grid. We drive it by focusing its search field,
        // typing a name that uniquely surfaces the target glyph, and
        // clicking the glyph cell — the picker auto-dismisses on selection.
        // The badge then has to land on every platform before the next
        // session is touched, otherwise we wouldn't be testing simultaneous
        // propagation.

        TestStep.log("Host setting AlphaProject → 🚀 via emoji picker")

        TestStep.macContextMenuClick(elementTitle: "e2e-emoji-a", menuItem: "Set Emoji")
        TestStep.macWaitForElement(titled: "Search", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macFocusElement(titled: "Search")
        TestStep.macType(text: "rocket")
        TestStep.macWaitForElement(titled: "🚀", timeout: 5)
        TestStep.macCGClick(titled: "🚀")

        TestStep.macWaitForElement(titled: "emoji 🚀", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji 🚀", timeout: 15, instance: 1)
        TestStep.iosWaitForElement(.labelContains("emoji 🚀"), timeout: 20)

        TestStep.log("Host setting BravoProject → 🐛 via emoji picker")

        TestStep.macContextMenuClick(elementTitle: "e2e-emoji-b", menuItem: "Set Emoji")
        TestStep.macWaitForElement(titled: "Search", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macFocusElement(titled: "Search")
        TestStep.macType(text: "bug")
        TestStep.macWaitForElement(titled: "🐛", timeout: 5)
        TestStep.macCGClick(titled: "🐛")

        TestStep.macWaitForElement(titled: "emoji 🐛", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji 🐛", timeout: 15, instance: 1)
        TestStep.iosWaitForElement(.labelContains("emoji 🐛"), timeout: 20)

        TestStep.log("Host setting CharlieProject → 📝 via emoji picker")

        TestStep.macContextMenuClick(elementTitle: "e2e-emoji-c", menuItem: "Set Emoji")
        TestStep.macWaitForElement(titled: "Search", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macFocusElement(titled: "Search")
        TestStep.macType(text: "memo")
        TestStep.macWaitForElement(titled: "📝", timeout: 5)
        TestStep.macCGClick(titled: "📝")

        TestStep.macWaitForElement(titled: "emoji 📝", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji 📝", timeout: 15, instance: 1)
        TestStep.iosWaitForElement(.labelContains("emoji 📝"), timeout: 20)

        // All three emojis must coexist on every platform.
        TestStep.macScreenshot(label: "host-after-set-three")
        TestStep.macScreenshot(label: "viewer-after-set-three", instance: 1)
        TestStep.iosScreenshot(label: "ios-after-set-three")

        // ── Phase 5: Re-edit BravoProject from "Emoji: 🐛" → ✅ ──────────
        //
        // When an emoji is already set, the menu label shows
        // "Emoji: <value>" instead of "Set Emoji". Editing must replace the
        // emoji and propagate the new value, not stack.

        TestStep.log("Host changing BravoProject → ✅ via 'Emoji: 🐛' entry")

        TestStep.macContextMenuClick(elementTitle: "e2e-emoji-b", menuItem: "Emoji: 🐛")
        TestStep.macWaitForElement(titled: "Search", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macFocusElement(titled: "Search")
        // searchKey is `checkMarkButton` (camelCase, no spaces); the picker's
        // filter does substring contains() against the lowercased searchKey,
        // so a multi-word "check mark button" wouldn't match.
        TestStep.macType(text: "checkmark")
        TestStep.macWaitForElement(titled: "✅", timeout: 5)
        TestStep.macCGClick(titled: "✅")

        // 🐛 must be gone everywhere, replaced by ✅. 🚀 and 📝 unchanged.
        TestStep.macWaitForElementToDisappear(titled: "emoji 🐛", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji ✅", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji 🚀", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji 📝", timeout: 15)

        TestStep.macWaitForElementToDisappear(titled: "emoji 🐛", timeout: 15, instance: 1)
        TestStep.macWaitForElement(titled: "emoji ✅", timeout: 15, instance: 1)

        TestStep.iosWaitForElementToDisappear(.labelContains("emoji 🐛"), timeout: 20)
        TestStep.iosWaitForElement(.labelContains("emoji ✅"), timeout: 20)

        TestStep.macScreenshot(label: "host-after-edit")
        TestStep.macScreenshot(label: "viewer-after-edit", instance: 1)
        TestStep.iosScreenshot(label: "ios-after-edit")

        // ── Phase 6: Mac viewer changes Charlie 📝 → 🎨 ──────────────────
        //
        // The Mac viewer's `RemoteSessionSidebarRow` carries the same
        // right-click menu as the host. Editing from instance 1 routes
        // through the relay back to the host's
        // `MirrorWindowManager.setSessionEmoji`, which writes tmux and
        // pushes session state to every viewer. The new emoji must land
        // on host, viewer, and iOS.

        TestStep.log("Mac viewer changing CharlieProject → 🎨 via 'Emoji: 📝' entry")

        TestStep.macContextMenuClick(
            elementTitle: "CharlieProject",
            menuItem: "Emoji: 📝",
            instance: 1
        )
        TestStep.macWaitForElement(titled: "Search", timeout: 5, instance: 1)
        TestStep.wait(seconds: 0.5)
        TestStep.macFocusElement(titled: "Search", instance: 1)
        TestStep.macType(text: "palette", instance: 1)
        TestStep.macWaitForElement(titled: "🎨", timeout: 5, instance: 1)
        TestStep.macCGClick(titled: "🎨", instance: 1)

        TestStep.macWaitForElementToDisappear(titled: "emoji 📝", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji 🎨", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji 🚀", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji ✅", timeout: 15)

        TestStep.macWaitForElementToDisappear(titled: "emoji 📝", timeout: 15, instance: 1)
        TestStep.macWaitForElement(titled: "emoji 🎨", timeout: 15, instance: 1)

        TestStep.iosWaitForElementToDisappear(.labelContains("emoji 📝"), timeout: 20)
        TestStep.iosWaitForElement(.labelContains("emoji 🎨"), timeout: 20)

        TestStep.macScreenshot(label: "host-after-viewer-change")
        TestStep.macScreenshot(label: "viewer-after-viewer-change", instance: 1)
        TestStep.iosScreenshot(label: "ios-after-viewer-change")

        // ── Phase 7: iOS viewer changes Bravo ✅ → 😍 via emoji picker ───
        //
        // iOS presents the SwiftEmojiPicker as a half-detent sheet. We open
        // it via long-press → "Emoji: ✅", wait for the picker to render,
        // and tap a glyph that's already visible on the initial Smileys
        // page so we don't have to drive the picker's search field
        // (XCUITest taps land on the field but iOS doesn't reliably grant
        // it keyboard focus, so typed input never reaches the filter).
        // The new emoji must round-trip through the relay back to the host
        // (which writes tmux and pushes session state) and then back out to
        // every viewer.

        TestStep.log("iOS viewer changing BravoProject → 😍 via emoji picker")

        TestStep.iosLongPress(.label("BravoProject"), duration: 1)
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("Emoji: ✅"))
        TestStep.iosWaitForElement(.label("😍"), timeout: 5)
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("😍"))

        TestStep.macWaitForElementToDisappear(titled: "emoji ✅", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji 😍", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji 🚀", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji 🎨", timeout: 15)

        TestStep.macWaitForElementToDisappear(titled: "emoji ✅", timeout: 15, instance: 1)
        TestStep.macWaitForElement(titled: "emoji 😍", timeout: 15, instance: 1)

        TestStep.iosWaitForElementToDisappear(.labelContains("emoji ✅"), timeout: 20)
        TestStep.iosWaitForElement(.labelContains("emoji 😍"), timeout: 20)

        TestStep.macScreenshot(label: "host-after-ios-set")
        TestStep.macScreenshot(label: "viewer-after-ios-set", instance: 1)
        TestStep.iosScreenshot(label: "ios-after-ios-set")

        // ── Phase 8: iOS viewer clears Alpha 🚀 via long-press menu ──────
        //
        // SwiftUI `.contextMenu { }` opens on a sustained press on iOS.
        // Tapping "Clear Emoji" sends a `setSessionEmoji(nil)` command back
        // through the relay to the host's `MirrorWindowManager`, which
        // writes tmux and pushes session state to every viewer. This
        // exercises the iOS-to-host command path the host- and Mac-viewer
        // phases above don't touch.
        //
        // Clearing instead of editing keeps the test free of platform-
        // specific emoji typing concerns (iOS hardware keyboard input via
        // AppleScript can be flaky for multi-codepoint glyphs).

        TestStep.log("iOS viewer clearing AlphaProject's emoji via long-press")

        TestStep.iosLongPress(.label("AlphaProject"), duration: 1)
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("Clear Emoji"))

        TestStep.macWaitForElementToDisappear(titled: "emoji 🚀", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji 😍", timeout: 15)
        TestStep.macWaitForElement(titled: "emoji 🎨", timeout: 15)

        TestStep.macWaitForElementToDisappear(titled: "emoji 🚀", timeout: 15, instance: 1)
        TestStep.macWaitForElement(titled: "emoji 😍", timeout: 15, instance: 1)

        TestStep.iosWaitForElementToDisappear(.labelContains("emoji 🚀"), timeout: 20)
        TestStep.iosWaitForElement(.labelContains("emoji 😍"), timeout: 20)

        TestStep.macScreenshot(label: "host-after-ios-clear")
        TestStep.macScreenshot(label: "viewer-after-ios-clear", instance: 1)
        TestStep.iosScreenshot(label: "ios-after-ios-clear")

        // ── Phase 9: Clear the remaining two so the sidebar ends bare ───

        TestStep.log("Host clearing BravoProject and CharlieProject")

        TestStep.macContextMenuClick(
            elementTitle: "e2e-emoji-b",
            menuItem: "Clear Emoji"
        )
        TestStep.macWaitForElementToDisappear(titled: "emoji 😍", timeout: 15)

        TestStep.macContextMenuClick(
            elementTitle: "e2e-emoji-c",
            menuItem: "Clear Emoji"
        )
        TestStep.macWaitForElementToDisappear(titled: "emoji 🎨", timeout: 15)

        TestStep.macWaitForElementToDisappear(titled: "emoji 😍", timeout: 15, instance: 1)
        TestStep.macWaitForElementToDisappear(titled: "emoji 🎨", timeout: 15, instance: 1)

        TestStep.iosWaitForElementToDisappear(.labelContains("emoji 😍"), timeout: 20)
        TestStep.iosWaitForElementToDisappear(.labelContains("emoji 🎨"), timeout: 20)

        TestStep.macScreenshot(label: "host-after-clear-all")
        TestStep.macScreenshot(label: "viewer-after-clear-all", instance: 1)
        TestStep.iosScreenshot(label: "ios-after-clear-all")

        // ── Phase 10: Re-add emoji and restart host to verify persistence ─
        //
        // Emojis are stored as the tmux `@gallager-emoji` user option, so they
        // should survive the host app being killed and relaunched. Viewers
        // are lost on restart (in-memory pairings under --e2e-test), so this
        // phase only checks the host side.

        TestStep.log("Re-adding emoji and restarting host to verify persistence")

        TestStep.macContextMenuClick(elementTitle: "e2e-emoji-a", menuItem: "Set Emoji")
        TestStep.macWaitForElement(titled: "Search", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macFocusElement(titled: "Search")
        TestStep.macType(text: "floppy")
        TestStep.macWaitForElement(titled: "💾", timeout: 5)
        TestStep.macCGClick(titled: "💾")
        TestStep.macWaitForElement(titled: "emoji 💾", timeout: 10)
        TestStep.macScreenshot(label: "host-before-restart")

        TestStep.terminateMacApp()
        TestStep.wait(seconds: 2)
        TestStep.launchMacApp()
        TestStep.wait(seconds: 3)
        Shortcut.openPanesWindow()

        // The session row should come back with the persisted emoji,
        // hydrated from the tmux user option on the first refresh after launch.
        TestStep.macWaitForElement(titled: "emoji 💾", timeout: 30)
        TestStep.macScreenshot(label: "host-after-restart")
    }
}
