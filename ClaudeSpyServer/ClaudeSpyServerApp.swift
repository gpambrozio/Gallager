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
    @State private var updaterController = UpdaterController()

    init() {
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

            prepareDependencies {
                $0[PreferencesService.self] = prefs
                $0[SecretsService.self] = .inMemory()
            }

            // Force regular activation policy so the app has a menu bar
            DockIconManager.isE2ETestMode = true
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
                .environment(\.claudeProjectScanner, coordinator.projectScanner)
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

            // View menu
            CommandMenu("View") {
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
        } label: {
            MenuBarLabel(pendingCount: coordinator.windowManager.pendingSessionCount)
                .task {
                    await coordinator.setupAllServices()
                }
        }
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
