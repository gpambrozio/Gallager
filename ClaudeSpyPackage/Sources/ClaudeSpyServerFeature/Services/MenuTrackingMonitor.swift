import AppKit
import Foundation

/// Watches `NSMenu` tracking notifications globally so any periodic
/// state-mutating loop can stand down while a popup is open.
///
/// `didBeginTrackingNotification` and `didEndTrackingNotification` fire on
/// every menu open/close — both menu-bar drop-downs and SwiftUI
/// `.contextMenu` / `Menu` popups. The count is bumped on begin and
/// decremented on end; consumers consult `isTracking` from their refresh
/// loops to skip cycles whose `@Observable` mutations would otherwise
/// ripple through SwiftUI reconciliation and cause AppKit to dismiss the
/// open popup mid-hover (most visibly the "Open in Editor" submenu).
@MainActor
final public class MenuTrackingMonitor {
    /// Number of `NSMenu`s currently in tracking mode.
    public private(set) var trackingCount = 0

    /// `true` while at least one menu is in tracking mode.
    public var isTracking: Bool { trackingCount > 0 }

    private var observationTask: Task<Void, Never>?

    public init() {
        startObserving()
    }

    /// Begin observing menu tracking notifications. Idempotent — calling
    /// repeatedly is a no-op until `stopObserving()` is called.
    public func startObserving() {
        guard observationTask == nil else { return }
        let center = NotificationCenter.default
        observationTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await _ in center.notifications(named: NSMenu.didBeginTrackingNotification) {
                        await self?.increment()
                    }
                }
                group.addTask { [weak self] in
                    for await _ in center.notifications(named: NSMenu.didEndTrackingNotification) {
                        await self?.decrement()
                    }
                }
            }
        }
    }

    public func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    private func increment() {
        trackingCount += 1
    }

    private func decrement() {
        trackingCount = max(0, trackingCount - 1)
    }
}
