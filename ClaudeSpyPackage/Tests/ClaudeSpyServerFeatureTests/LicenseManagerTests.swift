#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import ClaudeSpyNetworking
    import ConcurrencyExtras
    import Dependencies
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("LicenseManager")
    @MainActor
    struct LicenseManagerTests {
        /// LS keys are UUIDs; activate() rejects anything else client-side.
        private nonisolated static let validKey = "084A4570-4DD0-49DF-9214-86565DFC8959"

        private func makeManager(
            client: LicensingClient,
            secrets: SecretsService = .inMemory()
        ) -> (LicenseManager, AppSettings) {
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[LicensingClient.self] = client
                $0[SecretsService.self] = secrets
                $0[DeviceNameClient.self] = DeviceNameClient(current: { "Test Mac" })
            } operation: {
                let settings = AppSettings()
                settings.deviceId = "device-1"
                let manager = LicenseManager(settings: settings)
                return (manager, settings)
            }
        }

        @Test("refreshStatus populates status")
        func refresh() async {
            let (manager, settings) = makeManager(client: LicensingClient(
                activate: { _, _, _, _ in LicenseStatus(state: .active) },
                deactivate: { _, _ in },
                status: { _, _ in LicenseStatus(state: .trial, expiresAt: Date().addingTimeInterval(86_400)) }
            ))
            await manager.refreshStatus()
            #expect(manager.status?.state == .trial)
            #expect(manager.trialDaysLeft == 1)
            // Keeps AppSettings alive past the awaits above — LicenseManager holds it weakly.
            withExtendedLifetime(settings) { }
        }

        @Test("activate sanitizes the key, stores it in secrets, and updates status")
        func activateStoresKey() async throws {
            let secrets = SecretsService.inMemory()
            let (manager, settings) = makeManager(
                client: LicensingClient(
                    activate: { _, key, _, _ in
                        #expect(key == Self.validKey)
                        return LicenseStatus(state: .active, activationLimit: 3, activationUsage: 1)
                    },
                    deactivate: { _, _ in },
                    status: { _, _ in LicenseStatus(state: .active) }
                ),
                secrets: secrets
            )
            // Email-copied wrap artifacts (padding, embedded newline,
            // zero-width space) are stripped before validation and send.
            manager.licenseKeyField = "  084A4570-4DD0-49DF-\n9214-86565DFC8959\u{200B}  "
            await manager.activate()
            #expect(manager.status?.state == .active)
            #expect(manager.actionState == .idle)
            let stored = try await secrets.loadSecret(LicenseKeychainAccounts.licenseKey)
            #expect(stored == Self.validKey)
            withExtendedLifetime(settings) { }
        }

        @Test("activate rejects a non-UUID key without calling the server")
        func activateRejectsMalformedKey() async {
            let called = LockIsolated(false)
            let (manager, settings) = makeManager(client: LicensingClient(
                activate: { _, _, _, _ in
                    called.setValue(true)
                    return LicenseStatus(state: .active)
                },
                deactivate: { _, _ in },
                status: { _, _ in LicenseStatus(state: .none) }
            ))
            manager.licenseKeyField = "KEY-42"
            await manager.activate()
            #expect(manager.actionState == .error("Invalid key"))
            #expect(called.value == false)
            withExtendedLifetime(settings) { }
        }

        @Test("activation failure surfaces the server message")
        func activateFailure() async {
            let (manager, settings) = makeManager(client: LicensingClient(
                activate: { _, _, _, _ in
                    throw LicensingClientError.server("This license key has reached the activation limit.")
                },
                deactivate: { _, _ in },
                status: { _, _ in LicenseStatus(state: .none) }
            ))
            manager.licenseKeyField = Self.validKey
            await manager.activate()
            #expect(
                manager.actionState
                    == .error("This license key has reached the activation limit.")
            )
            withExtendedLifetime(settings) { }
        }

        @Test("deactivate clears the stored key and refreshes")
        func deactivateClears() async throws {
            let secrets = SecretsService.inMemory()
            try await secrets.storeSecret("KEY-42", LicenseKeychainAccounts.licenseKey)
            let (manager, settings) = makeManager(
                client: LicensingClient(
                    activate: { _, _, _, _ in LicenseStatus(state: .active) },
                    deactivate: { _, _ in },
                    status: { _, _ in LicenseStatus(state: .none) }
                ),
                secrets: secrets
            )
            await manager.deactivate()
            #expect(manager.status?.state == LicenseStatus.State.none)
            let stored = try await secrets.loadSecret(LicenseKeychainAccounts.licenseKey)
            #expect(stored == nil)
            withExtendedLifetime(settings) { }
        }

        @Test("activate fires onActivationSuccess")
        func activateFiresCallback() async {
            let (manager, settings) = makeManager(client: LicensingClient(
                activate: { _, _, _, _ in LicenseStatus(state: .active) },
                deactivate: { _, _ in },
                status: { _, _ in LicenseStatus(state: .active) }
            ))
            let fired = LockIsolated(0)
            manager.onActivationSuccess = { fired.withValue { $0 += 1 } }
            manager.licenseKeyField = Self.validKey
            await manager.activate()
            #expect(fired.value == 1)
            withExtendedLifetime(settings) { }
        }

        @Test("refreshStatus observing expired→active fires onActivationSuccess")
        func refreshExpiredToActiveFiresCallback() async {
            let statusResponse = LockIsolated(LicenseStatus(state: .expired))
            let (manager, settings) = makeManager(client: LicensingClient(
                activate: { _, _, _, _ in LicenseStatus(state: .active) },
                deactivate: { _, _ in },
                status: { _, _ in statusResponse.value }
            ))
            let fired = LockIsolated(0)
            manager.onActivationSuccess = { fired.withValue { $0 += 1 } }

            await manager.refreshStatus() // none → expired
            #expect(fired.value == 0)

            statusResponse.setValue(LicenseStatus(state: .active))
            await manager.refreshStatus() // expired → active: resubscribed externally
            #expect(fired.value == 1)

            await manager.refreshStatus() // active → active: no re-fire
            #expect(fired.value == 1)
            withExtendedLifetime(settings) { }
        }

        @Test("checkTrialAlerts fires once and persists flags")
        func trialAlertsFireOnce() async {
            let expiry = Date().addingTimeInterval(20 * 3_600) // inside 24h window
            let fired = LockIsolated<[Int]>([])
            let (manager, settings) = withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[LicensingClient.self] = LicensingClient(
                    activate: { _, _, _, _ in LicenseStatus(state: .active) },
                    deactivate: { _, _ in },
                    status: { _, _ in LicenseStatus(state: .trial, expiresAt: expiry) }
                )
                $0[SecretsService.self] = .inMemory()
                $0[LicenseNotificationService.self] = LicenseNotificationService(
                    showTrialExpiryNotification: { hours in fired.withValue { $0.append(hours) } }
                )
            } operation: {
                let settings = AppSettings()
                settings.deviceId = "device-1"
                return (LicenseManager(settings: settings), settings)
            }

            await manager.refreshStatus()
            manager.checkTrialAlerts()
            #expect(fired.value == [24]) // one notification: the most urgent
            #expect(settings.trialAlertsFired.count == 2) // both thresholds marked

            manager.checkTrialAlerts()
            #expect(fired.value == [24]) // idempotent
        }
    }

    @Suite("TrialAlertPlanner")
    struct TrialAlertPlannerTests {
        private let expiry = Date(timeIntervalSince1970: 1_800_000_000)

        @Test("Nothing fires above 48h remaining")
        func nothingEarly() {
            let now = expiry.addingTimeInterval(-49 * 3_600)
            #expect(TrialAlertPlanner.thresholdsToFire(now: now, expiresAt: expiry, alreadyFired: []).isEmpty)
        }

        @Test("48h threshold fires inside the window, once")
        func fires48() {
            let now = expiry.addingTimeInterval(-47 * 3_600)
            #expect(
                TrialAlertPlanner.thresholdsToFire(now: now, expiresAt: expiry, alreadyFired: [])
                    == [.hours48]
            )
            #expect(
                TrialAlertPlanner.thresholdsToFire(now: now, expiresAt: expiry, alreadyFired: [48])
                    .isEmpty
            )
        }

        @Test("Inside 24h, both unfired thresholds apply, most urgent first")
        func fires24AndCatchUp() {
            let now = expiry.addingTimeInterval(-20 * 3_600)
            #expect(
                TrialAlertPlanner.thresholdsToFire(now: now, expiresAt: expiry, alreadyFired: [])
                    == [.hours24, .hours48]
            )
            #expect(
                TrialAlertPlanner.thresholdsToFire(now: now, expiresAt: expiry, alreadyFired: [48])
                    == [.hours24]
            )
        }

        @Test("Nothing fires after expiry")
        func nothingAfterExpiry() {
            let now = expiry.addingTimeInterval(60)
            #expect(TrialAlertPlanner.thresholdsToFire(now: now, expiresAt: expiry, alreadyFired: []).isEmpty)
        }
    }
#endif
