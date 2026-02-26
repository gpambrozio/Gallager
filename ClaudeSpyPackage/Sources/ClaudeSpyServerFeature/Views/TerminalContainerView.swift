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
        /// When connected, rows are locked to the tmux pane height so that
        /// absolute cursor positioning in live `%output` maps correctly.
        private var rowsLockedToTmux = false

        private var fontName: String?
        private var fontSize: CGFloat?
        private var containerSize: NSSize = .zero

        private var onStateChange: TerminalStateChangeHandler?

        // Track initial scroll state
        private var hasScrolledInitial = false

        // Track consecutive key send failures for error reporting
        private var consecutiveKeyFailures = 0
        private let maxConsecutiveKeyFailures = 3

        // Serializes key sends so concurrent onInput callbacks don't race
        private var pendingKeyTask: Task<Void, Never>?

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

            // Wire up input handling — chained tasks ensure keys are sent in order
            terminalView.onInput = { [weak self] keys in
                guard let self, let paneInfo = self.paneInfo else { return }
                let previous = self.pendingKeyTask
                self.pendingKeyTask = Task {
                    _ = await previous?.value
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
                    consecutiveKeyFailures = 0
                } catch {
                    consecutiveKeyFailures += 1
                    print("Failed to send key to tmux: \(error)")

                    if consecutiveKeyFailures >= maxConsecutiveKeyFailures {
                        updateState(.error("Failed to send keystrokes to tmux"))
                        break
                    }
                }
            }
        }

        func stop() {
            pendingKeyTask?.cancel()
            pendingKeyTask = nil
            rowsLockedToTmux = false

            // Don't stop the recorder here — its lifecycle is managed by MirrorWindowManager,
            // so it persists across view recreation (e.g. pane switching in sidebar).

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

            // Get initial dimensions from tmux. Rows must match the tmux pane
            // so that absolute cursor positioning in live %output events maps correctly.
            do {
                let dims = try await tmuxService.getPaneDimensions(paneInfo.target)
                updateTerminalDimensions(cols: dims.width, rows: dims.height)
            } catch {
                updateTerminalDimensions(cols: paneInfo.width, rows: paneInfo.height)
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
                        self?.updateTerminalDimensions(cols: newWidth, rows: newHeight)
                        windowManager?.resizeWindow(target: target, columns: newWidth, rows: newHeight)
                    }
                )

                subscriptionId = result.subscriptionId
                updateState(.connected)

                // Update dimensions from result
                updateTerminalDimensions(cols: result.width, rows: result.height)

                // Feed initial content to terminal
                if !result.initialContent.isEmpty {
                    handleData(result.initialContent)
                }
            } catch {
                updateState(.error(error.localizedDescription))
            }
        }

        // MARK: Data Handling

        // Feed diagnostic: log every feed to detect split frames
        private static var feedLog: FileHandle?
        private static var feedCount = 0
        private static let feedLogLimit = 500

        private func handleData(_ data: Data) {
            let bytes = [UInt8](data)[...]

            // Log feed sizes and detect partial escape sequences
            Self.logFeed(data)

            // DEBUG: bypass scroll preservation to test if it causes artifacts
            terminalView.feed(byteArray: bytes)
            if !hasScrolledInitial {
                scrollToBottom()
                hasScrolledInitial = true
            }
        }

        private static func logFeed(_ data: Data) {
            guard feedCount < feedLogLimit else { return }
            feedCount += 1

            if feedLog == nil {
                let path = "/tmp/claudespy-feeds.txt"
                FileManager.default.createFile(atPath: path, contents: nil)
                feedLog = FileHandle(forWritingAtPath: path)
            }

            // Check for truecolor BG markers to identify animation data
            let bgMarker = Data([0x1B, 0x5B, 0x34, 0x38, 0x3B, 0x32, 0x3B]) // ESC[48;2;
            var bgCount = 0
            var range = data.startIndex..<data.endIndex
            while let found = data.range(of: bgMarker, in: range) {
                bgCount += 1
                range = found.upperBound..<data.endIndex
            }

            // Check for bare CSI parameters (digits;digits followed by H or m
            // without preceding ESC[) - this indicates split escape sequences
            let hasBareParams = Self.detectBareCSIParams(data)

            // Check first/last bytes
            let first8 = data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
            let last8 = data.suffix(8).map { String(format: "%02x", $0) }.joined(separator: " ")

            // Check if data starts with ESC[
            let startsWithCSI = data.count >= 2 && data[data.startIndex] == 0x1B && data[data.startIndex + 1] == 0x5B
            // Check if data starts with a digit (bare parameter)
            let startsWithDigit = !data.isEmpty && data[data.startIndex] >= 0x30 && data[data.startIndex] <= 0x39

            var flags = ""
            if bgCount > 0 { flags += " ANIM(\(bgCount)bg)" }
            if hasBareParams { flags += " BARE_PARAMS!" }
            if startsWithDigit { flags += " STARTS_DIGIT!" }

            let line = "feed#\(feedCount) \(data.count)B first=[\(first8)] last=[\(last8)] csi=\(startsWithCSI)\(flags)\n"
            feedLog?.write(Data(line.utf8))
            feedLog?.synchronizeFile()
        }

        /// Detects potential bare CSI parameters in data — sequences like "2;5H"
        /// that appear without a preceding ESC[ within a reasonable window.
        private static func detectBareCSIParams(_ data: Data) -> Bool {
            // Look for pattern: digit(s) ; digit(s) H (or m) without ESC[ before it
            let bytes = [UInt8](data)
            for i in 0..<bytes.count {
                let b = bytes[i]
                // Look for 'H' or 'm' that could be CSI final bytes
                if b == 0x48 || b == 0x6D { // 'H' or 'm'
                    // Check if preceded by digits and semicolons (CSI parameters)
                    var j = i - 1
                    var hasDigit = false
                    var hasSemicolon = false
                    while j >= 0 {
                        let p = bytes[j]
                        if p >= 0x30 && p <= 0x39 { // digit
                            hasDigit = true
                            j -= 1
                        } else if p == 0x3B { // semicolon
                            hasSemicolon = true
                            j -= 1
                        } else {
                            break
                        }
                    }
                    // If we found digits;digits pattern and the byte before it is NOT '['
                    if hasDigit && hasSemicolon && j >= 0 && bytes[j] != 0x5B {
                        return true
                    }
                }
            }
            return false
        }

        // MARK: Terminal Operations

        func feed(_ data: Data) {
            let bytes = [UInt8](data)
            terminalView.feed(byteArray: bytes[...])
        }

        func clear() {
            feed(Data("\u{1b}[2J\u{1b}[H".utf8))
        }

        /// Updates terminal dimensions from tmux pane size.
        /// Rows are locked to the tmux pane height so that absolute cursor
        /// positioning in live `%output` events maps correctly to mirror rows.
        func updateTerminalDimensions(cols newColumns: Int, rows newRows: Int) {
            let changed = newColumns != columns || newRows != rows
            columns = newColumns
            rows = newRows
            rowsLockedToTmux = true
            if changed {
                terminalView.getTerminal().resize(cols: columns, rows: rows)
                updateTerminalFrameSize()
                notifyStateChange()
            }
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
            guard
                name != fontName || size != fontSize else { return }
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

        // MARK: External Dimension Changes

        func handleExternalColumnChange(width: Int) {
            guard width != lastExternalWidth else { return }
            lastExternalWidth = width

            // Forward to pane stream manager (it will notify via onDimensionChange callback)
            // Note: rows are dynamic based on container, so we pass current rows
            paneStreamManager?.updateDimensions(paneId: paneInfo?.paneId ?? "", width: width, height: rows)
        }

        // MARK: Private Helpers

        /// Recalculates rows based on container height and resizes terminal.
        /// When rows are locked to tmux pane height, only updates frame sizing.
        private func recalculateRowsAndResize() {
            guard rows > 0 else { return }

            if !rowsLockedToTmux {
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
