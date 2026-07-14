import Foundation

/// E2E: installing a sidecar plugin from a local `.zip` (via
/// `gallager plugin install --zip`) makes it appear in the Agents picker **and**
/// auto-selects it — live, no app restart.
///
/// Guards two pieces of the local-zip install feature:
///   1. The new `gallager plugin install --zip <path>` CLI verb → router `path`
///      branch → `AppCoordinator.installPluginFromZip`.
///   2. The picker refresh (`pluginCatalogRevision`) + auto-select
///      (`lastInstalledPluginID` → `onChange` → `selectedAgentID`) that fire on a
///      successful install while the Agents tab is open.
///
/// The install is driven through the CLI (over the app's Unix socket) rather than
/// the Settings "Install from Zip…" button, because that button opens an
/// `NSOpenPanel` that e2e can't drive. The zip itself is built from the real
/// `EchoPluginSidecar` binary so the install actually enables (a successful
/// install — not enableFailed — is what sets `lastInstalledPluginID`).
public enum AgentsInstallZipAutoSelectScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Agents Install Zip Auto Select",
        tags: ["plugin", "sidecar", "agents", "settings", "cli-api", "macos-only"]
    ) {
        // 1. Build a self-contained sidecar .zip (stored at ${zipPath}) and a tmux
        //    pane to run the CLI from.
        TestStep.macStageSidecarZip(
            id: "ziptest-sidecar",
            displayName: "Zip Install Test",
            storeAs: "zipPath"
        )
        TestStep.tmuxCreateSession(name: "zip-install", width: 100, height: 30)

        Shortcut.macOnlySetup

        // 2. Wire the `gallager` CLI helper in the pane (talks to the running app
        //    over its Unix socket — same setup as PluginEnableDisableScenario).
        Shortcut.tmuxClearAndSetPrompt(target: "zip-install:0")
        Shortcut.tmuxRunCommand(
            target: "zip-install:0",
            command: #"export GALLAGER_SOCKET="$TMPDIR/gallager-e2e.sock""#
        )
        Shortcut.tmuxRunCommand(
            target: "zip-install:0",
            command: #"gallager() { "${macOSAppPath}/Contents/MacOS/GallagerCLI" "$@"; }"#
        )

        // 3. Open Settings → Agents. Only the bundled agents exist so far.
        TestStep.macOpenSettings()
        TestStep.macSelectSettingsTab("Agents")
        TestStep.macWaitForElement(titled: "Claude Code", timeout: 10)
        TestStep.macScreenshot(label: "mac-agents-before-zip-install")

        // 4. Install the local zip via the CLI (no NSOpenPanel). The Agents tab is
        //    open, so the install must update it live.
        Shortcut.tmuxRunCommand(
            target: "zip-install:0",
            command: #"gallager plugin install --zip "${zipPath}" --yes > /tmp/e2e-zip-install.txt 2>&1"#
        )

        // 5. The CLI reports a successful install (id echoed back).
        TestStep.waitForFileContains(
            path: "/tmp/e2e-zip-install.txt",
            substring: "Installed: ziptest-sidecar",
            storeAs: "zipInstallOut",
            timeout: 20
        )

        // 6. The new plugin appears in the picker AND is auto-selected: its
        //    per-agent form ("Auto-run Zip Install Test …") only renders when that
        //    segment is the selected one, so this proves both the live refresh and
        //    the auto-select.
        TestStep.macWaitForElement(titled: "Zip Install Test", timeout: 15)
        TestStep.macWaitForElement(titled: "Auto-run Zip Install Test", timeout: 10)
        TestStep.macScreenshot(label: "mac-agents-zip-installed-selected")
    }
}
