// ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/LicenseManager.swift
#if os(macOS)
    import ClaudeSpyEncryption
    import ClaudeSpyNetworking
    import Dependencies
    import Foundation
    import Observation

    /// Keychain accounts used for licensing secrets.
    public enum LicenseKeychainAccounts {
        public static let licenseKey = "lemonsqueezy-license-key"
    }

    /// Owns the Mac app's view of the hosted-relay license: current status,
    /// activation/deactivation actions, and the stored key. Trial-expiry
    /// alerting hangs off this class (Task 14).
    @Observable
    @MainActor
    final public class LicenseManager {
        public enum ActionState: Equatable {
            case idle
            case working
            case error(String)
        }

        public private(set) var status: LicenseStatus?
        public private(set) var actionState: ActionState = .idle
        public var licenseKeyField = ""

        /// Called after a successful `activate()` (and after `refreshStatus()`
        /// observes an expired→active transition, e.g. the user resubscribed via
        /// the Lemon Squeezy customer portal). `AppCoordinator` wires this to
        /// `ConnectedViewerManager.enableReconnectAndRetryAll()` so a host the
        /// relay previously blocked (which sets `shouldReconnect = false` on
        /// each `ConnectedViewer`) resumes its existing pairs immediately
        /// instead of waiting for a relaunch.
        public var onActivationSuccess: (@MainActor () -> Void)?

        @ObservationIgnored
        @Dependency(LicensingClient.self) private var client
        @ObservationIgnored
        @Dependency(SecretsService.self) private var secrets
        @ObservationIgnored
        @Dependency(DeviceNameClient.self) private var deviceNameClient
        @ObservationIgnored
        @Dependency(LicenseNotificationService.self) private var notifications

        private weak var settings: AppSettings?

        public init(settings: AppSettings) {
            self.settings = settings
        }

        /// Ceil of remaining trial days; nil unless status is an unexpired trial.
        public var trialDaysLeft: Int? {
            guard let status, status.state == .trial, let expiresAt = status.expiresAt else {
                return nil
            }
            let remaining = expiresAt.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            return Int((remaining / 86_400).rounded(.up))
        }

        public func loadStoredKey() async {
            guard licenseKeyField.isEmpty else { return }
            licenseKeyField = (try? await secrets.loadSecret(LicenseKeychainAccounts.licenseKey)) ?? ""
        }

        public func refreshStatus() async {
            guard let settings else { return }
            let previousState = status?.state
            do {
                status = try await client.status(settings.externalServerURL, settings.deviceId)
            } catch {
                // Status refresh is best-effort background work; existing
                // status (possibly nil) stays and connection errors surface
                // through the relay client's own state.
                return
            }
            // The relay blocks a host's viewer pairs (`shouldReconnect = false`)
            // the moment its subscription lapses. A poll that observes
            // expired→active (e.g. the user resubscribed via the Lemon Squeezy
            // customer portal, outside `activate()`) must resume them the same
            // way a successful `activate()` does.
            if previousState == .expired, status?.state == .active {
                onActivationSuccess?()
            }
        }

        public func activate() async {
            guard let settings else { return }
            let key = licenseKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                actionState = .error("Enter a license key first")
                return
            }
            actionState = .working
            do {
                status = try await client.activate(
                    settings.externalServerURL, key, settings.deviceId, deviceNameClient.current()
                )
                try? await secrets.storeSecret(key, LicenseKeychainAccounts.licenseKey)
                licenseKeyField = key
                actionState = .idle
                // Resume any pairs the relay blocked while this host had no
                // active subscription — see `onActivationSuccess` doc comment.
                onActivationSuccess?()
            } catch {
                actionState = .error(error.localizedDescription)
            }
        }

        public func deactivate() async {
            guard let settings else { return }
            actionState = .working
            do {
                try await client.deactivate(settings.externalServerURL, settings.deviceId)
                try? await secrets.deleteSecret(LicenseKeychainAccounts.licenseKey)
                licenseKeyField = ""
                actionState = .idle
                await refreshStatus()
            } catch {
                actionState = .error(error.localizedDescription)
            }
        }

        /// Fires pending 48h/24h trial-expiry alerts. Idempotent: flags are
        /// persisted per trial expiry in AppSettings.trialAlertsFired.
        public func checkTrialAlerts() {
            guard
                let settings,
                let status, status.state == .trial,
                let expiresAt = status.expiresAt else { return }

            let expiryKey = "\(Int(expiresAt.timeIntervalSince1970))"
            let alreadyFired = Set(settings.trialAlertsFired.compactMap { token -> Int? in
                let parts = token.split(separator: "-")
                guard parts.count == 2, parts[0] == expiryKey else { return nil }
                return Int(parts[1])
            })

            let pending = TrialAlertPlanner.thresholdsToFire(
                now: Date(), expiresAt: expiresAt, alreadyFired: alreadyFired
            )
            guard let mostUrgent = pending.first else { return }

            // MARK: - before-deliver, intentionally: the token is recorded even though
            // delivery is fire-and-forget and may no-op (e.g. notification permission
            // is currently `.denied`). We accept a missed 48h/24h banner rather than
            // risk re-firing on every 30-min poll; the countdown is always visible in
            // the Settings → Remote Access License section regardless.
            notifications.showTrialExpiryNotification(mostUrgent.rawValue)
            settings.trialAlertsFired.append(
                contentsOf: pending.map { "\(expiryKey)-\($0.rawValue)" }
            )
        }
    }
#endif
