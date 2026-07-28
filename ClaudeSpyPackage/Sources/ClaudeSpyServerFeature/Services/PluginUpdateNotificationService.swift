#if os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging
    import UserNotifications

    /// Posts "plugin updates installed — restart …" desktop notifications.
    /// Mirrors LicenseNotificationService's live handler (permission request +
    /// UNUserNotificationCenter add).
    @DependencyClient
    public struct PluginUpdateNotificationService: Sendable {
        public var showUpdateNotification: @Sendable (_ body: String) -> Void
    }

    extension PluginUpdateNotificationService: DependencyKey {
        public static var previewValue: PluginUpdateNotificationService {
            PluginUpdateNotificationService(showUpdateNotification: { _ in })
        }

        public static var liveValue: PluginUpdateNotificationService {
            let handler = LivePluginUpdateNotificationHandler()
            return PluginUpdateNotificationService(showUpdateNotification: { body in
                Task {
                    await handler.show(body: body)
                }
            })
        }
    }

    /// Actor managing UNUserNotificationCenter permission + delivery. The
    /// ensurePermission() body is identical to LiveLicenseNotificationHandler's.
    private actor LivePluginUpdateNotificationHandler {
        private let logger = Logger(label: "com.claudespy.pluginupdatenotification")
        private var isAuthorized = false
        private var hasRequestedPermission = false
        private var hasInstalledDelegate = false

        func show(body: String) async {
            await ensurePermission()
            guard isAuthorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "Plugin updates installed"
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "plugin-update-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                logger.warning("Failed to deliver plugin-update notification: \(error)")
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
#endif
