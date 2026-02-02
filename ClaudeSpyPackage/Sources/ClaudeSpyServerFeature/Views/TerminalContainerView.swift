import AppKit
import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftTerm
import SwiftUI

// MARK: - State Change Callback

/// Callback type for reporting terminal state changes to parent view
typealias TerminalStateChangeHandler = @MainActor (StreamState, Int, Int) -> Void

// MARK: - Terminal Container View

/// A self-contained SwiftUI view that mirrors a tmux pane.
///
/// This view handles everything internally:
/// - Creates and manages the terminal view
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

    func makeNSView(context: Context) -> InteractiveTerminalView {
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

        return coordinator.terminalView
    }

    func updateNSView(_ nsView: InteractiveTerminalView, context: Context) {
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

    static func dismantleNSView(_ nsView: InteractiveTerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: @unchecked Sendable {
        // MARK: Views

        let terminalView: InteractiveTerminalView

        // MARK: Services (held for lifetime)

        private weak var paneStreamManager: PaneStreamManager?
        private weak var windowManager: MirrorWindowManager?
        private weak var tmuxService: TmuxService?

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
            self.terminalView = InteractiveTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
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
            self.tmuxService = tmuxService
            self.onStateChange = onStateChange
            lastExternalWidth = paneInfo.width

            // Apply initial settings
            updateFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            applyTheme(settings.theme)

            // Wire up input handling
            terminalView.onInput = { [weak self] keys in
                guard let self, let paneInfo = self.paneInfo else { return }
                Task {
                    await self.sendKeysToTmux(keys, target: paneInfo.target)
                }
            }

            // Start connection
            Task {
                await connect(paneInfo: paneInfo, tmuxService: tmuxService)
            }
        }

        // MARK: - Input Handling

        private func sendKeysToTmux(_ keys: [TmuxKey], target: String) async {
            guard let tmuxService else { return }

            for key in keys {
                // Skip delays - they're for iOS relay, not needed for local
                if case .delay = key { continue }

                do {
                    try await tmuxService.sendKeys(
                        target,
                        keys: key.tmuxKeyName,
                        literal: key.requiresLiteralMode
                    )
                } catch {
                    // Log error but continue - don't let one failed key block the rest
                    print("Failed to send key to tmux: \(error)")
                }
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
                let result = try await paneStreamManager.subscribe(
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

                subscriptionId = result.subscriptionId
                updateState(.connected)

                // Update columns from result dimensions
                updateColumns(result.width)

                // Feed initial content to terminal
                if !result.initialContent.isEmpty {
                    handleData(result.initialContent)
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
            terminalView.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
            terminalView.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        }

        private func applyLightTheme() {
            terminalView.nativeForegroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            terminalView.nativeBackgroundColor = NSColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
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
            guard rows > 0 else { return }

            // Derive cell height from SwiftTerm's optimal frame size
            let currentOptimalSize = terminalView.getOptimalFrameSize().size
            let cellHeight = currentOptimalSize.height / CGFloat(rows)
            guard cellHeight > 0 else { return }

            // Calculate rows from container height
            let newRows = max(1, Int(containerSize.height / cellHeight))

            if newRows != rows {
                rows = newRows
                terminalView.getTerminal().resize(cols: columns, rows: rows)
                notifyStateChange()
            }

            updateTerminalFrameSize()
        }

        // MARK: - Size Calculations

        private func updateTerminalFrameSize() {
            // Let SwiftTerm tell us the optimal size - it knows its own cell dimensions and scroller width
            let optimalSize = terminalView.getOptimalFrameSize().size
            terminalView.setTerminalSize(optimalSize)
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
