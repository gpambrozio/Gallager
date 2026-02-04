#if os(iOS)
    import Foundation
    import UIKit
    import UserNotifications

    /// Manages push notification registration and token handling
    @Observable
    @MainActor
    final public class PushNotificationService: NSObject {
        // MARK: - Singleton

        public static let shared = PushNotificationService()

        // MARK: - Properties

        /// The raw device token data from APNs
        public private(set) var deviceToken: Data?

        /// The device token as a hex string, suitable for sending to server
        public private(set) var tokenString: String?

        /// Current notification permission status
        public private(set) var permissionStatus: UNAuthorizationStatus = .notDetermined

        /// Deep link info from a tapped notification.
        /// Set when user taps a notification, consumed by MainView to navigate to the session.
        public var pendingDeepLink: DeepLinkInfo?

        /// Information needed to deep link to a specific session
        public struct DeepLinkInfo: Equatable {
            public let paneId: String
            public let macId: String
        }

        /// Whether we've successfully registered for remote notifications
        public var isRegistered: Bool {
            tokenString != nil
        }

        // MARK: - Initialization

        private override init() {
            super.init()
        }

        // MARK: - Public API

        /// Request notification permissions and register for remote notifications
        /// Call this after the user has paired their device
        public func requestAuthorization() async throws {
            let center = UNUserNotificationCenter.current()

            // Request permission
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])

            // Update status
            await updatePermissionStatus()

            if granted {
                // Register for remote notifications
                UIApplication.shared.registerForRemoteNotifications()
            }
        }

        /// Check and update current permission status
        public func updatePermissionStatus() async {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            permissionStatus = settings.authorizationStatus
        }

        /// Called from AppDelegate when device token is received
        public func didRegisterForRemoteNotifications(deviceToken: Data) {
            self.deviceToken = deviceToken
            tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        }

        /// Called from AppDelegate on registration failure
        public func didFailToRegisterForRemoteNotifications(error: Error) {
            print("Failed to register for remote notifications: \(error.localizedDescription)")
            deviceToken = nil
            tokenString = nil
        }

        /// Clear token data (e.g., on unpair)
        public func clearToken() {
            deviceToken = nil
            tokenString = nil
        }

        /// Clear the app badge
        public func clearBadge() {
            UNUserNotificationCenter.current().setBadgeCount(0)
        }

        // MARK: - Local Notifications

        /// Schedule a local notification immediately.
        /// Used when app receives WebSocket events while backgrounded - the server
        /// won't send a push (since we're "connected"), so we show a local notification instead.
        public func scheduleLocalNotification(title: String, body: String, paneId: String? = nil, macId: String? = nil) {
            guard permissionStatus == .authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.badge = 1

            // Include paneId and macId for deep linking when notification is tapped
            if let paneId {
                content.userInfo["paneId"] = paneId
            }
            if let macId {
                content.userInfo["pairId"] = macId
            }

            // Trigger immediately
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    print("Failed to schedule local notification: \(error)")
                }
            }
        }

        // MARK: - Deep Linking

        /// Handle a notification response (user tapped on notification).
        /// Extracts paneId and macId from userInfo and sets it for deep linking.
        ///
        /// - Parameter response: The notification response from UNUserNotificationCenterDelegate
        public func handleNotificationResponse(_ response: UNNotificationResponse) {
            let userInfo = response.notification.request.content.userInfo

            // Extract paneId and macId from notification payload for deep linking
            if let paneId = userInfo["paneId"] as? String,
               let macId = userInfo["pairId"] as? String
            {
                pendingDeepLink = DeepLinkInfo(paneId: paneId, macId: macId)
            }
        }

        /// Consume the pending deep link, returning and clearing the deep link info.
        /// Call this after navigation has been performed.
        ///
        /// - Returns: The deep link info to navigate to, or nil if no pending deep link
        public func consumePendingDeepLink() -> DeepLinkInfo? {
            let deepLink = pendingDeepLink
            pendingDeepLink = nil
            return deepLink
        }
    }
#endif
