import ClaudeSpyNetworking
import Foundation
import Testing
import VaporTesting
@testable import ClaudeSpyExternalServerLib

/// Tests for the PAIRING_PAUSED_MESSAGE maintenance switch (spec:
/// docs/superpowers/specs/2026-07-31-pairing-pause-design.md).
///
/// Nested under `EnvSerializedSuites` to bound how many full Vapor apps boot
/// concurrently. Config is injected via `configure(_:env:)` — never `setenv`
/// (see that container's doc comment).
extension EnvSerializedSuites {
    @Suite("Pairing pause", .serialized)
    struct PairingPauseTests {
        /// Boots the relay with the given extra env on top of a hermetic
        /// temp DATA_DIRECTORY (licensing stays disabled: no LS ids injected).
        private func withPauseApp(
            env extraEnv: [String: String],
            _ test: (Application) async throws -> Void
        ) async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("claudespy-pairing-pause-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            var env = extraEnv
            env["DATA_DIRECTORY"] = tempDir.path
            try await withApp(configure: { app in
                try await configure(app, env: env)
            }, test)
        }

        @Test("PAIRING_PAUSED_MESSAGE is trimmed into app storage")
        func messageStored() async throws {
            try await withPauseApp(env: ["PAIRING_PAUSED_MESSAGE": "  Paused for maintenance.\n"]) { app in
                #expect(app.pairingPausedMessage == "Paused for maintenance.")
            }
        }

        @Test("Absent PAIRING_PAUSED_MESSAGE leaves the relay unpaused")
        func messageAbsent() async throws {
            try await withPauseApp(env: [:]) { app in
                #expect(app.pairingPausedMessage == nil)
            }
        }

        @Test("Whitespace-only PAIRING_PAUSED_MESSAGE leaves the relay unpaused")
        func messageBlank() async throws {
            try await withPauseApp(env: ["PAIRING_PAUSED_MESSAGE": "   \n"]) { app in
                #expect(app.pairingPausedMessage == nil)
            }
        }

        private static let testPublicKey = "dGVzdC1tYWMtcHVibGljLWtleS0wMTIzNDU2Nzg5MDEyMw=="

        @Test("Paused relay refuses register with the operator's message and PAIRING_PAUSED code")
        func registerRefusedWhenPaused() async throws {
            try await withPauseApp(env: ["PAIRING_PAUSED_MESSAGE": "Paused for maintenance."]) { app in
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
                    #expect(info.message == "Paused for maintenance.")
                    #expect(info.code == ErrorMessage.pairingPausedCode)
                }
                #expect(await app.metricsService.pausedPairingAttemptsTotal == 1)
                // The refused registration must not have created a redeemable
                // code: completing it fails.
                try await app.testing().test(.POST, "api/pairing/complete", beforeRequest: { req in
                    try req.content.encode(PairingCompletion(
                        pairingCode: "ABC123", deviceId: "viewer-1", deviceName: "iPhone",
                        publicKey: Self.testPublicKey, publicKeyId: "vkey-1"
                    ))
                }) { res in
                    let response = try res.content.decode(PairingResponse.self)
                    guard case .error = response else {
                        Issue.record("Expected .error for a never-registered code, got \(response)")
                        return
                    }
                }
            }
        }

        @Test(
            "Register works normally when the relay is not paused",
            arguments: [[:], ["PAIRING_PAUSED_MESSAGE": "   \n"]]
        )
        func registerNormalWhenNotPaused(env: [String: String]) async throws {
            try await withPauseApp(env: env) { app in
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
                #expect(await app.metricsService.pausedPairingAttemptsTotal == 0)
            }
        }

        @Test("Complete still succeeds while paused (register-only scope)")
        func completeUnaffectedByPause() async throws {
            try await withPauseApp(env: ["PAIRING_PAUSED_MESSAGE": "Paused for maintenance."]) { app in
                // Seed a pending code directly on the service, modeling a code
                // registered just before the pause took effect.
                _ = await app.pairingService.registerCode(
                    code: "ABC123",
                    deviceId: "host-1",
                    deviceName: "My Mac",
                    username: "tester",
                    publicKey: Self.testPublicKey,
                    publicKeyId: "key-1"
                )
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
            }
        }
    }
}
