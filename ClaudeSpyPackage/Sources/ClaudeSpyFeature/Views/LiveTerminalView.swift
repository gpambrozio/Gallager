#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftTerm
    import SwiftUI
    import UIKit

    /// Displays a live streaming terminal from the host app.
    ///
    /// This view requests a terminal stream from the host, displays the live output,
    /// and handles dimension changes. It replaces the static snapshot view.
    ///
    /// When `isInteractive` is true, the terminal accepts keyboard input which is
    /// forwarded to tmux via the relay server.
    struct LiveTerminalView: View {
        let paneId: String

        /// Binding to the response state for displaying response options above the terminal
        @Binding var responseState: ResponseState?

        /// Binding to the terminal title detected via OSC escape sequences
        @Binding var terminalTitle: String?

        /// Binding to the latest clipboard content from the host (OSC 52)
        @Binding var clipboardContent: String?

        /// Whether the host is connected
        let isConnected: Bool

        /// Whether yolo mode is enabled for this pane
        let isYoloMode: Bool

        /// Whether the navigation bar is hidden (show overlay keyboard button)
        let hideNavigationBar: Bool

        /// Whether to show the keyboard toggle button in the toolbar.
        /// Set to false when used in multi-pane layouts where the parent manages the keyboard.
        let showKeyboardButton: Bool

        /// Whether this terminal pane is the active/selected one.
        /// When false, keyboard input is suppressed regardless of `isInteractive`.
        /// Used in multi-pane layouts where only the selected pane accepts input.
        let isActive: Bool

        /// Command sender for response actions
        let sendCommand: CommandSender

        @Environment(ViewerRelayClient.self) private var relayClient
        @Environment(\.dismiss) private var dismiss
        @State private var coordinator: StreamCoordinator

        /// Whether the terminal is in interactive mode (keyboard is showing)
        @State private var isInteractive = false

        /// Tracks keyboard visibility to sync toolbar icon and trigger layout updates
        @State private var keyboardVisible = false

        init(
            paneId: String,
            responseState: Binding<ResponseState?>,
            terminalTitle: Binding<String?>,
            clipboardContent: Binding<String?> = .constant(nil),
            isConnected: Bool,
            isYoloMode: Bool = false,
            hideNavigationBar: Bool = false,
            showKeyboardButton: Bool = true,
            isActive: Bool = true,
            settings: IOSSettings,
            sendCommand: @escaping CommandSender
        ) {
            self.paneId = paneId
            self._responseState = responseState
            self._terminalTitle = terminalTitle
            self._clipboardContent = clipboardContent
            self.isConnected = isConnected
            self.isYoloMode = isYoloMode
            self.hideNavigationBar = hideNavigationBar
            self.showKeyboardButton = showKeyboardButton
            self.isActive = isActive
            self.sendCommand = sendCommand
            self.coordinator = StreamCoordinator(
                paneId: paneId,
                fontName: settings.terminalFontName,
                fontSize: CGFloat(settings.terminalFontSize)
            )
        }

        var body: some View {
            VStack(spacing: 0) {
                // Response view above terminal (hidden when terminal keyboard is active)
                // We use isInteractive (explicit terminal input mode) rather than keyboardVisible
                // to avoid hiding when response view's own TextField activates the keyboard
                if
                    !isInteractive,
                    let responseState,
                    let responseView = responseState.event.responseView(
                        isYoloMode: isYoloMode,
                        isConnected: isConnected,
                        sendCommand: sendCommand,
                        state: responseState
                    ) {
                    responseView
                        .padding()
                        .background(Color(.systemGroupedBackground))
                        // Force a fresh view identity per event so per-event
                        // @State (e.g. AskUserQuestion's collected answers) is
                        // discarded when a new hook event replaces the prior one.
                        .id(responseState.event.id)

                    Divider()
                }

                // Terminal content with overlay keyboard button when nav bar is hidden
                terminalContent
                    .overlay(alignment: .topTrailing) {
                        if hideNavigationBar {
                            keyboardOverlayButton
                        }
                    }
            }
            .toolbar {
                if showKeyboardButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isInteractive.toggle()
                        } label: {
                            Label(
                                keyboardVisible ? "Hide Keyboard" : "Show Keyboard",
                                symbol: keyboardVisible ? .keyboardChevronCompactDown : .keyboard
                            )
                        }
                        .disabled(!isConnected || coordinator.streamState != .streaming)
                    }
                }
            }
            .task {
                await startStreaming()
            }
            .onDisappear {
                Task { await stopStreaming() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardVisible = true
                // Scroll to bottom after keyboard animation completes
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    coordinator.terminalState?.scrollToBottom?()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardVisible = false
                // Note: We intentionally don't set isInteractive = false here because keyboard
                // switching (e.g., to SwiftTerm's secondary keyboard) briefly fires this notification.
                // The slight state desync is preferable to breaking keyboard switching.
            }
            .onChange(of: coordinator.streamState) { _, newState in
                if newState == .ended {
                    dismiss()
                }
            }
            .onChange(of: coordinator.terminalTitle) { _, newTitle in
                terminalTitle = newTitle
            }
            .onChange(of: coordinator.pendingClipboardContent) { _, newContent in
                clipboardContent = newContent
            }
        }

        /// Overlay button for keyboard toggle when navigation bar is hidden
        @ViewBuilder
        private var keyboardOverlayButton: some View {
            Button {
                isInteractive.toggle()
            } label: {
                (keyboardVisible ? Symbols.keyboardChevronCompactDown.image : Symbols.keyboard.image)
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(!isConnected || coordinator.streamState != .streaming)
            .padding(8)
        }

        @ViewBuilder
        private var terminalContent: some View {
            switch coordinator.streamState {
            case .idle,
                 .connecting:
                ProgressView("Connecting to terminal...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .streaming,
                 .ended: // View auto-dismisses on stream end
                if let state = coordinator.terminalState {
                    // When showKeyboardButton is false, parent controls interactivity
                    // entirely through isActive. Otherwise, use internal toggle.
                    let effectiveInteractive = showKeyboardButton ? (isInteractive && isActive) : isActive
                    TerminalStreamContainerView(
                        terminalState: state,
                        isInteractive: effectiveInteractive,
                        onInput: { keys in
                            coordinator.enqueueKeySend(keys: keys, relayClient: relayClient)
                        }
                    )
                } else {
                    ProgressView("Initializing terminal...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

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
                coordinator.error = "Host is not connected"
                return
            }

            // Generate a unique session ID for this streaming attempt
            // This prevents stale callbacks from processing messages
            let streamSessionId = UUID()
            coordinator.streamSessionId = streamSessionId
            coordinator.streamState = .connecting

            // Capture coordinator strongly - it's held by @State so won't outlive the view,
            // and stopStreaming() clears the callback to break the reference
            let currentCoordinator = coordinator
            let currentPaneId = paneId

            // Set up per-pane stream message handler BEFORE sending the command
            // Use strong capture to prevent the coordinator from being deallocated during async gaps
            relayClient.setTerminalStreamHandler(for: currentPaneId) { message in
                // Verify this callback is for the current stream session
                guard currentCoordinator.streamSessionId == streamSessionId else { return }
                currentCoordinator.handleStreamMessage(message)
            }

            // Request stream start
            let result = await relayClient.sendCommand(
                StartTerminalStream(),
                paneId: paneId
            )

            // Only handle failure - streaming state is set when initial state arrives
            if case let .failure(err) = result {
                // Only update state if this is still the active stream session
                if coordinator.streamSessionId == streamSessionId {
                    coordinator.streamState = .error
                    coordinator.error = err.localizedDescription
                }
            }
        }

        private func stopStreaming() async {
            // Cancel any in-flight key sends before tearing down the session
            coordinator.cancelPendingKeys()

            // Invalidate the current stream session first
            coordinator.streamSessionId = nil
            relayClient.setTerminalStreamHandler(for: paneId, handler: nil)

            guard isConnected else { return }
            _ = await relayClient.sendCommand(
                StopTerminalStream(),
                paneId: paneId
            )
        }
    }

    // MARK: - Stream Coordinator

    /// Observable class that manages stream state.
    /// Uses a session ID to prevent stale callbacks from processing messages.
    @Observable
    @MainActor
    final private class StreamCoordinator {
        let paneId: String
        let fontName: String
        let fontSize: CGFloat

        var streamState: StreamState = .idle
        var terminalState: TerminalState?
        var terminalTitle: String?
        var error: String?

        /// Latest clipboard content received from the host via OSC 52.
        /// The parent view checks focus state before applying to UIPasteboard.
        var pendingClipboardContent: String?

        /// Unique identifier for the current streaming session.
        /// Set when streaming starts, cleared when streaming stops.
        /// Prevents race conditions where old callbacks process messages meant for new sessions.
        var streamSessionId: UUID?

        @ObservationIgnored
        private var keystrokeDebouncer: KeystrokeDebouncer?

        init(paneId: String, fontName: String, fontSize: CGFloat) {
            self.paneId = paneId
            self.fontName = fontName
            self.fontSize = fontSize
        }

        /// Cancel any in-flight key-send chain.
        func cancelPendingKeys() {
            keystrokeDebouncer?.cancelAll()
        }

        /// Accumulates rapid keystrokes and flushes them as a single command after a short delay.
        func enqueueKeySend(keys: [TmuxKey], relayClient: ViewerRelayClient) {
            if keystrokeDebouncer == nil {
                keystrokeDebouncer = KeystrokeDebouncer(paneId: paneId, relayClient: relayClient)
            }
            keystrokeDebouncer?.enqueue(keys)
        }

        func handleStreamMessage(_ message: TerminalStreamMessage) {
            switch message.updateType {
            case let .initialState(initial):
                // If already streaming, ignore duplicate initialState.
                // This happens when another iOS device subscribes to the same pane —
                // the host broadcasts initialState to all devices. Replacing the
                // TerminalState while streaming would break the UIKit onData wiring.
                guard streamState != .streaming else { return }

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

            case let .titleChange(change):
                terminalTitle = change.title

            case .notification:
                // Terminal notifications are not displayed on iOS yet
                break

            case let .clipboardUpdate(update):
                pendingClipboardContent = update.content

            case .streamEnd:
                // Only process streamEnd if we're actually streaming.
                // Ignore if we're still connecting - this can happen when the host restarts
                // a stale stream (stops old, starts new) and the streamEnd from the old
                // stream arrives before our new initialState.
                guard streamState == .streaming else { return }
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

        /// Callback called once after initial content is fed (for scroll-to-bottom and enabling preservation)
        var onInitialContentLoaded: (() -> Void)?

        /// Call after setting onData to flush any pending content
        func flushPendingContent() {
            guard !pendingInitialContent.isEmpty, let onData else { return }
            let content = pendingInitialContent
            pendingInitialContent = Data()
            onData(content)
            onInitialContentLoaded?()
        }

        /// Callback when dimensions change
        var onResize: ((Int, Int) -> Void)?

        /// Scrolls the terminal to the bottom. Set by UIKit side, callable from SwiftUI.
        var scrollToBottom: (() -> Void)?

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

    /// UIKit container for the streaming terminal.
    ///
    /// Uses `InteractiveTerminalView` which supports both read-only and interactive modes.
    /// When `isInteractive` is true, the keyboard is shown and input is forwarded via `onInput`.
    private struct TerminalStreamContainerView: UIViewRepresentable {
        let terminalState: TerminalState

        /// Whether the terminal accepts keyboard input
        let isInteractive: Bool

        /// Callback when user types (keys are ready for relay transmission)
        let onInput: @MainActor ([TmuxKey]) -> Void

        func makeUIView(context: Context) -> UIScrollView {
            // Calculate cell size using FontMetrics (matches SwiftTerm's computeFontDimensions)
            let cellSize = FontMetrics.calculateCellSize(
                fontName: terminalState.fontName,
                fontSize: terminalState.fontSize
            )

            let exactWidth = CGFloat(terminalState.width) * cellSize.width + FontMetrics.horizontalBuffer
            let exactHeight = CGFloat(terminalState.height) * cellSize.height

            // Create font
            let font = UIFont(name: terminalState.fontName, size: terminalState.fontSize)
                ?? UIFont.monospacedSystemFont(ofSize: terminalState.fontSize, weight: .regular)

            // Create interactive terminal view
            let initialFrame = CGRect(x: 0, y: 0, width: exactWidth, height: exactHeight)
            let terminalView = InteractiveTerminalView(frame: initialFrame, font: font)
            terminalView.translatesAutoresizingMaskIntoConstraints = false

            // Configure terminal
            terminalView.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
            terminalView.nativeBackgroundColor = UIColor.black
            terminalView.isScrollEnabled = true
            terminalView.inputAssistantItem.leadingBarButtonGroups = []
            terminalView.inputAssistantItem.trailingBarButtonGroups = []

            // Wire up input callback
            terminalView.onInput = onInput

            // Create scroll view for horizontal and vertical scrolling.
            // The terminal view is sized to match the terminal content exactly.
            // When the terminal has more rows than fit on screen, the outer scroll
            // view provides vertical scrolling — SwiftTerm naturally maintains the
            // correct buffer size via processSizeChange because the view frame
            // matches the terminal dimensions.
            let scrollView = UIScrollView()
            scrollView.backgroundColor = .black
            scrollView.addSubview(terminalView)
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.showsVerticalScrollIndicator = false
            scrollView.alwaysBounceVertical = false
            scrollView.alwaysBounceHorizontal = false
            context.coordinator.outerScrollView = scrollView

            let widthConstraint = terminalView.widthAnchor.constraint(equalToConstant: exactWidth)
            widthConstraint.priority = .defaultHigh

            let heightConstraint = terminalView.heightAnchor.constraint(equalToConstant: exactHeight)
            heightConstraint.priority = .defaultHigh

            NSLayoutConstraint.activate([
                terminalView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                terminalView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                terminalView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                terminalView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                // Width: at least screen width, prefers exact terminal width
                terminalView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor),
                widthConstraint,
                // Height: at least screen height, prefers exact terminal height.
                // Short terminals fill the screen; tall terminals expand and the
                // outer scroll view provides vertical scrolling.
                terminalView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
                heightConstraint,
            ])

            // Store references
            context.coordinator.terminalView = terminalView
            context.coordinator.cellSize = cellSize
            context.coordinator.widthConstraint = widthConstraint
            context.coordinator.heightConstraint = heightConstraint

            // Wire up data callbacks
            terminalState.onData = { [weak terminalView] data in
                guard let terminalView else { return }
                terminalView.feedPreservingScroll([UInt8](data)[...])
            }

            // Scroll both the inner terminal (scrollback) and outer scroll view
            // (tall terminal overflow) to the bottom.
            terminalState.scrollToBottom = { [weak terminalView, weak scrollView] in
                guard let terminalView else { return }
                // Inner: scroll SwiftTerm's scrollback to bottom
                terminalView.scrollToBottom()
                // Outer: scroll to show the bottom of the terminal (where the cursor/prompt is)
                if let scrollView {
                    let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                    scrollView.contentOffset.y = maxY
                }
            }

            terminalState.onInitialContentLoaded = { [weak terminalState, weak terminalView] in
                Task { @MainActor in
                    guard let terminalView else { return }
                    // Delay to let layout settle after initial content feed
                    try? await Task.sleep(for: .milliseconds(100))
                    terminalState?.scrollToBottom?()
                    terminalView.preserveUserScroll = true
                }
            }

            terminalState.flushPendingContent()

            let coordinator = context.coordinator
            terminalState.onResize = { [weak coordinator] newWidth, newHeight in
                coordinator?.handleResize(width: newWidth, height: newHeight)
            }

            // Set initial keyboard state
            if isInteractive {
                terminalView.activateInput()
            }

            return scrollView
        }

        func updateUIView(_ scrollView: UIScrollView, context: Context) {
            // Toggle keyboard visibility based on interactive state
            guard let terminalView = context.coordinator.terminalView else { return }

            if isInteractive {
                terminalView.activateInput()
            } else {
                terminalView.deactivateInput()
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        @MainActor
        final class Coordinator {
            var terminalView: InteractiveTerminalView?
            weak var outerScrollView: UIScrollView?
            var cellSize: CGSize = .zero
            var widthConstraint: NSLayoutConstraint?
            var heightConstraint: NSLayoutConstraint?

            func handleResize(width: Int, height: Int) {
                guard let terminalView else { return }

                let newWidth = CGFloat(width) * cellSize.width + FontMetrics.horizontalBuffer
                widthConstraint?.constant = newWidth

                let newHeight = CGFloat(height) * cellSize.height
                heightConstraint?.constant = newHeight
            }
        }
    }

    // MARK: - Preview

    #Preview("Live Terminal") {
        let settings = IOSSettings()
        NavigationStack {
            LiveTerminalView(
                paneId: "%1",
                responseState: .init(get: { nil }, set: { _ in }),
                terminalTitle: .init(get: { nil }, set: { _ in }),
                isConnected: true,
                settings: settings,
                sendCommand: { _ in }
            )
        }
        .environment(ViewerRelayClient())
        .environment(settings)
    }
#endif
