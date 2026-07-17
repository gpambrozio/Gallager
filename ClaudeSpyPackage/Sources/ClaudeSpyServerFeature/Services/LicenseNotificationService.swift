// ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/LicenseNotificationService.swift
#if os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging
    import UserNotifications

    /// Posts trial-expiry desktop notifications. Mirrors
    /// TerminalNotificationService's live handler (permission request +
    /// UNUserNotificationCenter add); taps are routed by
    /// ForegroundNotificationDelegate via userInfo["licenseAlert"].
    @DependencyClient
    public struct LicenseNotificationService: Sendable {
        public var showTrialExpiryNotification: @Sendable (_ hoursRemaining: Int) -> Void
    }

    extension LicenseNotificationService: DependencyKey {
        public static var previewValue: LicenseNotificationService {
            LicenseNotificationService(showTrialExpiryNotification: { _ in })
        }

        public static var liveValue: LicenseNotificationService {
            let handler = LiveLicenseNotificationHandler()
            return LicenseNotificationService(showTrialExpiryNotification: { hoursRemaining in
                Task {
                    await handler.show(hoursRemaining: hoursRemaining)
                }
            })
        }
    }

    // MARK: - Live Implementation

    /// Actor that manages UNUserNotificationCenter permission and delivery for
    /// trial-expiry alerts. Mirrors TerminalNotificationService's
    /// LiveNotificationHandler.ensurePermission() (same
    /// notDetermined/authorized/denied handling and delegate installation).
    private actor LiveLicenseNotificationHandler {
        private let logger = Logger(label: "com.claudespy.licensenotification")
        private var isAuthorized = false
        private var hasRequestedPermission = false
        private var hasInstalledDelegate = false

        func show(hoursRemaining: Int) async {
            await ensurePermission()
            guard isAuthorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "Gallager trial ending"
            content.body = "Your hosted-relay trial ends in less than \(hoursRemaining) hours. "
                + "Subscribe to keep remote access."
            content.sound = .default
            content.userInfo = ["licenseAlert": true]

            let request = UNNotificationRequest(
                identifier: "license-trial-\(hoursRemaining)h",
                content: content,
                trigger: nil
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
                logger.debug("Delivered trial-expiry notification", metadata: [
                    "hoursRemaining": "\(hoursRemaining)",
                ])
            } catch {
                logger.warning("Failed to deliver trial-expiry notification: \(error)")
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
