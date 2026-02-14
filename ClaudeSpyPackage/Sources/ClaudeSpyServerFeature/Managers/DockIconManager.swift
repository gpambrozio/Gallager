import AppKit
import Dependencies
import DependenciesMacros

/// A dependency for managing the app's dock icon visibility.
///
/// Wraps `NSApp.setActivationPolicy` so it can be controlled in tests.
/// Use `@Dependency(DockIconService.self)` to access it.
@DependencyClient
public struct DockIconService: Sendable {
    /// Start observing window changes to auto-show/hide dock icon.
    public var startObserving: @Sendable () async -> Void

    /// Stop observing window changes.
    public var stopObserving: @Sendable () async -> Void
}

// MARK: - DependencyKey

extension DockIconService: DependencyKey {
    public static var liveValue: DockIconService {
        DockIconService(
            startObserving: {
                await LiveDockIconManagerHolder.shared.startObserving()
            },
            stopObserving: {
                await LiveDockIconManagerHolder.shared.stopObserving()
            }
        )
    }
}

/// Holds the singleton LiveDockIconManager instance.
/// A static holder is needed because liveValue is non-async and
/// cannot create a @MainActor-isolated instance inline.
@MainActor
private enum LiveDockIconManagerHolder {
    static let shared = LiveDockIconManager()
}

// MARK: - E2E Test Support

public enum DockIconConfig {
    /// When true, the dock icon manager will not switch activation policy.
    /// Set during E2E testing so the app keeps its menu bar visible.
    @MainActor
    public static var isE2ETestMode = false
}

// MARK: - Live Implementation

/// Internal class that manages the dock icon visibility based on window state.
@MainActor
final private class LiveDockIconManager {
    private var observationTask: Task<Void, Never>?
    private var updatePolicyTask: Task<Void, Never>?

    /// Window identifiers to ignore when counting visible windows
    private let ignoredWindowClasses: Set<String> = [
        "NSStatusBarWindow",
        "_NSPopoverWindow",
        "NSMenuWindowManagerWindow",
    ]

    init() { }

    deinit {
        observationTask?.cancel()
    }

    func startObserving() {
        guard observationTask == nil else { return }

        // Check initial window state
        updateActivationPolicy()

        observationTask = Task { [weak self] in
            await self?.observeWindowNotifications()
        }
    }

    func stopObserving() {
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
        // Cancel any pending update and schedule a new one.
        // This ensures we only update once after rapid window close events.
        updatePolicyTask?.cancel()
        updatePolicyTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                updateActivationPolicy()
            } catch {
                // Task was cancelled
            }
        }
    }

    // MARK: - Private Methods

    private func isRelevantWindow(_ window: NSWindow) -> Bool {
        guard window.level == .normal else { return false }

        let className = String(describing: type(of: window))
        if ignoredWindowClasses.contains(className) { return false }

        let hasTitle = window.styleMask.contains(.titled)
        let isClosable = window.styleMask.contains(.closable)
        guard hasTitle || isClosable else { return false }
        guard window.frame.width > 100 && window.frame.height > 100 else { return false }

        return true
    }

    private func countVisibleAppWindows() -> Int {
        return NSApp.windows.filter { window in
            isRelevantWindow(window) && window.isVisible
        }.count
    }

    private func updateActivationPolicy() {
        guard !DockIconConfig.isE2ETestMode else { return }
        let visibleCount = countVisibleAppWindows()
        let currentPolicy = NSApp.activationPolicy()

        if visibleCount > 0 {
            if currentPolicy != .regular {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: false)
            }
        } else {
            if currentPolicy != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
