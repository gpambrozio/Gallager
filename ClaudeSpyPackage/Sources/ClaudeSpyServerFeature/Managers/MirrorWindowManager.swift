import AppKit
import SwiftUI

/// Manages multiple mirror windows and handles hook events
@Observable
@MainActor
public final class MirrorWindowManager {
    /// Currently open mirror windows keyed by pane target
    public private(set) var openWindows: [String: NSWindow] = [:]

    /// Active Claude pane IDs
    public private(set) var activePanes: Set<String> = []

    /// Pane IDs that the user has manually closed (don't auto-reopen until session ends)
    private var userClosedPanes: Set<String> = []

    /// Maps window target to pane ID for reverse lookup when window closes
    private var windowPaneIds: [String: String] = [:]

    /// Strong references to window delegates (NSWindow.delegate is weak)
    private var windowDelegates: [String: MirrorWindowDelegate] = [:]

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
            activePanes.remove(paneId)
            await closeMirrorForPane(paneId)
        default:
            activePanes.insert(paneId)
            // Only auto-open if user hasn't manually closed this pane's window
            if !userClosedPanes.contains(paneId) {
                await openMirrorForPane(paneId)
            }
        }
    }

    /// Cleans up active Claude sessions for panes that no longer exist
    /// Call this after refreshing the pane list
    public func cleanupInactiveSessions(currentPanes: [PaneInfo]) {
        let existingPaneIds = Set(currentPanes.map(\.id))
        activePanes = activePanes.intersection(existingPaneIds)
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

        // Set up window delegate to handle closing (must store strong reference)
        let delegate = MirrorWindowDelegate(manager: self, target: paneInfo.target)
        window.delegate = delegate
        windowDelegates[paneInfo.target] = delegate

        // Store window and pane ID mapping
        openWindows[paneInfo.target] = window
        windowPaneIds[paneInfo.target] = paneInfo.id

        // Center and show window
        window.center()
        window.makeKeyAndOrderFront(nil)

        return window
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

        guard let pane = allPanes.first(where: { $0.id == paneId }) else {
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
