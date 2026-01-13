#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftUI

    /// A live streaming terminal view for iOS that shows real-time terminal content from the Mac.
    ///
    /// This view replaces the static TerminalSnapshotView for live interaction with the terminal.
    /// It displays possible responses above the terminal and handles terminal resizing.
    struct LiveTerminalView: View {
        let paneId: String
        @Binding var responseState: ResponseState?
        let isConnected: Bool
        let sendCommand: CommandSender

        @Environment(IOSSettings.self) private var settings
        @Environment(RelayClient.self) private var relayClient
        @Environment(\.dismiss) private var dismiss

        @State private var terminalController = IOSTerminalController()
        @State private var streamService: TerminalStreamService?
        @State private var errorMessage: String?

        var body: some View {
            VStack(spacing: 0) {
                // Response view above terminal if available
                if
                    let responseState,
                    let responseView = responseState.event.responseView(
                        isConnected: isConnected,
                        sendCommand: {
                            await sendCommand($0)
                            dismiss()
                        },
                        state: responseState
                    ) {
                    responseView
                        .padding()
                        .background(Color(.systemGroupedBackground))

                    Divider()
                }

                // Error message if any
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding()
                }

                // Terminal view with status overlay
                ZStack(alignment: .topTrailing) {
                    IOSTerminalContainerView(terminalController: terminalController)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Connection status indicator
                    if let service = streamService {
                        statusIndicator(for: service.state)
                            .padding(8)
                    }
                }
            }
            .navigationTitle("Live Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await setupAndConnect()
            }
            .onDisappear {
                Task {
                    await streamService?.stopStreaming()
                }
            }
            .onChange(of: settings.terminalFontName) { _, newValue in
                terminalController.fontName = newValue
            }
            .onChange(of: settings.terminalFontSize) { _, newValue in
                terminalController.fontSize = CGFloat(newValue)
            }
        }

        // MARK: - Status Indicator

        @ViewBuilder
        private func statusIndicator(for state: TerminalStreamState) -> some View {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor(for: state))
                    .frame(width: 8, height: 8)
                Text(statusText(for: state))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
        }

        private func statusColor(for state: TerminalStreamState) -> Color {
            switch state {
            case .connected: .green
            case .connecting: .orange
            case .disconnected: .gray
            case .error: .red
            }
        }

        private func statusText(for state: TerminalStreamState) -> String {
            switch state {
            case .connected: "Live"
            case .connecting: "Connecting..."
            case .disconnected: "Disconnected"
            case .error: "Error"
            }
        }

        // MARK: - Setup

        private func setupAndConnect() async {
            // Configure terminal with settings
            terminalController.fontName = settings.terminalFontName
            terminalController.fontSize = CGFloat(settings.terminalFontSize)
            terminalController.applyDarkTheme()

            // Create stream service
            let service = TerminalStreamService(paneId: paneId, relayClient: relayClient)
            streamService = service

            // Set up service callbacks
            service.onInitialContent = { data in
                // Resize terminal before feeding initial content
                terminalController.resize(columns: service.width, rows: service.height)
                terminalController.clear()
                terminalController.feed(data)
            }

            service.onData = { data in
                terminalController.feed(data)
            }

            service.onResize = { newWidth, newHeight in
                terminalController.resize(columns: newWidth, rows: newHeight)
            }

            service.onStopped = { reason in
                if reason != "user_requested" {
                    errorMessage = "Stream ended: \(reason)"
                }
            }

            // Start streaming (service handles handler registration internally)
            do {
                try await service.startStreaming()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    #Preview {
        NavigationStack {
            LiveTerminalView(
                paneId: "%1",
                responseState: .constant(nil),
                isConnected: true,
                sendCommand: { _ in }
            )
        }
        .environment(IOSSettings.shared)
        .environment(RelayClient())
    }
#endif
