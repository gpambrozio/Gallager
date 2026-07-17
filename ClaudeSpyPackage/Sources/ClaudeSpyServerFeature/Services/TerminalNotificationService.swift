#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging
    import UserNotifications

    /// Displays macOS desktop notifications — both for terminal notification
    /// escape sequences (OSC 9/777) detected in monitored tmux panes and for
    /// agent notifications pushed by a remote host while acting as its viewer.
    @DependencyClient
    public struct TerminalNotificationService: Sendable {
        /// Show a local desktop notification. Fired both for terminal escape
        /// sequences (OSC 9/777) in the app's own monitored panes and for agent
        /// notifications pushed by a remote host while acting as its viewer.
        /// When `hostId` is non-nil the notification came from that remote host,
        /// so tapping it reveals the remote session rather than a local pane.
        public var showNotification: @Sendable (
            _ paneId: String,
            _ notification: TerminalStreamMessage.TerminalNotification,
            _ hostId: String?
        ) -> Void
    }

    // MARK: - E2E Test Support

    public extension TerminalNotificationService {
        /// Factory for E2E tests — appends notifications to a log file instead of
        /// displaying desktop notifications, allowing test assertions on the file.
        static func e2eTest(logPath: String) -> TerminalNotificationService {
            TerminalNotificationService(
                showNotification: { paneId, notification, hostId in
                    let title = notification.title ?? ""
                    // Append the originating host only for viewer notifications
                    // (hostId set) so scenarios can assert on them; local terminal
                    // notifications keep the original three-field format.
                    let origin = hostId.map { "|\($0)" } ?? ""
                    let entry = "\(paneId)|\(title)|\(notification.body)\(origin)\n"
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
            TerminalNotificationService(showNotification: { _, _, _ in })
        }

        public static var liveValue: TerminalNotificationService {
            let handler = LiveNotificationHandler()
            return TerminalNotificationService(
                showNotification: { paneId, notification, hostId in
                    Task {
                        await handler.show(paneId: paneId, notification: notification, hostId: hostId)
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
            notification: TerminalStreamMessage.TerminalNotification,
            hostId: String?
        ) async {
            await ensurePermission()
            guard isAuthorized else { return }

            let content = UNMutableNotificationContent()
            content.title = notification.title ?? "Terminal"
            content.body = notification.body
            content.sound = .default
            content.categoryIdentifier = "terminalNotification"
            // Carry the originating remote host (viewer mode) so a tap can reveal
            // the remote session; left nil for the app's own local panes.
            var userInfo: [String: String] = ["paneId": paneId]
            if let hostId {
                userInfo["hostId"] = hostId
            }
            content.userInfo = userInfo

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
                    isAuthorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
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
    ///
    /// `@unchecked Sendable` is safe here because:
    /// - `onTapped` is `@MainActor`-isolated and only accessed from MainActor contexts
    /// - `willPresent` accesses no mutable state
    /// - `didReceive` hops to MainActor via `await MainActor.run` before touching `onTapped`
    final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        static let shared = ForegroundNotificationDelegate()

        /// Handler called on the main actor when a notification is tapped.
        /// `hostId` is non-nil when the notification came from a remote host
        /// (viewer mode), so the tap reveals that host's remote session.
        @MainActor var onTapped: ((_ paneId: String, _ hostId: String?) -> Void)?

        /// Handler called on the main actor when a trial-expiry alert
        /// (`userInfo["licenseAlert"] == true`) is tapped.
        @MainActor var onLicenseAlertTapped: (() -> Void)?

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
            let userInfo = response.notification.request.content.userInfo

            if userInfo["licenseAlert"] as? Bool == true {
                // Schedule after didReceive returns — the system may reclaim focus
                // while this async method is still running.
                await MainActor.run {
                    let handler = onLicenseAlertTapped
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        handler?()
                    }
                }
                return
            }

            guard let paneId = userInfo["paneId"] as? String else { return }
            let hostId = userInfo["hostId"] as? String
            // Schedule after didReceive returns — the system may reclaim focus
            // while this async method is still running.
            await MainActor.run {
                let handler = onTapped
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    handler?(paneId, hostId)
                }
            }
        }
    }
#endif
