#if os(iOS)
    import Foundation
    import UIKit
    import UserNotifications

    /// Handles UIApplication delegate methods and UNUserNotificationCenter delegate methods.
    /// This class encapsulates all app delegate logic that was previously in the main app target,
    /// keeping the app entry point minimal while maintaining all functionality in the package.
    public class AppDelegateHandler: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
        // MARK: - UIApplicationDelegate

        public func application(
            _: UIApplication,
            didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            // Set ourselves as the notification center delegate to handle notification taps
            UNUserNotificationCenter.current().delegate = self
            // Register the static permission notification categories
            // (Yes / Always / No, issue #710). Merging keeps dynamic question
            // categories from still-delivered notifications functional.
            Task { @MainActor in
                await NotificationActionService.shared.registerBaseCategories()
            }
            return true
        }

        public func application(
            _: UIApplication,
            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
        ) {
            Task { @MainActor in
                PushNotificationService.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
            }
        }

        public func application(
            _: UIApplication,
            didFailToRegisterForRemoteNotificationsWithError error: Error
        ) {
            Task { @MainActor in
                PushNotificationService.shared.didFailToRegisterForRemoteNotifications(error: error)
            }
        }

        /// Handles silent (`apns-push-type: background`) pushes used by the
        /// relay to keep the iOS badge in sync with the host's
        /// needs-attention count. iOS auto-applies `aps.badge` only when it
        /// displays a notification banner — silent pushes wake the app in
        /// the background with no UI, so we must read the badge ourselves
        /// and apply it.
        public func application(
            _: UIApplication,
            didReceiveRemoteNotification userInfo: [AnyHashable: Any],
            fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
        ) {
            if
                let aps = userInfo["aps"] as? [String: Any],
                let badge = aps["badge"] as? Int {
                Task { @MainActor in
                    PushNotificationService.shared.applyBadge(badge)
                }
            }
            completionHandler(.noData)
        }

        // MARK: - UNUserNotificationCenterDelegate

        /// Called when the user taps a notification or one of its action
        /// buttons (app possibly launched into the background for it). Action
        /// taps are handled by `NotificationActionService` (answering the form
        /// over the relay, issue #710) — the completion handler is deferred
        /// until that round-trip finishes so iOS keeps the process alive.
        /// Plain taps fall through to the existing deep-link path.
        public func userNotificationCenter(
            _: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            Task { @MainActor in
                let handled = await NotificationActionService.shared.handle(response)
                if !handled {
                    PushNotificationService.shared.handleNotificationResponse(response)
                }
                completionHandler()
            }
        }

        /// Called when notification arrives while app is in foreground
        public func userNotificationCenter(
            _: UNUserNotificationCenter,
            willPresent _: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            // Show the notification even when app is in foreground (banner + sound)
            completionHandler([.banner, .sound])
        }
    }
#endif
