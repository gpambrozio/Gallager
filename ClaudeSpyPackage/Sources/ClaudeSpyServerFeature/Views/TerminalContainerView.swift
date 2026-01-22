import AppKit
import ClaudeSpyCommon
import SwiftTerm
import SwiftUI

// MARK: - State Change Callback

/// Callback type for reporting terminal state changes to parent view
typealias TerminalStateChangeHandler = @MainActor (StreamState, Int, Int) -> Void

// MARK: - Resizing Scroll View

/// A scroll view that notifies when its frame changes
final class ResizingScrollView: NSScrollView {
    var onResize: ((NSSize) -> Void)?

    override func layout() {
        super.layout()
        onResize?(frame.size)
    }
}

// MARK: - Terminal Container View

/// A self-contained SwiftUI view that mirrors a tmux pane.
///
/// This view handles everything internally:
/// - Creates and manages the terminal views (scroll view + terminal)
/// - Connects to the pane stream
/// - Feeds data to the terminal
/// - Handles dimension changes
/// - Reports state back to parent via callback
struct TerminalContainerView: NSViewRepresentable {
    let paneInfo: PaneInfo
    let onStateChange: TerminalStateChangeHandler?

    @Environment(AppSettings.self) private var settings
    @Environment(TmuxService.self) private var tmuxService
    @Environment(PaneStreamManager.self) private var paneStreamManager
    @Environment(MirrorWindowManager.self) private var windowManager

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ResizingScrollView {
        let coordinator = context.coordinator

        // Start the coordinator with all dependencies
        coordinator.start(
            paneInfo: paneInfo,
            tmuxService: tmuxService,
            paneStreamManager: paneStreamManager,
            windowManager: windowManager,
            settings: settings,
            onStateChange: onStateChange
        )

        // Set up resize callback
        coordinator.scrollView.onResize = { [weak coordinator] size in
            coordinator?.updateContainerSize(size)
        }

        return coordinator.scrollView
    }

    func updateNSView(_ nsView: ResizingScrollView, context: Context) {
        let coordinator = context.coordinator

        // Update settings if changed
        coordinator.updateSettings(settings)

        // Update container size on layout changes
        coordinator.updateContainerSize(nsView.frame.size)

        // Check for column changes from tmux refresh (rows are dynamic)
        if let currentPane = tmuxService.panes.first(where: { $0.id == paneInfo.id }) {
            coordinator.handleExternalColumnChange(width: currentPane.width)
        }
    }

    static func dismantleNSView(_ nsView: ResizingScrollView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: @unchecked Sendable {
        // MARK: Views

        let scrollView: ResizingScrollView
        let terminalView: ReadOnlyTerminalView

        // MARK: Services (held for lifetime)

        private weak var paneStreamManager: PaneStreamManager?
        private weak var windowManager: MirrorWindowManager?

        // MARK: State

        private var paneInfo: PaneInfo?
        private var subscriptionId: UUID?
        private var streamState: StreamState = .disconnected
        private var columns = 80
        private var rows = 24
        private var lastExternalWidth = 0

        private var fontName = "SF Mono"
        private var fontSize: CGFloat = 12
        private var containerSize: NSSize = .zero

        private var onStateChange: TerminalStateChangeHandler?

        // Track initial scroll state
        private var hasScrolledInitial = false

        // MARK: Initialization

        init() {
            // Create terminal view
            self.terminalView = ReadOnlyTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

            // Create scroll view to contain the terminal
            self.scrollView = ResizingScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

            setupScrollView()
            setupTerminal()
        }

        private func setupScrollView() {
            scrollView.documentView = terminalView
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            scrollView.scrollerStyle = .overlay
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.autoresizesSubviews = false
            terminalView.autoresizingMask = []
        }

        private func setupTerminal() {
            applyDarkTheme()
        }

        // MARK: Lifecycle

        func start(
            paneInfo: PaneInfo,
            tmuxService: TmuxService,
            paneStreamManager: PaneStreamManager,
            windowManager: MirrorWindowManager,
            settings: AppSettings,
            onStateChange: TerminalStateChangeHandler?
        ) {
            self.paneInfo = paneInfo
            self.paneStreamManager = paneStreamManager
            self.windowManager = windowManager
            self.onStateChange = onStateChange
            lastExternalWidth = paneInfo.width

            // Apply initial settings
            updateFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            applyTheme(settings.theme)

            // Start connection
            Task {
                await connect(paneInfo: paneInfo, tmuxService: tmuxService)
            }
        }

        func stop() {
            guard let subId = subscriptionId else { return }
            let manager = paneStreamManager
            Task {
                await manager?.unsubscribe(subId)
            }
            subscriptionId = nil
            // Don't call updateState here - the view is being dismantled
            // and updating @State during teardown causes a crash
        }

        // MARK: Connection

        private func connect(paneInfo: PaneInfo, tmuxService: TmuxService) async {
            updateState(.connecting)

            // Get initial columns from tmux (rows are dynamic based on container)
            do {
                let dims = try await tmuxService.getPaneDimensions(paneInfo.target)
                updateColumns(dims.width)
            } catch {
                updateColumns(paneInfo.width)
            }

            clear()

            // Subscribe to stream
            guard let paneStreamManager else {
                updateState(.error("Stream manager unavailable"))
                return
            }

            do {
                let target = paneInfo.target
                let subId = try await paneStreamManager.subscribe(
                    paneId: paneInfo.paneId,
                    target: target,
                    onData: { [weak self] data in
                        self?.handleData(data)
                    },
                    onDimensionChange: { [weak self, weak windowManager] newWidth, newHeight in
                        self?.updateColumns(newWidth)
                        windowManager?.resizeWindow(target: target, columns: newWidth, rows: newHeight)
                    }
                )

                subscriptionId = subId
                updateState(.connected)

                // Update columns from manager if available
                if let dims = paneStreamManager.dimensions(for: paneInfo.paneId) {
                    updateColumns(dims.width)
                }
            } catch {
                updateState(.error(error.localizedDescription))
            }
        }

        // MARK: Data Handling

        private func handleData(_ data: Data) {
            let bytes = [UInt8](data)[...]

            if !hasScrolledInitial {
                // First data - feed, scroll to bottom, enable preservation
                terminalView.feed(byteArray: bytes)
                scrollToBottom()
                terminalView.preserveUserScroll = true
                hasScrolledInitial = true
            } else {
                // Subsequent data - preserve user's scroll position
                terminalView.feedPreservingScroll(bytes)
            }
        }

        // MARK: Terminal Operations

        func feed(_ data: Data) {
            let bytes = [UInt8](data)
            terminalView.feed(byteArray: bytes[...])
        }

        func clear() {
            feed(Data("\u{1b}[2J\u{1b}[H".utf8))
        }

        /// Updates columns from tmux. Rows are calculated dynamically from container height.
        func updateColumns(_ newColumns: Int) {
            guard newColumns != columns else { return }
            columns = newColumns
            terminalView.getTerminal().resize(cols: columns, rows: rows)
            updateTerminalFrameSize()
            notifyStateChange()
        }

        func scrollToBottom() {
            terminalView.scroll(toPosition: 1)
        }

        func updateContainerSize(_ size: NSSize) {
            guard size != containerSize else { return }
            containerSize = size
            recalculateRowsAndResize()
        }

        // MARK: Settings

        func updateSettings(_ settings: AppSettings) {
            updateFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            applyTheme(settings.theme)
        }

        private func updateFont(name: String, size: CGFloat) {
            guard name != fontName || size != fontSize else { return }
            fontName = name
            fontSize = size

            let font = NSFont(name: fontName, size: fontSize)
                ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
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
            let bgColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            terminalView.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
            terminalView.nativeBackgroundColor = bgColor
            scrollView.backgroundColor = bgColor
        }

        private func applyLightTheme() {
            let bgColor = NSColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
            terminalView.nativeForegroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            terminalView.nativeBackgroundColor = bgColor
            scrollView.backgroundColor = bgColor
        }

        // MARK: External Dimension Changes

        func handleExternalColumnChange(width: Int) {
            guard width != lastExternalWidth else { return }
            lastExternalWidth = width

            // Forward to pane stream manager (it will notify via onDimensionChange callback)
            // Note: rows are dynamic based on container, so we pass current rows
            paneStreamManager?.updateDimensions(paneId: paneInfo?.paneId ?? "", width: width, height: rows)
        }

        // MARK: Private Helpers

        /// Recalculates rows based on container height and resizes terminal
        private func recalculateRowsAndResize() {
            let cellSize = FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)
            guard cellSize.height > 0 else { return }

            // Calculate rows from container height
            let newRows = max(1, Int(containerSize.height / cellSize.height))

            if newRows != rows {
                rows = newRows
                terminalView.getTerminal().resize(cols: columns, rows: rows)
                notifyStateChange()
            }

            updateTerminalFrameSize()
        }

        private func updateTerminalFrameSize() {
            let cellSize = FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)

            // Width: fixed to terminal columns (tmux width)
            let width = CGFloat(columns) * cellSize.width + FontMetrics.horizontalBuffer

            // Height: fill container (rows are dynamic based on container)
            let height = max(CGFloat(rows) * cellSize.height, containerSize.height)

            terminalView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        }

        private func updateState(_ state: StreamState) {
            streamState = state
            notifyStateChange()
        }

        private func notifyStateChange() {
            onStateChange?(streamState, columns, rows)
        }
    }
}
