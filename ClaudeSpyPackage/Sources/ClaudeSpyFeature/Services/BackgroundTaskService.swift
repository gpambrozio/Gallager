#if os(iOS)
    import ClaudeSpyCommon
    import Foundation
    import UIKit

    /// Manages background task to keep WebSocket connection alive briefly when app backgrounds.
    ///
    /// Uses `beginBackgroundTask` to request ~30 seconds of additional runtime when the app
    /// enters the background. This allows the WebSocket to remain connected long enough to
    /// receive any pending events before iOS suspends the app.
    ///
    /// After suspension, push notifications handle alerting the user to new events.
    @Observable
    @MainActor
    final public class BackgroundTaskService {
        // MARK: - Singleton

        public static let shared = BackgroundTaskService()

        // MARK: - Properties

        private let logger = Logger(label: "com.claudespy.backgroundtask")

        /// Current background task identifier, or .invalid if no task is active
        private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

        /// Whether a background task is currently active
        public var isBackgroundTaskActive: Bool {
            backgroundTaskID != .invalid
        }

        /// Remaining background time (for debugging/display)
        public var remainingBackgroundTime: TimeInterval {
            UIApplication.shared.backgroundTimeRemaining
        }

        // MARK: - Initialization

        private init() { }

        // MARK: - Public API

        /// Start a background task to extend runtime when app enters background.
        /// Call this when the app's scene phase changes to `.background`.
        ///
        /// The task automatically ends when:
        /// - The system's expiration handler is called (~30 seconds)
        /// - `endBackgroundTask()` is called manually (e.g., when returning to foreground)
        public func startBackgroundTask() {
            // Don't start a new task if one is already active
            guard backgroundTaskID == .invalid else {
                logger.debug("Background task already active, skipping")
                return
            }

            logger.info("Starting background task to maintain WebSocket connection")

            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "MaintainWebSocket") { [weak self] in
                // Expiration handler - called when time is about to run out
                Task { @MainActor in
                    self?.logger.info("Background task expiring, ending task")
                    self?.endBackgroundTaskInternal()
                }
            }

            if backgroundTaskID == .invalid {
                logger.warning("Failed to start background task - system rejected request")
            } else {
                let taskID = backgroundTaskID.rawValue
                let remaining = String(format: "%.1f", remainingBackgroundTime)
                logger.info("Background task started (taskID: \(taskID), remainingTime: \(remaining)s)")
            }
        }

        /// End the background task manually.
        /// Call this when the app returns to foreground (scene phase changes to `.active`).
        public func endBackgroundTask() {
            guard backgroundTaskID != .invalid else {
                logger.debug("No active background task to end")
                return
            }

            logger.info("Ending background task (app returned to foreground)")
            endBackgroundTaskInternal()
        }

        // MARK: - Private Methods

        private func endBackgroundTaskInternal() {
            guard backgroundTaskID != .invalid else { return }

            let taskID = backgroundTaskID
            backgroundTaskID = .invalid

            UIApplication.shared.endBackgroundTask(taskID)
            logger.debug("Background task ended (taskID: \(taskID.rawValue))")
        }
    }
#endif
