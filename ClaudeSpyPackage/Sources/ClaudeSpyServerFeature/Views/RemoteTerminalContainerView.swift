import AppKit
import ClaudeSpyCommon
import ClaudeSpyNetworking
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
    var onStreamEnd: (() -> Void)?

    @State private var streamState: RemoteStreamState = .connecting
    @State private var streamWidth = 80
    @State private var streamHeight = 24

    var body: some View {
        VStack(spacing: 0) {
            RemoteTerminalNSView(
                paneId: paneId,
                connection: connection,
                settings: settings,
                onStateChange: { state, width, height in
                    streamState = state
                    streamWidth = width
                    streamHeight = height
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if settings.showStatusBar {
                statusBar
            }
        }
        .navigationTitle("Remote: \(hostName) - \(paneId)")
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
    let onStateChange: @MainActor (RemoteStreamState, Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InteractiveTerminalView {
        let coordinator = context.coordinator

        coordinator.start(
            paneId: paneId,
            connection: connection,
            settings: settings,
            onStateChange: onStateChange
        )

        return coordinator.terminalView
    }

    func updateNSView(_ nsView: InteractiveTerminalView, context: Context) {
        context.coordinator.updateSettings(settings)
        context.coordinator.updateContainerSize(nsView.frame.size)
    }

    static func dismantleNSView(_ nsView: InteractiveTerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: @unchecked Sendable {
        let terminalView: InteractiveTerminalView

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

        // Serializes key sends so concurrent onInput callbacks don't race
        private var pendingKeyTask: Task<Void, Never>?

        init() {
            self.terminalView = InteractiveTerminalView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600)
            )
            applyDarkTheme()
        }

        func start(
            paneId: String,
            connection: ViewerConnection,
            settings: AppSettings,
            onStateChange: @MainActor @escaping (RemoteStreamState, Int, Int) -> Void
        ) {
            self.paneId = paneId
            self.connection = connection
            self.onStateChange = onStateChange

            updateFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            applyTheme(settings.theme)

            // Wire keystroke forwarding via relay
            terminalView.onInput = { [weak self] keys in
                guard let self, let connection = self.connection else { return }
                self.enqueueKeySend(keys: keys, connection: connection)
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
            pendingKeyTask?.cancel()
            pendingKeyTask = nil

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

        /// Enqueue a keystroke send, chaining on any pending send to preserve ordering.
        private func enqueueKeySend(keys: [TmuxKey], connection: ViewerConnection) {
            guard let paneId else { return }
            let previous = pendingKeyTask
            pendingKeyTask = Task {
                _ = await previous?.value
                _ = await connection.relayClient.sendCommand(
                    SendKeystroke(keys),
                    paneId: paneId
                )
            }
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

            case .streamEnd:
                updateState(.disconnected)
            }
        }

        // MARK: - Settings

        func updateSettings(_ settings: AppSettings) {
            updateFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            applyTheme(settings.theme)
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
