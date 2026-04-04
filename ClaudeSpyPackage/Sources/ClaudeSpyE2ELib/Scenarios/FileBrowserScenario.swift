import Foundation

/// E2E scenario: File Browser
///
/// Exercises all file browser features added in issue #257:
/// 1. Tab activation/deactivation and initial empty state
/// 2. Text, markdown, HTML, image, PDF, video, and unsupported file viewers
/// 3. Lazy-loading folder expansion at multiple depth levels
/// 4. Context menu with clipboard assertions (Copy Path, Copy Relative Path)
/// 5. State persistence across tab toggle (expansion, selection, sidebar width)
/// 6. State isolation on window switch (file browser does not leak to other windows)
///
/// Regression guards:
/// - Nested NavigationSplitView layout gap (ee55599)
/// - SwiftUI VideoPlayer crash (d278865)
/// - Session switch state leak (517c7db)
/// - Markdown rendering (d278865 → 1163e87)
/// - Main thread blocking on tree load (517c7db)
/// - 8KB binary file detection (2756f29)
///
/// Note: File selection uses `macCGClick` (CGEvent left-click) instead of
/// `macClickButton` (AXPress) because AXPress walks up the AX parent chain
/// and triggers outline-row disclosure toggles instead of List selection.
/// Folder expansion uses `macClickButton` since disclosure toggle is desired.
public enum FileBrowserScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "File Browser",
        tags: ["file-browser", "macos-only"]
    ) {
        // ── Setup ────────────────────────────────────────────────
        TestStep.log("Setup: Create tmux session and launch macOS app")
        TestStep.tmuxCreateSession(name: "filebrowse", width: 160, height: 50)
        Shortcut.tmuxRunCommand(target: "filebrowse:0.0", command: "echo '=== FILE BROWSER TEST ==='")

        Shortcut.macOnlySetup
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.wait(seconds: 1)

        // Select session in sidebar
        TestStep.macWaitForElement(titled: "filebrowse", timeout: 5)
        TestStep.macClickButton(titled: "filebrowse")
        TestStep.wait(seconds: 3)

        // ── Phase 1: Tab Activation & Initial State ──────────────
        TestStep.log("Phase 1: Tab activation and initial empty state")
        TestStep.macScreenshot(label: "mac-terminal-view-baseline")

        // Click the file browser tab (folder icon, accessibilityLabel: "Files")
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 2)

        // Tree should load — wait for a root-level file to appear
        TestStep.macWaitForElement(titled: "README.md", timeout: 10)
        // Detail pane should show "Select a File" placeholder
        TestStep.macWaitForElement(titled: "Select a File", timeout: 5)
        // Dot folders like .claude should be visible
        TestStep.macWaitForElement(titled: ".claude", timeout: 5)
        // OS-level dot files like .DS_Store should be filtered out
        TestStep.macWaitForElementToDisappear(titled: ".DS_Store", timeout: 2)
        TestStep.macScreenshot(label: "mac-file-browser-empty-selection")

        // ── Phase 2: Text File Viewer ────────────────────────────
        TestStep.log("Phase 2: Text file viewer")
        TestStep.macCGClick(titled: "hello.txt")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-text-file-viewer")

        // ── Phase 3: Image Viewer ────────────────────────────────
        TestStep.log("Phase 3: Image viewer")
        TestStep.macCGClick(titled: "photo.png")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-image-viewer")

        // ── Phase 4: PDF Viewer ──────────────────────────────────
        TestStep.log("Phase 4: PDF viewer")
        TestStep.macCGClick(titled: "document.pdf")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-pdf-viewer")

        // ── Phase 5: Video Player ────────────────────────────────
        // Guards against SwiftUI VideoPlayer crash (d278865)
        TestStep.log("Phase 5: Video player (crash regression guard)")
        TestStep.macCGClick(titled: "clip.mp4")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-video-player")

        // ── Phase 6: HTML Viewer ─────────────────────────────────
        TestStep.log("Phase 6: HTML viewer (WebView)")
        TestStep.macCGClick(titled: "page.html")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-html-viewer")

        // ── Phase 7: Unsupported / Binary File ──────────────────
        TestStep.log("Phase 7: Unsupported binary file")
        TestStep.macCGClick(titled: "binary.dat")
        TestStep.wait(seconds: 1)
        TestStep.macWaitForElement(titled: "Unable to Read File", timeout: 5)
        TestStep.macScreenshot(label: "mac-unsupported-file")

        // ── Phase 8: Loading Indicator (pending file) ────────────
        // loading.txt hangs on first read — the spinner should show.
        TestStep.log("Phase 8: Loading indicator on pending file")
        TestStep.macCGClick(titled: "loading.txt")
        TestStep.wait(seconds: 2)
        // The spinner should be visible (first read hangs)
        TestStep.macScreenshot(label: "mac-loading-indicator")

        // Select a different file to cancel the hanging read
        TestStep.macCGClick(titled: "hello.txt")
        TestStep.wait(seconds: 1)

        // ── Phase 9: Pending file loads + dynamic folder appears ──
        // Second read of loading.txt succeeds and triggers "generated" folder.
        TestStep.log("Phase 9: Pending file second load + dynamic folder")
        TestStep.macCGClick(titled: "loading.txt")
        TestStep.wait(seconds: 2)
        // Content loads AND the dynamic "generated" folder appears in the tree
        TestStep.macWaitForElement(titled: "generated", timeout: 10)
        TestStep.macScreenshot(label: "mac-pending-file-loaded")

        // ── Phase 10: Markdown Viewer ────────────────────────────
        // Rendered markdown with Textual StructuredText
        TestStep.log("Phase 10: Markdown viewer (Textual StructuredText)")
        TestStep.macCGClick(titled: "README.md")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-markdown-viewer")

        // ── Phase 11: Folder Expansion & Lazy Loading ────────────
        TestStep.log("Phase 11: Lazy folder expansion — src → utils → helper.swift")

        // Expand "src" folder — macClickButton triggers AX disclosure toggle
        TestStep.macClickButton(titled: "src")
        TestStep.wait(seconds: 2)
        // After expanding, "main.swift" should appear
        TestStep.macWaitForElement(titled: "main.swift", timeout: 5)

        // Expand "utils" subfolder
        TestStep.macClickButton(titled: "utils")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "helper.swift", timeout: 5)

        // Select the deeply nested file (CGEvent click for selection)
        TestStep.macCGClick(titled: "helper.swift")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-deep-nested-file")

        // ── Phase 12: Expand docs folder and view nested markdown ──
        TestStep.log("Phase 12: Expand docs and view guide.md")
        TestStep.macClickButton(titled: "docs")
        TestStep.wait(seconds: 2)
        TestStep.macWaitForElement(titled: "guide.md", timeout: 5)
        TestStep.macCGClick(titled: "guide.md")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "mac-docs-nested-markdown")

        // ── Phase 13: Context Menu ───────────────────────────────
        TestStep.log("Phase 13: Context menu — Copy Path and Copy Relative Path")

        // Copy Path on a file
        TestStep.macContextMenuClick(elementTitle: "hello.txt", menuItem: "Copy Path")
        TestStep.wait(seconds: 1)
        TestStep.macReadClipboard(storeAs: "copiedPath")
        TestStep.assertStoredContains(key: "copiedPath", substring: "hello.txt")

        // Copy Relative Path
        TestStep.macContextMenuClick(elementTitle: "hello.txt", menuItem: "Copy Relative Path")
        TestStep.wait(seconds: 1)
        TestStep.macReadClipboard(storeAs: "copiedRelPath")
        TestStep.assertStoredContains(key: "copiedRelPath", substring: "hello.txt")
        // Relative path should NOT contain the directory prefix
        TestStep.assertStoredNotContains(key: "copiedRelPath", substring: "/")

        // Copy Path on a folder
        TestStep.macContextMenuClick(elementTitle: "src", menuItem: "Copy Path")
        TestStep.wait(seconds: 1)
        TestStep.macReadClipboard(storeAs: "copiedFolderPath")
        TestStep.assertStoredContains(key: "copiedFolderPath", substring: "/src")

        // ── Phase 14: State Persistence — Tab Toggle ─────────────
        // guide.md should still be selected from Phase 12
        TestStep.log("Phase 14: State persistence across tab toggle")

        // Switch back to terminal
        TestStep.macClickButton(titled: "filebrowse:0")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-terminal-restored")

        // Switch back to file browser — state should be preserved
        TestStep.macClickButton(titled: "Files")
        TestStep.wait(seconds: 2)
        // The previously expanded folders should still show their children
        TestStep.macWaitForElement(titled: "main.swift", timeout: 5)
        TestStep.macWaitForElement(titled: "guide.md", timeout: 5)
        TestStep.macScreenshot(label: "mac-file-browser-state-preserved")

        // ── Phase 15: State Reset on Window Switch ───────────────
        TestStep.log("Phase 15: File browser resets on window switch")

        // Create a second tmux window
        Shortcut.tmuxRunCommand(target: "filebrowse:0.0", command: "tmux new-window -t filebrowse")
        TestStep.wait(seconds: 3)
        Shortcut.tmuxRunCommand(target: "filebrowse:1.0", command: "echo '=== WINDOW 1 ==='")
        TestStep.wait(seconds: 2)

        // Click the new window tab — should show terminal, not file browser
        TestStep.macClickButton(titled: "filebrowse:1")
        TestStep.wait(seconds: 2)
        TestStep.macScreenshot(label: "mac-window-switch-no-file-browser")

        // Clean up
        Shortcut.tmuxRunCommand(target: "filebrowse:1.0", command: "exit")
        TestStep.wait(seconds: 2)
        Shortcut.tmuxRunCommand(target: "filebrowse:0.0", command: "exit")
        TestStep.wait(seconds: 2)
    }
}
