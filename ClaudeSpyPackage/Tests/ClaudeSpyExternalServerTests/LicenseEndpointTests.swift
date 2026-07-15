import ClaudeSpyNetworking
import Foundation
import Testing
import VaporTesting
@testable import ClaudeSpyExternalServerLib

/// Endpoint tests exercise only trial/status paths so no Lemon Squeezy stub
/// server is needed (activation flows are covered at the actor level in
/// LicensingServiceTests; the full loop is covered by the E2E scenario).
///
/// Nested under `EnvSerializedSuites` so it also serializes against the other
/// suites that mutate process-global environment variables.
extension EnvSerializedSuites {
    @Suite("License endpoints", .serialized)
    struct LicenseEndpointTests {
        private func withLicensingApp(
            trialDays: String = "7",
            _ test: (Application) async throws -> Void
        ) async throws {
            setenv("LEMONSQUEEZY_STORE_ID", "123", 1)
            setenv("LEMONSQUEEZY_PRODUCT_ID", "456", 1)
            setenv("TRIAL_DAYS", trialDays, 1)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("claudespy-license-endpoint-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            setenv("DATA_DIRECTORY", tempDir.path, 1)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
                unsetenv("DATA_DIRECTORY")
                unsetenv("LEMONSQUEEZY_STORE_ID")
                unsetenv("LEMONSQUEEZY_PRODUCT_ID")
                unsetenv("TRIAL_DAYS")
            }
            try await withApp(configure: configure, test)
        }

        /// Boots the app with licensing DISABLED, hermetic against a developer's
        /// local `.env`. `Application.make(.testing)` loads `.env` with
        /// `overwrite: false`; if that file sets `LEMONSQUEEZY_STORE_ID`/
        /// `LEMONSQUEEZY_PRODUCT_ID` (as a staging-deploy `.env` does) it would
        /// silently ENABLE licensing and break these "disabled relay" assertions.
        /// Forcing the two ids present-but-EMPTY makes
        /// `LicensingConfiguration.fromEnvironment()` read them as unset (empty is
        /// trimmed to nil) AND stops the `.env` load from filling them in.
        private func withDisabledLicensingApp(
            _ test: (Application) async throws -> Void
        ) async throws {
            setenv("LEMONSQUEEZY_STORE_ID", "", 1)
            setenv("LEMONSQUEEZY_PRODUCT_ID", "", 1)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("claudespy-license-endpoint-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            setenv("DATA_DIRECTORY", tempDir.path, 1)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
                unsetenv("DATA_DIRECTORY")
                unsetenv("LEMONSQUEEZY_STORE_ID")
                unsetenv("LEMONSQUEEZY_PRODUCT_ID")
            }
            try await withApp(configure: configure, test)
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

        @Test("Pairing register auto-starts a trial and succeeds")
        func registerStartsTrial() async throws {
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
                // The register touched the relay → trial exists now.
                try await app.testing().test(.GET, "api/license/status?deviceId=host-1") { res in
                    let status = try res.content.decode(LicenseStatus.self)
                    #expect(status.state == .trial)
                }
            }
        }

        @Test("Pairing register is blocked with SUBSCRIPTION_REQUIRED after trial expiry")
        func registerBlockedAfterTrial() async throws {
            // TRIAL_DAYS=0 → the auto-started trial is already expired.
            try await withLicensingApp(trialDays: "0") { app in
                try await app.testing().test(.POST, "api/pairing/register", beforeRequest: { req in
                    try req.content.encode(PairingRegistration(
                        deviceId: "host-1", deviceName: "My Mac", pairingCode: "ABC123",
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
