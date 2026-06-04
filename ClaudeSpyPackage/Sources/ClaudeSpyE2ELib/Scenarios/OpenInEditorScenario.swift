import Foundation

/// E2E scenario: Open in Editor
///
/// Exercises the "Open in Editor" feature added in issue #461:
/// 1. The file context menu in the file browser exposes an `Open in Editor`
///    submenu listing the editors registered through the
///    `EditorClient` dependency.
/// 2. Selecting an editor from the submenu launches the registered editor
///    with the chosen file's path. We assert this by checking the fake
///    editor's append-only log under `$TMPDIR`.
/// 3. The same submenu is reachable on the file *tab* context menu, proving
///    the shared `FileContextMenu` wiring picks up the new entry.
/// 4. The `Cmd+E` keyboard shortcut, registered as a top-level menu command,
///    surfaces the same editor list as a confirmation dialog when a file
///    tab is focused.
///
/// In E2E mode the macOS app's `EditorClient` dependency is replaced with
/// `EditorClient.fakeScript(...)` (see `--fake-editor-script`), which:
/// - returns *two* editors ("Fake Editor", "Fake Editor 2") from
///   `detectInstalledKnownEditors` so the menu and dialog render their
///   multi-row layout — a single-entry list would never exercise the
///   `ForEach` paths.
/// - launches `fake_editor.py` with the file path as its only argument
/// - additionally appends each `(filePath)` to a known log so the assertion
///   does not race with the script's own write
public enum OpenInEditorScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Open in Editor",
        tags: ["file-browser", "editors", "macos-only"]
    ) {
        // ── Setup ────────────────────────────────────────────────
        TestStep.log("Setup: create tmux session and launch macOS app")
        TestStep.tmuxCreateSession(name: "openineditor", width: 160, height: 50)
        Shortcut.tmuxRunCommand(target: "openineditor:0.0", command: "echo '=== OPEN IN EDITOR TEST ==='")

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        // Re-pin the sidebar after this second resize: `.balanced` NavigationSplitView
        // reflows column widths on resize, so without this the sidebar width is
        // non-deterministic across runs and the screenshots flake.
        TestStep.macSetSidebarWidth(250)

        // Select the session in the sidebar.
        TestStep.macWaitForElement(titled: "openineditor", timeout: 5)
        TestStep.macClickButton(titled: "openineditor")
        TestStep.wait(seconds: 2)

        // ── Phase 1: Open the file browser ───────────────────────
        TestStep.log("Phase 1: open the file browser")
        TestStep.macClickButton(titled: "Files")
        TestStep.macWaitForElement(titled: "README.md", timeout: 10)
        TestStep.macWaitForElement(titled: "hello.txt", timeout: 5)
        TestStep.macScreenshot(label: "mac-file-browser-ready")

        // ── Phase 2: "Open in Editor" via tree context menu ──────
        //
        // Right-click `hello.txt` in the tree. The "Open in Editor" submenu
        // surfaces the two fake editors registered by the E2E launch arg.
        // Picking "Fake Editor" launches our Python script with the file
        // path; the log file under `$TMPDIR` then contains the absolute path
        // to `hello.txt`.
        TestStep.log("Phase 2: 'Open in Editor → Fake Editor' on a tree file")

        // Clean slate so subsequent phases can re-assert against a fresh log.
        TestStep.removeFile(path: "${fakeEditorLogPath}")

        TestStep.macContextSubmenuClick(
            elementTitle: "hello.txt",
            parentMenuItem: "Open in Editor",
            submenuItem: "Fake Editor"
        )

        // The fake editor writes to `${fakeEditorLogPath}` once it receives
        // the file path. Poll instead of relying on a sleep so flakiness
        // around the Python interpreter spin-up doesn't break the run.
        TestStep.waitForFileContains(
            path: "${fakeEditorLogPath}",
            substring: "hello.txt",
            storeAs: "treeMenuLog",
            timeout: 10
        )
        TestStep.assertStoredContains(key: "treeMenuLog", substring: "hello.txt")
        TestStep.macScreenshot(label: "mac-tree-menu-fake-editor-launched")

        // ── Phase 3: "Open in Editor" via file-tab context menu ──
        //
        // Open `README.md` in a file tab so we can right-click the tab
        // itself. The shared `FileContextMenu` should expose the same
        // submenu for tab right-clicks.
        TestStep.log("Phase 3: 'Open in Editor' from a file-tab context menu")
        // Clear the log so the README.md assertion can't accidentally
        // pass against a stale Phase 2 entry that happens to contain
        // README.md (it doesn't today, but stays honest if fixtures shift).
        TestStep.removeFile(path: "${fakeEditorLogPath}")
        TestStep.macContextMenuClick(elementTitle: "README.md", menuItem: "Open in New Tab")
        TestStep.macWaitForElement(titled: "File tab: README.md", timeout: 5)

        TestStep.macContextSubmenuClick(
            elementTitle: "File tab: README.md",
            parentMenuItem: "Open in Editor",
            submenuItem: "Fake Editor"
        )
        TestStep.waitForFileContains(
            path: "${fakeEditorLogPath}",
            substring: "README.md",
            storeAs: "tabMenuLog",
            timeout: 10
        )
        TestStep.assertStoredContains(key: "tabMenuLog", substring: "README.md")
        TestStep.macScreenshot(label: "mac-tab-menu-fake-editor-launched")

        // ── Phase 4: Cmd+E keyboard shortcut on focused tab ──────
        //
        // Open `hello.txt` in a new tab (so the tab is focused), then send
        // Cmd+E via AppleScript keystroke. The `Open in Editor` confirmation
        // dialog appears showing both fake editors; click "Fake Editor 2" to
        // exercise the second row and dispatch.
        TestStep.log("Phase 4: Cmd+E on a focused file tab")
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 1)
        TestStep.macContextMenuClick(elementTitle: "hello.txt", menuItem: "Open in New Tab")
        TestStep.macWaitForElement(titled: "File tab: hello.txt", timeout: 5)
        TestStep.macClickButton(titled: "File tab: hello.txt")
        TestStep.wait(seconds: 1)

        // Wipe the log so the post-dispatch assertion can't be satisfied by a
        // stale Phase 2 entry — that was the original false-positive in this
        // phase. With a fresh log, `waitForFileContains` only succeeds if the
        // Cmd+E dispatch actually ran the script.
        TestStep.removeFile(path: "${fakeEditorLogPath}")

        // Send Cmd+E to trigger the top-level "Open in Editor…" command. The
        // confirmation dialog appears showing the editor list.
        TestStep.macPressKey(.character("e"), modifiers: .command)
        // Both editors should be visible in the multi-row dialog.
        TestStep.macWaitForElement(titled: "Fake Editor", timeout: 5)
        TestStep.macWaitForElement(titled: "Fake Editor 2", timeout: 5)
        TestStep.macScreenshot(label: "mac-cmd-e-dialog")
        // SwiftUI's confirmationDialog renders its action buttons in a sheet
        // whose AXPress handler is unreliable from outside the process; a
        // CGEvent click at the element's frame goes through correctly. Clicking
        // the second-row entry also exercises the multi-editor `ForEach`.
        TestStep.macCGClick(titled: "Fake Editor 2")

        // Fresh log → only the Cmd+E dispatch can put "hello.txt" in there.
        TestStep.waitForFileContains(
            path: "${fakeEditorLogPath}",
            substring: "hello.txt",
            storeAs: "cmdELog",
            timeout: 10
        )
        TestStep.assertStoredContains(key: "cmdELog", substring: "hello.txt")
        TestStep.macScreenshot(label: "mac-cmd-e-dispatched")

        // ── Phase 5: Settings → Editors tab shows both fake editors ─
        //
        // The Settings window's new "Editors" tab should list both editors
        // seeded by the E2E launch arg. Asserting on both rows guards
        // against a regression that collapses the multi-row list view.
        TestStep.log("Phase 5: Settings → Editors lists both fake editors")
        TestStep.macOpenSettings()
        TestStep.wait(seconds: 2)
        TestStep.macSelectSettingsTab("Editors")
        TestStep.macWaitForElement(titled: "Editor: Fake Editor", timeout: 5)
        TestStep.macWaitForElement(titled: "Editor: Fake Editor 2", timeout: 5)
        TestStep.macScreenshot(label: "mac-settings-editors-tab")
        // The settings window's title reflects the selected tab, not "Settings",
        // so close it via the active tab title rather than guessing the chrome.
        TestStep.macCloseWindow(titled: "Editors")

        // Tear down.
        Shortcut.tmuxRunCommand(target: "openineditor:0.0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
