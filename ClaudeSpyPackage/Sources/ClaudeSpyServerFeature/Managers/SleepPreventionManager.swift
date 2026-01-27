import Foundation
import IOKit.pwr_mgt
import Logging

/// Manages system sleep prevention based on active Claude Code sessions.
///
/// When Claude Code sessions are active, this manager prevents the Mac from sleeping
/// so users can monitor sessions remotely without interruption. The assertion is
/// automatically released when all sessions end.
@MainActor
final public class SleepPreventionManager {
    /// Whether sleep prevention is currently active
    public private(set) var isPreventingSleep = false

    /// The reason shown in Activity Monitor under "Assertions" (for debugging)
    private let assertionReason = "ClaudeSpy: Active Claude Code sessions" as CFString

    /// IOKit assertion ID (0 when no assertion is held)
    private var assertionID: IOPMAssertionID = 0

    private let logger = Logger(label: "com.claudespy.sleep-prevention")

    public init() { }

    deinit {
        // Release any held assertion on cleanup
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }

    // MARK: - Public API

    /// Updates sleep prevention based on active session count.
    ///
    /// Call this whenever the active session count changes.
    /// - Parameters:
    ///   - sessionCount: Number of active Claude Code sessions
    ///   - isEnabled: Whether sleep prevention is enabled in settings
    public func updateForSessionCount(_ sessionCount: Int, isEnabled: Bool) {
        let shouldPreventSleep = isEnabled && sessionCount > 0

        if shouldPreventSleep && !isPreventingSleep {
            acquireAssertion()
        } else if !shouldPreventSleep && isPreventingSleep {
            releaseAssertion()
        }
    }

    /// Releases any held assertion (for explicit cleanup).
    public func releaseIfNeeded() {
        if isPreventingSleep {
            releaseAssertion()
        }
    }

    // MARK: - Private

    private func acquireAssertion() {
        // kIOPMAssertionTypePreventUserIdleSystemSleep prevents idle sleep
        // but allows sleep from lid close or explicit sleep command
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
