import Foundation
import Testing
import VaporTesting
@testable import ClaudeSpyExternalServerLib

/// Endpoint-level tests for the `/metrics` Prometheus exposition route.
///
/// Nested under `EnvSerializedSuites` to bound how many full Vapor apps boot
/// concurrently (see that container's doc for why setenv is banned here).
extension EnvSerializedSuites {
    @Suite("Metrics endpoint", .serialized)
    struct MetricsEndpointTests {
        /// Production tokens must be ≥ 32 characters (enforced in `configure.swift`).
        /// 64 hex chars matches `openssl rand -hex 32` output, the documented happy path.
        private static let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

        private func withConfiguredApp(
            _ test: (Application) async throws -> Void
        ) async throws {
            // Isolate PairingService persistence into a fresh temp dir so we don't
            // pollute (or read from) the developer's local pairs.json. Config is
            // injected (never setenv — see `configure(_:env:)`).
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("claudespy-metrics-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try await withApp(configure: { app in
                try await configure(app, env: [
                    "METRICS_TOKEN": Self.token,
                    "DATA_DIRECTORY": tempDir.path,
                ])
            }, test)
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
