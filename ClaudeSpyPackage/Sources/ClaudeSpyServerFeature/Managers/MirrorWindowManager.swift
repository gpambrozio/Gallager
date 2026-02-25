import AppKit
import ClaudeSpyCommon
import SwiftUI

/// Manages multiple mirror windows and handles hook events
@Observable
@MainActor
final public class MirrorWindowManager {
    /// Currently open mirror windows keyed by pane target
    public private(set) var openWindows: [String: NSWindow] = [:]

    /// Active Claude sessions keyed by pane ID
    public private(set) var activeSessions: [String: ClaudeSession] = [:]

    /// Pane IDs that the user has manually closed (don't auto-reopen until session ends)
    private var userClosedPanes: Set<String> = []

    /// Maps window target to pane ID for reverse lookup when window closes
    private var windowPaneIds: [String: String] = [:]

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

                // Always refresh panes to keep UI updated
                let panes = await self.tmuxService.refreshPanes()

                // Only run cleanup if we have sessions to check
                if !self.activeSessions.isEmpty {
                    self.cleanupStaleSessions(currentPanes: panes)
                }
            }
        }
    }

    /// Stops the periodic session validation task.
    public func stopPeriodicSessionValidation() {
        sessionValidationTask?.cancel()
        sessionValidationTask = nil
    }

    // MARK: - Session Management

    /// Updates a session for the given pane ID, creating one if it doesn't exist.
    /// Encapsulates the copy-mutate-reassign pattern for struct values in dictionaries.
    /// - Parameters:
    ///   - paneId: The tmux pane ID
    ///   - update: A closure that mutates the session
    private func updateSession(paneId: String, _ update: (inout ClaudeSession) -> Void) {
        var session = activeSessions[paneId] ?? ClaudeSession(paneId: paneId)
        update(&session)
        activeSessions[paneId] = session
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
            activeSessions.removeValue(forKey: paneId)
            await closeMirrorForPane(paneId)
        default:
            // Get or create session and add the event
            updateSession(paneId: paneId) { $0.addEvent(event) }

            // Only auto-open if setting is enabled and user hasn't manually closed this pane's window
            if settings.autoOpenMirrorOnSession && !userClosedPanes.contains(paneId) {
                await openMirrorForPane(paneId)
            }
        }
    }

    /// Opens a mirror window for the specified pane
    /// - Parameter paneInfo: The pane to mirror
    /// - Returns: The created or existing window
    @discardableResult
    public func openMirror(for paneInfo: PaneInfo) -> NSWindow {
        let windowKey = paneInfo.target

        // Create the mirror view with required environment
        let mirrorView = MirrorWindowView(paneInfo: paneInfo)
            .environment(settings)
            .environment(tmuxService)
            .environment(self)
            .environment(paneStreamManager)

        let window = showMirrorWindow(
            key: windowKey,
            title: "Mirror: \(paneInfo.paneId) (\(paneInfo.target))",
            terminalColumns: paneInfo.width,
            terminalRows: paneInfo.height,
            rootView: mirrorView
        )

        // Store pane ID mapping for local mirrors
        windowPaneIds[windowKey] = paneInfo.paneId

        return window
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
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)
        window.setContentSize(size)

        // Set up window delegate to handle closing (must store strong reference)
        let delegate = MirrorWindowDelegate(manager: self, target: key)
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
    ///   - target: The pane target
    ///   - columns: New width in character columns
    ///   - rows: New height in character rows
    public func resizeWindow(target: String, columns: Int, rows: Int) {
        guard let window = openWindows[target] else { return }

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

    /// Closes the mirror window for the specified pane target (programmatic close, not user-initiated)
    public func closeMirror(for target: String) {
        guard let window = openWindows[target] else { return }
        // Clear mappings BEFORE closing so windowWillClose delegate doesn't mark as user-closed
        openWindows.removeValue(forKey: target)
        windowPaneIds.removeValue(forKey: target)
        windowDelegates.removeValue(forKey: target)
        window.close()
    }

    /// Closes the mirror window for the specified pane ID
    /// - Parameter paneId: The tmux pane ID (e.g., "%0", "%1")
    public func closeMirrorForPane(_ paneId: String) async {
        // Refresh panes to get current state and find the target for this pane ID
        let allPanes = await tmuxService.refreshPanes()

        guard let pane = allPanes.first(where: { $0.paneId == paneId }) else {
            return
        }

        closeMirror(for: pane.target)
    }

    /// Closes all mirror windows (programmatic, doesn't mark as user-closed)
    public func closeAll() {
        let windows = openWindows
        openWindows.removeAll()
        windowPaneIds.removeAll()
        windowDelegates.removeAll()
        for (_, window) in windows {
            window.close()
        }
    }

    /// Called when a window is closed by the user
    fileprivate func windowWillClose(target: String) {
        // Mark this pane as user-closed so we don't auto-reopen it
        if let paneId = windowPaneIds[target] {
            userClosedPanes.insert(paneId)
        }
        openWindows.removeValue(forKey: target)
        windowPaneIds.removeValue(forKey: target)
        windowDelegates.removeValue(forKey: target)
    }

    /// Terminal titles keyed by pane target, detected via OSC escape sequences
    public private(set) var terminalTitles: [String: String] = [:]

    /// Updates the terminal title for a pane and the associated window title.
    /// - Parameters:
    ///   - target: The pane target (e.g., "mysession:0.1")
    ///   - title: The new terminal title
    public func updateTerminalTitle(target: String, title: String) {
        terminalTitles[target] = title
        openWindows[target]?.title = title
    }

    /// Brings a mirror window to front if it exists
    public func bringToFront(target: String) {
        if let window = openWindows[target] {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate()
        }
    }

    /// Returns whether a mirror is open for the given target
    public func isOpen(target: String) -> Bool {
        openWindows[target] != nil
    }

    /// List of currently mirrored pane targets
    public var mirroredTargets: [String] {
        Array(openWindows.keys).sorted()
    }

    /// Set of pane IDs that have active Claude sessions
    public var activeSessionPaneIds: Set<String> {
        Set(activeSessions.keys)
    }

    /// Number of sessions that need user attention
    public var pendingSessionCount: Int {
        activeSessions.values.filter(\.needsAttention).count
    }

    /// All sessions sorted with attention-needing sessions first
    public var sortedSessions: [ClaudeSession] {
        activeSessions.values.sorted {
            // Attention-needing sessions come first, then sort by pane ID
            if $0.needsAttention != $1.needsAttention {
                return $0.needsAttention
            }
            return $0.paneId < $1.paneId
        }
    }

    /// Opens a mirror for the specified tmux pane by ID.
    /// If the pane no longer exists, the session is removed as stale.
    /// - Parameter paneId: The tmux pane ID (e.g., "%0", "%1")
    public func openMirrorForPane(_ paneId: String) async {
        // Refresh panes to get current state
        let allPanes = await tmuxService.refreshPanes()

        // Find the pane with this pane ID (not target)
        guard let pane = allPanes.first(where: { $0.paneId == paneId }) else {
            // Pane no longer exists - clean up the stale session
            removeStaleSession(paneId: paneId)
            return
        }

        openMirror(for: pane)
    }

    // MARK: - Session Cleanup

    /// Removes a stale session for a pane that no longer exists.
    ///
    /// This also closes any associated mirror window.
    /// - Parameter paneId: The tmux pane ID to remove
    private func removeStaleSession(paneId: String) {
        activeSessions.removeValue(forKey: paneId)
        userClosedPanes.remove(paneId)

        // Close the mirror window if open
        for (target, mappedPaneId) in windowPaneIds where mappedPaneId == paneId {
            closeMirror(for: target)
        }
    }

    /// Cleans up active Claude sessions for panes that no longer exist.
    /// Call this to remove orphaned sessions when their tmux panes have been closed.
    /// - Parameter currentPanes: The list of currently existing tmux panes
    public func cleanupStaleSessions(currentPanes: [PaneInfo]) {
        let existingPaneIds = Set(currentPanes.map(\.paneId))
        let stalePaneIds = activeSessions.keys.filter { !existingPaneIds.contains($0) }

        for paneId in stalePaneIds {
            removeStaleSession(paneId: paneId)
        }
    }
}

/// Window delegate to handle window lifecycle
private class MirrorWindowDelegate: NSObject, NSWindowDelegate {
    weak var manager: MirrorWindowManager?
    let target: String

    init(manager: MirrorWindowManager, target: String) {
        self.manager = manager
        self.target = target
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            manager?.windowWillClose(target: target)
        }
    }
}
