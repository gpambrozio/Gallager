import Foundation

/// E2E scenario: per-folder workbench layout persistence for **remote/viewer**
/// sessions (issue #608, Scope A — viewer-local). A Mac viewing a paired Mac
/// host persists each remote session's browser-tab + split arrangement per
/// folder, keyed by `(pairId, folder)`, the same way local sessions persist
/// theirs. See `docs/folder-layout-persistence-plan.md`.
///
/// The host's tmux server shares one working directory across its sessions, so
/// two host sessions are always "in the same folder" — exactly the condition
/// the folder-keyed restore targets. The scenario proves, end-to-end on the
/// viewer side, that the live auto-save → `LayoutStore` → seed-on-birth pipeline
/// works for **remote** sessions:
///
/// 1. **Folder clone onto a new remote session** — open a browser tab in the
///    viewer's view of host session `ralpha`, then select the sibling host
///    session `rbeta` (same folder, never viewed) and watch it inherit the
///    folder's browser tab. The tab only appears on `rbeta` if the remote
///    persist + seed fired.
/// 2. **Live independence (restore reads only at birth)** — closing the cloned
///    tab on the live `rbeta` does NOT re-seed or alter the live `ralpha`; an
///    already-arranged remote workbench is never re-read from the store.
///
/// **Why no viewer relaunch leg?** The acceptance criteria also call for a
/// viewer quit/relaunch restoring from disk. Under `--e2e-test` each app
/// instance backs `PreferencesService` with in-memory storage
/// (`ClaudeSpyServerApp`), so a relaunched viewer loses its pairing and can't
/// reconnect — there'd be no remote session to restore into. The disk round
/// trip itself (atomic `layouts.json` write/read under `--gallager-state-root`)
/// is covered by `LayoutStoreTests`; the window-ref split remap is covered by
/// `LayoutSnapshotMapperTests`. This scenario covers the remote-specific
/// wiring those unit tests can't: folder resolution from synced pane state,
/// `persistChangedRemoteLayouts`, and `seedRemoteLayoutIfNeeded`.
public enum RemoteLayoutPersistenceMacViewerScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Remote Layout Persistence Mac Viewer",
        tags: ["layout-persistence", "remote", "macos-only"]
    ) {
        // ── Setup: pair two Mac apps ─────────────────────────────────
        Shortcut.twoMacPairing

        // ── Setup: two host sessions sharing the tmux server's cwd ───
        TestStep.log("Setup: create two host sessions (same folder) — ralpha and rbeta")
        TestStep.tmuxCreateSession(name: "ralpha", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "ralpha:0")
        TestStep.tmuxCreateSession(name: "rbeta", width: 100, height: 30)
        Shortcut.tmuxClearAndSetPrompt(target: "rbeta:0")

        // Open the host's panes window so the host scans + relays the sessions.
        Shortcut.openPanesWindow()
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macWaitForElement(titled: "ralpha", timeout: 15)

        // ── Viewer connects and selects ralpha ───────────────────────
        TestStep.log("Phase 1: viewer selects remote session ralpha and opens a browser tab")
        Shortcut.openPanesWindow(instance: 1)
        TestStep.macResizeWindow(width: 1_200, height: 700, instance: 1)
        TestStep.macSetSidebarWidth(250, instance: 1)
        TestStep.macWaitForElement(titled: "ralpha", timeout: 15, instance: 1)
        TestStep.macWaitForElement(titled: "rbeta", timeout: 15, instance: 1)
        TestStep.macClickButton(titled: "ralpha", instance: 1)
        // Wait for the remote tab bar to materialize — its "+" (New Tab) button
        // is a stable signal that doesn't depend on the window's tmux name.
        TestStep.macWaitForElementQuery(.label("New Tab"), timeout: 10, instance: 1)

        // Open a browser tab via the "+" menu → New Browser. The "+" is a
        // SwiftUI Menu; AXPress is flaky, so open it with a CGEvent click then
        // pick the inner item (same approach as RemoteTabReorderScenario).
        TestStep.macCGClickElement(query: .label("New Tab"), instance: 1)
        TestStep.wait(seconds: 1)
        TestStep.macClickButton(titled: "New Browser", instance: 1)
        // The new browser tab focuses the URL field and shows in the strip.
        TestStep.macWaitForElement(titled: "URL", timeout: 5, instance: 1)
        TestStep.macWaitForElementQuery(.labelContains("Browser tab:"), timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-ralpha-browser-tab", instance: 1)

        // ── Folder clone onto the sibling remote session rbeta ───────
        TestStep.log("Phase 2: select rbeta (same folder, never viewed) — it inherits ralpha's browser tab")
        // Remote auto-save runs on the same 2s cadence as local; give it a beat
        // to persist ralpha's layout before rbeta's seed-on-birth reads the
        // folder record.
        TestStep.wait(seconds: 3)
        TestStep.macClickButton(titled: "rbeta", instance: 1)
        TestStep.macWaitForElementQuery(.label("New Tab"), timeout: 10, instance: 1)
        // rbeta started with no browser tabs; this tab only appears if the
        // remote folder seed fired. Headline assertion.
        TestStep.macWaitForElementQuery(.labelContains("Browser tab:"), timeout: 10, instance: 1)
        TestStep.macScreenshot(label: "viewer-rbeta-cloned-from-folder", instance: 1)

        // ── Live independence (restore reads only at birth) ──────────
        TestStep.log("Phase 3: close the browser tab on rbeta; the live ralpha is NOT re-seeded and keeps its tab")
        TestStep.macCGClickElement(query: .labelContains("Close browser tab:"), instance: 1)
        TestStep.macWaitForElementQueryToDisappear(.labelContains("Browser tab:"), timeout: 5, instance: 1)

        TestStep.macClickButton(titled: "ralpha", instance: 1)
        TestStep.macWaitForElementQuery(.label("New Tab"), timeout: 10, instance: 1)
        // ralpha was already arranged, so its live workbench is never re-read
        // from the store — its browser tab is still open even though rbeta's
        // close changed the folder record.
        TestStep.macWaitForElementQuery(.labelContains("Browser tab:"), timeout: 5, instance: 1)
        TestStep.macScreenshot(label: "viewer-ralpha-unchanged-after-rbeta-diverged", instance: 1)

        // ── Tear down ────────────────────────────────────────────────
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "ralpha"])
        TestStep.tmuxCommand(arguments: ["kill-session", "-t", "rbeta"])
        TestStep.wait(seconds: 2)
    }
}
