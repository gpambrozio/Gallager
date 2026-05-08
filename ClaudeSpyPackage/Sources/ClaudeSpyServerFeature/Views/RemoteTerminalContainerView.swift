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
    /// When false, the terminal won't auto-grab focus on window add or window-becomes-key.
    /// Used in multi-pane layouts where multiple terminals share one window.
    var autoFocus = true
    /// Fires whenever this terminal becomes the window's first responder.
    /// Used to mirror focus back to the remote tmux via `SelectTmuxPane`.
    var onFocus: (@MainActor () -> Void)?

    @State private var streamState: RemoteStreamState = .connecting
    @State private var streamWidth = 80
    @State private var streamHeight = 24
    @State private var terminalTitle: String?
    @State private var imageUpload: ImageUploadState?

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
                autoFocus: autoFocus,
                onFocus: onFocus,
                onStateChange: { state, width, height in
                    streamState = state
                    streamWidth = width
                    streamHeight = height
                },
                onTitleChange: { title in
                    terminalTitle = title
                },
                onImagePaste: { image in
                    startImageUpload(image)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .center) {
                if let imageUpload {
                    ImageUploadOverlay(state: imageUpload, onCancel: cancelImageUpload)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: imageUpload?.id)

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
        // Tear down any in-flight upload or auto-dismiss timer when the view
        // is removed from the hierarchy (e.g. window closed mid-failure),
        // so detached tasks don't survive the view that owned them.
        .onDisappear {
            cancelImageUpload()
        }
    }

    private func startImageUpload(_ image: ClipboardImage) {
        // Cancel any in-flight upload before starting a new one. Two rapid
        // Cmd+V presses should not race two SendImage commands at the host,
        // and a rapid second paste should also short-circuit any in-flight
        // failure auto-dismiss timer.
        imageUpload?.cancel()

        // Refuse images that won't fit the relay's WebSocket frame budget
        // before we even open the connection — the user gets a clear error
        // instead of a silent disconnect on the wire.
        if image.data.count > SendImage.maxRawBytes {
            let mb = Double(image.data.count) / (1_024 * 1_024)
            let message = String(
                format: "Image is %.1f MB. The relay only supports images under %d KB.",
                mb,
                SendImage.maxRawBytes / 1_024
            )
            imageUpload = .failed(
                sizeBytes: image.data.count,
                message: message,
                dismissTask: dismissTimer(after: .seconds(4))
            )
            return
        }

        let sizeBytes = image.data.count
        let task = Task { @MainActor in
            let result = await connection.relayClient.sendCommand(
                SendImage(data: image.data, format: image.format),
                paneId: paneId,
                timeout: 30
            )
            // Treat cancellation as silent — the user already saw the popover
            // dismiss when they hit Cancel and we don't want a transient
            // "failed" flash to take its place.
            if Task.isCancelled { return }
            switch result {
            case .success:
                imageUpload = nil
            case let .failure(error):
                if error is CancellationError {
                    imageUpload = nil
                } else {
                    imageUpload = .failed(
                        sizeBytes: sizeBytes,
                        message: error.localizedDescription,
                        dismissTask: dismissTimer(after: .seconds(3))
                    )
                }
            }
        }
        imageUpload = .uploading(sizeBytes: sizeBytes, task: task)
    }

    /// Spawns an auto-dismiss timer that clears `imageUpload` after the given
    /// duration. Returned so the caller can cancel it if a new upload starts
    /// before the timer fires.
    private func dismissTimer(after delay: Duration) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled {
                imageUpload = nil
            }
        }
    }

    private func cancelImageUpload() {
        imageUpload?.cancel()
        imageUpload = nil
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

// MARK: - Image Upload State

/// Transient state for an in-flight or just-failed image paste upload.
/// Each case owns the task whose cancellation will tear down the matching UI
/// — the in-flight relay request for `.uploading`, the auto-dismiss timer for
/// `.failed`. We carry a per-state `id` so SwiftUI's `.animation(value:)` can
/// drive a transition between consecutive uploads without forcing Equatable
/// on `Task`, which is a reference type.
private enum ImageUploadState {
    case uploading(id: UUID, sizeBytes: Int, task: Task<Void, Never>)
    case failed(id: UUID, sizeBytes: Int, message: String, dismissTask: Task<Void, Never>)

    static func uploading(sizeBytes: Int, task: Task<Void, Never>) -> ImageUploadState {
        .uploading(id: UUID(), sizeBytes: sizeBytes, task: task)
    }

    static func failed(
        sizeBytes: Int,
        message: String,
        dismissTask: Task<Void, Never>
    ) -> ImageUploadState {
        .failed(id: UUID(), sizeBytes: sizeBytes, message: message, dismissTask: dismissTask)
    }

    var id: UUID {
        switch self {
        case let .uploading(id, _, _),
             let .failed(id, _, _, _):
            id
        }
    }

    var sizeBytes: Int {
        switch self {
        case let .uploading(_, sizeBytes, _),
             let .failed(_, sizeBytes, _, _):
            sizeBytes
        }
    }

    var failureMessage: String? {
        if case let .failed(_, _, message, _) = self { return message }
        return nil
    }

    func cancel() {
        switch self {
        case let .uploading(_, _, task):
            task.cancel()
        case let .failed(_, _, _, dismissTask):
            dismissTask.cancel()
        }
    }
}

// MARK: - Image Upload Overlay

/// Popover-style overlay shown while an image paste is being forwarded to the
/// remote host. Includes a cancel button so a user can abort large uploads.
private struct ImageUploadOverlay: View {
    let state: ImageUploadState
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if state.failureMessage == nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Symbols.exclamationmarkTriangle.image
                    .fontWeight(.bold)
                    .foregroundStyle(.yellow)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(state.failureMessage == nil ? "Sending image…" : "Image paste failed")
                    .font(.headline)
                Text(state.failureMessage ?? sizeDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if state.failureMessage == nil {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("image-upload-cancel")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator)
        }
        .shadow(radius: 8, y: 2)
        .accessibilityIdentifier("image-upload-overlay")
    }

    private var sizeDescription: String {
        let bytes = Double(state.sizeBytes)
        if bytes >= 1_024 * 1_024 {
            return String(format: "%.1f MB", bytes / (1_024 * 1_024))
        }
        if bytes >= 1_024 {
            return String(format: "%.0f KB", bytes / 1_024)
        }
        return "\(state.sizeBytes) B"
    }
}

#Preview("Uploading") {
    ImageUploadOverlay(
        state: .uploading(sizeBytes: 412_000, task: Task { }),
        onCancel: { }
    )
    .padding(40)
    .background(Color.gray.opacity(0.3))
}

#Preview("Failed") {
    ImageUploadOverlay(
        state: .failed(
            sizeBytes: 1_572_864,
            message: "Image is 1.5 MB. The relay only supports images under 700 KB.",
            dismissTask: Task { }
        ),
        onCancel: { }
    )
    .padding(40)
    .background(Color.gray.opacity(0.3))
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
    let autoFocus: Bool
    let onFocus: (@MainActor () -> Void)?
    let onStateChange: @MainActor (RemoteStreamState, Int, Int) -> Void
    let onTitleChange: @MainActor (String) -> Void
    let onImagePaste: @MainActor (ClipboardImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InteractiveTerminalView {
        let coordinator = context.coordinator

        // Configure auto-focus before starting (must be set before viewDidMoveToWindow fires).
        coordinator.terminalView.autoFocusEnabled = autoFocus

        coordinator.start(
            paneId: paneId,
            connection: connection,
            settings: settings,
            onStateChange: onStateChange,
            onTitleChange: onTitleChange
        )
        coordinator.terminalView.isEditorActive = isEditorActive
        coordinator.terminalView.onBecomeFirstResponder = onFocus
        // Route image pastes through the SwiftUI parent so the upload state
        // and cancel popover live alongside the terminal view in the body
        // hierarchy. Returning `true` consumes the paste — `Ctrl+V` is sent
        // by the host once it has the bytes on its pasteboard.
        coordinator.terminalView.onImagePaste = { image in
            onImagePaste(image)
            return true
        }

        return coordinator.terminalView
    }

    func updateNSView(_ nsView: InteractiveTerminalView, context: Context) {
        context.coordinator.updateSettings(settings)
        context.coordinator.updateContainerSize(nsView.frame.size)

        // Re-bind focus and paste callbacks so closures captured here reflect
        // the current parent state on every layout pass.
        nsView.onBecomeFirstResponder = onFocus
        nsView.onImagePaste = { image in
            onImagePaste(image)
            return true
        }

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
            terminalView.onImagePaste = nil

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
