import AppKit

/// Manages the app's dock icon visibility based on window state.
///
/// The app runs as an "accessory" app (no dock icon) when no windows are visible,
/// and switches to "regular" mode (dock icon visible) when windows are open.
/// This provides a cleaner experience for menu bar apps while still showing
/// the dock icon when the user is actively working with windows.
@MainActor
final public class DockIconManager {
    private var isObserving = false

    /// Window identifiers to ignore when counting visible windows
    /// (e.g., menu bar popups, status item windows)
    private let ignoredWindowClasses: Set<String> = [
        "NSStatusBarWindow",
        "_NSPopoverWindow",
        "NSMenuWindowManagerWindow"
    ]

    public init() {}

    /// Starts observing window changes and sets initial activation policy.
    /// Call this once during app startup.
    public func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        // Set initial policy to accessory (no dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Observe window visibility changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeVisible),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeVisible),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        // Also observe when windows are ordered out (hidden without closing)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
    }

    /// Stops observing window changes.
    public func stopObserving() {
        guard isObserving else { return }
        isObserving = false

        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notification Handlers

    @objc private func windowDidBecomeVisible(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        // Ignore non-regular windows
        guard isRelevantWindow(window) else { return }

        updateActivationPolicy()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        // Delay the check slightly to allow the window to fully close
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            self.updateActivationPolicy()
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        // Check if we need to hide dock icon after window operations
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            self.updateActivationPolicy()
        }
    }

    // MARK: - Private Methods

    /// Checks if a window is a relevant app window (not menu bar, popup, etc.)
    private func isRelevantWindow(_ window: NSWindow) -> Bool {
        let className = String(describing: type(of: window))

        // Ignore known non-app windows
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
