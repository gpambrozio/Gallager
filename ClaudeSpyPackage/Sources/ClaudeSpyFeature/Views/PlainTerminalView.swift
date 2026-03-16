#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftUI

    /// A wrapper view for displaying plain terminals (without Claude sessions).
    ///
    /// This view wraps `LiveTerminalView` but provides simpler handling since
    /// plain terminals don't have response states or event-driven interactions.
    struct PlainTerminalView: View {
        let paneId: String
        let relayClient: ViewerRelayClient
        let settings: IOSSettings

        @Environment(\.verticalSizeClass) private var verticalSizeClass

        /// Always nil for plain terminals - no response state
        @State private var responseState: ResponseState?

        /// Terminal title detected via OSC escape sequences
        @State private var terminalTitle: String?

        /// Whether the host is connected
        private var isConnected: Bool {
            relayClient.isHostConnected
        }

        /// Hide navigation bar on iPhone in landscape to maximize terminal space
        private var hideNavigationBar: Bool {
            UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact
        }

        var body: some View {
            LiveTerminalView(
                paneId: paneId,
                responseState: $responseState,
                terminalTitle: $terminalTitle,
                isConnected: isConnected,
                hideNavigationBar: hideNavigationBar,
                settings: settings,
                sendCommand: sendCommand
            )
            .environment(relayClient)
            .navigationTitle(terminalTitle ?? "Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(hideNavigationBar ? .hidden : .visible, for: .navigationBar)
        }

        /// Send a command to the host for this pane
        private func sendCommand(_ command: CommandType) async {
            await relayClient.send(command, paneId: paneId)
        }
    }

    #Preview {
        NavigationStack {
            PlainTerminalView(
                paneId: "%1",
                relayClient: ViewerRelayClient(),
                settings: IOSSettings()
            )
        }
        .environment(ViewerRelayClient())
    }
#endif
