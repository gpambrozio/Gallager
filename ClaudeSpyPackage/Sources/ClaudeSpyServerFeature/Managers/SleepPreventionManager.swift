import Dependencies
import DependenciesMacros
import Foundation
import IOKit.pwr_mgt
import Logging

/// A dependency for managing system sleep prevention.
///
/// Wraps IOKit sleep assertion APIs so they can be controlled in tests.
/// Use `@Dependency(SleepPreventionService.self)` to access it.
@DependencyClient
public struct SleepPreventionService: Sendable {
    /// Updates sleep prevention based on active session count.
    public var updateForSessionCount: @Sendable (_ sessionCount: Int, _ isEnabled: Bool) async -> Void

    /// Releases any held assertion (for explicit cleanup).
    public var releaseIfNeeded: @Sendable () async -> Void
}

// MARK: - DependencyKey

extension SleepPreventionService: DependencyKey {
    public static var liveValue: SleepPreventionService {
        let manager = LiveSleepPreventionManager()

        return SleepPreventionService(
            updateForSessionCount: { sessionCount, isEnabled in
                await manager.updateForSessionCount(sessionCount, isEnabled: isEnabled)
            },
            releaseIfNeeded: {
                await manager.releaseIfNeeded()
            }
        )
    }
}

// MARK: - Live Implementation

/// Actor-isolated implementation of sleep prevention using IOKit assertions.
private actor LiveSleepPreventionManager {
    private var isPreventingSleep = false
    private let assertionReason = "ClaudeSpy: Active Claude Code sessions" as CFString
    private var assertionID: IOPMAssertionID = 0
    private let logger = Logger(label: "com.claudespy.sleep-prevention")

    init() { }

    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }

    func updateForSessionCount(_ sessionCount: Int, isEnabled: Bool) {
        let shouldPreventSleep = isEnabled && sessionCount > 0

        if shouldPreventSleep && !isPreventingSleep {
            acquireAssertion()
        } else if !shouldPreventSleep && isPreventingSleep {
            releaseAssertion()
        }
    }

    func releaseIfNeeded() {
        if isPreventingSleep {
            releaseAssertion()
        }
    }

    private func acquireAssertion() {
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            assertionReason,
            &assertionID
        )

        if result == kIOReturnSuccess {
            isPreventingSleep = true
        } else {
            logger.warning("Failed to acquire sleep prevention assertion: \(result)")
        }
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }

        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isPreventingSleep = false
    }
}
