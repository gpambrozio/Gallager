#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import ClaudeSpyNetworking
    import Dependencies
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("LicenseManager")
    @MainActor
    struct LicenseManagerTests {
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

        @Test("activate stores the key in secrets and updates status")
        func activateStoresKey() async throws {
            let secrets = SecretsService.inMemory()
            let (manager, settings) = makeManager(
                client: LicensingClient(
                    activate: { _, key, _, _ in
                        #expect(key == "KEY-42")
                        return LicenseStatus(state: .active, activationLimit: 3, activationUsage: 1)
                    },
                    deactivate: { _, _ in },
                    status: { _, _ in LicenseStatus(state: .active) }
                ),
                secrets: secrets
            )
            manager.licenseKeyField = "  KEY-42  " // trimmed before send
            await manager.activate()
            #expect(manager.status?.state == .active)
            #expect(manager.actionState == .idle)
            let stored = try await secrets.loadSecret(LicenseKeychainAccounts.licenseKey)
            #expect(stored == "KEY-42")
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
            manager.licenseKeyField = "KEY-42"
            await manager.activate()
            #expect(manager.actionState
                == .error("This license key has reached the activation limit."))
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
    }
#endif
