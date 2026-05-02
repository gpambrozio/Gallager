import AppKit
import ClaudeSpyCommon
import ClaudeSpyNetworking
import Dependencies
import SwiftTerm
import SwiftUI

// MARK: - Remote Terminal Container View

/// Displays a live terminal from a remote host, streaming data via the relay server.
///
/// This is the macOS counterpart to the iOS `LiveTerminalView`, using the same
/// `ViewerRelayClient` for terminal streaming and keystroke forwarding.
struct RemoteTerminalContainerView: View {
    let paneId: String
    let hostName: String
    let connection: ViewerConnection
    let settings: AppSettings
    /// The stable window key used by MirrorWindowManager to track this window
    var windowKey: String?
    var onStreamEnd: (() -> Void)?
    /// Whether to show the per-pane status bar (defaults to using the app setting)
    var showStatusBar: Bool?
    /// True when a prompt editor overlay is active above this terminal.
    /// Suppresses keyboard forwarding to the remote tmux pane so the editor gets input.
    var isEditorActive = false

    @State private var streamState: RemoteStreamState = .connecting
    @State private var streamWidth = 80
    @State private var streamHeight = 24
    @State private var terminalTitle: String?

    private var windowTitle: String {
        if let terminalTitle, !terminalTitle.isEmpty {
            return terminalTitle
        }
        return "Remote: \(hostName) - \(paneId)"
    }

    var body: some View {
        VStack(spacing: 0) {
            RemoteTerminalNSView(
                paneId: paneId,
                connection: connection,
                settings: settings,
                isEditorActive: isEditorActive,
                onStateChange: { state, width, height in
                    streamState = state
                    streamWidth = width
                    streamHeight = height
                },
                onTitleChange: { title in
                    terminalTitle = title
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showStatusBar ?? settings.showStatusBar {
                statusBar
            }
        }
        // Only set the navigation title when this view owns its window
        // (i.e. used as a standalone mirror window). When embedded as a tile in
        // RemoteWindowPaneLayoutView, the parent's title must remain in effect.
        .standaloneNavigationTitle(windowTitle, when: windowKey != nil)
        .onChange(of: terminalTitle) { _, newTitle in
            // Update the NSWindow title to match (SwiftUI navigationTitle doesn't sync to NSWindow)
            guard let newTitle, !newTitle.isEmpty, let windowKey else { return }
            // Use the stable window key for lookup instead of searching by title contents,
            // which would break after the first title update changes the window title.
            NSApp.windows.first { $0.identifier?.rawValue == windowKey }?.title = newTitle
        }
        .onChange(of: streamState) { _, newState in
            if newState == .disconnected {
                onStreamEnd?()
            }
        }
    }

    private var statusBar: some View {
        HStack {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
            }

            Divider()
                .frame(height: 12)

            Text("\(streamWidth)x\(streamHeight)")

            Spacer()

            Text(hostName)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusColor: SwiftUI.Color {
        switch streamState {
        case .streaming: .green
        case .connecting: .orange
        case .disconnected: .gray
        case .error: .red
        }
    }

    private var statusText: String {
        switch streamState {
        case .streaming: "Streaming"
        case .connecting: "Connecting..."
        case .disconnected: "Disconnected"
        case let .error(message): "Error: \(message)"
        }
    }
}

// MARK: - Stream State

enum RemoteStreamState: Equatable {
    case connecting
    case streaming
    case disconnected
    case error(String)
}

// MARK: - NSViewRepresentable

/// NSViewRepresentable that wraps an InteractiveTerminalView for remote terminal streaming.
private struct RemoteTerminalNSView: NSViewRepresentable {
    let paneId: String
    let connection: ViewerConnection
    let settings: AppSettings
    let isEditorActive: Bool
    let onStateChange: @MainActor (RemoteStreamState, Int, Int) -> Void
    let onTitleChange: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InteractiveTerminalView {
        let coordinator = context.coordinator

        coordinator.start(
            paneId: paneId,
            connection: connection,
            settings: settings,
            onStateChange: onStateChange,
            onTitleChange: onTitleChange
        )
        coordinator.terminalView.isEditorActive = isEditorActive

        return coordinator.terminalView
    }

    func updateNSView(_ nsView: InteractiveTerminalView, context: Context) {
        context.coordinator.updateSettings(settings)
        context.coordinator.updateContainerSize(nsView.frame.size)

        // Update editor-active flag. When the editor just closed, restore first
        // responder to the terminal so typing resumes without a manual click.
        let wasEditorActive = nsView.isEditorActive
        nsView.isEditorActive = isEditorActive
        if wasEditorActive, !isEditorActive {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    static func dismantleNSView(_ nsView: InteractiveTerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: @unchecked Sendable {
        let terminalView: InteractiveTerminalView
        @Dependency(ClipboardClient.self) private var clipboard

        private var paneId: String?
        private weak var connection: ViewerConnection?
        private var streamSubscriptionId: UUID?
        private var streamState: RemoteStreamState = .connecting
        private var columns = 80
        private var rows = 24
        private var fontName: String?
        private var fontSize: CGFloat?
        private var containerSize: NSSize = .zero
        private var hasReceivedInitialState = false
        private var streamTask: Task<Void, Never>?
        private var onStateChange: (@MainActor (RemoteStreamState, Int, Int) -> Void)?
        private var onTitleChange: (@MainActor (String) -> Void)?

        private var keystrokeDebouncer: KeystrokeDebouncer?

        init() {
            self.terminalView = InteractiveTerminalView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600)
            )
            // Disable custom block glyph rendering — see TerminalContainerView.init for details.
            terminalView.customBlockGlyphs = false
            applyDarkTheme()
        }

        func start(
            paneId: String,
            connection: ViewerConnection,
            settings: AppSettings,
            onStateChange: @MainActor @escaping (RemoteStreamState, Int, Int) -> Void,
            onTitleChange: @MainActor @escaping (String) -> Void
        ) {
            self.paneId = paneId
            self.connection = connection
            self.onStateChange = onStateChange

            terminalView.terminalAccessibilityIdentifier = "terminal-\(paneId)"
            self.onTitleChange = onTitleChange

            updateFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            applyTheme(settings.theme)

            // Wire keystroke forwarding via relay
            terminalView.onInput = { [weak self] keys in
                guard let self, let connection = self.connection else { return }
                self.enqueueKeySend(keys: keys, connection: connection)
            }

            // Wire raw input (mouse escape sequences) forwarding via relay
            terminalView.onRawInput = { [weak self] data in
                guard let self, let connection = self.connection else { return }
                self.enqueueRawInput(data: data, connection: connection)
            }

            // Subscribe to terminal stream for this specific pane
            let subscriptionId = connection.subscribeToTerminalStream(paneId: paneId) { [weak self] message in
                self?.handleStreamMessage(message)
            }
            streamSubscriptionId = subscriptionId

            // Start streaming
            streamTask = Task {
                updateState(.connecting)
                let result = await connection.relayClient.sendCommand(
                    StartTerminalStream(),
                    paneId: paneId
                )

                switch result {
                case .success:
                    break // Stream messages will arrive via subscription
                case let .failure(error):
                    updateState(.error(error.localizedDescription))
                }
            }
        }

        func stop() {
            terminalView.onRawInput = nil
            terminalView.onInput = nil

            keystrokeDebouncer?.cancelAll()
            keystrokeDebouncer = nil

            streamTask?.cancel()
            streamTask = nil

            // Unsubscribe from terminal stream
            if let subscriptionId = streamSubscriptionId {
                connection?.unsubscribeFromTerminalStream(subscriptionId)
                streamSubscriptionId = nil
            }

            // Tell the host to stop streaming this pane
            if let connection, let paneId {
                let relayClient = connection.relayClient
                let id = paneId
                Task {
                    _ = await relayClient.sendCommand(StopTerminalStream(), paneId: id)
                }
            }
        }

        // MARK: - Key Sends

        /// Accumulates rapid keystrokes and flushes them as a single command after a short delay.
        private func enqueueKeySend(keys: [TmuxKey], connection: ViewerConnection) {
            guard let paneId else { return }
            if keystrokeDebouncer == nil {
                keystrokeDebouncer = KeystrokeDebouncer(paneId: paneId, relayClient: connection.relayClient)
            }
            keystrokeDebouncer?.enqueue(keys)
        }

        /// Forwards raw bytes (mouse escape sequences) to the host via the relay.
        private func enqueueRawInput(data: Data, connection: ViewerConnection) {
            guard let paneId else { return }
            if keystrokeDebouncer == nil {
                keystrokeDebouncer = KeystrokeDebouncer(paneId: paneId, relayClient: connection.relayClient)
            }
            keystrokeDebouncer?.enqueueRawInput(data)
        }

        // MARK: - Stream Message Handling

        private func handleStreamMessage(_ message: TerminalStreamMessage) {
            switch message.updateType {
            case let .initialState(state):
                columns = state.width
                rows = state.height
                terminalView.getTerminal().resize(cols: columns, rows: rows)
                updateTerminalFrameSize()

                if let data = Data(base64Encoded: state.contentBase64) {
                    let bytes = [UInt8](data)[...]
                    terminalView.feed(byteArray: bytes)
                    terminalView.scroll(toPosition: 1)
                    terminalView.preserveUserScroll = true
                }

                hasReceivedInitialState = true
                updateState(.streaming)

            case let .dataChunk(chunk):
                guard hasReceivedInitialState else { return }
                if let data = Data(base64Encoded: chunk.dataBase64) {
                    let bytes = [UInt8](data)[...]
                    terminalView.feedPreservingScroll(bytes)
                }

            case let .dimensionChange(change):
                columns = change.width
                rows = change.height
                terminalView.getTerminal().resize(cols: columns, rows: rows)
                updateTerminalFrameSize()
                notifyStateChange()

            case let .titleChange(change):
                onTitleChange?(change.title)

            case .notification:
                // Terminal notifications are handled globally by PaneStreamManager
                break

            case let .clipboardUpdate(update):
                applyClipboardIfFocused(update.content)

            case .streamEnd:
                updateState(.disconnected)
            }
        }

        // MARK: - Clipboard

        /// Sets the system clipboard if this terminal's window is the key window
        /// and the app is active.
        private func applyClipboardIfFocused(_ content: String) {
            guard NSApp.isActive else { return }
            // Check if the terminal view's window is key
            guard terminalView.window?.isKeyWindow == true else { return }
            clipboard.setString(content)
        }

        // MARK: - Settings

        func updateSettings(_ settings: AppSettings) {
            updateFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            applyTheme(settings.theme)
            terminalView.autoCopyOnSelect = settings.autoCopyOnSelect
        }

        func updateContainerSize(_ size: NSSize) {
            guard size != containerSize else { return }
            containerSize = size
        }

        private func updateFont(name: String, size: CGFloat) {
            guard name != fontName || size != fontSize else { return }
            fontName = name
            fontSize = size

            let font = NSFont(name: name, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            terminalView.font = font
            updateTerminalFrameSize()
        }

        func applyTheme(_ theme: TerminalTheme) {
            switch theme {
            case .defaultDark,
                 .solarizedDark:
                applyDarkTheme()
            case .defaultLight,
                 .solarizedLight:
                applyLightTheme()
            }
        }

        private func applyDarkTheme() {
            terminalView.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
            terminalView.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        }

        private func applyLightTheme() {
            terminalView.nativeForegroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            terminalView.nativeBackgroundColor = NSColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        }

        // MARK: - Private Helpers

        private func updateTerminalFrameSize() {
            let optimalSize = terminalView.getOptimalFrameSize().size
            terminalView.setTerminalSize(optimalSize)
        }

        private func updateState(_ state: RemoteStreamState) {
            streamState = state
            notifyStateChange()
        }

        private func notifyStateChange() {
            onStateChange?(streamState, columns, rows)
        }
    }
}
