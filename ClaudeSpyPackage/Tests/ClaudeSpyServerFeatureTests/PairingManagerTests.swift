#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import ClaudeSpyNetworking
    import ConcurrencyExtras
    import Dependencies
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("PairingManager")
    @MainActor
    struct PairingManagerTests {
        /// Builds a manager whose relay `register` endpoint is stubbed;
        /// `status` reports the viewer as not yet connected so the completion
        /// poll idles harmlessly until `cancelPairing()`.
        private func makeManager(
            register: @escaping @Sendable (String, PairingRegistration) async throws -> PairingResponse
        ) async throws -> (PairingManager, AppSettings) {
            try await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[SecretsService.self] = .inMemory()
                $0[DeviceNameClient.self] = DeviceNameClient(current: { "Test Mac" })
                $0[PairingAPIClient.self] = PairingAPIClient(
                    register: register,
                    status: { _, _ in
                        PairingStatus(valid: true, hostConnected: true, viewerConnected: false)
                    },
                    delete: { _, _ in }
                )
            } operation: {
                let settings = AppSettings()
                settings.deviceId = "device-1"
                let manager = try PairingManager(
                    settings: settings,
                    e2eeService: await E2EEService()
                )
                return (manager, settings)
            }
        }

        @Test("Subscription-blocked registration retries once the license is restored")
        func retryAfterSubscriptionRestored() async throws {
            let response = LockIsolated<PairingResponse>(.error(ErrorInfo(
                message: "Subscription required",
                code: ErrorMessage.subscriptionRequiredCode
            )))
            let (manager, settings) = try await makeManager(register: { _, _ in response.value })

            await manager.generatePairingCode()
            #expect(manager.state == .error("Subscription required — see the License section below"))

            // License activated: the relay accepts the registration now.
            response.setValue(.registered(pairId: "pair-1"))
            await manager.retryAfterSubscriptionRestored()

            #expect(manager.state.isWaiting)
            manager.cancelPairing()
            withExtendedLifetime(settings) { }
        }

        @Test("Retry is a no-op unless blocked by the subscription gate")
        func retryOnlyWhenBlocked() async throws {
            let registerCalls = LockIsolated(0)
            let (manager, settings) = try await makeManager(register: { _, _ in
                registerCalls.withValue { $0 += 1 }
                return .error(ErrorInfo(message: "Pairing code expired"))
            })

            // Idle: nothing to retry.
            await manager.retryAfterSubscriptionRestored()
            #expect(manager.state == .idle)
            #expect(registerCalls.value == 0)

            // A non-subscription error must not be retried either.
            await manager.generatePairingCode()
            #expect(registerCalls.value == 1)
            await manager.retryAfterSubscriptionRestored()
            #expect(registerCalls.value == 1)
            #expect(manager.state == .error("Pairing code expired"))
            withExtendedLifetime(settings) { }
        }
    }
#endif
