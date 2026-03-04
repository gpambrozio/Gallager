#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import Logging
    import UserNotifications

    /// Manages displaying macOS desktop notifications for terminal notification
    /// escape sequences (OSC 9/777) detected in monitored tmux panes.
    @MainActor
    final class TerminalNotificationService {
        private let logger = Logger(label: "com.claudespy.terminalnotification")
        private var isAuthorized = false
        private var hasRequestedPermission = false

        /// Show a macOS desktop notification for a terminal notification.
        ///
        /// Requests notification permission on first call. Notifications are
        /// delivered via `UNUserNotificationCenter`.
        func showNotification(
            paneId: String,
            notification: TerminalStreamMessage.TerminalNotification
        ) {
            Task {
                await ensurePermission()
                guard isAuthorized else { return }

                let content = UNMutableNotificationContent()
                content.title = notification.title ?? "Terminal"
                content.body = notification.body
                content.sound = .default
                content.categoryIdentifier = "terminalNotification"
                content.userInfo = ["paneId": paneId]

                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil // Deliver immediately
                )

                do {
                    try await UNUserNotificationCenter.current().add(request)
                    logger.debug("Delivered terminal notification", metadata: [
                        "paneId": "\(paneId)",
                        "title": "\(notification.title ?? "(none)")",
                    ])
                } catch {
                    logger.warning("Failed to deliver notification: \(error)")
                }
            }
        }

        // MARK: - Permission

        private func ensurePermission() async {
            guard !isAuthorized else { return }

            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            switch settings.authorizationStatus {
            case .authorized, .provisional:
                isAuthorized = true
            case .notDetermined:
                guard !hasRequestedPermission else { return }
                hasRequestedPermission = true
                do {
                    isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
                    logger.info("Notification permission \(isAuthorized ? "granted" : "denied")")
                } catch {
                    logger.warning("Failed to request notification permission: \(error)")
                }
            case .denied:
                if !hasRequestedPermission {
                    hasRequestedPermission = true
                    logger.info("Notification permission denied by user")
                }
            @unknown default:
                break
            }
        }
    }
#endif
