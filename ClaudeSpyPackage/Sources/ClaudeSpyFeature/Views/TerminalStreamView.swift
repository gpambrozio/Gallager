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
                        sendCommand: sendCommand,
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
                    // Queue chunk for ordered processing - ensures chunks are processed
                    // in order even if Tasks from multiple callbacks race
                    coordinator?.queueChunk(chunk)
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

    /// Coordinator that manages the terminal view and receives streaming updates.
    /// Modeled after Mac's TerminalController for consistent behavior.
    @MainActor
    final class TerminalStreamCoordinator: ObservableObject {
        /// Published so SwiftUI updates the frame when dimensions change
        @Published private(set) var width: Int
        @Published private(set) var height: Int

        /// The underlying SwiftTerm terminal view
        private var terminalView: TerminalView?

        /// Font settings for frame calculations
        private var fontName = "SF Mono"
        private var fontSize: CGFloat = 12

        /// Chunks buffered before terminal is ready or dimensions received
        private var pendingChunks: [TerminalStreamChunk] = []

        /// Whether we've received dimensions from TerminalStreamStarted
        private var dimensionsReceived = false

        /// Whether we've cleared the terminal (happens once when ready)
        private var hasCleared = false

        /// Task chain to ensure chunks are processed in order
        private var pendingProcess: Task<Void, Never>?

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        /// Registers the terminal view and ensures it's properly configured.
        /// Called from makeUIView after terminal creation.
        func setTerminalView(_ view: TerminalView, fontName: String, fontSize: CGFloat) {
            terminalView = view
            self.fontName = fontName
            self.fontSize = fontSize

            // Always ensure buffer matches our dimensions (like Mac's resize)
            view.getTerminal().resize(cols: width, rows: height)

            // Update the pixel frame to match
            updateTerminalFrameSize()

            // If dimensions already received, we're ready to process data
            if dimensionsReceived {
                // Clear once when terminal is ready (handles race where dimensions arrived first)
                clearOnceIfNeeded()
                flushPendingChunks()
            }
        }

        /// Updates dimensions when TerminalStreamStarted is received.
        /// Resizes both buffer AND frame synchronously (like Mac's resize method).
        func updateDimensions(width: Int, height: Int) {
            self.width = width
            self.height = height
            dimensionsReceived = true

            guard let view = terminalView else {
                // Terminal not ready yet - dimensions will be applied in setTerminalView
                return
            }

            // Resize the terminal's internal buffer
            view.getTerminal().resize(cols: width, rows: height)

            // Update the pixel frame to match (synchronous, like Mac)
            updateTerminalFrameSize()

            // Clear once when terminal is ready (like Mac pattern)
            clearOnceIfNeeded()

            // Flush any buffered chunks
            flushPendingChunks()
        }

        /// Clears the terminal display (matches Mac's clear method)
        func clear() {
            guard let view = terminalView else { return }
            let clearSequence = Data("\u{1b}[2J\u{1b}[H".utf8)
            view.feed(byteArray: ArraySlice(clearSequence))
        }

        /// Feeds raw data to the terminal (matches Mac's feed method)
        func feed(_ data: Data) {
            guard let view = terminalView else { return }
            view.feed(byteArray: ArraySlice(data))
        }

        /// Queue a chunk for ordered processing.
        /// Ensures chunks are processed in order even if Tasks race.
        func queueChunk(_ chunk: TerminalStreamChunk) {
            let previousProcess = pendingProcess
            pendingProcess = Task {
                await previousProcess?.value
                processChunk(chunk)
            }
        }

        // MARK: - Private Methods

        /// Clears the terminal once when it's ready to receive data.
        /// Called from both setTerminalView and updateDimensions to handle race conditions.
        private func clearOnceIfNeeded() {
            guard !hasCleared else { return }
            hasCleared = true
            clear()
        }

        /// Updates the terminal frame size based on current font and dimensions.
        /// Matches Mac's updateTerminalFrameSize method.
        private func updateTerminalFrameSize() {
            guard let view = terminalView else { return }

            let cellSize = FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)

            // Calculate required size (matches Mac calculation)
            let frameWidth = CGFloat(width) * cellSize.width + FontMetrics.horizontalBuffer
            let frameHeight = CGFloat(height) * cellSize.height

            view.frame = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        }

        /// Processes a single chunk, buffering if not ready
        private func processChunk(_ chunk: TerminalStreamChunk) {
            // Buffer chunks until we have dimensions AND terminal view
            guard dimensionsReceived, terminalView != nil else {
                pendingChunks.append(chunk)
                return
            }

            // Check if dimensions changed (e.g., terminal was resized on Mac)
            if chunk.width != width || chunk.height != height {
                updateDimensions(width: chunk.width, height: chunk.height)
            }

            // Feed the data
            if let data = chunk.data {
                feed(data)
            }
        }

        private func flushPendingChunks() {
            guard terminalView != nil, dimensionsReceived else { return }

            for chunk in pendingChunks {
                if let data = chunk.data {
                    feed(data)
                }
            }
            pendingChunks.removeAll()
        }
    }

    /// SwiftUI wrapper around SwiftTerm's TerminalView for streaming.
    /// Modeled after Mac's TerminalContainerView for consistent behavior.
    private struct TerminalStreamContainerView: UIViewRepresentable {
        @ObservedObject var coordinator: TerminalStreamCoordinator
        let fontName: String
        let fontSize: CGFloat

        func makeUIView(context: Context) -> UIScrollView {
            // Create terminal with initial frame (will be resized by coordinator)
            let initialFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
            let font = UIFont(name: fontName, size: fontSize)
                ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let terminalView = TerminalView(frame: initialFrame, font: font)

            // Set dark theme colors (matches Mac's applyDarkTheme)
            let bgColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            terminalView.nativeForegroundColor = UIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
            terminalView.nativeBackgroundColor = bgColor

            // Disable TerminalView's own scrolling since we wrap it
            terminalView.isScrollEnabled = false
            terminalView.contentOffset = .zero

            // Disable automatic content resizing - we want fixed terminal size (like Mac)
            terminalView.autoresizingMask = []

            // Hide input assistant (keyboard suggestions)
            terminalView.inputAssistantItem.leadingBarButtonGroups = []
            terminalView.inputAssistantItem.trailingBarButtonGroups = []

            // Create scroll view wrapper (matches Mac's scroll view setup)
            let scrollView = UIScrollView()
            scrollView.backgroundColor = bgColor
            scrollView.addSubview(terminalView)
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.showsVerticalScrollIndicator = true
            scrollView.alwaysBounceVertical = true
            scrollView.alwaysBounceHorizontal = false

            // Ensure no automatic content insets (like Mac)
            scrollView.contentInsetAdjustmentBehavior = .never

            // Disable automatic content resizing (like Mac)
            scrollView.autoresizesSubviews = false

            // Store reference for updateUIView
            context.coordinator.terminalView = terminalView

            // Register terminal view with the stream coordinator
            // This will resize buffer and frame to match coordinator dimensions
            coordinator.setTerminalView(terminalView, fontName: fontName, fontSize: fontSize)

            // Sync scroll view content size with terminal frame
            scrollView.contentSize = terminalView.frame.size

            return scrollView
        }

        func updateUIView(_ scrollView: UIScrollView, context: Context) {
            guard let terminalView = context.coordinator.terminalView else { return }

            // Sync scroll view content size with terminal frame
            // (coordinator handles frame updates via updateTerminalFrameSize)
            if scrollView.contentSize != terminalView.frame.size {
                scrollView.contentSize = terminalView.frame.size
            }

            // Auto-scroll: check if user is near the bottom
            let cellSize = FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)
            let lineHeight = cellSize.height
            let scrollThreshold = lineHeight * 2 // Two lines tolerance

            let nearBottom = scrollView.contentOffset.y >=
                scrollView.contentSize.height - scrollView.bounds.height - scrollThreshold

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
