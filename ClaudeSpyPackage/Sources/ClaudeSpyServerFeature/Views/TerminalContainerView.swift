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
            coordinator?.updateMinimumSize(size)
        }

        return coordinator.scrollView
    }

    func updateNSView(_ nsView: ResizingScrollView, context: Context) {
        let coordinator = context.coordinator

        // Update settings if changed
        coordinator.updateSettings(settings)

        // Update minimum size on layout changes
        coordinator.updateMinimumSize(nsView.frame.size)

        // Check for dimension changes from tmux refresh
        if let currentPane = tmuxService.panes.first(where: { $0.id == paneInfo.id }) {
            coordinator.handleExternalDimensionChange(
                width: currentPane.width,
                height: currentPane.height
            )
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
        private var lastExternalHeight = 0

        private var fontName = "SF Mono"
        private var fontSize: CGFloat = 12
        private var minimumSize: NSSize = .zero

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
            lastExternalHeight = paneInfo.height

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

            // Get initial dimensions
            do {
                let dims = try await tmuxService.getPaneDimensions(paneInfo.target)
                resize(columns: dims.width, rows: dims.height)
            } catch {
                resize(columns: paneInfo.width, rows: paneInfo.height)
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
                        self?.resize(columns: newWidth, rows: newHeight)
                        windowManager?.resizeWindow(target: target, columns: newWidth, rows: newHeight)
                    }
                )

                subscriptionId = subId
                updateState(.connected)

                // Update dimensions from manager if available
                if let dims = paneStreamManager.dimensions(for: paneInfo.paneId) {
                    resize(columns: dims.width, rows: dims.height)
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

        func resize(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
            terminalView.getTerminal().resize(cols: columns, rows: rows)
            updateTerminalFrameSize()
            notifyStateChange()
        }

        func scrollToBottom() {
            terminalView.scroll(toPosition: 1)
        }

        func updateMinimumSize(_ size: NSSize) {
            minimumSize = size
            updateTerminalFrameSize()
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

        func handleExternalDimensionChange(width: Int, height: Int) {
            guard width != lastExternalWidth || height != lastExternalHeight else { return }
            lastExternalWidth = width
            lastExternalHeight = height

            // Forward to pane stream manager (it will notify via onDimensionChange callback)
            paneStreamManager?.updateDimensions(paneId: paneInfo?.paneId ?? "", width: width, height: height)
        }

        // MARK: Private Helpers

        private func updateTerminalFrameSize() {
            let cellSize = FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)

            // Calculate required size with buffer for SwiftTerm's internal scroller
            let width = CGFloat(columns) * cellSize.width + FontMetrics.horizontalBuffer
            let height = CGFloat(rows) * cellSize.height

            // Use the larger of terminal size or minimum (visible) size
            let finalWidth = max(width, minimumSize.width)
            let finalHeight = max(height, minimumSize.height)

            terminalView.frame = NSRect(origin: .zero, size: NSSize(width: finalWidth, height: finalHeight))
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
