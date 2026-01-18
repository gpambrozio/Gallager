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
        let relayClient: RelayClient
        let settings: IOSSettings

        /// Always nil for plain terminals - no response state
        @State private var responseState: ResponseState?

        /// Whether the Mac is connected
        private var isConnected: Bool {
            relayClient.isMacConnected
        }

        var body: some View {
            LiveTerminalView(
                paneId: paneId,
                responseState: $responseState,
                isConnected: isConnected,
                settings: settings,
                sendCommand: sendCommand
            )
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
        }

        /// Send a command to the Mac for this pane
        private func sendCommand(_ command: CommandType) async {
            switch command {
            case let .sendKeystroke(spec):
                _ = await relayClient.sendCommand(spec, paneId: paneId)
            case let .cancelOperation(spec):
                _ = await relayClient.sendCommand(spec, paneId: paneId)
            case let .captureSnapshot(spec):
                _ = await relayClient.sendCommand(spec, paneId: paneId)
            case let .startTerminalStream(spec):
                _ = await relayClient.sendCommand(spec, paneId: paneId)
            case let .stopTerminalStream(spec):
                _ = await relayClient.sendCommand(spec, paneId: paneId)
            }
        }
    }

    #Preview {
        NavigationStack {
            PlainTerminalView(
                paneId: "%1",
                relayClient: RelayClient(),
                settings: .shared
            )
        }
        .environment(RelayClient())
    }
#endif
