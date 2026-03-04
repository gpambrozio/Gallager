#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging
    import UserNotifications

    /// Displays macOS desktop notifications for terminal notification
    /// escape sequences (OSC 9/777) detected in monitored tmux panes.
    @DependencyClient
    public struct TerminalNotificationService: Sendable {
        /// Show a notification for a terminal escape sequence.
        public var showNotification: @Sendable (
            _ paneId: String,
            _ notification: TerminalStreamMessage.TerminalNotification
        ) -> Void
    }

    // MARK: - E2E Test Support

    public extension TerminalNotificationService {
        /// Factory for E2E tests — appends notifications to a log file instead of
        /// displaying desktop notifications, allowing test assertions on the file.
        static func e2eTest(logPath: String) -> TerminalNotificationService {
            TerminalNotificationService(
                showNotification: { paneId, notification in
                    let title = notification.title ?? ""
                    let entry = "\(paneId)|\(title)|\(notification.body)\n"
                    let data = Data(entry.utf8)

                    if let handle = FileHandle(forWritingAtPath: logPath) {
                        defer { handle.closeFile() }
                        handle.seekToEndOfFile()
                        handle.write(data)
                    } else {
                        FileManager.default.createFile(atPath: logPath, contents: data)
                    }
                }
            )
        }
    }

    // MARK: - DependencyKey

    extension TerminalNotificationService: DependencyKey {
        public static var previewValue: TerminalNotificationService {
            TerminalNotificationService(showNotification: { _, _ in })
        }

        public static var liveValue: TerminalNotificationService {
            let handler = LiveNotificationHandler()
            return TerminalNotificationService(
                showNotification: { paneId, notification in
                    Task {
                        await handler.show(paneId: paneId, notification: notification)
                    }
                }
            )
        }
    }

    // MARK: - Live Implementation

    /// Actor that manages UNUserNotificationCenter permission and delivery.
    private actor LiveNotificationHandler {
        private let logger = Logger(label: "com.claudespy.terminalnotification")
        private var isAuthorized = false
        private var hasRequestedPermission = false
        private var hasInstalledDelegate = false

        func show(
            paneId: String,
            notification: TerminalStreamMessage.TerminalNotification
        ) async {
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
                trigger: nil
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

        private func ensurePermission() async {
            guard !isAuthorized else { return }

            let center = UNUserNotificationCenter.current()

            // Install delegate so notifications display even when the app is in the foreground.
            // UNUserNotificationCenter holds its delegate weakly, so ForegroundNotificationDelegate
            // retains itself via a static property.
            if !hasInstalledDelegate {
                hasInstalledDelegate = true
                await MainActor.run {
                    UNUserNotificationCenter.current().delegate = ForegroundNotificationDelegate.shared
                }
            }

            let settings = await center.notificationSettings()

            switch settings.authorizationStatus {
            case .authorized,
                 .provisional:
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

    // MARK: - Foreground Notification Delegate

    /// Allows notifications to display as banners even when the app is in the foreground.
    /// Without this, macOS silently suppresses notifications for the active app.
    final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        static let shared = ForegroundNotificationDelegate()

        /// Handler called on the main actor when a notification is tapped.
        @MainActor var onTapped: ((_ paneId: String) -> Void)?

        func userNotificationCenter(
            _: UNUserNotificationCenter,
            willPresent _: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }

        func userNotificationCenter(
            _: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            guard let paneId = response.notification.request.content.userInfo["paneId"] as? String else { return }
            // Schedule after didReceive returns — the system may reclaim focus
            // while this async method is still running.
            await MainActor.run {
                let handler = onTapped
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    handler?(paneId)
                }
            }
        }
    }
#endif
