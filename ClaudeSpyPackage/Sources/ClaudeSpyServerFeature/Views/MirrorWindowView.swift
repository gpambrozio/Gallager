import ClaudeSpyCommon
import SwiftUI

/// View for a single pane mirror window
struct MirrorWindowView: View {
    let paneInfo: PaneInfo
    @Environment(AppSettings.self) private var settings
    @Environment(TmuxService.self) private var tmuxService
    @Environment(MirrorWindowManager.self) private var windowManager

    @State private var paneStream: PaneStream?
    @State private var terminalController = TerminalController()
    @State private var showJumpToBottom = false

    /// The active Claude session for this pane, if any
    private var claudeSession: ClaudeSession? {
        windowManager.activeSessions[paneInfo.paneId]
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Terminal view
                TerminalContainerView(terminalController: terminalController)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .horizontal)

                // Jump to bottom button (shown when scrolled up)
                if showJumpToBottom {
                    jumpToBottomBar
                }

                // Status bar
                if settings.showStatusBar {
                    statusBar
                }
            }

            // Claude session events overlay
            if let session = claudeSession {
                SessionEventsOverlay(session: session)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                pauseResumeButton
            }
        }
        .navigationTitle("Mirror: \(paneInfo.paneId) (\(paneInfo.target))")
        .task {
            await connectToPane()
        }
        .onDisappear {
            Task {
                await disconnect()
            }
        }
        .onChange(of: settings.fontName) { _, newValue in
            terminalController.fontName = newValue
        }
        .onChange(of: settings.fontSize) { _, newValue in
            terminalController.fontSize = CGFloat(newValue)
        }
        .onChange(of: settings.theme) { _, newValue in
            terminalController.applyTheme(newValue)
        }
        .onChange(of: tmuxService.panes) { _, newPanes in
            // Check if our pane's dimensions changed during global refresh
            guard let updatedPane = newPanes.first(where: { $0.id == paneInfo.id }),
                  let stream = paneStream else { return }
            // updateDimensions will trigger onDimensionChange callback if dimensions changed
            stream.updateDimensions(width: updatedPane.width, height: updatedPane.height)
        }
    }

    // MARK: - Subviews

    private var pauseResumeButton: some View {
        Button {
            togglePause()
        } label: {
            if paneStream?.state == .paused {
                Symbols.play.image
            } else {
                Symbols.pause.image
            }
        }
        .help(paneStream?.state == .paused ? "Resume" : "Pause")
        .disabled(paneStream?.state.isActive != true)
    }

    private var jumpToBottomBar: some View {
        HStack {
            Spacer()
            Button {
                terminalController.scrollToBottom()
                showJumpToBottom = false
            } label: {
                Label("Jump to Bottom", symbol: .arrowDown)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
        .padding(8)
        .background(.bar)
    }

    private var statusBar: some View {
        HStack {
            // Connection status indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
            }

            Divider()
                .frame(height: 12)

            // Dimensions
            Text("\(paneStream?.width ?? paneInfo.width)x\(paneStream?.height ?? paneInfo.height)")

            Divider()
                .frame(height: 12)

            // Scrollback info
            Text("Scrollback: \(formatNumber(paneStream?.scrollbackLines ?? 0)) lines")

            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Computed Properties

    private var statusColor: Color {
        switch paneStream?.state ?? .disconnected {
        case .connected:
            return .green
        case .paused:
            return .yellow
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }

    private var statusText: String {
        switch paneStream?.state ?? .disconnected {
        case .connected:
            return "Connected"
        case .paused:
            return "Paused"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Disconnected"
        case let .error(message):
            return "Error: \(message)"
        }
    }

    // MARK: - Actions

    private func connectToPane() async {
        let stream = PaneStream(target: paneInfo.target, tmuxService: tmuxService)
        paneStream = stream

        // Configure font from settings
        terminalController.fontName = settings.fontName
        terminalController.fontSize = CGFloat(settings.fontSize)
        terminalController.applyTheme(settings.theme)

        // Get pane dimensions first and resize terminal BEFORE feeding content
        do {
            let dims = try await tmuxService.getPaneDimensions(paneInfo.target)
            terminalController.resize(columns: dims.width, rows: dims.height)
        } catch {
            // Fall back to pane info dimensions
            terminalController.resize(columns: paneInfo.width, rows: paneInfo.height)
        }

        // Clear terminal and reset cursor position before receiving data
        terminalController.clear()

        // Set up data handler
        stream.onData = { data in
            terminalController.feed(data)
        }

        // Set up dimension change handler
        stream.onDimensionChange = { [weak windowManager, weak terminalController] newWidth, newHeight in
            // Safety check: don't resize if terminal is being torn down
            guard let terminalController else { return }
            // Resize the terminal to match new pane dimensions
            terminalController.resize(columns: newWidth, rows: newHeight)
            // Resize the window to match
            windowManager?.resizeWindow(target: paneInfo.target, columns: newWidth, rows: newHeight)
        }

        do {
            try await stream.connect()
            // Update dimensions if they changed
            terminalController.resize(columns: stream.width, rows: stream.height)
        } catch {
            // Error is captured in stream state
        }
    }

    private func disconnect() async {
        await paneStream?.disconnect()
        paneStream = nil
    }

    private func togglePause() {
        guard let stream = paneStream else { return }
        if stream.state == .paused {
            stream.resume()
        } else if stream.state == .connected {
            stream.pause()
        }
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}
