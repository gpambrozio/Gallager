import AppKit
import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftTerm
import SwiftUI

// MARK: - State Change Callback

/// Callback type for reporting terminal state changes to parent view
typealias TerminalStateChangeHandler = @MainActor (StreamState, Int, Int) -> Void

/// Callback type for reporting terminal title changes to parent view
typealias TerminalTitleChangeHandler = @MainActor (String) -> Void

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
    let paneState: PaneState
    /// When false, the terminal won't auto-grab focus on window add or window-becomes-key.
    /// Used in multi-pane layouts where multiple terminals share one window.
    var autoFocus = true
    let onStateChange: TerminalStateChangeHandler?
    let onTitleChange: TerminalTitleChangeHandler?

    @Environment(AppSettings.self) private var settings
    @Environment(TmuxService.self) private var tmuxService
    @Environment(PaneStreamManager.self) private var paneStreamManager
    @Environment(EditorSessionManager.self) private var editorSessionManager

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InteractiveTerminalView {
        let coordinator = context.coordinator

        // Configure auto-focus before starting (must be set before viewDidMoveToWindow fires)
        coordinator.terminalView.autoFocusEnabled = autoFocus

        // Start the coordinator with all dependencies
        coordinator.start(
            paneState: paneState,
            tmuxService: tmuxService,
            paneStreamManager: paneStreamManager,
            settings: settings,
            onStateChange: onStateChange,
            onTitleChange: onTitleChange
        )

        return coordinator.terminalView
    }

    func updateNSView(_ nsView: InteractiveTerminalView, context: Context) {
        let coordinator = context.coordinator

        // Update editor state — suppress keyboard/focus when editor overlay is active
        let editorActive = editorSessionManager.session(for: paneState.paneId) != nil
        let wasEditorActive = nsView.isEditorActive
        nsView.isEditorActive = editorActive

        // When editor just closed, restore focus to the terminal
        if wasEditorActive, !editorActive {
            nsView.window?.makeFirstResponder(nsView)
        }

        // Update pane state — tmux rearranges pane indices when panes are
        // added or removed, so the target (e.g., "session:0.1") can change.
        // The coordinator must track the current target for key routing.
        coordinator.updatePaneState(paneState)

        // Update settings if changed
        coordinator.updateSettings(settings)

        // Update container size on layout changes
        coordinator.updateContainerSize(nsView.frame.size)

        // Check for dimension changes from pane state (updated after %layout-change)
        coordinator.handleExternalDimensionChange(width: paneState.width, height: paneState.height)
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
        private weak var tmuxService: TmuxService?

        // MARK: State

        private var paneState: PaneState?
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
        private var onTitleChange: TerminalTitleChangeHandler?

        /// Track initial scroll state
        private var hasScrolledInitial = false

        // Track consecutive key send failures for error reporting
        private var consecutiveKeyFailures = 0
        private let maxConsecutiveKeyFailures = 3

        /// Serializes key sends so concurrent onInput callbacks don't race
        private var pendingKeyTask: Task<Void, Never>?

        // MARK: Initialization

        init() {
            self.terminalView = InteractiveTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            // Disable custom block glyph rendering. SwiftTerm's drawBoxDrawings snaps cell
            // widths to integer pixels (baseCellWidthPx), while text uses fractional
            // cellDimension.width. For non-integer cell widths (e.g. SF Mono 12pt = 7.42pt),
            // this causes cumulative positioning drift — up to ~42pt at column 100 on non-Retina.
            // Using the font's own box drawing glyphs keeps them on the same text grid.
            terminalView.customBlockGlyphs = false
            applyDarkTheme()
        }

        // MARK: Lifecycle

        func start(
            paneState: PaneState,
            tmuxService: TmuxService,
            paneStreamManager: PaneStreamManager,
            settings: AppSettings,
            onStateChange: TerminalStateChangeHandler?,
            onTitleChange: TerminalTitleChangeHandler?
        ) {
            self.paneState = paneState
            self.paneStreamManager = paneStreamManager
            self.tmuxService = tmuxService
            self.onStateChange = onStateChange
            self.onTitleChange = onTitleChange
            lastExternalWidth = paneState.width

            terminalView.terminalAccessibilityIdentifier = "terminal-\(paneState.paneId)"

            // Apply initial settings
            updateFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            applyTheme(settings.theme)

            // Wire up input handling — chained tasks ensure keys are sent in order
            terminalView.onInput = { [weak self] keys in
                guard let self, let paneState = self.paneState else { return }
                let previous = self.pendingKeyTask
                self.pendingKeyTask = Task {
                    _ = await previous?.value
                    await self.sendKeysToTmux(keys, target: paneState.target)
                }
            }

            // Wire up raw input (mouse escape sequences) — same serialization chain
            terminalView.onRawInput = { [weak self] data in
                guard let self, let paneState = self.paneState else { return }
                let previous = self.pendingKeyTask
                self.pendingKeyTask = Task {
                    _ = await previous?.value
                    await self.sendRawBytesToTmux(data, target: paneState.target)
                }
            }

            // Wire up title change handling
            terminalView.onTitleChange = { [weak self] title in
                self?.handleTitleChange(title)
            }

            // Start connection
            Task {
                await connect(paneState: paneState, tmuxService: tmuxService)
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

        private func sendRawBytesToTmux(_ data: Data, target: String) async {
            guard let tmuxService else { return }

            do {
                try await tmuxService.sendRawBytes(target, data: data)
                consecutiveKeyFailures = 0
            } catch {
                consecutiveKeyFailures += 1
                print("Failed to send raw bytes to tmux: \(error)")

                if consecutiveKeyFailures >= maxConsecutiveKeyFailures {
                    updateState(.error("Failed to send mouse events to tmux"))
                }
            }
        }

        /// Updates the pane state when tmux rearranges pane indices.
        /// The `onInput` closure reads `self.paneState.target` on each call,
        /// so updating the stored state is sufficient — no closure re-wiring needed.
        func updatePaneState(_ newState: PaneState) {
            paneState = newState
        }

        func stop() {
            // Disconnect input handlers first so no new tmux commands fire
            // after the pane is destroyed (prevents SIGABRT from NSTask).
            terminalView.onInput = nil
            terminalView.onRawInput = nil

            pendingKeyTask?.cancel()
            pendingKeyTask = nil
            rowsLockedToTmux = false
            terminalView.lockedDimensions = nil
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

        private func connect(paneState: PaneState, tmuxService: TmuxService) async {
            updateState(.connecting)

            // Get initial dimensions from tmux. Rows must match the tmux pane
            // so that absolute cursor positioning in live %output events maps correctly.
            do {
                let dims = try await tmuxService.getPaneDimensions(paneState.target)
                updateTerminalDimensions(cols: dims.width, rows: dims.height)
            } catch {
                updateTerminalDimensions(cols: paneState.width, rows: paneState.height)
            }

            clear()

            // Subscribe to stream
            guard let paneStreamManager else {
                updateState(.error("Stream manager unavailable"))
                return
            }

            do {
                let target = paneState.target
                // Note: onTitleChange is intentionally omitted here. Title changes are detected
                // locally by SwiftTerm's delegate (terminalView.onTitleChange) and then reported
                // back to PaneStreamManager via reportTitleChange(), which forwards to other
                // subscribers. This avoids a circular callback loop.
                let result = try await paneStreamManager.subscribe(
                    paneId: paneState.paneId,
                    target: target,
                    onData: { [weak self] data in
                        self?.handleData(data)
                    },
                    onDimensionChange: { [weak self] newWidth, newHeight in
                        self?.updateTerminalDimensions(cols: newWidth, rows: newHeight)
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

                // capture-pane doesn't include DEC private mode state (mouse
                // tracking). Query tmux for the pane's mouse flags and inject
                // the enable sequences so SwiftTerm enters the correct mode.
                await syncMouseMode(target: target, tmuxService: tmuxService)
            } catch {
                updateState(.error(error.localizedDescription))
            }
        }

        // MARK: Title Handling

        private func handleTitleChange(_ title: String) {
            // Notify the parent view
            onTitleChange?(title)

            // Report to PaneStreamManager so other subscribers (e.g., TerminalStreamService) are notified
            if let paneState, let subscriptionId {
                paneStreamManager?.reportTitleChange(
                    paneId: paneState.paneId,
                    title: title,
                    fromSubscription: subscriptionId
                )
            }
        }

        // MARK: Data Handling

        private func handleData(_ data: Data) {
            let bytes = [UInt8](data)[...]

            if !hasScrolledInitial {
                // First data - feed and enable scroll preservation.
                // Don't scrollToBottom here: for terminals taller than the viewport,
                // scrolling to bottom shows empty rows and hides the prompt at the top.
                // SwiftTerm's natural rendering starts from the top which is correct.
                terminalView.feed(byteArray: bytes)
                terminalView.preserveUserScroll = true
                hasScrolledInitial = true
            } else {
                // Subsequent data - preserve user's scroll position
                terminalView.feedPreservingScroll(bytes)
            }
        }

        // MARK: Mouse Mode Sync

        /// Queries the tmux pane's mouse tracking flags and injects the
        /// corresponding DEC private mode sequences into SwiftTerm.
        /// `capture-pane` only captures text + SGR attributes, not terminal
        /// state like mouse mode, so the mirror must sync this separately.
        private func syncMouseMode(target: String, tmuxService: TmuxService) async {
            do {
                let result = try await tmuxService.getPaneMouseMode(target)
                guard result != .off else { return }

                var sequences = ""
                switch result {
                case .standard:
                    sequences += "\u{1b}[?1000h"
                case .button:
                    sequences += "\u{1b}[?1002h"
                case .any:
                    sequences += "\u{1b}[?1003h"
                case .off:
                    break
                }
                // SGR encoding (almost always paired with mouse tracking)
                if result != .off {
                    sequences += "\u{1b}[?1006h"
                }

                terminalView.feed(byteArray: Array(sequences.utf8)[...])
            } catch {
                // Non-fatal — mouse just won't work until the app redraws
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

        /// Updates terminal dimensions from tmux pane size.
        /// Rows are locked to the tmux pane height so that absolute cursor
        /// positioning in live `%output` events maps correctly to mirror rows.
        func updateTerminalDimensions(cols newColumns: Int, rows newRows: Int) {
            let changed = newColumns != columns || newRows != rows
            columns = newColumns
            rows = newRows
            rowsLockedToTmux = true
            // Lock dimensions on the terminal view so its sizeChanged delegate
            // can re-apply them when SwiftTerm's async processSizeChange fires.
            terminalView.lockedDimensions = (cols: columns, rows: rows)
            if changed {
                terminalView.getTerminal().resize(cols: columns, rows: rows)
                updateTerminalFrameSize()
                reapplyDimensionsIfNeeded()
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
            terminalView.autoCopyOnSelect = settings.autoCopyOnSelect
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
            // SwiftTerm's resetFont() recalculates cols/rows from frame.width
            // without subtracting scroller width. Re-apply our correct dimensions.
            reapplyDimensionsIfNeeded()
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

        func handleExternalDimensionChange(width: Int, height: Int) {
            guard width != lastExternalWidth else { return }
            lastExternalWidth = width

            // Resize terminal immediately to avoid cursor misposition.
            // Without this, the shell's prompt redraw (via pipe-pane) arrives
            // while the terminal still has the old column count, then the async
            // dimension callback reflows content that was already correct,
            // placing the cursor at the end of the line instead of after the prompt.
            updateTerminalDimensions(cols: width, rows: height)

            // Also update the stream so other subscribers (e.g., iOS relay) get notified
            paneStreamManager?.updateDimensions(paneId: paneState?.paneId ?? "", width: width, height: height)
        }

        // MARK: Private Helpers

        /// Recalculates rows based on container height and resizes terminal.
        /// When rows are locked to tmux pane height, only re-applies locked
        /// dimensions — frame updates are skipped to avoid triggering SwiftTerm's
        /// processSizeChange which would override the locked row count.
        private func recalculateRowsAndResize() {
            guard rows > 0 else { return }

            if rowsLockedToTmux {
                // When locked, skip row recalculation but still update the
                // frame size so the terminal width tracks the container.
                // setTerminalSize uses locked optimal height (not bounds.height)
                // to avoid triggering processSizeChange row recalculation.
                updateTerminalFrameSize()
                reapplyDimensionsIfNeeded()
                return
            }

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
            reapplyDimensionsIfNeeded()
        }

        // MARK: - Size Calculations

        private func updateTerminalFrameSize() {
            // Let SwiftTerm tell us the optimal size - it knows its own cell dimensions and scroller width
            let optimalSize = terminalView.getOptimalFrameSize().size
            terminalView.setTerminalSize(optimalSize)
        }

        /// Re-applies the correct terminal dimensions if SwiftTerm's internal
        /// sizing logic (processSizeChange/resetFont) has overridden them.
        /// This happens because setTerminalSize uses bounds.height which may
        /// not be an exact multiple of cellHeight * rows, causing SwiftTerm
        /// to recalculate different dimensions.
        private func reapplyDimensionsIfNeeded() {
            let terminal = terminalView.getTerminal()
            if terminal.cols != columns || terminal.rows != rows {
                terminal.resize(cols: columns, rows: rows)
            }
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
