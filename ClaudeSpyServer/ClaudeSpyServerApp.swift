import ClaudeSpyServerFeature
import SwiftUI

@main
struct TmuxPaneMirrorApp: App {
    @State private var settings = AppSettings()
    @State private var tmuxService: TmuxService
    @State private var windowManager: MirrorWindowManager?
    @State private var hookServer = HookServerService()

    init() {
        let initialSettings = AppSettings()
        self._settings = State(initialValue: initialSettings)

        let service = TmuxService(
            tmuxPath: initialSettings.tmuxPath,
            socketPath: initialSettings.tmuxSocket.isEmpty ? nil : initialSettings.tmuxSocket
        )
        self._tmuxService = State(initialValue: service)
    }

    var body: some Scene {
        // Main window
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(tmuxService)
                .environment(windowManager ?? createWindowManager())
                .environment(hookServer)
                .task {
                    await hookServer.startServer()
                }
        }
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Mirror") {
                    // Open pane picker or bring main window to front
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Close All Mirrors") {
                    windowManager?.closeAll()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }

            // View menu
            CommandMenu("View") {
                Button("Refresh Pane List") {
                    // Will be handled by main view's refresh
                    NotificationCenter.default.post(name: .refreshPaneList, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Toggle("Show Status Bar", isOn: Bindable(settings).showStatusBar)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            // Window menu additions
            CommandGroup(after: .windowList) {
                Divider()

                ForEach(windowManager?.mirroredTargets ?? [], id: \.self) { target in
                    Button(target) {
                        windowManager?.bringToFront(target: target)
                    }
                }
            }
        }

        // Settings window
        Settings {
            SettingsView()
                .environment(settings)
        }
    }

    private func createWindowManager() -> MirrorWindowManager {
        let manager = MirrorWindowManager(settings: settings, tmuxService: tmuxService)
        Task { @MainActor in
            windowManager = manager

            // Forward hook events to window manager for handling
            hookServer.onHookEvent = { [weak manager] event in
                await manager?.handleHookEvent(event)
            }
        }
        return manager
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let refreshPaneList = Notification.Name("refreshPaneList")
}
