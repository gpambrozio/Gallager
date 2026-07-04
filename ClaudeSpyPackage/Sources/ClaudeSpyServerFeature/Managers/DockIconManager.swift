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

    /// Set the dock tile badge to `count` (hidden when ≤ 0). The manager owns
    /// the badge so it can re-apply it after `.accessory` → `.regular`
    /// activation-policy transitions, which destroy the Dock's tile state
    /// (issue #217). Synchronous and MainActor-bound so rapid successive
    /// counts can't be applied out of order.
    public var setBadgeCount: @MainActor @Sendable (_ count: Int) -> Void
}

// MARK: - DependencyKey

extension DockIconService: DependencyKey {
    public static var previewValue: DockIconService {
        DockIconService(
            startObserving: { },
            stopObserving: { },
            setBadgeCount: { _ in }
        )
    }

    public static var liveValue: DockIconService {
        DockIconService(
            startObserving: {
                await LiveDockIconManagerHolder.shared.startObserving()
            },
            stopObserving: {
                await LiveDockIconManagerHolder.shared.stopObserving()
            },
            setBadgeCount: { count in
                LiveDockIconManagerHolder.shared.setBadgeCount(count)
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
final class LiveDockIconManager {
    /// Default debounce window between rapid `handleWindowClosing` events and
    /// the resulting `updateActivationPolicy` call.
    static let defaultClosingDebounce: Duration = .milliseconds(100)

    private var observationTask: Task<Void, Never>?
    private var updatePolicyTask: Task<Void, Never>?

    /// Window identifiers to ignore when counting visible windows
    private let ignoredWindowClasses: Set = [
        "NSStatusBarWindow",
        "_NSPopoverWindow",
        "NSMenuWindowManagerWindow",
    ]

    private let closingDebounce: Duration

    @Dependency(\.continuousClock) private var clock

    /// Test hook fired immediately after the debounce timer resolves and
    /// `updateActivationPolicy()` runs. `nil` in production so there's no
    /// observable cost; tests substitute it to count debounced fires.
    var onActivationPolicyUpdated: (@MainActor () -> Void)?

    /// Test hook that receives every dock-tile badge write. `nil` in
    /// production, where writes go to `NSApp.dockTile.badgeLabel`; tests
    /// substitute it to record the write sequence.
    var badgeLabelWriter: (@MainActor (String?) -> Void)?

    /// The AppKit surface `updateActivationPolicy()` touches: activation
    /// policy read/write, visible-window count, and app activation.
    struct PolicyControls {
        var currentPolicy: @MainActor () -> NSApplication.ActivationPolicy
        var setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
        var visibleWindowCount: @MainActor () -> Int
        var activate: @MainActor () -> Void
    }

    /// Test hook substituting the AppKit surface of
    /// `updateActivationPolicy()`. `nil` in production, where the shared
    /// `NSApplication` is used; tests substitute it to drive policy
    /// transitions headlessly — `NSApp` is nil under `swift test` and E2E
    /// mode pins the policy, so the transition branches (including the
    /// badge re-apply that fixes issue #217) are otherwise unreachable.
    var policyControls: PolicyControls?

    /// The badge count currently requested by the app, kept so the badge can
    /// be re-applied whenever the dock tile is recreated by an activation
    /// policy transition.
    private(set) var badgeCount = 0

    init(closingDebounce: Duration = LiveDockIconManager.defaultClosingDebounce) {
        self.closingDebounce = closingDebounce
    }

    deinit {
        observationTask?.cancel()
        updatePolicyTask?.cancel()
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

    func setBadgeCount(_ count: Int) {
        badgeCount = count
        applyBadge()
    }

    /// Writes the stored badge count to the dock tile.
    ///
    /// `NSDockTile.badgeLabel`'s setter dedups unchanged values in-process,
    /// but the Dock discards its badge state whenever an `.accessory`
    /// transition destroys the tile — so re-setting the same value after the
    /// tile is recreated never reaches the Dock (issue #217). Clearing first
    /// forces the subsequent set to actually be transmitted.
    private func applyBadge() {
        writeBadgeLabel(nil)
        if badgeCount > 0 {
            writeBadgeLabel("\(badgeCount)")
        }
    }

    private func writeBadgeLabel(_ label: String?) {
        if let badgeLabelWriter {
            badgeLabelWriter(label)
        } else {
            NSApp?.dockTile.badgeLabel = label
        }
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

    func handleWindowClosing() {
        // Cancel any pending update and schedule a new one.
        // This ensures we only update once after rapid window close events.
        updatePolicyTask?.cancel()
        let interval = closingDebounce
        updatePolicyTask = Task { [weak self] in
            do {
                try await self?.clock.sleep(for: interval)
                self?.updateActivationPolicy()
                self?.onActivationPolicyUpdated?()
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
        // `NSApp` is an implicitly-unwrapped global that is nil until the shared
        // application instance exists. It is always live in the running app, but
        // can be nil in a headless unit-test process (where this would otherwise
        // trap). Treat "no application" as zero windows.
        guard let app = NSApp else { return 0 }
        return app.windows.filter { window in
            isRelevantWindow(window) && window.isVisible
        }.count
    }

    private func updateActivationPolicy() {
        if let policyControls {
            applyActivationPolicy(using: policyControls)
            return
        }
        guard !DockIconConfig.isE2ETestMode else { return }
        // No shared application instance (e.g. a headless unit-test process where
        // the `NSApp` IUO global is nil) → there is no dock icon to manage. The
        // caller still fires `onActivationPolicyUpdated`, so debounce-counting
        // tests are unaffected.
        guard let app = NSApp else { return }
        applyActivationPolicy(using: PolicyControls(
            currentPolicy: { app.activationPolicy() },
            setPolicy: { app.setActivationPolicy($0) },
            visibleWindowCount: { self.countVisibleAppWindows() },
            activate: { app.activate(ignoringOtherApps: false) }
        ))
    }

    private func applyActivationPolicy(using controls: PolicyControls) {
        let visibleCount = controls.visibleWindowCount()
        let currentPolicy = controls.currentPolicy()

        if visibleCount > 0 {
            if currentPolicy != .regular {
                controls.setPolicy(.regular)
                controls.activate()
            }
            // The tile may be freshly created — by the transition above, or by
            // a manual `.regular` set elsewhere (menu bar, notification tap)
            // right before the window that triggered this update appeared.
            // Fresh tiles start badge-less, so re-apply unconditionally.
            applyBadge()
        } else if currentPolicy != .accessory {
            controls.setPolicy(.accessory)
        }
    }
}
