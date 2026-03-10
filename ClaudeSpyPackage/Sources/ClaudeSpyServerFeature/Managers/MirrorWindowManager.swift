import AppKit
import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Manages multiple mirror windows and handles hook events
@Observable
@MainActor
final public class MirrorWindowManager {
    /// Currently open mirror windows keyed by pane ID
    public private(set) var openWindows: [String: NSWindow] = [:]

    /// Unified per-pane state keyed by pane ID.
    /// Contains tmux metadata, Claude session, terminal title, and yolo mode.
    public private(set) var paneStates: [String: PaneState] = [:]

    /// Pane IDs that the user has manually closed (don't auto-reopen until session ends)
    private var userClosedPanes: Set<String> = []

    /// Strong references to window delegates (NSWindow.delegate is weak)
    private var windowDelegates: [String: MirrorWindowDelegate] = [:]

    /// Task for periodic session validation
    private var sessionValidationTask: Task<Void, Never>?

    /// Interval between session validation checks (in seconds)
    private let validationInterval: TimeInterval = 5

    private let settings: AppSettings
    private let tmuxService: TmuxService

    /// Pane stream manager for sharing streams
    public var paneStreamManager: PaneStreamManager

    public init(
        settings: AppSettings,
        tmuxService: TmuxService,
        paneStreamManager: PaneStreamManager
    ) {
        self.settings = settings
        self.tmuxService = tmuxService
        self.paneStreamManager = paneStreamManager
    }

    // MARK: - Pane State Management

    /// Updates the pane states dictionary from tmux pane metadata.
    /// Creates new entries for newly discovered panes, updates metadata for existing panes,
    /// and removes entries for panes that no longer exist (cleaning up associated state).
    public func updatePaneStates(from panes: [PaneInfo]) {
        let currentPaneIds = Set(panes.map(\.paneId))

        // Update or create entries for current panes
        for pane in panes {
            if var state = paneStates[pane.paneId] {
                pane.updateMetadata(of: &state)
                paneStates[pane.paneId] = state
            } else {
                paneStates[pane.paneId] = pane.makePaneState()
            }
        }

        // Remove stale entries
        let stalePaneIds = paneStates.keys.filter { !currentPaneIds.contains($0) }
        for paneId in stalePaneIds {
            removeStaleState(paneId: paneId)
        }
    }

    // MARK: - Periodic Session Validation

    /// Starts a background task that periodically validates sessions against actual tmux panes.
    /// Sessions for panes that no longer exist are automatically removed.
    public func startPeriodicSessionValidation() {
        // Cancel any existing task
        sessionValidationTask?.cancel()

        sessionValidationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.validationInterval ?? 5))

                guard !Task.isCancelled, let self else { break }

                // Refresh panes and update state
                let panes = await self.tmuxService.refreshPanes()
                self.updatePaneStates(from: panes)
            }
        }
    }

    /// Stops the periodic session validation task.
    public func stopPeriodicSessionValidation() {
        sessionValidationTask?.cancel()
        sessionValidationTask = nil
    }

    // MARK: - Session Management

    /// Updates the Claude session for the given pane ID, creating pane state if needed.
    /// Encapsulates the copy-mutate-reassign pattern for struct values in dictionaries.
    /// - Parameters:
    ///   - paneId: The tmux pane ID
    ///   - update: A closure that mutates the session
    private func updateSession(paneId: String, _ update: (inout ClaudeSession) -> Void) {
        var session = paneStates[paneId]?.claudeSession ?? ClaudeSession(paneId: paneId)
        update(&session)
        if paneStates[paneId] != nil {
            paneStates[paneId]?.claudeSession = session
        } else {
            // Pane not yet known from tmux refresh — create minimal state
            paneStates[paneId] = PaneState(paneId: paneId, claudeSession: session)
        }
    }

    // MARK: - Hook Event Handling

    /// Handles incoming hook events - tracks active sessions and manages mirror windows
    /// - Parameter event: The hook event to process
    public func handleHookEvent(_ event: HookEvent) async {
        guard let paneId = event.tmuxPane else { return }

        // Track active session based on event type
        switch event.action {
        case .sessionEnd:
            // Add the final event before removing the session
            updateSession(paneId: paneId) { $0.addEvent(event) }
            paneStates[paneId]?.claudeSession = nil
            paneStates[paneId]?.yoloMode = false
            await closeMirrorForPane(paneId)

        case .sessionStart:
            // Allow auto-open again for new sessions.
            // Yolo mode is NOT reset here — context compaction restarts
            // send sessionStart without a preceding sessionEnd, so yolo
            // must carry over. Normal session endings already clear yolo
            // via the sessionEnd handler above.
            userClosedPanes.remove(paneId)
            updateSession(paneId: paneId) { $0.addEvent(event) }
            await autoOpenIfEnabled(paneId: paneId)

        case let .permissionRequest(body) where isYoloModeEnabled(for: paneId) && body.isYoloAutoApprovable:
            // Yolo mode: auto-approve by sending Enter after a short delay
            updateSession(paneId: paneId) { $0.addEvent(event) }
            do {
                try await Task.sleep(for: .milliseconds(500))
                try await tmuxService.sendKeys(paneId, keys: "Enter")
            } catch {
                // If auto-approve fails, fall through to normal flow
            }

        default:
            updateSession(paneId: paneId) { $0.addEvent(event) }
            await autoOpenIfEnabled(paneId: paneId)
        }
    }

    /// Opens a mirror window for the specified pane
    /// - Parameter paneState: The pane state to mirror
    /// - Returns: The created or existing window
    @discardableResult
    public func openMirror(for paneState: PaneState) -> NSWindow {
        let paneId = paneState.paneId

        // Create the mirror view with required environment
        let mirrorView = MirrorWindowView(paneState: paneState)
            .environment(settings)
            .environment(tmuxService)
            .environment(self)
            .environment(paneStreamManager)

        let window = showMirrorWindow(
            key: paneId,
            title: "Mirror: \(paneState.paneId) (\(paneState.target))",
            terminalColumns: paneState.width,
            terminalRows: paneState.height,
            rootView: mirrorView
        )

        return window
    }

    /// Opens a mirror window for the specified PaneInfo (convenience for callers that have PaneInfo)
    @discardableResult
    public func openMirror(for paneInfo: PaneInfo) -> NSWindow {
        // Ensure pane state exists with current metadata
        if var state = paneStates[paneInfo.paneId] {
            paneInfo.updateMetadata(of: &state)
            paneStates[paneInfo.paneId] = state
        } else {
            paneStates[paneInfo.paneId] = paneInfo.makePaneState()
        }
        guard let state = paneStates[paneInfo.paneId] else {
            // Should never happen since we just set it above, but satisfy the compiler
            return openMirror(for: paneInfo.makePaneState())
        }
        return openMirror(for: state)
    }

    /// Opens a standalone mirror window for a remote terminal session.
    /// - Parameters:
    ///   - paneId: The remote pane ID
    ///   - hostId: The remote host's pairing ID
    ///   - hostName: Display name of the remote host
    ///   - terminalColumns: The remote pane width in columns
    ///   - terminalRows: The remote pane height in rows
    ///   - connection: The viewer connection to the remote host
    @discardableResult
    public func openRemoteMirror(
        paneId: String,
        hostId: String,
        hostName: String,
        terminalColumns: Int,
        terminalRows: Int,
        connection: ViewerConnection
    ) -> NSWindow {
        let windowKey = "remote-\(hostId)-\(paneId)"

        let remoteView = RemoteTerminalContainerView(
            paneId: paneId,
            hostName: hostName,
            connection: connection,
            settings: settings,
            windowKey: windowKey,
            onStreamEnd: { [weak self] in
                self?.closeMirror(for: windowKey)
            }
        )

        return showMirrorWindow(
            key: windowKey,
            title: "Remote: \(hostName) - \(paneId)",
            terminalColumns: terminalColumns,
            terminalRows: terminalRows,
            rootView: remoteView
        )
    }

    // MARK: - Window Helpers

    /// Creates or brings to front a mirror window with the given content.
    ///
    /// Window size is calculated from terminal dimensions using actual font metrics.
    /// Cell size calculation matches SwiftTerm's `computeFontDimensions()`.
    /// See: `docs/swiftterm-sizing.md` for details.
    @discardableResult
    private func showMirrorWindow<Content: View>(
        key: String,
        title: String,
        terminalColumns: Int,
        terminalRows: Int,
        rootView: Content
    ) -> NSWindow {
        // If window already exists, bring it to front
        if let existingWindow = openWindows[key] {
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            NSApp.activate()
            return existingWindow
        }

        let cellSize = FontMetrics.calculateCellSize(
            fontName: settings.fontName,
            fontSize: CGFloat(settings.fontSize)
        )
        // Vertical padding: title bar (~28) + toolbar (~38) + status bar (~28) + buffer
        let verticalPadding: CGFloat = 110

        let contentWidth = CGFloat(terminalColumns) * cellSize.width + FontMetrics.horizontalBuffer
        let contentHeight = CGFloat(terminalRows) * cellSize.height + verticalPadding

        // Ensure reasonable minimum size
        let size = NSSize(
            width: max(700, contentWidth),
            height: max(500, contentHeight)
        )

        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.identifier = NSUserInterfaceItemIdentifier(key)
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)
        window.setContentSize(size)

        // Set up window delegate to handle closing (must store strong reference)
        let delegate = MirrorWindowDelegate(manager: self, key: key)
        window.delegate = delegate
        windowDelegates[key] = delegate

        openWindows[key] = window

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()

        return window
    }

    /// Resizes an existing mirror window to match new pane dimensions
    /// - Parameters:
    ///   - paneId: The pane ID
    ///   - columns: New width in character columns
    ///   - rows: New height in character rows
    public func resizeWindow(paneId: String, columns: Int, rows: Int) {
        guard let window = openWindows[paneId] else { return }

        // Calculate new window size using the same logic as openMirror
        let cellSize = FontMetrics.calculateCellSize(
            fontName: settings.fontName,
            fontSize: CGFloat(settings.fontSize)
        )
        let verticalPadding: CGFloat = 110

        let contentWidth = CGFloat(columns) * cellSize.width + FontMetrics.horizontalBuffer
        let contentHeight = CGFloat(rows) * cellSize.height + verticalPadding

        // Apply minimum size constraints
        let width = max(700, contentWidth)
        let height = max(500, contentHeight)

        // Resize the window, keeping the top-left corner in place
        var frame = window.frame
        let oldHeight = frame.height
        frame.size = NSSize(width: width, height: height)
        // Adjust origin to keep top-left corner fixed (since macOS origin is bottom-left)
        frame.origin.y += oldHeight - height
        window.setFrame(frame, display: true, animate: true)
    }

    /// Closes the mirror window for the specified key (programmatic close, not user-initiated)
    public func closeMirror(for key: String) {
        guard let window = openWindows[key] else { return }
        // Clear mappings BEFORE closing so windowWillClose delegate doesn't mark as user-closed
        openWindows.removeValue(forKey: key)
        windowDelegates.removeValue(forKey: key)
        window.close()
    }

    /// Closes the mirror window for the specified pane ID
    /// - Parameter paneId: The tmux pane ID (e.g., "%0", "%1")
    public func closeMirrorForPane(_ paneId: String) async {
        closeMirror(for: paneId)
    }

    /// Closes all mirror windows (programmatic, doesn't mark as user-closed)
    public func closeAll() {
        let windows = openWindows
        openWindows.removeAll()
        windowDelegates.removeAll()
        for (_, window) in windows {
            window.close()
        }
    }

    /// Called when a window is closed by the user
    fileprivate func windowWillClose(key: String) {
        // Mark this pane as user-closed so we don't auto-reopen it
        // (only for local pane windows, not remote windows)
        if !key.hasPrefix("remote-") {
            userClosedPanes.insert(key)
        }
        openWindows.removeValue(forKey: key)
        windowDelegates.removeValue(forKey: key)
    }

    /// Updates the terminal title for a pane and the associated window title.
    /// - Parameters:
    ///   - paneId: The tmux pane ID
    ///   - title: The new terminal title
    public func updateTerminalTitle(paneId: String, title: String) {
        paneStates[paneId]?.terminalTitle = title
        openWindows[paneId]?.title = title
    }

    /// Brings a mirror window to front if it exists
    public func bringToFront(paneId: String) {
        if let window = openWindows[paneId] {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate()
        }
    }

    /// Returns whether a mirror is open for the given pane ID
    public func isOpen(paneId: String) -> Bool {
        openWindows[paneId] != nil
    }

    /// List of currently mirrored pane IDs
    public var mirroredPaneIds: [String] {
        Array(openWindows.keys).sorted()
    }

    /// Set of pane IDs that have active Claude sessions
    public var activeSessionPaneIds: Set<String> {
        Set(paneStates.filter { $0.value.claudeSession != nil }.keys)
    }

    /// Number of sessions that need user attention
    public var pendingSessionCount: Int {
        paneStates.values.filter { $0.claudeSession?.needsAttention == true }.count
    }

    /// All sessions sorted with attention-needing sessions first
    public var sortedSessions: [ClaudeSession] {
        paneStates.values
            .compactMap(\.claudeSession)
            .sorted {
                if $0.needsAttention != $1.needsAttention {
                    return $0.needsAttention
                }
                return $0.paneId < $1.paneId
            }
    }

    /// Auto-opens a mirror for the pane if the setting is enabled and the user hasn't manually closed it.
    private func autoOpenIfEnabled(paneId: String) async {
        if settings.autoOpenMirrorOnSession && !userClosedPanes.contains(paneId) {
            await openMirrorForPane(paneId)
        }
    }

    /// Opens a mirror for the specified tmux pane by ID.
    /// If the pane no longer exists, the session is removed as stale.
    /// - Parameter paneId: The tmux pane ID (e.g., "%0", "%1")
    public func openMirrorForPane(_ paneId: String) async {
        // If we have state with valid metadata, use it directly
        if let state = paneStates[paneId], !state.target.isEmpty {
            openMirror(for: state)
            return
        }

        // Otherwise refresh from tmux
        let allPanes = await tmuxService.refreshPanes()
        guard let pane = allPanes.first(where: { $0.paneId == paneId }) else {
            removeStaleState(paneId: paneId)
            return
        }

        openMirror(for: pane)
    }

    // MARK: - Yolo Mode

    /// Sets yolo mode for a pane's Claude session.
    /// When enabled, permission requests are auto-approved by sending Enter keystroke.
    /// - Parameters:
    ///   - enabled: Whether to enable or disable yolo mode
    ///   - paneId: The pane ID to set yolo mode for
    public func setYoloMode(enabled: Bool, for paneId: String) {
        if paneStates[paneId] != nil {
            paneStates[paneId]?.yoloMode = enabled
        } else {
            // Create minimal state if needed
            paneStates[paneId] = PaneState(paneId: paneId, yoloMode: enabled)
        }
    }

    /// Whether yolo mode is enabled for the given pane
    public func isYoloModeEnabled(for paneId: String) -> Bool {
        paneStates[paneId]?.yoloMode ?? false
    }

    // MARK: - State Cleanup

    /// Removes state for a pane that no longer exists.
    /// Also closes any associated mirror window.
    private func removeStaleState(paneId: String) {
        paneStates.removeValue(forKey: paneId)
        userClosedPanes.remove(paneId)
        closeMirror(for: paneId)
    }
}

/// Window delegate to handle window lifecycle
private class MirrorWindowDelegate: NSObject, NSWindowDelegate {
    weak var manager: MirrorWindowManager?
    let key: String

    init(manager: MirrorWindowManager, key: String) {
        self.manager = manager
        self.key = key
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            manager?.windowWillClose(key: key)
        }
    }
}
