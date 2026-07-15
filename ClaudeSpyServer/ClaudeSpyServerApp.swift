import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import ClaudeSpyServerFeature
import Dependencies
import SwiftUI

@main
struct TmuxPaneMirrorApp: App {
    @State private var coordinator: AppCoordinator
    @State private var showingTmuxInstallGuide: Bool
    @State private var showingLaunchAtLoginPrompt = false
    @State private var updaterController: UpdaterController
    @NSApplicationDelegateAdaptor private var shutdownDelegate: AppShutdownDelegate
    @Environment(\.openSettings) private var openSettings

    init() {
        let isE2E = CommandLine.arguments.contains("--e2e-test")
        _updaterController = State(initialValue: UpdaterController(startUpdater: !isE2E))

        // Check if tmux is available at any common path (skip check in E2E tests)
        @Dependency(TmuxBinaryLocator.self) var tmuxLocator
        let tmuxFound = isE2E || tmuxLocator.find() != nil
        _showingTmuxInstallGuide = State(initialValue: !tmuxFound)

        // Bootstrap logging FIRST, before any Logger instances are created
        // Log level is determined by LOG_LEVEL env var (default: warning)
        LoggingConfiguration.bootstrap()

        // E2E test support: override reported app version and minimum partner version.
        // Applied before the E2E branch so scenarios hitting either path see the override.
        if let idx = CommandLine.arguments.firstIndex(of: "--app-version"),
           idx + 1 < CommandLine.arguments.count
        {
            VersionCompatibility.appVersionOverride = CommandLine.arguments[idx + 1]
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--min-required-partner-version"),
           idx + 1 < CommandLine.arguments.count
        {
            VersionCompatibility.minRequiredPartnerVersionOverride = CommandLine.arguments[idx + 1]
        }

        // E2E test support: use in-memory storage to avoid polluting real UserDefaults/Keychain
        if CommandLine.arguments.contains("--e2e-test") {
            let prefs = PreferencesService.inMemory()

            // Suppress first-launch dialogs (launch-at-login prompt)
            prefs.setBool(true, AppSettings.Keys.hasAskedAboutLaunchAtLogin.rawValue)

            // E2E tests expect manual resize by default; disable auto-resize so scenarios
            // that test it can toggle it explicitly.
            prefs.setBool(false, AppSettings.Keys.alwaysAutoResize.rawValue)

            // E2E test support: override server URL via launch argument
            if let idx = CommandLine.arguments.firstIndex(of: "--server-url"),
               idx + 1 < CommandLine.arguments.count
            {
                prefs.setString(CommandLine.arguments[idx + 1], AppSettings.Keys.externalServerURL.rawValue)
            }

            // E2E test support: override tmux socket for isolation
            if let idx = CommandLine.arguments.firstIndex(of: "--tmux-socket"),
               idx + 1 < CommandLine.arguments.count
            {
                prefs.setString(CommandLine.arguments[idx + 1], AppSettings.Keys.tmuxSocket.rawValue)
            }

            // (The legacy hook HTTP server + `--hook-port-file` are gone; the
            // plugin ingress Unix socket — set up in AppCoordinator and isolated
            // per scenario via `--gallager-state-root` — replaces them.)

            // E2E test support: override notification log path for verification
            let notificationLogPath: String?
            if let idx = CommandLine.arguments.firstIndex(of: "--notification-log"),
               idx + 1 < CommandLine.arguments.count
            {
                notificationLogPath = CommandLine.arguments[idx + 1]
            } else {
                notificationLogPath = nil
            }

            // E2E test support: override push notification log path for verification
            let pushLogPath: String?
            if let idx = CommandLine.arguments.firstIndex(of: "--push-log"),
               idx + 1 < CommandLine.arguments.count
            {
                pushLogPath = CommandLine.arguments[idx + 1]
            } else {
                pushLogPath = nil
            }

            // E2E test support: file-backed clipboard for instance isolation
            let clipboardFilePath: String?
            if let idx = CommandLine.arguments.firstIndex(of: "--clipboard-file"),
               idx + 1 < CommandLine.arguments.count
            {
                clipboardFilePath = CommandLine.arguments[idx + 1]
            } else {
                clipboardFilePath = nil
            }

            // E2E test support: sentinel file that toggles the Git tab's mock
            // between clean and dirty (issue #573), driven by the
            // `setGitMockChanges(_:)` step.
            let gitChangesFilePath: String?
            if let idx = CommandLine.arguments.firstIndex(of: "--git-changes-file"),
               idx + 1 < CommandLine.arguments.count
            {
                gitChangesFilePath = CommandLine.arguments[idx + 1]
            } else {
                gitChangesFilePath = nil
            }

            // E2E test support: register a fake editor backed by a Python script
            // so scenarios can verify "Open in Editor" forwards the file path
            // without launching real editor apps on the host.
            let fakeEditorScript: String?
            if let idx = CommandLine.arguments.firstIndex(of: "--fake-editor-script"),
               idx + 1 < CommandLine.arguments.count
            {
                fakeEditorScript = CommandLine.arguments[idx + 1]
            } else {
                fakeEditorScript = nil
            }
            // E2E test support: where the fake editor writes the paths it received.
            let fakeEditorLog: String?
            if let idx = CommandLine.arguments.firstIndex(of: "--fake-editor-log"),
               idx + 1 < CommandLine.arguments.count
            {
                fakeEditorLog = CommandLine.arguments[idx + 1]
            } else {
                fakeEditorLog = nil
            }

            // E2E test support: redirect default-browser opens to a log file
            // so scenarios can verify `.alwaysInDefaultBrowser` clicks without
            // actually launching the system browser on every run.
            let defaultBrowserLogPath: String?
            if let idx = CommandLine.arguments.firstIndex(of: "--default-browser-log"),
               idx + 1 < CommandLine.arguments.count
            {
                defaultBrowserLogPath = CommandLine.arguments[idx + 1]
            } else {
                defaultBrowserLogPath = nil
            }

            // E2E test support: redirect browser downloads away from the real
            // ~/Downloads — writing there triggers a TCC consent prompt the
            // unattended test app can never answer, wedging the download.
            let downloadsDirPath: String?
            if let idx = CommandLine.arguments.firstIndex(of: "--downloads-dir"),
               idx + 1 < CommandLine.arguments.count
            {
                downloadsDirPath = CommandLine.arguments[idx + 1]
            } else {
                downloadsDirPath = nil
            }

            // E2E test support: pin the advertised device name. The system
            // `ComputerName` varies per machine (e.g. "Managed's Virtual Machine"
            // on a CI box vs "MacMini"), and the iOS/Mac viewer renders it in its
            // Sessions header, unpair dialog, and version-mismatch text — making
            // screenshot baselines non-portable. Overriding keeps it deterministic.
            let deviceNameOverride: String?
            if let idx = CommandLine.arguments.firstIndex(of: "--e2e-device-name"),
               idx + 1 < CommandLine.arguments.count
            {
                deviceNameOverride = CommandLine.arguments[idx + 1]
            } else {
                deviceNameOverride = nil
            }

            prepareDependencies {
                $0[PreferencesService.self] = prefs
                $0[SecretsService.self] = .inMemory()
                // Project lists now come from the plugin cores via
                // `PluginHost.setProjects` (the per-agent scanners moved into the
                // cores). E2E project-list determinism is handled by the plugin
                // runtime / `--gallager-state-root` fixtures (Step 10), not by
                // injecting scanners here.
                // Build fake filesystem tree for the file browser.
                // Binary sample files (image, PDF, video) come from the E2E bundle
                // via --sample-files-dir passed by the test orchestrator.
                let sampleDir: String? = {
                    guard let idx = CommandLine.arguments.firstIndex(of: "--sample-files-dir"),
                          idx + 1 < CommandLine.arguments.count
                    else { return nil }
                    return CommandLine.arguments[idx + 1]
                }()
                var fakeTree: [String: FakeEntry] = [
                    "README.md": .file(.markdown("""
                    # Fake Project

                    This is a **test project** for the file browser.

                    ## Features
                    - Folder recursion
                    - Multiple file types
                    - Markdown rendering
                    """)),
                    "hello.txt": .file(.text("Hello, world!\nThis is a plain text file.\n")),
                    "page.html": .file(.html("""
                    <!DOCTYPE html>
                    <html>
                    <head><title>Test Page</title></head>
                    <body>
                        <h1>Hello from HTML</h1>
                        <p>This is a test HTML page rendered in the file browser.</p>
                    </body>
                    </html>
                    """)),
                    "binary.dat": .file(.unsupported()),
                    "src": .folder([
                        "main.swift": .file(.text("""
                        import Foundation

                        @main
                        struct App {
                            static func main() {
                                print("Hello, world!")
                            }
                        }
                        """)),
                        "utils": .folder([
                            "helper.swift": .file(.text("""
                            /// A helper function for testing folder recursion.
                            func greet(_ name: String) -> String {
                                "Hello, \\(name)!"
                            }
                            """)),
                        ]),
                    ]),
                    "docs": .folder([
                        "guide.md": .file(.markdown("""
                        # User Guide

                        ## Getting Started
                        1. Open the app
                        2. Select a session
                        3. Browse files
                        """)),
                    ]),
                ]
                if let sampleDir {
                    fakeTree["photo.png"] = .file(.image(bundlePath: sampleDir + "/test_image.png"))
                    fakeTree["document.pdf"] = .file(.pdf(bundlePath: sampleDir + "/test_pdf.pdf"))
                    fakeTree["clip.mp4"] = .file(.video(bundlePath: sampleDir + "/test_video.mp4"))
                }
                // Dot entries: .claude should show, .DS_Store should be filtered
                fakeTree[".claude"] = .folder([
                    "settings.json": .file(.text("{ \"model\": \"opus\" }\n")),
                ])
                fakeTree[".DS_Store"] = .file(.unsupported())
                // Long markdown file used by the scroll-preservation phase to
                // verify that the user's scroll position is restored after
                // tab/session switches. Numbered lines make it visually
                // obvious in the screenshot which part of the file is on
                // screen at any moment.
                fakeTree["long.md"] = .file(.markdown(longMarkdownContent))
                // Long plain-text file used by the scroll-preservation phase
                // to verify that the text viewer (a separate SwiftUI
                // implementation from the markdown viewer) also restores the
                // saved offset on tab/session switches.
                fakeTree["long.txt"] = .file(.text(longPlainTextContent))
                // Replace the short page.html with a long HTML fixture so the
                // WebView scroll-preservation phase has something tall enough
                // to scroll. Reuses the existing tree row to avoid bumping
                // Phase 22's row count past the viewport.
                fakeTree["page.html"] = .file(.html(longHTMLContent))
                // Pending file: hangs on first load, succeeds on second.
                // Dynamic entries appear in the tree after the pending file loads.
                fakeTree["loading.txt"] = .file(.pendingText("This file loaded successfully!\n"))
                // Ephemeral file: disappears from the tree after its content is read,
                // so scenarios can exercise "file deleted while tab is open" behaviour.
                fakeTree["ephemeral.txt"] = .file(
                    .ephemeralText("This file is about to disappear.\n")
                )
                // Thirty numbered rows so that expanding `generated` makes the
                // file tree taller than the viewport — the tree-scroll
                // preservation phase (issue #437) needs enough rows to scroll.
                // The folder stays collapsed in every other phase, so earlier
                // screenshots are unaffected. Names and contents deliberately
                // avoid the strings other phases search for ("hello", "helper",
                // "swift", "## BOTTOM").
                var generatedChildren: [String: FakeEntry] = [
                    "output.txt": .file(.text("Generated content.\n")),
                ]
                for index in 1 ... 30 {
                    let name = String(format: "tree-scroll-%02d.txt", index)
                    generatedChildren[name] = .file(.text("Generated row \(index).\n"))
                }
                let dynamicEntries: [String: FakeEntry] = [
                    "generated": .folder(generatedChildren),
                ]
                $0[FileSystemLoadingService.self] = .inMemory(tree: fakeTree, dynamicEntries: dynamicEntries)
                $0[FileTextSearchService.self] = .inMemory(tree: fakeTree, dynamicEntries: dynamicEntries)
                // Git tab (issue #258): in-memory provider that starts clean and
                // flips to the fixture changes when a scenario sets the sentinel
                // file (issue #573), so the eagerly-loaded badge only appears
                // where a scenario asks for it. Falls back to the always-dirty
                // mock if no sentinel path was provided.
                if let gitChangesFilePath {
                    try? FileManager.default.removeItem(atPath: gitChangesFilePath)
                    $0[GitWorkbenchProviderClient.self] = .e2e(changesFilePath: gitChangesFilePath)
                } else {
                    $0[GitWorkbenchProviderClient.self] = .mock
                }
                $0[LoginItemService.self] = LoginItemService(
                    isEnabled: { false },
                    setEnabled: { _ in }
                )
                if let notificationLogPath {
                    // Clean up any previous log from earlier runs
                    try? FileManager.default.removeItem(atPath: notificationLogPath)
                    $0[TerminalNotificationService.self] = .e2eTest(logPath: notificationLogPath)
                }
                if let pushLogPath {
                    try? FileManager.default.removeItem(atPath: pushLogPath)
                    $0[PushNotificationLogService.self] = .e2eTest(logPath: pushLogPath)
                }
                if let clipboardFilePath {
                    // Clean up any previous clipboard file
                    try? FileManager.default.removeItem(atPath: clipboardFilePath)
                    $0[ClipboardClient.self] = .fileBacked(path: clipboardFilePath)
                }
                if let fakeEditorScript {
                    if let fakeEditorLog {
                        try? FileManager.default.removeItem(atPath: fakeEditorLog)
                    }
                    $0[EditorClient.self] = .fakeScript(
                        scriptPath: fakeEditorScript,
                        logPath: fakeEditorLog
                    )
                }
                if let defaultBrowserLogPath {
                    try? FileManager.default.removeItem(atPath: defaultBrowserLogPath)
                    $0[URLOpener.self] = .logged(path: defaultBrowserLogPath)
                }
                if let downloadsDirPath {
                    // Start each run with an empty downloads directory so
                    // collision-naming assertions are deterministic. Only
                    // temp-directory paths (where the E2E orchestrator puts
                    // them) are wiped — recursively deleting an arbitrary
                    // caller-supplied directory would destroy real files if
                    // someone hand-launched with `--downloads-dir ~/Downloads`.
                    if BrowserDownloadsLocation.isSafeToWipe(downloadsDirPath) {
                        try? FileManager.default.removeItem(atPath: downloadsDirPath)
                    }
                    $0[BrowserDownloadsLocation.self] = .fixed(path: downloadsDirPath)
                }
                if let deviceNameOverride {
                    $0[DeviceNameClient.self] = DeviceNameClient(current: { deviceNameOverride })
                }
            }

            // Force regular activation policy so the app has a menu bar
            DockIconConfig.isE2ETestMode = true
            NSApplication.shared.setActivationPolicy(.regular)

            // Start accessibility server for E2E UI inspection
            #if DEBUG
                TestAccessibilityServer.startIfNeeded()
            #endif
        }

        let coord = AppCoordinator()
        _coordinator = State(initialValue: coord)
        // Wire cleanup before any delegate calls can fire. applicationShouldTerminate
        // returns .terminateNow when onShouldTerminate is nil; setting it here (in
        // @MainActor init) ensures it is never nil when the delegate is invoked —
        // SwiftUI can call NSApp.terminate during scene setup on .regular-policy apps.
        shutdownDelegate.onShouldTerminate = {
            await coord.shutdown()
        }
    }

    var body: some Scene {
        // Main panes window - can be shown via menu bar "Show Panes Window"
        Window("Panes", id: "panes") {
            ContentView()
                .environment(coordinator.settings)
                .environment(coordinator.tmuxService)
                .environment(coordinator.windowManager)
                .environment(coordinator.windowManager.paneStreamManager)
                .environment(coordinator.getOrCreatePairingManager())
                .environment(coordinator)
                .environment(coordinator.editorSessionManager)
                .environment(coordinator.remoteEditorContentStore)
                .environment(coordinator.markdownOpenSuggestionStore)
                .environment(coordinator.licenseManager)
                .environment(\.e2eeService, coordinator.e2eeService)
                .onAppear {
                    if coordinator.settings.openPanesWindowOnLaunch || showingTmuxInstallGuide {
                        NSApp.setActivationPolicy(.regular)
                        MenuBarExtraView.bringAppToFront()
                    }
                }
                .sheet(isPresented: $showingTmuxInstallGuide, onDismiss: {
                    // After tmux is found, proceed with launch-at-login prompt
                    Task { await checkForLaunchAtLoginPrompt() }
                }) {
                    TmuxInstallationGuideView { foundPath in
                        coordinator.settings.tmuxPath = foundPath
                    }
                }
                .task {
                    // Only run first-launch dialogs if tmux is already installed
                    guard !showingTmuxInstallGuide else { return }
                    await checkForLaunchAtLoginPrompt()
                }
                .sheet(isPresented: $showingLaunchAtLoginPrompt) {
                    LaunchAtLoginPromptView()
                        .environment(coordinator.settings)
                }
        }
        .defaultLaunchBehavior(
            (coordinator.settings.openPanesWindowOnLaunch || showingTmuxInstallGuide) ? .presented : .suppressed
        )
        .onChange(of: totalPendingSessionCount, initial: true) { _, newValue in
            // Routed through DockIconService (not NSApp.dockTile directly) so
            // the badge survives .accessory → .regular activation-policy
            // transitions, which destroy the Dock's tile state (issue #217).
            @Dependency(DockIconService.self) var dockIconService
            dockIconService.setBadgeCount(newValue)
        }
        .commands {
            // App menu - custom About window
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }

            // App menu - Check for Updates + Install CLI
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterController: updaterController)
                InstallCLIMenuItem()
            }

            // File menu - New Session (⌘N) opens the Local section's popover
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    NotificationCenter.default.post(name: .newLocalSession, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(after: .newItem) {
                CloseTabMenuItem()
            }

            CommandGroup(after: .textEditing) {
                Button("Find in Files") {
                    NotificationCenter.default.post(name: .openContentSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            // Window menu - tab navigation shortcuts
            CommandGroup(before: .windowList) {
                Button("Previous Tab") {
                    NotificationCenter.default.post(name: .selectPreviousTab, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button("Next Tab") {
                    NotificationCenter.default.post(name: .selectNextTab, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Session") {
                    NotificationCenter.default.post(name: .selectPreviousSession, object: nil)
                }
                .keyboardShortcut("`", modifiers: [.command, .shift])

                Button("Next Session") {
                    NotificationCenter.default.post(name: .selectNextSession, object: nil)
                }
                .keyboardShortcut("`", modifiers: .command)

                Divider()
            }

            // Edit menu - Copy as Rich Text / Copy with Control Sequences
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Copy as Rich Text") {
                    NSApp.sendAction(#selector(TerminalActions.copyAsRichText), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button("Copy with Control Sequences") {
                    NSApp.sendAction(#selector(TerminalActions.copyWithControlSequences), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .control])
            }

            // View menu - replace default toolbar items (removes Enter Full Screen)
            CommandGroup(replacing: .toolbar) {
                Button("Increase Font Size") {
                    coordinator.settings.increaseFontSize()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Decrease Font Size") {
                    coordinator.settings.decreaseFontSize()
                }
                .keyboardShortcut("-", modifiers: .command)

                Divider()

                Button("Refresh Pane List") {
                    NotificationCenter.default.post(name: .refreshPaneList, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Toggle("Show Status Bar", isOn: Bindable(coordinator.settings).showStatusBar)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            // Help menu - CLI API Reference
            CommandGroup(replacing: .help) {
                APIReferenceMenuItem()
            }
        }

        // About window - custom About panel with Gallager explanation
        Window("About Gallager", id: "about") {
            AboutWindowView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // CLI API Reference window
        Window("CLI API Reference", id: "api-reference") {
            APIReferenceView()
        }
        .defaultSize(width: 700, height: 600)
        .defaultLaunchBehavior(.suppressed)

        // Settings window
        Settings {
            SettingsView()
                .environment(coordinator.settings)
                .environment(updaterController)
                .environment(coordinator.getOrCreatePairingManager())
                .environment(coordinator)
                .environment(coordinator.licenseManager)
                .environment(\.e2eeService, coordinator.e2eeService)
        }

        // Menu bar extra - always visible, main entry point to the app
        MenuBarExtra {
            MenuBarExtraView()
                .environment(coordinator.windowManager)
                .environment(coordinator.settings)
                .environment(coordinator)
        } label: {
            MenuBarLabel(pendingCount: totalPendingSessionCount)
                .task {
                    coordinator.settings.applyAppearance()
                    // Capture the Settings-opening action once at launch so a
                    // non-view context (the license trial-expiry notification
                    // tap handler) can open Settings later. `MenuBarLabel` is
                    // the menu bar icon itself, so — unlike the Panes window's
                    // content — it's guaranteed to run even if no window is
                    // ever shown (issue #392, Task 14).
                    coordinator.openSettingsAction = { openSettings() }
                }
                .task(id: showingTmuxInstallGuide) {
                    guard !showingTmuxInstallGuide else { return }
                    await coordinator.setupAllServices()
                }
        }
    }

    /// Total number of sessions needing attention across local and remote sources
    private var totalPendingSessionCount: Int {
        let localCount = coordinator.windowManager.pendingSessionCount
        let remoteCount = coordinator.remoteSessionStore?.paneStates.values
            .filter { $0.agentSession?.needsAttention == true }.count ?? 0
        return localCount + remoteCount
    }

    /// Checks if we should show the launch at login prompt.
    /// Called after tmux setup is complete.
    private func checkForLaunchAtLoginPrompt() async {
        // Only show if user hasn't been asked yet
        guard !coordinator.settings.hasAskedAboutLaunchAtLogin else { return }

        // Small delay to avoid sheet animation conflicts
        try? await Task.sleep(for: .milliseconds(300))
        showingLaunchAtLoginPrompt = true
    }
}

/// Long markdown content for the file browser's scroll-preservation E2E phase.
/// Numbered lines and a "BOTTOM" marker make it easy to see in screenshots
/// which part of the file is on screen.
private let longMarkdownContent: String = {
    var lines: [String] = ["# Scroll Preservation Test", ""]
    lines.append("This file is intentionally tall so the file viewer must")
    lines.append("scroll. The numbered lines below make the visible region")
    lines.append("recognisable in screenshot baselines.")
    lines.append("")
    for index in 1 ... 120 {
        lines.append("Line \(index): The quick brown fox jumps over the lazy dog.")
    }
    lines.append("")
    lines.append("## BOTTOM MARKER")
    lines.append("")
    lines.append("If you can read this line, you are at the bottom of the file.")
    return lines.joined(separator: "\n")
}()

/// Long HTML fixture for the WebView scroll-preservation E2E phase. The
/// `ScrollableWebView` wrapper is a separate code path from the markdown and
/// plain-text viewers, so it needs its own scroll-tall page. The closing
/// `<h1>HTML BOTTOM MARKER</h1>` is the assertion target — it only renders on
/// screen when the WebView has been scrolled all the way down.
private let longHTMLContent: String = {
    var lines: [String] = [
        "<!DOCTYPE html>",
        "<html>",
        "<head>",
        "  <meta charset=\"utf-8\">",
        "  <title>Scroll Preservation Test (HTML)</title>",
        "  <style>",
        "    body { font-family: -apple-system, sans-serif; padding: 20px; }",
        "    p { margin: 12px 0; }",
        "  </style>",
        "</head>",
        "<body>",
        "  <h1>Scroll Preservation Test (HTML)</h1>",
        "  <p>This page is intentionally tall so the WebView must scroll.</p>",
    ]
    for index in 1 ... 120 {
        lines.append("  <p>Line \(index): The quick brown fox jumps over the lazy dog.</p>")
    }
    lines.append("  <h1>HTML BOTTOM MARKER</h1>")
    lines.append("  <p>If you can read this line, you are at the bottom of the page.</p>")
    lines.append("</body>")
    lines.append("</html>")
    return lines.joined(separator: "\n")
}()

/// Plain-text counterpart to `longMarkdownContent`. The text viewer uses a
/// different SwiftUI implementation from the markdown viewer, so the
/// scroll-preservation E2E phase exercises both paths against their own
/// fixtures. The marker string is distinct so screenshot baselines and AX
/// queries don't conflict if both files happen to be open simultaneously.
private let longPlainTextContent: String = {
    var lines: [String] = ["=== Scroll Preservation Test (Plain Text) ===", ""]
    lines.append("This file is intentionally tall so the file viewer must")
    lines.append("scroll. The numbered lines below make the visible region")
    lines.append("recognisable in screenshot baselines.")
    lines.append("")
    for index in 1 ... 120 {
        lines.append("Line \(index): The quick brown fox jumps over the lazy dog.")
    }
    lines.append("")
    lines.append("=== TEXT BOTTOM MARKER ===")
    lines.append("")
    lines.append("If you can read this line, you are at the bottom of the file.")
    return lines.joined(separator: "\n")
}()

/// Cmd-W menu item.
///
/// When the panes scene is focused, `MainView` publishes a
/// `closeCurrentTabAction` focused value that closes the active tab (or
/// window when no tab is open). Other scenes (Settings, About, CLI API
/// Reference) don't publish that value, so the button falls back to sending
/// `performClose:` to the key window — restoring the standard macOS Cmd-W
/// behaviour on those windows.
private struct CloseTabMenuItem: View {
    @FocusedValue(\.closeCurrentTabAction) private var closeCurrentTabAction

    var body: some View {
        Button("Close Tab") {
            if let closeCurrentTabAction {
                closeCurrentTabAction()
            } else {
                NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
            }
        }
        .keyboardShortcut("w", modifiers: .command)
    }
}

/// Menu item that opens the custom About window.
///
/// Extracted to a separate view so it has access to `@Environment(\.openWindow)`,
/// which is not available directly in `CommandGroup` closures.
private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Gallager") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "about")
            NSApp.activate()
        }
    }
}

/// Menu item that opens the CLI API Reference window.
private struct APIReferenceMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("CLI API Reference") {
            openWindow(id: "api-reference")
        }
    }
}

/// Menu item to install/uninstall the `gallager` CLI symlink.
///
/// When installing on a zsh user's machine, offers to also install the zsh
/// completion script alongside the CLI so tab-completion works out of the box.
private struct InstallCLIMenuItem: View {
    @State private var installed = CLIInstaller.isInstalled

    var body: some View {
        Button(installed ? "Uninstall Command Line Tool..." : "Install Command Line Tool...") {
            if installed {
                if CLIInstaller.uninstall() {
                    installed = false
                }
            } else {
                let installCompletion = CLIInstaller.userShellIsZsh && askAboutZshCompletion()
                let result = CLIInstaller.install(installZshCompletion: installCompletion)
                if result.cliInstalled {
                    installed = true
                }
                if result.completionRequested, !result.completionInstalled {
                    showCompletionFailureAlert(reason: result.completionFailureReason)
                }
            }
        }
    }

    /// Shows a confirmation alert asking whether to install the zsh completion script.
    private func askAboutZshCompletion() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install zsh tab completion?"
        alert.informativeText = """
        Your login shell is zsh. Also install tab completion for \
        the gallager command? It will be written to \
        /usr/local/share/zsh/site-functions/_gallager in the same admin prompt.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Completion")
        alert.addButton(withTitle: "Skip")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Notifies the user that the CLI installed but completion didn't.
    private func showCompletionFailureAlert(reason: String?) {
        let alert = NSAlert()
        alert.messageText = "Zsh completion was not installed"
        alert.informativeText = reason.map { "The CLI is installed, but completion failed: \($0)." }
            ?? "The CLI is installed, but completion could not be generated."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
