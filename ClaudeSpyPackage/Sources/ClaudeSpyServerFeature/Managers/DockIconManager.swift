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

    /// Window identifiers to ignore when counting visible windows
    /// (e.g., menu bar popups, status item windows)
    private let ignoredWindowClasses: Set<String> = [
        "NSStatusBarWindow",
        "_NSPopoverWindow",
        "NSMenuWindowManagerWindow"
    ]

    public init() {}

    deinit {
        observationTask?.cancel()
    }

    /// Starts observing window changes and sets initial activation policy.
    /// Call this once during app startup.
    public func startObserving() {
        guard observationTask == nil else { return }

        // Set initial policy to accessory (no dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Start observing window notifications using async streams
        observationTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                // Window became key (focused)
                group.addTask { @MainActor [weak self] in
                    for await notification in NotificationCenter.default.notifications(
                        named: NSWindow.didBecomeKeyNotification
                    ) {
                        self?.handleWindowVisible(notification)
                    }
                }

                // Window became main
                group.addTask { @MainActor [weak self] in
                    for await notification in NotificationCenter.default.notifications(
                        named: NSWindow.didBecomeMainNotification
                    ) {
                        self?.handleWindowVisible(notification)
                    }
                }

                // Window will close
                group.addTask { @MainActor [weak self] in
                    for await _ in NotificationCenter.default.notifications(
                        named: NSWindow.willCloseNotification
                    ) {
                        await self?.handleWindowClosing()
                    }
                }

                // Window resigned key (lost focus, may be hidden)
                group.addTask { @MainActor [weak self] in
                    for await _ in NotificationCenter.default.notifications(
                        named: NSWindow.didResignKeyNotification
                    ) {
                        await self?.handleWindowClosing()
                    }
                }
            }
        }
    }

    /// Stops observing window changes.
    public func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Notification Handlers

    private func handleWindowVisible(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard isRelevantWindow(window) else { return }
        updateActivationPolicy()
    }

    private func handleWindowClosing() async {
        // Delay the check slightly to allow the window to fully close
        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            // Task was cancelled, don't update policy
            return
        }
        updateActivationPolicy()
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
        // Regular windows have titled, closable style masks
        let hasTitle = window.styleMask.contains(.titled)
        let isClosable = window.styleMask.contains(.closable)

        // Settings and regular windows should have title and be closable
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

    /// Forces an update of the activation policy. Call this when manually opening windows.
    public func forceUpdate() {
        updateActivationPolicy()
    }
}
