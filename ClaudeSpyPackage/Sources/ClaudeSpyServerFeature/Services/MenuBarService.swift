import AppKit
import ClaudeSpyCommon
import ClaudeSpyNetworking
import Combine
import Observation

/// Manages the menu bar status item with badge for pending permission requests
@Observable
@MainActor
final public class MenuBarService {
    /// The status item in the menu bar
    private var statusItem: NSStatusItem?

    /// Reference to the window manager for session data
    private weak var windowManager: MirrorWindowManager?

    /// Reference to the tmux service for opening mirrors
    private weak var tmuxService: TmuxService?

    /// Observation tracking for activeSessions changes
    private var observationTask: Task<Void, Never>?

    /// Cached pending count for badge
    public private(set) var pendingCount = 0

    public init() { }

    // MARK: - Setup

    /// Sets up the menu bar with required dependencies
    /// - Parameters:
    ///   - windowManager: The window manager to observe for session changes
    ///   - tmuxService: The tmux service for opening mirror windows
    public func setup(windowManager: MirrorWindowManager, tmuxService: TmuxService) {
        self.windowManager = windowManager
        self.tmuxService = tmuxService

        createStatusItem()
        startObserving()
    }

    /// Creates the status item in the system menu bar
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            updateButtonAppearance(button, pendingCount: 0)
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Updates the button appearance based on pending count
    private func updateButtonAppearance(_ button: NSStatusBarButton, pendingCount: Int) {
        // Use the ant symbol as the menu bar icon
        let image = NSImage(systemSymbolName: "ant", accessibilityDescription: "Claude Spy")
        image?.isTemplate = true
        button.image = image

        // Show badge if there are pending permission requests
        if pendingCount > 0 {
            button.title = " \(pendingCount)"
        } else {
            button.title = ""
        }
    }

    /// Starts observing the window manager for session changes
    private func startObserving() {
        observationTask?.cancel()

        observationTask = Task { [weak self] in
            guard let self else { return }

            // Poll for changes since @Observable doesn't support external observation easily
            while !Task.isCancelled {
                await self.updatePendingCount()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Updates the pending count based on active sessions
    private func updatePendingCount() async {
        guard let windowManager else { return }

        let count = windowManager.activeSessions.values.filter(\.needsAttention).count
        if count != pendingCount {
            pendingCount = count
            if let button = statusItem?.button {
                updateButtonAppearance(button, pendingCount: count)
            }
        }
    }

    // MARK: - Menu Actions

    @objc
    private func statusItemClicked() {
        showMenu()
    }

    /// Shows the menu with session list
    private func showMenu() {
        guard let windowManager else { return }

        let menu = NSMenu()

        // Get sessions sorted by attention status (needs attention first)
        let sessions = windowManager.activeSessions.values.sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention {
                return lhs.needsAttention
            }
            return lhs.displayName < rhs.displayName
        }

        if sessions.isEmpty {
            let item = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            // Add header
            let headerItem = NSMenuItem(title: "Claude Sessions", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            menu.addItem(headerItem)
            menu.addItem(NSMenuItem.separator())

            // Add session items
            for session in sessions {
                let item = createSessionMenuItem(for: session)
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Add app control items
        let showWindowItem = NSMenuItem(
            title: "Show Main Window",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        showWindowItem.target = self
        menu.addItem(showWindowItem)

        let preferencesItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        menu.addItem(NSMenuItem.separator())

        // Add quit item
        let quitItem = NSMenuItem(title: "Quit ClaudeSpy", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Show the menu
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    /// Creates a menu item for a session
    private func createSessionMenuItem(for session: ClaudeSession) -> NSMenuItem {
        // Build title with project name and latest event
        var title = session.displayName
        if let latestEvent = session.latestEvent {
            title += " - \(latestEvent.action.title)"
        }

        let item = NSMenuItem(title: title, action: #selector(sessionItemClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = session.paneId

        // Add indicator for sessions needing attention
        if session.needsAttention {
            item.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Needs attention")
            item.image?.isTemplate = false
        }

        return item
    }

    @objc
    private func sessionItemClicked(_ sender: NSMenuItem) {
        guard
            let paneId = sender.representedObject as? String,
            let windowManager
        else {
            return
        }

        Task {
            await windowManager.openMirrorForPane(paneId)
            // Bring the app to front
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc
    private func showMainWindow() {
        // Temporarily show dock icon to allow window to appear
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Open a new main window or bring existing to front
        if let mainWindow = NSApp.windows.first(where: { $0.title.isEmpty || $0.title == "ClaudeSpy" }) {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            // Post notification to open main window
            NotificationCenter.default.post(name: .showMainWindow, object: nil)
        }
    }

    @objc
    private func openPreferences() {
        // Temporarily show dock icon if in menu bar only mode
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Use the standard Settings command
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc
    private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Cleanup

    /// Removes the status item from the menu bar
    public func teardown() {
        observationTask?.cancel()
        observationTask = nil

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    deinit {
        // Note: deinit won't be called on MainActor, but teardown handles cleanup
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    static let showMainWindow = Notification.Name("showMainWindow")
}
