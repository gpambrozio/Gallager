import AppKit
import SwiftUI

/// Manages multiple mirror windows
@Observable
@MainActor
public final class MirrorWindowManager {
    /// Currently open mirror windows keyed by pane target
    public private(set) var openWindows: [String: NSWindow] = [:]

    private let settings: AppSettings
    private let tmuxService: TmuxService

    public init(settings: AppSettings, tmuxService: TmuxService) {
        self.settings = settings
        self.tmuxService = tmuxService
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

        // Calculate window size based on pane dimensions
        // Approximate character cell size for SF Mono at 12pt
        let charWidth: CGFloat = 7.2
        let charHeight: CGFloat = 14
        let horizontalPadding: CGFloat = 20
        let verticalPadding: CGFloat = 80 // For toolbar and status bar

        let contentWidth = CGFloat(paneInfo.width) * charWidth + horizontalPadding
        let contentHeight = CGFloat(paneInfo.height) * charHeight + verticalPadding

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
        window.setFrameAutosaveName("MirrorWindow-\(paneInfo.target)")
        window.isReleasedWhenClosed = false

        // Set minimum size
        window.minSize = NSSize(width: 400, height: 300)

        // Set up window delegate to handle closing
        let delegate = MirrorWindowDelegate(manager: self, target: paneInfo.target)
        window.delegate = delegate

        // Store window
        openWindows[paneInfo.target] = window

        // Show window
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
