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

        @ObservationIgnored
        @Dependency(LicensingClient.self) private var client
        @ObservationIgnored
        @Dependency(SecretsService.self) private var secrets
        @ObservationIgnored
        @Dependency(DeviceNameClient.self) private var deviceNameClient

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
            do {
                status = try await client.status(settings.externalServerURL, settings.deviceId)
            } catch {
                // Status refresh is best-effort background work; existing
                // status (possibly nil) stays and connection errors surface
                // through the relay client's own state.
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
    }
#endif
