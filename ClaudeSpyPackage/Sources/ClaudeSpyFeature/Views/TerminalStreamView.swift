#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftTerm
    import SwiftUI
    import UIKit

    /// Displays a live streaming terminal from the Mac app
    struct TerminalStreamView: View {
        let paneId: String
        let initialWidth: Int
        let initialHeight: Int
        @Binding var responseState: ResponseState?
        let isConnected: Bool
        let sendCommand: CommandSender
        let onDisappear: () -> Void

        @Environment(IOSSettings.self) private var settings
        @Environment(RelayClient.self) private var relayClient
        @Environment(\.dismiss) private var dismiss

        @State private var streamState: StreamState = .connecting
        @State private var terminalCoordinator: TerminalStreamCoordinator?

        enum StreamState: Equatable {
            case connecting
            case connected
            case disconnected(reason: String?)
            case error(String)

            var isStreamConnected: Bool {
                if case .connected = self { return true }
                return false
            }
        }

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

                // Status bar
                streamStatusBar

                // Terminal view
                if let coordinator = terminalCoordinator {
                    TerminalStreamContainerView(
                        coordinator: coordinator,
                        fontName: settings.terminalFontName,
                        fontSize: CGFloat(settings.terminalFontSize)
                    )
                } else {
                    ProgressView("Connecting to terminal...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                }
            }
            .navigationTitle("Live Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await setupStreaming()
            }
            .onDisappear {
                onDisappear()
            }
        }

        @ViewBuilder
        private var streamStatusBar: some View {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if streamState.isStreamConnected {
                    Text("LIVE")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.systemGroupedBackground))
        }

        private var statusColor: SwiftUI.Color {
            switch streamState {
            case .connecting:
                return .yellow
            case .connected:
                return .green
            case .disconnected:
                return .gray
            case .error:
                return .red
            }
        }

        private var statusText: String {
            switch streamState {
            case .connecting:
                return "Connecting..."
            case .connected:
                return "Streaming from \(paneId)"
            case let .disconnected(reason):
                return reason ?? "Disconnected"
            case let .error(message):
                return "Error: \(message)"
            }
        }

        private func setupStreaming() async {
            // Create the coordinator
            let coordinator = TerminalStreamCoordinator(
                width: initialWidth,
                height: initialHeight
            )
            terminalCoordinator = coordinator

            // Set up callbacks
            relayClient.onTerminalStreamStarted = { [weak coordinator] started in
                Task { @MainActor in
                    guard started.paneId == paneId else { return }
                    coordinator?.updateDimensions(width: started.width, height: started.height)
                    streamState = .connected
                }
            }

            relayClient.onTerminalStreamChunk = { [weak coordinator] chunk in
                Task { @MainActor in
                    guard chunk.paneId == paneId else { return }
                    coordinator?.feed(chunk: chunk)
                }
            }

            relayClient.onTerminalStreamStopped = { stopped in
                Task { @MainActor in
                    guard stopped.paneId == paneId else { return }
                    streamState = .disconnected(reason: stopped.reason)
                }
            }

            // Start the stream
            await relayClient.startTerminalStream(paneId: paneId)
        }
    }

    /// Coordinator that manages the terminal view and receives streaming updates
    @MainActor
    final class TerminalStreamCoordinator: ObservableObject {
        private(set) var width: Int
        private(set) var height: Int
        private var terminalView: TerminalView?
        private var pendingData: [Data] = []

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        func setTerminalView(_ view: TerminalView) {
            terminalView = view

            // Feed any pending data
            for data in pendingData {
                view.feed(byteArray: ArraySlice(data))
            }
            pendingData.removeAll()
        }

        func updateDimensions(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        func feed(chunk: TerminalStreamChunk) {
            guard let data = chunk.data else { return }

            // Update dimensions if changed
            if chunk.width != width || chunk.height != height {
                updateDimensions(width: chunk.width, height: chunk.height)
            }

            if let view = terminalView {
                view.feed(byteArray: ArraySlice(data))
            } else {
                // Buffer data until terminal view is ready
                pendingData.append(data)
            }
        }
    }

    /// SwiftUI wrapper around SwiftTerm's TerminalView for streaming
    private struct TerminalStreamContainerView: UIViewRepresentable {
        @ObservedObject var coordinator: TerminalStreamCoordinator
        let fontName: String
        let fontSize: CGFloat

        func makeUIView(context: Context) -> UIScrollView {
            // Use FontMetrics to calculate cell size
            let cellSize = FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)

            // Calculate frame for the terminal
            let exactWidth = CGFloat(coordinator.width) * cellSize.width
            let exactHeight = CGFloat(coordinator.height) * cellSize.height
            let exactFrame = CGRect(x: 0, y: 0, width: exactWidth, height: exactHeight)

            // Create the terminal with the exact frame
            let font = UIFont(name: fontName, size: fontSize)
                ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let terminalView = TerminalView(frame: exactFrame, font: font)

            // Set dark theme colors
            terminalView.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
            terminalView.nativeBackgroundColor = UIColor.black

            // Disable TerminalView's own scrolling since we wrap it
            terminalView.isScrollEnabled = false
            terminalView.contentOffset = .zero
            terminalView.inputAssistantItem.leadingBarButtonGroups = []
            terminalView.inputAssistantItem.trailingBarButtonGroups = []

            // Create scroll view wrapper
            let scrollView = UIScrollView()
            scrollView.backgroundColor = .black
            scrollView.addSubview(terminalView)
            scrollView.contentSize = exactFrame.size
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.showsVerticalScrollIndicator = true
            scrollView.alwaysBounceVertical = true
            scrollView.alwaysBounceHorizontal = false

            // Store references
            context.coordinator.terminalView = terminalView
            context.coordinator.scrollView = scrollView

            // Register terminal view with the stream coordinator
            coordinator.setTerminalView(terminalView)

            return scrollView
        }

        func updateUIView(_ scrollView: UIScrollView, context: Context) {
            // Auto-scroll to bottom when new content arrives
            guard let terminalView = context.coordinator.terminalView else { return }

            // Check if user is near the bottom (within 50 pixels)
            let nearBottom = scrollView.contentOffset.y >= scrollView.contentSize.height - scrollView.bounds.height - 50

            // Update terminal frame if dimensions changed
            let cellSize = FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)
            let newWidth = CGFloat(coordinator.width) * cellSize.width
            let newHeight = CGFloat(coordinator.height) * cellSize.height

            if terminalView.frame.width != newWidth || terminalView.frame.height != newHeight {
                terminalView.frame = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
                scrollView.contentSize = terminalView.frame.size
            }

            // Auto-scroll to bottom if user was near bottom
            if nearBottom {
                let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: maxY)
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        @MainActor
        class Coordinator {
            var terminalView: TerminalView?
            var scrollView: UIScrollView?
        }
    }

    #Preview {
        NavigationStack {
            TerminalStreamView(
                paneId: "%1",
                initialWidth: 80,
                initialHeight: 24,
                responseState: .constant(nil),
                isConnected: true,
                sendCommand: { _ in },
                onDisappear: { }
            )
        }
        .environment(IOSSettings.shared)
        .environment(RelayClient())
    }

    #Preview("With Permission Request") {
        let event = HookEvent(
            action: .permissionRequest(PermissionRequestBody.preview),
            projectPath: "/Users/test/Projects/TestProject",
            tmuxPane: "%1"
        )
        var responseState: ResponseState? = ResponseState(event: event)

        NavigationStack {
            TerminalStreamView(
                paneId: "%1",
                initialWidth: 80,
                initialHeight: 24,
                responseState: Binding(get: { responseState }, set: { responseState = $0 }),
                isConnected: true,
                sendCommand: { _ in },
                onDisappear: { }
            )
        }
        .environment(IOSSettings.shared)
        .environment(RelayClient())
    }
#endif
