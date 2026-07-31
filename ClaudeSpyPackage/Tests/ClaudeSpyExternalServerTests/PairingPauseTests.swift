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
    }
}
