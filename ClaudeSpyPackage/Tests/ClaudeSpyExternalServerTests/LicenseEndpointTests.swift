import ClaudeSpyNetworking
import Foundation
import Testing
import VaporTesting
@testable import ClaudeSpyExternalServerLib

/// Endpoint tests exercise only trial/status paths so no Lemon Squeezy stub
/// server is needed (activation flows are covered at the actor level in
/// LicensingServiceTests; the full loop is covered by the E2E scenario).
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
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudespy-license-endpoint-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("DATA_DIRECTORY", tempDir.path, 1)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            unsetenv("DATA_DIRECTORY")
        }
        try await withApp(configure: configure) { app in
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
}
