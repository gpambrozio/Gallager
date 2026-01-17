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
        @Environment(IOSSettings.self) private var settings
        @Environment(\.dismiss) private var dismiss

        @State private var streamState: StreamState = .idle
        @State private var terminalState: TerminalState?
        @State private var error: String?

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
            switch streamState {
            case .idle,
                 .connecting:
                ProgressView("Connecting to terminal...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .streaming:
                if let state = terminalState {
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
                    description: error ?? "Unknown error"
                )
            }
        }

        // MARK: - Streaming

        private func startStreaming() async {
            guard isConnected else {
                streamState = .error
                error = "Mac is not connected"
                return
            }

            streamState = .connecting

            // Set up stream message handler
            relayClient.onTerminalStream = { message in
                guard message.paneId == paneId else { return }
                Task { @MainActor in
                    handleStreamMessage(message)
                }
            }

            // Request stream start
            let result = await relayClient.sendCommand(
                StartTerminalStream(),
                paneId: paneId
            )

            // Only handle failure - streaming state is set when initial state arrives
            if case let .failure(err) = result {
                streamState = .error
                error = err.localizedDescription
            }
        }

        private func stopStreaming() async {
            guard isConnected else { return }
            relayClient.onTerminalStream = nil
            _ = await relayClient.sendCommand(
                StopTerminalStream(),
                paneId: paneId
            )
        }

        @MainActor
        private func handleStreamMessage(_ message: TerminalStreamMessage) {
            switch message.updateType {
            case let .initialState(initial):
                // Create terminal state with initial content
                guard let content = initial.content else { return }
                let state = TerminalState(
                    width: initial.width,
                    height: initial.height,
                    fontName: settings.terminalFontName,
                    fontSize: CGFloat(settings.terminalFontSize)
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
            let terminalView = TerminalView(frame: initialFrame, font: font)
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
            context.coordinator.scrollView = scrollView
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
            Coordinator(terminalState: terminalState)
        }

        @MainActor
        final class Coordinator {
            var terminalView: TerminalView?
            var scrollView: UIScrollView?
            var cellSize: CGSize = .zero
            var widthConstraint: NSLayoutConstraint?
            var heightConstraint: NSLayoutConstraint?
            let terminalState: TerminalState

            init(terminalState: TerminalState) {
                self.terminalState = terminalState
            }

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
                responseState: .constant(nil),
                isConnected: true,
                sendCommand: { _ in }
            )
        }
        .environment(RelayClient())
        .environment(IOSSettings.shared)
    }
#endif
