import AppKit

/// Manages the app's dock icon visibility based on window state.
///
/// The app runs as an "accessory" app (no dock icon) when no windows are visible,
/// and switches to "regular" mode (dock icon visible) when windows are open.
/// This provides a cleaner experience for menu bar apps while still showing
/// the dock icon when the user is actively working with windows.
@MainActor
final public class DockIconManager {
    private var observationTask: Task<Void, Never>?
    private var updatePolicyTask: Task<Void, Never>?

    /// Window identifiers to ignore when counting visible windows
    /// (e.g., menu bar popups, status item windows)
    private let ignoredWindowClasses: Set<String> = [
        "NSStatusBarWindow",
        "_NSPopoverWindow",
        "NSMenuWindowManagerWindow",
    ]

    public init() { }

    deinit {
        observationTask?.cancel()
    }

    /// Starts observing window changes.
    /// Call this once during app startup.
    /// Note: The app's LSUIElement=YES in Info.plist already sets accessory policy by default.
    public func startObserving() {
        guard observationTask == nil else { return }

        // Check initial window state - windows may already be open before we started observing
        updateActivationPolicy()

        // Start observing window notifications using async streams
        observationTask = Task { [weak self] in
            await self?.observeWindowNotifications()
        }
    }

    /// Stops observing window changes.
    public func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Notification Observation

    private func observeWindowNotifications() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.observeWindowBecameKey() }
            group.addTask { await self.observeWindowBecameMain() }
            group.addTask { await self.observeWindowWillClose() }
            group.addTask { await self.observeWindowResignedKey() }
        }
    }

    private func observeWindowBecameKey() async {
        for await notification in NotificationCenter.default.notifications(
            named: NSWindow.didBecomeKeyNotification
        ) {
            handleWindowVisible(notification)
        }
    }

    private func observeWindowBecameMain() async {
        for await notification in NotificationCenter.default.notifications(
            named: NSWindow.didBecomeMainNotification
        ) {
            handleWindowVisible(notification)
        }
    }

    private func observeWindowWillClose() async {
        for await _ in NotificationCenter.default.notifications(
            named: NSWindow.willCloseNotification
        ) {
            handleWindowClosing()
        }
    }

    private func observeWindowResignedKey() async {
        for await _ in NotificationCenter.default.notifications(
            named: NSWindow.didResignKeyNotification
        ) {
            handleWindowClosing()
        }
    }

    // MARK: - Notification Handlers

    private func handleWindowVisible(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard isRelevantWindow(window) else { return }
        updateActivationPolicy()
    }

    private func handleWindowClosing() {
        // Cancel any pending update and schedule a new one
        // This ensures we only update once after rapid window close events
        updatePolicyTask?.cancel()
        updatePolicyTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                updateActivationPolicy()
            } catch {
                // Task was cancelled, don't update policy
            }
        }
    }

    // MARK: - Private Methods

    /// Checks if a window is a relevant app window (not menu bar, popup, etc.)
    private func isRelevantWindow(_ window: NSWindow) -> Bool {
        // Filter by window level - only normal level windows are app windows
        // This catches status bar windows, popups, menus, floating panels, etc.
        guard window.level == .normal else {
            return false
        }

        // Secondary check: ignore known system window classes (in case level check isn't sufficient)
        let className = String(describing: type(of: window))
        if ignoredWindowClasses.contains(className) {
            return false
        }

        // Ignore windows without standard window features
        // App windows typically have titled or closable style masks (or both)
        let hasTitle = window.styleMask.contains(.titled)
        let isClosable = window.styleMask.contains(.closable)

        // Accept windows with either title bar or close button
        guard hasTitle || isClosable else {
            return false
        }

        // Ignore very small windows (likely utility/popup windows)
        guard window.frame.width > 100 && window.frame.height > 100 else {
            return false
        }

        return true
    }

    /// Counts visible app windows (excluding menu bar extras, popups, etc.)
    private func countVisibleAppWindows() -> Int {
        return NSApp.windows.filter { window in
            isRelevantWindow(window) && window.isVisible
        }.count
    }

    /// Updates the activation policy based on visible window count.
    private func updateActivationPolicy() {
        let visibleCount = countVisibleAppWindows()
        let currentPolicy = NSApp.activationPolicy()

        if visibleCount > 0 {
            // Show dock icon when windows are visible
            if currentPolicy != .regular {
                NSApp.setActivationPolicy(.regular)
                // Ensure the app is properly activated
                NSApp.activate(ignoringOtherApps: false)
            }
        } else {
            // Hide dock icon when no windows are visible
            if currentPolicy != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
