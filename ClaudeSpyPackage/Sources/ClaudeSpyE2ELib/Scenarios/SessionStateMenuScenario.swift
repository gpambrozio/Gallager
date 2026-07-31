import Foundation

/// E2E scenario: manually setting a session's state from the "Set State"
/// context menu, on the macOS host *and* the iOS viewer (issue #695).
///
/// A single Claude session (`e2e-state`, project "StateProject") is created on
/// the host, so it starts idle. The scenario then drives the override from
/// both platforms:
///   1. Host right-click → "Set State" pins Waiting for input, then Idle, then
///      re-pins Waiting for input and clears it with "Automatic" — the host
///      sidebar indicator must follow each choice and revert to the agent's
///      own state when cleared, and the iOS session row must mirror every
///      change (its accessibility value carries the shown state's label).
///   2. iOS long-press → "Set State" pins Waiting for input and later clears
///      it with "Automatic" — driving the viewer-initiated `SetSessionState`
///      command path back to the host, which must update its own sidebar and
///      push the new state to the viewer.
///
/// Every host right-click targets a row showing the idle moon or the attention
/// bell (static glyphs). We deliberately never right-click a row in the
/// *Working* state: that row renders a `ProgressView`, which SwiftUI merges
/// into an `AXBusyIndicator` that swallows the row's accessibility children,
/// so a context menu can't be opened on it (the same merge the sidebar works
/// around elsewhere with `SessionProgressAccessibilityProxy`).
///
/// On iOS the row's visible status text stays on the agent's own state, so the
/// override is observed via the row's accessibility *value* ("Waiting for
/// input" appears only while the override is pinned) — the same value
/// VoiceOver reads.
///
/// The complementary guarantee — that a later plugin state update *clears* the
/// override so a live agent always wins — is the existing `applyState` behavior
/// already e2e-proven by `GallagerCLIScenario` ("hook events override CLI
/// state"): the menu writes the very same `cliSessionState` field the CLI does,
/// so both are cleared by the same code. It isn't re-driven here because
/// reliably re-triggering a *definite* plugin state onto an already-running
/// agent session mid-scenario is flaky in the harness.
///
/// The Mac-viewer flavor of the menu isn't driven here: its
/// `SetSessionState` command rides exactly the relay plumbing that the iOS
/// phases below and `SessionColorSyncScenario`'s Mac-viewer phase already
/// exercise end-to-end.
public enum SessionStateMenuScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Session State Menu",
        tags: ["state", "sync"]
    ) {
        // ── Setup: pair host with iOS viewer, one Claude session ────────

        FreshPairingScenario.scenario

        TestStep.tmuxCreateSession(name: "e2e-state", width: 100, height: 30)
        TestStep.wait(seconds: 3)

        TestStep.tmuxStorePaneId(target: "e2e-state:0.0", storeAs: "statePaneId")

        // SessionStart makes the row a Claude session sitting idle, so each
        // override below is a visible change from the agent's own state.
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-state-session",
                "timestamp": "2026-07-30T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${statePaneId}",
            projectPath: "/Users/test/StateProject"
        )
        TestStep.wait(seconds: 3)

        Shortcut.openPanesWindow()
        TestStep.macWaitForElement(titled: "StateProject", timeout: 30)
        TestStep.macWaitForElement(titled: "Idle", timeout: 15)

        // The iOS row's accessibility value carries the shown state's label
        // ("Idle" with no override set).
        TestStep.iosWaitForElement(.labelContains("StateProject"), timeout: 15)
        TestStep.iosWaitForElement(.valueContains("Idle"), timeout: 15)

        TestStep.macScreenshot(label: "mac-state-idle-baseline")
        TestStep.iosScreenshot(label: "ios-state-idle-baseline")

        // ── Phase 1: host pins "Waiting for input" via "Set State" ──────
        //
        // Right-clicks the idle row (a static moon glyph). The row flips to the
        // attention bell — also a static glyph, so it stays right-clickable.
        // The override must also land on the iOS row.

        TestStep.log("Host setting StateProject → Waiting for input via 'Set State' submenu")
        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Waiting for input"
        )
        TestStep.macWaitForElement(titled: "Waiting for input", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Idle", timeout: 15)
        TestStep.iosWaitForElement(.valueContains("Waiting for input"), timeout: 20)
        TestStep.macScreenshot(label: "mac-state-waiting")
        TestStep.iosScreenshot(label: "ios-state-waiting")

        // ── Phase 2: host pins "Idle" (right-clicking the bell row) ─────
        //
        // On iOS an Idle override reads the same as the agent's own idle
        // state, so the observable signal is the waiting value vanishing.

        TestStep.log("Host setting StateProject → Idle via 'Set State' submenu")
        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Idle"
        )
        TestStep.macWaitForElement(titled: "Idle", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Waiting for input", timeout: 15)
        TestStep.iosWaitForElementToDisappear(.valueContains("Waiting for input"), timeout: 20)
        TestStep.macScreenshot(label: "mac-state-idle-override")

        // ── Phase 3: host's "Automatic" clears the override ─────────────
        //
        // Re-pin Waiting for input so the override differs from the agent's idle
        // state (and confirm iOS saw the pin, so the disappearance below can't
        // pass vacuously), then clear it — the row must fall back to the
        // agent's Idle on both platforms.

        TestStep.log("Host re-setting StateProject → Waiting for input, then clearing via 'Automatic'")
        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Waiting for input"
        )
        TestStep.macWaitForElement(titled: "Waiting for input", timeout: 15)
        TestStep.iosWaitForElement(.valueContains("Waiting for input"), timeout: 20)

        TestStep.macContextSubmenuClick(
            elementTitle: "e2e-state",
            parentMenuItem: "Set State",
            submenuItem: "Automatic"
        )
        TestStep.macWaitForElement(titled: "Idle", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Waiting for input", timeout: 15)
        TestStep.iosWaitForElementToDisappear(.valueContains("Waiting for input"), timeout: 20)
        TestStep.macScreenshot(label: "mac-state-automatic-cleared")

        // ── Phase 4: iOS pins "Waiting for input" via long-press menu ───
        //
        // SwiftUI `.contextMenu { }` opens on a sustained press on iOS; the
        // "Set State" entry is a SwiftUI `Menu`, so tapping it slides in the
        // state items. This drives the viewer-initiated `SetSessionState`
        // command path the host-driven phases above don't touch.

        TestStep.log("iOS setting StateProject → Waiting for input via long-press context menu")
        TestStep.iosLongPress(.label("StateProject"), duration: 1)
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("Set State"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("Waiting for input"))

        TestStep.macWaitForElement(titled: "Waiting for input", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Idle", timeout: 15)
        TestStep.iosWaitForElement(.valueContains("Waiting for input"), timeout: 20)
        TestStep.macScreenshot(label: "mac-state-waiting-from-ios")
        TestStep.iosScreenshot(label: "ios-state-waiting-from-ios")

        // ── Phase 5: iOS clears the override via "Automatic" ────────────
        //
        // "Automatic" is only offered while an override is set (it was just
        // pinned from iOS above). Clearing must revert the host sidebar to the
        // agent's Idle and drop the waiting value from the iOS row.

        TestStep.log("iOS clearing StateProject's override via 'Automatic'")
        TestStep.iosLongPress(.label("StateProject"), duration: 1)
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("Set State"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.label("Automatic"))

        TestStep.macWaitForElement(titled: "Idle", timeout: 15)
        TestStep.macWaitForElementToDisappear(titled: "Waiting for input", timeout: 15)
        TestStep.iosWaitForElementToDisappear(.valueContains("Waiting for input"), timeout: 20)
        TestStep.macScreenshot(label: "mac-state-cleared-from-ios")
        TestStep.iosScreenshot(label: "ios-state-cleared-from-ios")
    }
}
