import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyServerFeature
import SwiftUI

@main
struct TmuxPaneMirrorApp: App {
    @State private var coordinator: AppCoordinator
    @State private var updaterController = UpdaterController()

    init() {
        // Bootstrap logging FIRST, before any Logger instances are created
        // Log level is determined by LOG_LEVEL env var (default: warning)
        LoggingConfiguration.bootstrap()

        // Now create coordinator (which creates loggers internally)
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
                .environment(coordinator.externalServerClient)
                .environment(\.e2eeService, coordinator.e2eeService)
        }
        .defaultLaunchBehavior(.presented) // TODO: Change back to .suppressed
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
                .environment(coordinator.externalServerClient)
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
}
