import ClaudeSpyNetworking
import Foundation
import Testing
import VaporTesting
@testable import ClaudeSpyExternalServerLib

/// Endpoint tests exercise only trial/status paths so no Lemon Squeezy stub
/// server is needed (activation flows are covered at the actor level in
/// LicensingServiceTests; the full loop is covered by the E2E scenario).
///
/// Nested under `EnvSerializedSuites` to bound how many full Vapor apps boot
/// concurrently (see that container's doc for why setenv is banned here).
extension EnvSerializedSuites {
    @Suite("License endpoints", .serialized)
    struct LicenseEndpointTests {
        private func withLicensingApp(
            trialDays: String = "7",
            _ test: (Application) async throws -> Void
        ) async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("claudespy-license-endpoint-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            // Config is injected (never setenv — see `configure(_:env:)`): the
            // explicit dict also makes the boot hermetic against a developer's
            // local `.env`, which `Application.make(.testing)` loads into the
            // process environment but `configure` no longer reads from.
            try await withApp(configure: { app in
                try await configure(app, env: [
                    "LEMONSQUEEZY_STORE_ID": "123",
                    "LEMONSQUEEZY_PRODUCT_ID": "456",
                    "TRIAL_DAYS": trialDays,
                    "DATA_DIRECTORY": tempDir.path,
                ])
            }, test)
        }

        /// Boots the app with licensing DISABLED: the injected env simply omits
        /// `LEMONSQUEEZY_STORE_ID`/`LEMONSQUEEZY_PRODUCT_ID`, and because
        /// `configure` reads only the injected dict a staging-deploy `.env`
        /// (loaded into the process env by `Application.make(.testing)`) can't
        /// silently ENABLE licensing and break these "disabled relay" assertions.
        private func withDisabledLicensingApp(
            _ test: (Application) async throws -> Void
        ) async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("claudespy-license-endpoint-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try await withApp(configure: { app in
                try await configure(app, env: ["DATA_DIRECTORY": tempDir.path])
            }, test)
        }

        @Test("GET /api/license/status returns none for a fresh device and starts no trial")
        func statusFreshDevice() async throws {
            try await withLicensingApp { app in
                try await app.testing().test(.GET, "api/license/status?deviceId=fresh-1") { res in
                    #expect(res.status == .ok)
                    let status = try res.content.decode(LicenseStatus.self)
                    #expect(status.state == .none)
                }
                // Second read still .none — status must not auto-start trials.
                try await app.testing().test(.GET, "api/license/status?deviceId=fresh-1") { res in
                    let status = try res.content.decode(LicenseStatus.self)
                    #expect(status.state == .none)
                }
            }
        }

        @Test("GET /api/license/status returns notRequired when licensing is disabled")
        func statusDisabledRelay() async throws {
            try await withDisabledLicensingApp { app in
                try await app.testing().test(.GET, "api/license/status?deviceId=any") { res in
                    #expect(res.status == .ok)
                    let status = try res.content.decode(LicenseStatus.self)
                    #expect(status.state == .notRequired)
                }
            }
        }

        @Test("Status endpoint requires deviceId")
        func statusMissingDeviceId() async throws {
            try await withLicensingApp { app in
                try await app.testing().test(.GET, "api/license/status") { res in
                    #expect(res.status == .badRequest)
                }
            }
        }

        @Test("DELETE /api/license/activation with no activation is a 204 no-op")
        func deactivateNoop() async throws {
            try await withLicensingApp { app in
                try await app.testing().test(.DELETE, "api/license/activation?deviceId=fresh-1") { res in
                    #expect(res.status == .noContent)
                }
            }
        }

        private static let testPublicKey = "dGVzdC1tYWMtcHVibGljLWtleS0wMTIzNDU2Nzg5MDEyMw=="

        @Test("Pairing register succeeds but does NOT start a trial")
        func registerDoesNotStartTrial() async throws {
            try await withLicensingApp { app in
                try await app.testing().test(.POST, "api/pairing/register", beforeRequest: { req in
                    try req.content.encode(PairingRegistration(
                        deviceId: "host-1", deviceName: "My Mac", pairingCode: "ABC123",
                        publicKey: Self.testPublicKey, publicKeyId: "key-1", username: "tester"
                    ))
                }) { res in
                    #expect(res.status == .ok)
                    let response = try res.content.decode(PairingResponse.self)
                    guard case .registered = response else {
                        Issue.record("Expected .registered, got \(response)")
                        return
                    }
                }
                // Registering a code alone must not start the trial clock.
                try await app.testing().test(.GET, "api/license/status?deviceId=host-1") { res in
                    let status = try res.content.decode(LicenseStatus.self)
                    #expect(status.state == .none)
                }
            }
        }

        @Test("Completing a pairing starts the host's trial")
        func completeStartsTrial() async throws {
            try await withLicensingApp { app in
                try await app.testing().test(.POST, "api/pairing/register", beforeRequest: { req in
                    try req.content.encode(PairingRegistration(
                        deviceId: "host-1", deviceName: "My Mac", pairingCode: "ABC123",
                        publicKey: Self.testPublicKey, publicKeyId: "key-1", username: "tester"
                    ))
                }) { res in #expect(res.status == .ok) }

                try await app.testing().test(.POST, "api/pairing/complete", beforeRequest: { req in
                    try req.content.encode(PairingCompletion(
                        pairingCode: "ABC123", deviceId: "viewer-1", deviceName: "iPhone",
                        publicKey: Self.testPublicKey, publicKeyId: "vkey-1"
                    ))
                }) { res in
                    #expect(res.status == .ok)
                    let response = try res.content.decode(PairingResponse.self)
                    guard case .paired = response else {
                        Issue.record("Expected .paired, got \(response)")
                        return
                    }
                }
                // The viewer pairing started the host's trial.
                try await app.testing().test(.GET, "api/license/status?deviceId=host-1") { res in
                    let status = try res.content.decode(LicenseStatus.self)
                    #expect(status.state == .trial)
                }
            }
        }

        @Test("Register is blocked with SUBSCRIPTION_REQUIRED once the trial has expired")
        func registerBlockedAfterTrial() async throws {
            // TRIAL_DAYS=0 → the trial started by completing a pairing is already expired.
            try await withLicensingApp(trialDays: "0") { app in
                // Register + complete once: allowed (pre-trial), and complete starts the
                // (already-expired) trial for host-1.
                try await app.testing().test(.POST, "api/pairing/register", beforeRequest: { req in
                    try req.content.encode(PairingRegistration(
                        deviceId: "host-1", deviceName: "My Mac", pairingCode: "ABC123",
                        publicKey: Self.testPublicKey, publicKeyId: "key-1", username: "tester"
                    ))
                }) { res in
                    let response = try res.content.decode(PairingResponse.self)
                    guard case .registered = response else {
                        Issue.record("Expected .registered, got \(response)")
                        return
                    }
                }
                try await app.testing().test(.POST, "api/pairing/complete", beforeRequest: { req in
                    try req.content.encode(PairingCompletion(
                        pairingCode: "ABC123", deviceId: "viewer-1", deviceName: "iPhone",
                        publicKey: Self.testPublicKey, publicKeyId: "vkey-1"
                    ))
                }) { res in #expect(res.status == .ok) }

                // A NEW register for the same host is now blocked — its trial expired.
                try await app.testing().test(.POST, "api/pairing/register", beforeRequest: { req in
                    try req.content.encode(PairingRegistration(
                        deviceId: "host-1", deviceName: "My Mac", pairingCode: "XYZ789",
                        publicKey: Self.testPublicKey, publicKeyId: "key-1", username: "tester"
                    ))
                }) { res in
                    #expect(res.status == .ok)
                    let response = try res.content.decode(PairingResponse.self)
                    guard case let .error(info) = response else {
                        Issue.record("Expected .error, got \(response)")
                        return
                    }
                    #expect(info.code == ErrorMessage.subscriptionRequiredCode)
                }
            }
        }

        @Test("Pairing register is untouched when licensing is disabled")
        func registerUnrestrictedWhenDisabled() async throws {
            try await withDisabledLicensingApp { app in
                try await app.testing().test(.POST, "api/pairing/register", beforeRequest: { req in
                    try req.content.encode(PairingRegistration(
                        deviceId: "host-1", deviceName: "My Mac", pairingCode: "ABC123",
                        publicKey: Self.testPublicKey, publicKeyId: "key-1", username: "tester"
                    ))
                }) { res in
                    let response = try res.content.decode(PairingResponse.self)
                    guard case .registered = response else {
                        Issue.record("Expected .registered, got \(response)")
                        return
                    }
                }
            }
        }
    }
}
