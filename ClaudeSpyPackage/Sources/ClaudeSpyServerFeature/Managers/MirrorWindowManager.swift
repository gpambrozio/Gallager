import AppKit
import SwiftUI

/// Manages multiple mirror windows and handles hook events
@Observable
@MainActor
public final class MirrorWindowManager {
    /// Currently open mirror windows keyed by pane target
    public private(set) var openWindows: [String: NSWindow] = [:]

    /// Active Claude panes (pane ID -> last activity timestamp)
    /// Example: ["%0": Date(), "%1": Date()]
    public private(set) var activePanes: [String: Date] = [:]

    private let settings: AppSettings
    private let tmuxService: TmuxService

    public init(settings: AppSettings, tmuxService: TmuxService) {
        self.settings = settings
        self.tmuxService = tmuxService
    }

    // MARK: - Hook Event Handling

    /// Handles incoming hook events - tracks active panes and manages mirror windows
    /// - Parameter event: The hook event to process
    public func handleHookEvent(_ event: HookEvent) async {
        guard let paneId = event.tmuxPane else { return }

        // Track active pane based on event type
        switch event.action {
        case .sessionEnd:
            activePanes.removeValue(forKey: paneId)
            await closeMirrorForPane(paneId)
        case .sessionStart:
            activePanes[paneId] = Date()
            await openMirrorForPane(paneId)
        case .preToolUse, .permissionRequest, .unknown:
            activePanes[paneId] = Date()
        }
    }

    /// Check if a tmux pane has an active Claude Code session
    /// - Parameter paneId: The tmux pane ID (e.g., "%0", "%1")
    public func hasActiveClaudePane(_ paneId: String) -> Bool {
        guard let lastActivity = activePanes[paneId] else { return false }

        // Consider a pane stale after 5 minutes of inactivity
        let staleThreshold: TimeInterval = 5 * 60
        return Date().timeIntervalSince(lastActivity) < staleThreshold
    }

    /// Clean up stale panes (called periodically)
    public func cleanupStalePanes() {
        let staleThreshold: TimeInterval = 5 * 60
        let now = Date()

        activePanes = activePanes.filter { _, lastActivity in
            now.timeIntervalSince(lastActivity) < staleThreshold
        }
    }

    /// Opens a mirror window for the specified pane
    /// - Parameter paneInfo: The pane to mirror
    /// - Returns: The created or existing window
    @discardableResult
    public func openMirror(for paneInfo: PaneInfo) -> NSWindow {
        // If window already exists for this pane, bring it to front
        if let existingWindow = openWindows[paneInfo.target] {
            existingWindow.makeKeyAndOrderFront(nil)
            return existingWindow
        }

        // Create the mirror view
        let mirrorView = MirrorWindowView(paneInfo: paneInfo)
            .environment(settings)
            .environment(tmuxService)

        // Create hosting controller
        let hostingController = NSHostingController(rootView: mirrorView)

        // Calculate window size based on pane dimensions using actual font metrics
        // Cell size calculation matches SwiftTerm's computeFontDimensions()
        // See: docs/swiftterm-sizing.md for details
        let cellSize = FontMetrics.calculateCellSize(
            fontName: settings.fontName,
            fontSize: CGFloat(settings.fontSize)
        )
        // Vertical padding: title bar (~28) + toolbar (~38) + status bar (~28) + buffer
        let verticalPadding: CGFloat = 110

        let contentWidth = CGFloat(paneInfo.width) * cellSize.width + FontMetrics.horizontalBuffer
        let contentHeight = CGFloat(paneInfo.height) * cellSize.height + verticalPadding

        // Ensure reasonable minimum size
        let width = max(700, contentWidth)
        let height = max(500, contentHeight)

        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.title = "Mirror: \(paneInfo.id) (\(paneInfo.target))"
        window.isReleasedWhenClosed = false

        // Set minimum size
        window.minSize = NSSize(width: 400, height: 300)

        // Always use calculated size based on pane dimensions (no frame autosave)
        window.setContentSize(NSSize(width: width, height: height))

        // Set up window delegate to handle closing
        let delegate = MirrorWindowDelegate(manager: self, target: paneInfo.target)
        window.delegate = delegate

        // Store window
        openWindows[paneInfo.target] = window

        // Center and show window
        window.center()
        window.makeKeyAndOrderFront(nil)

        return window
    }

    /// Closes the mirror window for the specified pane target
    public func closeMirror(for target: String) {
        guard let window = openWindows[target] else { return }
        window.close()
        openWindows.removeValue(forKey: target)
    }

    /// Closes the mirror window for the specified pane ID
    /// - Parameter paneId: The tmux pane ID (e.g., "%0", "%1")
    public func closeMirrorForPane(_ paneId: String) async {
        // Refresh panes to get current state and find the target for this pane ID
        let allPanes = await tmuxService.refreshPanes()

        guard let pane = allPanes.first(where: { $0.id == paneId }) else {
            return
        }

        closeMirror(for: pane.target)
    }

    /// Closes all mirror windows
    public func closeAll() {
        for (target, window) in openWindows {
            window.close()
            openWindows.removeValue(forKey: target)
        }
    }

    /// Called when a window is closed by the user
    fileprivate func windowWillClose(target: String) {
        openWindows.removeValue(forKey: target)
    }

    /// Brings a mirror window to front if it exists
    public func bringToFront(target: String) {
        openWindows[target]?.makeKeyAndOrderFront(nil)
    }

    /// Returns whether a mirror is open for the given target
    public func isOpen(target: String) -> Bool {
        openWindows[target] != nil
    }

    /// List of currently mirrored pane targets
    public var mirroredTargets: [String] {
        Array(openWindows.keys).sorted()
    }

    /// Opens a mirror for the specified tmux pane by ID
    /// - Parameter paneId: The tmux pane ID (e.g., "%0", "%1")
    public func openMirrorForPane(_ paneId: String) async {
        // Refresh panes to get current state
        let allPanes = await tmuxService.refreshPanes()

        // Find the pane with this ID
        guard let pane = allPanes.first(where: { $0.id == paneId }) else {
            return
        }

        openMirror(for: pane)
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
