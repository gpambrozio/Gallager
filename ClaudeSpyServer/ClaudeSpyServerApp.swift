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
    @State private var pluginSetupCheckTrigger = 0
    @State private var showingPluginSetup = false
    @State private var showingLaunchAtLoginPrompt = false
    @State private var updaterController: UpdaterController

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

            // Suppress first-launch dialogs (plugin setup, launch-at-login prompt)
            prefs.setBool(true, AppSettings.Keys.hasCompletedPluginSetup.rawValue)
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

            // E2E test support: override hook server port file for isolation
            let hookPortFile: String?
            if let idx = CommandLine.arguments.firstIndex(of: "--hook-port-file"),
               idx + 1 < CommandLine.arguments.count
            {
                hookPortFile = CommandLine.arguments[idx + 1]
            } else {
                hookPortFile = nil
            }

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

            prepareDependencies {
                $0[PreferencesService.self] = prefs
                $0[SecretsService.self] = .inMemory()
                $0[ClaudeProjectScanner.self] = .inMemory()
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
                // Pending file: hangs on first load, succeeds on second.
                // Dynamic entries appear in the tree after the pending file loads.
                fakeTree["loading.txt"] = .file(.pendingText("This file loaded successfully!\n"))
                let dynamicEntries: [String: FakeEntry] = [
                    "generated": .folder([
                        "output.txt": .file(.text("Generated content.\n")),
                    ]),
                ]
                $0[FileSystemLoadingService.self] = .inMemory(tree: fakeTree, dynamicEntries: dynamicEntries)
                $0[LoginItemService.self] = LoginItemService(
                    isEnabled: { false },
                    setEnabled: { _ in }
                )
                if let hookPortFile {
                    $0[HookServerService.self] = .live(portFilePath: hookPortFile)
                }
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
            }

            // Force regular activation policy so the app has a menu bar
            DockIconConfig.isE2ETestMode = true
            NSApplication.shared.setActivationPolicy(.regular)

            // Start accessibility server for E2E UI inspection
            #if DEBUG
                TestAccessibilityServer.startIfNeeded()
            #endif
        }

        _coordinator = State(initialValue: AppCoordinator())
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
                .environment(coordinator.pluginService)
                .environment(coordinator.editorSessionManager)
                .environment(coordinator.remoteEditorContentStore)
                .environment(\.e2eeService, coordinator.e2eeService)
                .onAppear {
                    if coordinator.settings.openPanesWindowOnLaunch || showingTmuxInstallGuide {
                        NSApp.setActivationPolicy(.regular)
                        MenuBarExtraView.bringAppToFront()
                    }
                }
                .sheet(isPresented: $showingTmuxInstallGuide, onDismiss: {
                    // After tmux is found, proceed with the plugin setup chain
                    pluginSetupCheckTrigger += 1
                }) {
                    TmuxInstallationGuideView { foundPath in
                        coordinator.settings.tmuxPath = foundPath
                    }
                }
                .task {
                    // Only run first-launch dialogs if tmux is already installed
                    guard !showingTmuxInstallGuide else { return }
                    pluginSetupCheckTrigger += 1
                }
                .task(id: pluginSetupCheckTrigger) {
                    guard pluginSetupCheckTrigger > 0 else { return }
                    await checkForPluginSetup()
                }
                .sheet(isPresented: $showingPluginSetup, onDismiss: {
                    // After plugin setup is dismissed, check for launch at login prompt
                    Task { await checkForLaunchAtLoginPrompt() }
                }) {
                    PluginSetupView()
                        .environment(coordinator.settings)
                        .environment(coordinator.pluginService)
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
            NSApp.dockTile.badgeLabel = newValue > 0 ? "\(newValue)" : nil
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

            // File menu - replace default items with Close Tab
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(after: .newItem) {
                Button("Close Tab") {
                    NotificationCenter.default.post(name: .closeCurrentTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
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
                .environment(coordinator.pluginService)
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
            .filter { $0.claudeSession?.needsAttention == true }.count ?? 0
        return localCount + remoteCount
    }

    /// Checks if we should show the plugin setup on first launch.
    /// Driven by `pluginSetupCheckTrigger` via `.task(id:)`.
    private func checkForPluginSetup() async {
        if !coordinator.settings.hasCompletedPluginSetup {
            // If claude isn't installed, jump straight to the setup sheet so
            // the user can follow the install flow.
            if let path = await coordinator.pluginService.findClaude() {
                coordinator.settings.claudeCommandPath = path
                await coordinator.pluginService.checkInstallation()
            } else {
                showingPluginSetup = true
                return
            }

            if case .notInstalled = coordinator.pluginService.state {
                showingPluginSetup = true
            } else if case .installed = coordinator.pluginService.state {
                coordinator.settings.hasCompletedPluginSetup = true
                await checkForLaunchAtLoginPrompt()
            }
        } else {
            await checkForLaunchAtLoginPrompt()
        }
    }

    /// Checks if we should show the launch at login prompt.
    /// Called after plugin setup is complete or skipped.
    private func checkForLaunchAtLoginPrompt() async {
        // Only show if user hasn't been asked yet
        guard !coordinator.settings.hasAskedAboutLaunchAtLogin else { return }

        // Small delay to avoid sheet animation conflicts
        try? await Task.sleep(for: .milliseconds(300))
        showingLaunchAtLoginPrompt = true
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
