#if os(iOS)
import Foundation
import UIKit
import UserNotifications

/// Manages push notification registration and token handling
@Observable
@MainActor
public final class PushNotificationService: NSObject, Sendable {
    // MARK: - Singleton

    public static let shared = PushNotificationService()

    // MARK: - Properties

    /// The raw device token data from APNs
    public private(set) var deviceToken: Data?

    /// The device token as a hex string, suitable for sending to server
    public private(set) var tokenString: String?

    /// Current notification permission status
    public private(set) var permissionStatus: UNAuthorizationStatus = .notDetermined

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
        self.permissionStatus = settings.authorizationStatus
    }

    /// Called from AppDelegate when device token is received
    public func didRegisterForRemoteNotifications(deviceToken: Data) {
        self.deviceToken = deviceToken
        self.tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    }

    /// Called from AppDelegate on registration failure
    public func didFailToRegisterForRemoteNotifications(error: Error) {
        print("Failed to register for remote notifications: \(error.localizedDescription)")
        self.deviceToken = nil
        self.tokenString = nil
    }

    /// Clear token data (e.g., on unpair)
    public func clearToken() {
        deviceToken = nil
        tokenString = nil
    }
}
#endif
