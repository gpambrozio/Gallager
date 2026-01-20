import ClaudeSpyCommon
import SwiftUI

/// View for a single pane mirror window
struct MirrorWindowView: View {
    let paneInfo: PaneInfo
    @Environment(AppSettings.self) private var settings
    @Environment(TmuxService.self) private var tmuxService
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(PaneStreamManager.self) private var paneStreamManager

    @State private var subscriptionId: UUID?
    @State private var terminalController = TerminalController()
    @State private var streamState: StreamState = .disconnected
    @State private var streamWidth: Int?
    @State private var streamHeight: Int?

    /// The active Claude session for this pane, if any
    private var claudeSession: ClaudeSession? {
        windowManager.activeSessions[paneInfo.paneId]
    }

    /// Minimum frame size for the terminal based on character dimensions
    private var terminalMinSize: CGSize {
        let cols = streamWidth ?? paneInfo.width
        let rows = streamHeight ?? paneInfo.height
        let cellSize = FontMetrics.calculateCellSize(
            fontName: settings.fontName,
            fontSize: CGFloat(settings.fontSize)
        )
        return CGSize(
            width: CGFloat(cols) * cellSize.width + FontMetrics.horizontalBuffer,
            height: CGFloat(rows) * cellSize.height
        )
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                terminalView

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
            guard let updatedPane = newPanes.first(where: { $0.id == paneInfo.id }) else { return }
            // PaneStreamManager will forward dimension changes to subscribers
            paneStreamManager.updateDimensions(
                paneId: paneInfo.paneId,
                width: updatedPane.width,
                height: updatedPane.height
            )
        }
    }

    // MARK: - Subviews

    private var terminalView: some View {
        TerminalContainerView(terminalController: terminalController)
            .frame(
                minWidth: terminalMinSize.width,
                maxWidth: .infinity,
                minHeight: terminalMinSize.height,
                maxHeight: .infinity
            )
            .ignoresSafeArea(edges: .horizontal)
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
            Text("\(streamWidth ?? paneInfo.width)x\(streamHeight ?? paneInfo.height)")

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
        switch streamState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }

    private var statusText: String {
        switch streamState {
        case .connected:
            return "Connected"
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
        streamState = .connecting

        // Configure font from settings
        terminalController.fontName = settings.fontName
        terminalController.fontSize = CGFloat(settings.fontSize)
        terminalController.applyTheme(settings.theme)

        // Get pane dimensions first and resize terminal BEFORE feeding content
        do {
            let dims = try await tmuxService.getPaneDimensions(paneInfo.target)
            terminalController.resize(columns: dims.width, rows: dims.height)
            streamWidth = dims.width
            streamHeight = dims.height
        } catch {
            // Fall back to pane info dimensions
            terminalController.resize(columns: paneInfo.width, rows: paneInfo.height)
            streamWidth = paneInfo.width
            streamHeight = paneInfo.height
        }

        // Clear terminal and reset cursor position before receiving data
        terminalController.clear()

        // Subscribe to PaneStreamManager
        // Note: We can't use [weak self] since View is a struct. Use weak captures for class instances.
        let target = paneInfo.target

        var hasScrolledInitial = false

        do {
            let subId = try await paneStreamManager.subscribe(
                paneId: paneInfo.paneId,
                target: target,
                onData: { [weak terminalController] data in
                    guard let terminalController else { return }
                    let bytes = [UInt8](data)[...]
                    if !hasScrolledInitial {
                        // First data - feed, scroll to bottom, enable preservation
                        terminalController.terminalView.feed(byteArray: bytes)
                        terminalController.scrollToBottom()
                        terminalController.terminalView.preserveUserScroll = true
                        hasScrolledInitial = true
                    } else {
                        // Subsequent data - preserve user's scroll position
                        terminalController.terminalView.feedPreservingScroll(bytes)
                    }
                },
                onDimensionChange: { [weak terminalController, weak windowManager] newWidth, newHeight in
                    // Resize the terminal to match new pane dimensions
                    terminalController?.resize(columns: newWidth, rows: newHeight)
                    // Resize the window to match
                    windowManager?.resizeWindow(target: target, columns: newWidth, rows: newHeight)
                }
            )

            subscriptionId = subId
            streamState = .connected

            // Update dimensions from manager if available
            if let dims = paneStreamManager.dimensions(for: paneInfo.paneId) {
                streamWidth = dims.width
                streamHeight = dims.height
                terminalController.resize(columns: dims.width, rows: dims.height)
            }
        } catch {
            streamState = .error(error.localizedDescription)
        }
    }

    private func disconnect() async {
        if let subId = subscriptionId {
            await paneStreamManager.unsubscribe(subId)
            subscriptionId = nil
        }
        streamState = .disconnected
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}
