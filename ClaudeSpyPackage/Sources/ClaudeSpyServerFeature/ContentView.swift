import SwiftUI

/// The root content view that sets up the navigation
public struct ContentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TmuxService.self) private var tmuxService

    public init() {}

    public var body: some View {
        NavigationStack {
            MainView()
        }
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
}
