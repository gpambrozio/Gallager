#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftTerm
    import SwiftUI
    import UIKit

    /// Displays a live streaming terminal from the Mac app.
    ///
    /// This view requests a terminal stream from the Mac, displays the live output,
    /// and handles dimension changes. It replaces the static snapshot view.
    struct LiveTerminalView: View {
        let paneId: String

        /// Binding to the response state for displaying response options above the terminal
        @Binding var responseState: ResponseState?

        /// Whether the Mac is connected
        let isConnected: Bool

        /// Command sender for response actions
        let sendCommand: CommandSender

        @Environment(RelayClient.self) private var relayClient
        @State private var coordinator: StreamCoordinator

        init(
            paneId: String,
            responseState: Binding<ResponseState?>,
            isConnected: Bool,
            settings: IOSSettings,
            sendCommand: @escaping CommandSender
        ) {
            self.paneId = paneId
            self._responseState = responseState
            self.isConnected = isConnected
            self.sendCommand = sendCommand
            self.coordinator = StreamCoordinator(
                paneId: paneId,
                fontName: settings.terminalFontName,
                fontSize: CGFloat(settings.terminalFontSize)
            )
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

                // Terminal content
                terminalContent
            }
            .navigationTitle("Live Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await startStreaming()
            }
            .onDisappear {
                Task { await stopStreaming() }
            }
        }

        @ViewBuilder
        private var terminalContent: some View {
            switch coordinator.streamState {
            case .idle,
                 .connecting:
                ProgressView("Connecting to terminal...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .streaming:
                if let state = coordinator.terminalState {
                    TerminalStreamContainerView(terminalState: state)
                } else {
                    ProgressView("Initializing terminal...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

            case .ended:
                ContentUnavailableView(
                    "Stream Ended",
                    symbol: .terminal,
                    description: "The terminal stream has ended."
                )

            case .error:
                ContentUnavailableView(
                    "Stream Error",
                    symbol: .exclamationmarkTriangle,
                    description: coordinator.error ?? "Unknown error"
                )
            }
        }

        // MARK: - Streaming

        private func startStreaming() async {
            guard isConnected else {
                coordinator.streamState = .error
                coordinator.error = "Mac is not connected"
                return
            }

            // Create coordinator that the callback can capture
            coordinator.streamState = .connecting

            // Set up stream message handler - coordinator is a class so weak capture works
            relayClient.onTerminalStream = { [weak coordinator] message in
                guard let coordinator, message.paneId == paneId else { return }
                coordinator.handleStreamMessage(message)
            }

            // Request stream start
            let result = await relayClient.sendCommand(
                StartTerminalStream(),
                paneId: paneId
            )

            // Only handle failure - streaming state is set when initial state arrives
            if case let .failure(err) = result {
                coordinator.streamState = .error
                coordinator.error = err.localizedDescription
            }
        }

        private func stopStreaming() async {
            relayClient.onTerminalStream = nil
            guard isConnected else { return }
            _ = await relayClient.sendCommand(
                StopTerminalStream(),
                paneId: paneId
            )
        }
    }

    // MARK: - Stream Coordinator

    /// Observable class that manages stream state.
    /// This allows the callback closure to capture a class reference that can be weakly held.
    @Observable
    @MainActor
    final private class StreamCoordinator {
        let paneId: String
        let fontName: String
        let fontSize: CGFloat

        var streamState: StreamState = .idle
        var terminalState: TerminalState?
        var error: String?

        init(paneId: String, fontName: String, fontSize: CGFloat) {
            self.paneId = paneId
            self.fontName = fontName
            self.fontSize = fontSize
        }

        func handleStreamMessage(_ message: TerminalStreamMessage) {
            switch message.updateType {
            case let .initialState(initial):
                // Create terminal state with initial content
                guard let content = initial.content else { return }
                let state = TerminalState(
                    width: initial.width,
                    height: initial.height,
                    fontName: fontName,
                    fontSize: fontSize
                )
                state.feed(content)
                terminalState = state
                streamState = .streaming

            case let .dataChunk(chunk):
                // Feed new data to terminal
                guard let data = chunk.data else { return }
                terminalState?.feed(data)

            case let .dimensionChange(dims):
                // Resize terminal
                terminalState?.resize(width: dims.width, height: dims.height)

            case .streamEnd:
                streamState = .ended
            }
        }
    }

    // MARK: - Stream State

    private enum StreamState {
        case idle
        case connecting
        case streaming
        case ended
        case error
    }

    // MARK: - Terminal State

    /// Manages the terminal state for the streaming view.
    @Observable
    @MainActor
    final class TerminalState {
        private(set) var width: Int
        private(set) var height: Int
        let fontName: String
        let fontSize: CGFloat

        /// Buffered content to feed when onData is connected
        private var pendingInitialContent = Data()

        /// Callback to feed data to the terminal view
        var onData: ((Data) -> Void)?

        /// Call after setting onData to flush any pending content
        func flushPendingContent() {
            guard !pendingInitialContent.isEmpty, let onData else { return }
            let content = pendingInitialContent
            pendingInitialContent = Data()
            onData(content)
        }

        /// Callback when dimensions change
        var onResize: ((Int, Int) -> Void)?

        init(width: Int, height: Int, fontName: String, fontSize: CGFloat) {
            self.width = width
            self.height = height
            self.fontName = fontName
            self.fontSize = fontSize
        }

        func feed(_ data: Data) {
            if let onData {
                onData(data)
            } else {
                pendingInitialContent.append(data)
            }
        }

        func resize(width: Int, height: Int) {
            guard self.width != width || self.height != height else { return }
            self.width = width
            self.height = height
            onResize?(width, height)
        }
    }

    // MARK: - Terminal Container View

    /// UIKit container for the streaming terminal
    private struct TerminalStreamContainerView: UIViewRepresentable {
        let terminalState: TerminalState

        func makeUIView(context: Context) -> UIScrollView {
            // Calculate cell size
            let cellSize = FontMetrics.calculateCellSize(
                fontName: terminalState.fontName,
                fontSize: terminalState.fontSize
            )

            let exactWidth = CGFloat(terminalState.width) * cellSize.width
            let exactHeight = CGFloat(terminalState.height) * cellSize.height

            // Create font
            let font = UIFont(name: terminalState.fontName, size: terminalState.fontSize)
                ?? UIFont.monospacedSystemFont(ofSize: terminalState.fontSize, weight: .regular)

            // Create terminal view with initial frame matching calculated size
            // This is needed because SwiftTerm renders based on frame, and content
            // is fed before Auto Layout runs. Constraints handle dynamic resizing after.
            let initialFrame = CGRect(x: 0, y: 0, width: exactWidth, height: exactHeight)
            let terminalView = ReadOnlyTerminalView(frame: initialFrame, font: font)
            terminalView.translatesAutoresizingMaskIntoConstraints = false

            // Configure terminal
            terminalView.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
            terminalView.nativeBackgroundColor = UIColor.black
            // Enable native scrolling so scrollback buffer is accessible
            terminalView.isScrollEnabled = true
            terminalView.inputAssistantItem.leadingBarButtonGroups = []
            terminalView.inputAssistantItem.trailingBarButtonGroups = []

            // Resize terminal buffer
            terminalView.getTerminal().resize(cols: terminalState.width, rows: terminalState.height)

            // Create scroll view for horizontal scrolling only (wide terminals)
            // The terminal's native scrolling handles vertical/scrollback
            let scrollView = UIScrollView()
            scrollView.backgroundColor = .black
            scrollView.addSubview(terminalView)
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.showsVerticalScrollIndicator = false
            scrollView.alwaysBounceVertical = false
            scrollView.alwaysBounceHorizontal = false

            // Use Auto Layout to properly size the terminal view
            // Terminal should fill available space but grow for wide/tall terminals
            let widthConstraint = terminalView.widthAnchor.constraint(equalToConstant: exactWidth)
            let heightConstraint = terminalView.heightAnchor.constraint(equalToConstant: exactHeight)
            // Lower priority so minimum size constraints take precedence
            widthConstraint.priority = .defaultHigh
            heightConstraint.priority = .defaultHigh

            NSLayoutConstraint.activate([
                // Pin to scroll view content (defines scrollable area)
                terminalView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                terminalView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                terminalView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                terminalView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

                // Minimum size = scroll view visible area (fills space when terminal is small)
                terminalView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor),
                terminalView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),

                // Exact terminal size (breaks when smaller than visible area)
                widthConstraint,
                heightConstraint,
            ])

            // Store references
            context.coordinator.terminalView = terminalView
            context.coordinator.cellSize = cellSize
            context.coordinator.widthConstraint = widthConstraint
            context.coordinator.heightConstraint = heightConstraint

            // Wire up callbacks
            terminalState.onData = { [weak terminalView] data in
                guard let terminalView else { return }
                let bytes = [UInt8](data)
                terminalView.feed(byteArray: bytes[...])
            }

            // Flush any pending initial content now that callback is connected
            terminalState.flushPendingContent()

            let coordinator = context.coordinator
            terminalState.onResize = { [weak coordinator] newWidth, newHeight in
                coordinator?.handleResize(width: newWidth, height: newHeight)
            }

            return scrollView
        }

        func updateUIView(_ scrollView: UIScrollView, context: Context) {
            // Updates handled by callbacks
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        @MainActor
        final class Coordinator {
            var terminalView: ReadOnlyTerminalView?
            var cellSize: CGSize = .zero
            var widthConstraint: NSLayoutConstraint?
            var heightConstraint: NSLayoutConstraint?

            func handleResize(width: Int, height: Int) {
                guard let terminalView else { return }

                let newWidth = CGFloat(width) * cellSize.width
                let newHeight = CGFloat(height) * cellSize.height

                // Update constraints for new terminal size
                widthConstraint?.constant = newWidth
                heightConstraint?.constant = newHeight

                terminalView.getTerminal().resize(cols: width, rows: height)
            }
        }
    }

    // MARK: - Preview

    #Preview("Live Terminal") {
        NavigationStack {
            LiveTerminalView(
                paneId: "%1",
                responseState: .init(get: { nil }, set: { _ in }),
                isConnected: true,
                settings: .shared,
                sendCommand: { _ in }
            )
        }
        .environment(RelayClient())
        .environment(IOSSettings.shared)
    }
#endif
