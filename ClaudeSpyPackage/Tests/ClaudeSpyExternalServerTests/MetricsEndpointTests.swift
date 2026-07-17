import Foundation
import Testing
import VaporTesting
@testable import ClaudeSpyExternalServerLib

/// Endpoint-level tests for the `/metrics` Prometheus exposition route.
///
/// `.serialized` is required because we set `METRICS_TOKEN` via `setenv`,
/// which mutates process-global state and would race under parallel execution.
/// Nested under `EnvSerializedSuites` so it also serializes against the other
/// suites that mutate process-global environment variables (the recursive
/// `.serialized` trait covers cross-suite races; this suite's own trait keeps
/// its tests serialized even if inspected in isolation).
extension EnvSerializedSuites {
    @Suite("Metrics endpoint", .serialized)
    struct MetricsEndpointTests {
        /// Production tokens must be ≥ 32 characters (enforced in `configure.swift`).
        /// 64 hex chars matches `openssl rand -hex 32` output, the documented happy path.
        private static let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

        private func withConfiguredApp(
            _ test: (Application) async throws -> Void
        ) async throws {
            setenv("METRICS_TOKEN", Self.token, 1)
            // Isolate PairingService persistence into a fresh temp dir so we don't
            // pollute (or read from) the developer's local pairs.json.
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("claudespy-metrics-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            setenv("DATA_DIRECTORY", tempDir.path, 1)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
                unsetenv("DATA_DIRECTORY")
                // Symmetric cleanup: avoid leaking process-env state into other suites.
                unsetenv("METRICS_TOKEN")
            }
            try await withApp(configure: configure, test)
        }

        @Test("GET /metrics returns 401 without bearer token")
        func unauthorizedNoHeader() async throws {
            try await withConfiguredApp { app in
                try await app.testing().test(.GET, "metrics") { res in
                    #expect(res.status == .unauthorized)
                }
            }
        }

        @Test("GET /metrics returns 401 with wrong token")
        func unauthorizedWrongToken() async throws {
            try await withConfiguredApp { app in
                try await app.testing().test(
                    .GET,
                    "metrics",
                    headers: ["Authorization": "Bearer wrong"]
                ) { res in
                    #expect(res.status == .unauthorized)
                }
            }
        }

        @Test("GET /metrics returns 200 + Prometheus body with valid token")
        func authorizedReturnsBody() async throws {
            try await withConfiguredApp { app in
                try await app.testing().test(
                    .GET,
                    "metrics",
                    headers: ["Authorization": "Bearer \(Self.token)"]
                ) { res in
                    #expect(res.status == .ok)
                    let contentType = res.headers.contentType
                    #expect(contentType?.type == "text")
                    #expect(contentType?.subType == "plain")
                    #expect(contentType?.parameters["version"] == "0.0.4")
                    let body = res.body.string
                    #expect(body.contains("claudespy_active_pairs 0"))
                    #expect(body.contains("claudespy_ws_connections{device_type=\"host\"} 0"))
                    #expect(body.contains("claudespy_messages_relayed_total 0"))
                    #expect(body.contains("claudespy_uptime_seconds"))
                }
            }
        }
    }
}
