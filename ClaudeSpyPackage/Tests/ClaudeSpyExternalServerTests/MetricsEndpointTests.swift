import Foundation
import Testing
import VaporTesting
@testable import ClaudeSpyExternalServerLib

/// Endpoint-level tests for the `/metrics` Prometheus exposition route.
///
/// `.serialized` is required because we set `METRICS_TOKEN` via `setenv`,
/// which mutates process-global state and would race under parallel execution.
@Suite("Metrics endpoint", .serialized)
struct MetricsEndpointTests {
    private static let token = "test-metrics-token"

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
                #expect(res.headers.contentType?.description.contains("text/plain") == true)
                let body = res.body.string
                #expect(body.contains("claudespy_active_pairs 0"))
                #expect(body.contains("claudespy_ws_connections{device_type=\"host\"} 0"))
                #expect(body.contains("claudespy_messages_relayed_total 0"))
                #expect(body.contains("claudespy_uptime_seconds"))
            }
        }
    }
}
