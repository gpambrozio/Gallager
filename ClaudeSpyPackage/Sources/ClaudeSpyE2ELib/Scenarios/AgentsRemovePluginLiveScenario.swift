import Foundation

/// E2E: removing a sidecar plugin updates the Agents picker **live**, without an
/// app restart (regression guard for two bugs found while shipping local-zip
/// install):
///
///   1. `PluginInstaller.remove` only called `registry.disable()` (stops the
///      core) but left the manifest/source registration in place, so the removed
///      plugin kept appearing in `registeredIDs` — and thus the picker — until
///      the next launch. `registry.unregisterSidecar` fixes that.
///   2. The Agents picker derives from the `@ObservationIgnored` plugin registry,
///      so a registry mutation never invalidated SwiftUI. An observed
///      `pluginCatalogRevision` (bumped on install/remove) now drives the refresh.
///
/// Also exercises the "Remove Plugin…" button living in the per-agent form body
/// (only for non-bundled, folder-dropped/URL plugins) and the destructive
/// confirmation dialog.
///
/// A folder-dropped `echo-sidecar` fixture is staged before launch so it shows up
/// as a third, removable segment alongside the bundled Claude Code / Codex.
public enum AgentsRemovePluginLiveScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Agents Remove Plugin Live",
        tags: ["plugin", "sidecar", "agents", "settings", "macos-only"]
    ) {
        // 1. Stage a removable folder-dropped sidecar before the app launches so
        //    it is discovered + registered (source `.folder`) on startup.
        TestStep.macStageSidecarFixture(id: "echo-sidecar")

        Shortcut.macOnlySetup

        // 2. Open Settings → Agents. The staged sidecar appears as a picker
        //    segment next to the bundled agents — proving launch discovery + that
        //    the picker lists runtime-registered sidecars.
        TestStep.macOpenSettings()
        TestStep.macSelectSettingsTab("Agents")
        TestStep.macWaitForElement(titled: "Echo Sidecar (E2E)", timeout: 10)

        // 3. Select the sidecar segment → its per-agent form loads with the
        //    in-form "Remove Plugin…" button (shown only for non-bundled plugins).
        //    The button is asserted in the accessibility tree; it sits at the
        //    bottom of the grouped form, which scrolls, so it may be below the
        //    fold in the screenshot (the Settings window can't be resized taller).
        TestStep.macClickButton(titled: "Echo Sidecar (E2E)")
        TestStep.macWaitForElement(titled: "Remove Plugin", timeout: 5)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-agents-sidecar-selected")

        // 4. Remove it via the form button + destructive confirmation dialog.
        TestStep.macClickButton(titled: "Remove Plugin")
        TestStep.macWaitForElement(titled: "Remove \"Echo Sidecar (E2E)\"", timeout: 5)
        TestStep.macClickButton(titled: "Remove \"Echo Sidecar (E2E)\"")

        // 5. The segment disappears from the picker immediately — no restart.
        //    Selection falls back to the first remaining agent (Claude Code).
        TestStep.macWaitForElementToDisappear(titled: "Echo Sidecar (E2E)", timeout: 10)
        TestStep.wait(seconds: 0.5)
        TestStep.macScreenshot(label: "mac-agents-sidecar-removed")
    }
}
