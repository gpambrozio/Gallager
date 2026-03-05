import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyServerFeature
import Dependencies
import SwiftUI

@main
struct TmuxPaneMirrorApp: App {
    @State private var coordinator: AppCoordinator
    @State private var showingPluginSetup = false
    @State private var showingLaunchAtLoginPrompt = false
    @State private var updaterController: UpdaterController

    init() {
        let isE2E = CommandLine.arguments.contains("--e2e-test")
        _updaterController = State(initialValue: UpdaterController(startUpdater: !isE2E))

        // Bootstrap logging FIRST, before any Logger instances are created
        // Log level is determined by LOG_LEVEL env var (default: warning)
        LoggingConfiguration.bootstrap()

        // E2E test support: use in-memory storage to avoid polluting real UserDefaults/Keychain
        if CommandLine.arguments.contains("--e2e-test") {
            let prefs = PreferencesService.inMemory()

            // Suppress first-launch dialogs (plugin setup, launch-at-login prompt)
            prefs.setBool(true, AppSettings.Keys.hasCompletedPluginSetup.rawValue)
            prefs.setBool(true, AppSettings.Keys.hasAskedAboutLaunchAtLogin.rawValue)

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

            prepareDependencies {
                $0[PreferencesService.self] = prefs
                $0[SecretsService.self] = .inMemory()
                $0[ClaudeProjectScanner.self] = .inMemory()
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
                .environment(\.e2eeService, coordinator.e2eeService)
                .task {
                    // Check if we should show the plugin setup on first launch
                    if !coordinator.settings.hasCompletedPluginSetup {
                        await coordinator.pluginService.checkInstallation()

                        // Show setup only if plugin is not installed
                        if case .notInstalled = coordinator.pluginService.state {
                            showingPluginSetup = true
                        } else if case .installed = coordinator.pluginService.state {
                            // Plugin is installed, mark setup as complete
                            coordinator.settings.hasCompletedPluginSetup = true
                            // Check if we should show launch at login prompt
                            checkForLaunchAtLoginPrompt()
                        }
                    } else {
                        // Plugin setup already done, check for launch at login prompt
                        checkForLaunchAtLoginPrompt()
                    }
                }
                .sheet(isPresented: $showingPluginSetup, onDismiss: {
                    // After plugin setup is dismissed, check for launch at login prompt
                    checkForLaunchAtLoginPrompt()
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
        .defaultLaunchBehavior(.suppressed)
        .commands {
            // App menu - custom About window
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }

            // App menu - Check for Updates
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterController: updaterController)
            }

            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Mirror") {
                    // Open pane picker or bring main window to front
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Close All Mirrors") {
                    coordinator.windowManager.closeAll()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }

            // Edit menu - Copy as Rich Text
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Copy as Rich Text") {
                    NSApp.sendAction(#selector(TerminalActions.copyAsRichText), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
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

            // Window menu additions
            CommandGroup(after: .windowList) {
                Divider()

                ForEach(coordinator.windowManager.mirroredTargets, id: \.self) { target in
                    Button(target) {
                        coordinator.windowManager.bringToFront(target: target)
                    }
                }
            }
        }

        // About window - custom About panel with Gallager explanation
        Window("About Gallager", id: "about") {
            AboutWindowView()
        }
        .windowResizability(.contentSize)
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
                .task {
                    await coordinator.setupAllServices()
                }
        }
    }

    /// Total number of sessions needing attention across local and remote sources
    private var totalPendingSessionCount: Int {
        let localCount = coordinator.windowManager.pendingSessionCount
        let remoteCount = coordinator.remoteSessionStore?.sessions.values
            .filter(\.needsAttention).count ?? 0
        return localCount + remoteCount
    }

    /// Checks if we should show the launch at login prompt.
    /// Called after plugin setup is complete or skipped.
    private func checkForLaunchAtLoginPrompt() {
        // Only show if user hasn't been asked yet
        guard !coordinator.settings.hasAskedAboutLaunchAtLogin else { return }

        // Small delay to avoid sheet animation conflicts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            showingLaunchAtLoginPrompt = true
        }
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
