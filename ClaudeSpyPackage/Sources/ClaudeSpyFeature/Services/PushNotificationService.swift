#if os(iOS)
    import Dependencies
    import DependenciesMacros
    import Foundation
    import UIKit
    import UserNotifications

    /// A dependency for interacting with push notification system APIs.
    ///
    /// Wraps `UNUserNotificationCenter` and `UIApplication` so they can be controlled in tests.
    /// Use `@Dependency(PushNotificationClient.self)` to access it.
    @DependencyClient
    public struct PushNotificationClient: Sendable {
        /// Request notification authorization and return whether granted.
        public var requestAuthorization: @Sendable () async throws -> Bool = { false }

        /// Register for remote notifications with APNs.
        public var registerForRemoteNotifications: @Sendable () async -> Void

        /// Get current notification settings.
        public var getAuthorizationStatus: @Sendable () async -> UNAuthorizationStatus = { .notDetermined }

        /// Set the app badge count.
        public var setBadgeCount: @Sendable (_ count: Int) -> Void

        /// Schedule a local notification immediately.
        public var scheduleLocalNotification: @Sendable (
            _ title: String,
            _ body: String,
            _ userInfo: [String: String]
        ) -> Void
    }

    // MARK: - DependencyKey

    extension PushNotificationClient: DependencyKey {
        public static var previewValue: PushNotificationClient {
            PushNotificationClient(
                requestAuthorization: { true },
                registerForRemoteNotifications: { },
                getAuthorizationStatus: { .authorized },
                setBadgeCount: { _ in },
                scheduleLocalNotification: { _, _, _ in }
            )
        }

        public static var liveValue: PushNotificationClient {
            PushNotificationClient(
                requestAuthorization: {
                    try await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .badge, .sound])
                },
                registerForRemoteNotifications: {
                    await UIApplication.shared.registerForRemoteNotifications()
                },
                getAuthorizationStatus: {
                    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                },
                setBadgeCount: { count in
                    UNUserNotificationCenter.current().setBadgeCount(count)
                },
                scheduleLocalNotification: { title, body, userInfo in
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = body
                    content.sound = .default
                    content.badge = 1
                    content.userInfo = userInfo

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
            )
        }
    }

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

        /// Whether the app is currently foregrounded (`scenePhase == .active`).
        /// Drives the backgrounded-only local-notification fallback: a host's
        /// notification pushed over the live socket is only materialized locally
        /// when the user can't already see the app. Updated from the scene phase.
        public private(set) var isAppActive = true

        /// Update the foreground/active flag from the app's scene phase.
        public func setAppActive(_ active: Bool) {
            isAppActive = active
        }

        /// Deep link info from a tapped notification.
        public var pendingDeepLink: DeepLinkInfo?

        /// Information needed to deep link to a specific session
        public struct DeepLinkInfo: Equatable {
            public let paneId: String
            public let hostId: String
        }

        /// Whether we've successfully registered for remote notifications
        public var isRegistered: Bool {
            tokenString != nil
        }

        @ObservationIgnored
        @Dependency(PushNotificationClient.self) private var client

        // MARK: - Initialization

        private override init() {
            super.init()
        }

        // MARK: - Public API

        /// Request notification permissions and register for remote notifications.
        ///
        /// In E2E mode we skip the system permission dialog (which would hang the
        /// scenario) and instead inject a deterministic synthetic device token.
        /// The relay needs *some* token in `pair.pushToken` to exercise the APNs
        /// dispatch path — scenarios that assert on badge aggregation rely on
        /// this so the relay can match sibling pairs by token.
        public func requestAuthorization() async throws {
            if CommandLine.arguments.contains("--e2e-test") {
                let synthetic = Self.syntheticDeviceToken()
                didRegisterForRemoteNotifications(deviceToken: synthetic)
                permissionStatus = .authorized
                return
            }

            let granted = try await client.requestAuthorization()

            await updatePermissionStatus()

            if granted {
                await client.registerForRemoteNotifications()
            }
        }

        /// Deterministic 32-byte token used in E2E so scenarios know exactly
        /// which token the relay receives. The bytes themselves are arbitrary;
        /// what matters is that the same value is registered every run, which
        /// makes assertions stable.
        private static func syntheticDeviceToken() -> Data {
            // "e2e-ios-synthetic-token-........"  → 32 bytes when zero-padded
            var bytes = [UInt8](repeating: 0, count: 32)
            let marker = "e2eiossynthetictoken".utf8
            for (idx, byte) in marker.enumerated() where idx < bytes.count {
                bytes[idx] = byte
            }
            return Data(bytes)
        }

        /// Check and update current permission status
        public func updatePermissionStatus() async {
            permissionStatus = await client.getAuthorizationStatus()
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
            client.setBadgeCount(0)
        }

        /// Apply an absolute badge count to the app icon. Used when a silent
        /// (`apns-push-type: background`) push carries an `aps.badge` value —
        /// iOS only auto-applies the badge for alert notifications, so the
        /// relay's silent decrement path relies on us reading the badge in
        /// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
        /// and pushing it through here.
        public func applyBadge(_ count: Int) {
            client.setBadgeCount(count)
        }

        // MARK: - Local Notifications

        /// Schedule a local notification immediately.
        public func scheduleLocalNotification(title: String, body: String, paneId: String? = nil, hostId: String? = nil) {
            guard permissionStatus == .authorized else { return }

            var userInfo: [String: String] = [:]
            if let paneId {
                userInfo["paneId"] = paneId
            }
            if let hostId {
                userInfo["pairId"] = hostId
            }

            client.scheduleLocalNotification(title, body, userInfo)
        }

        // MARK: - Deep Linking

        /// Handle a notification response (user tapped on notification).
        public func handleNotificationResponse(_ response: UNNotificationResponse) {
            let userInfo = response.notification.request.content.userInfo

            if
                let paneId = userInfo["paneId"] as? String,
                let hostId = userInfo["pairId"] as? String {
                pendingDeepLink = DeepLinkInfo(paneId: paneId, hostId: hostId)
            }
        }

        /// Consume the pending deep link, returning and clearing the deep link info.
        public func consumePendingDeepLink() -> DeepLinkInfo? {
            let deepLink = pendingDeepLink
            pendingDeepLink = nil
            return deepLink
        }
    }
#endif
