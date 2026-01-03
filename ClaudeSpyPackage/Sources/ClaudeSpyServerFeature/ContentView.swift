import SwiftUI

/// The root content view that sets up the environment and main navigation
public struct ContentView: View {
    @State private var settings = AppSettings()
    @State private var tmuxService: TmuxService
    @State private var windowManager: MirrorWindowManager?

    public init() {
        let initialSettings = AppSettings()
        self._settings = State(initialValue: initialSettings)
        self._tmuxService = State(initialValue: TmuxService(
            tmuxPath: initialSettings.tmuxPath,
            socketPath: initialSettings.tmuxSocket.isEmpty ? nil : initialSettings.tmuxSocket
        ))
    }

    public var body: some View {
        NavigationStack {
            MainView()
        }
        .environment(settings)
        .environment(tmuxService)
        .environment(windowManager ?? createWindowManager())
        .onChange(of: settings.tmuxPath) { _, newValue in
            tmuxService.configure(
                tmuxPath: newValue,
                socketPath: settings.tmuxSocket.isEmpty ? nil : settings.tmuxSocket
            )
        }
        .onChange(of: settings.tmuxSocket) { _, newValue in
            tmuxService.configure(
                tmuxPath: settings.tmuxPath,
                socketPath: newValue.isEmpty ? nil : newValue
            )
        }
    }

    private func createWindowManager() -> MirrorWindowManager {
        let manager = MirrorWindowManager(settings: settings, tmuxService: tmuxService)
        Task { @MainActor in
            windowManager = manager
        }
        return manager
    }
}
