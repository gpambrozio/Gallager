import ClaudeSpyNetworking
import Foundation
import Testing
import VaporTesting
@testable import ClaudeSpyExternalServerLib

/// Coverage for the server-side minimum-client-version gate (issue #659): a
/// client reporting a version below the relay's configured `MIN_CLIENT_VERSION`
/// is refused on WebSocket connect with `.error(.clientTooOld(...))` and the
/// socket is closed — before the connection is registered — while a new-enough
/// client connects normally. Also covers the unknown-version policy
/// (`MIN_CLIENT_VERSION_REJECT_UNKNOWN`): clients that don't report a version at
/// all are allowed by default and refused only when the policy opts in.
///
/// These drive the real WebSocket lifecycle against a running relay (modeled on
/// `LicenseEnforcementWebSocketTests`). Licensing is left OFF (the injected env
/// omits `LEMONSQUEEZY_*`) so the only gate exercised here is the version gate —
/// a host connecting with a new-enough version isn't independently blocked by
/// licensing.
///
/// Nested under `EnvSerializedSuites` to bound how many full Vapor apps boot
/// concurrently (see that container's doc for why setenv is banned here).
extension EnvSerializedSuites {
    @Suite(.serialized)
    struct MinClientVersionGateWebSocketTests {
        // Valid 32-byte base64 keys so a completed pair record looks realistic
        // (mirrors LicenseEnforcementWebSocketTests; the assertions don't use them).
        private static let hostPublicKey = "aG9zdC1wdWJsaWMta2V5LTAxMjM0NTY3ODkwMTIzNDU2Nw=="
        private static let hostKeyId = "host-key-id-1"
        private static let viewerPublicKey = "dmlld2VyLXB1YmxpYy1rZXktMDEyMzQ1Njc4OTAxMjM0NTY="
        private static let viewerKeyId = "viewer-key-id-1"

        // MARK: - Tests

        @Test("A viewer below the minimum is rejected with CLIENT_TOO_OLD and the socket closes")
        func tooOldViewerRejected() async throws {
            try await withRunningRelay(minClientVersion: "2.1") { app, port in
                let pairId = try await makePair(app)

                let viewer = TextCollector()
                let viewerWS = try await connectClient(
                    port: port,
                    query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-1&clientVersion=1.9",
                    collector: viewer
                )

                #expect(await waitUntil { errorMessages(in: viewer.all()).count == 1 })
                #expect(errorMessages(in: viewer.all()).first?.code == ErrorMessage.clientTooOldCode)
                #expect(errorMessages(in: viewer.all()).first?.recoverable == false)

                // The server closes the socket itself right after the error frame.
                #expect(await waitUntil { viewerWS.isClosed })
                // Rejected before registration, so the hub never sees the viewer.
                #expect(await !app.connectionHub.isViewerConnected(pairId: pairId))

                try? await viewerWS.close()
            }
        }

        @Test("A host below the minimum is also rejected (the gate covers hosts, ahead of licensing)")
        func tooOldHostRejected() async throws {
            try await withRunningRelay(minClientVersion: "2.1") { app, port in
                let pairId = try await makePair(app)

                let host = TextCollector()
                let hostWS = try await connectClient(
                    port: port,
                    query: "pairId=\(pairId)&deviceType=host&deviceId=host-device&clientVersion=1.9",
                    collector: host
                )

                #expect(await waitUntil { errorMessages(in: host.all()).first?.code == ErrorMessage.clientTooOldCode })
                #expect(await waitUntil { hostWS.isClosed })
                #expect(await !app.connectionHub.isHostConnected(pairId: pairId))

                try? await hostWS.close()
            }
        }

        @Test("A new-enough viewer connects normally (no error, socket stays open)")
        func newEnoughViewerAllowed() async throws {
            try await withRunningRelay(minClientVersion: "2.1") { app, port in
                let pairId = try await makePair(app)

                let viewer = TextCollector()
                let viewerWS = try await connectClient(
                    port: port,
                    query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-1&clientVersion=2.1",
                    collector: viewer
                )

                #expect(await waitUntil { await app.connectionHub.isViewerConnected(pairId: pairId) })
                #expect(errorMessages(in: viewer.all()).isEmpty)
                #expect(!viewerWS.isClosed)

                try? await viewerWS.close()
            }
        }

        @Test("An unknown-version client is allowed by default (rejectUnknown off)")
        func unknownVersionAllowedByDefault() async throws {
            try await withRunningRelay(minClientVersion: "2.1") { app, port in
                let pairId = try await makePair(app)

                // No clientVersion query param — an old build predating the field.
                let viewer = TextCollector()
                let viewerWS = try await connectClient(
                    port: port,
                    query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-1",
                    collector: viewer
                )

                #expect(await waitUntil { await app.connectionHub.isViewerConnected(pairId: pairId) })
                #expect(errorMessages(in: viewer.all()).isEmpty)
                #expect(!viewerWS.isClosed)

                try? await viewerWS.close()
            }
        }

        @Test("An unknown-version client is refused when MIN_CLIENT_VERSION_REJECT_UNKNOWN is on")
        func unknownVersionRefusedWhenConfigured() async throws {
            try await withRunningRelay(minClientVersion: "2.1", rejectUnknown: true) { app, port in
                let pairId = try await makePair(app)

                let viewer = TextCollector()
                let viewerWS = try await connectClient(
                    port: port,
                    query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-1",
                    collector: viewer
                )

                #expect(await waitUntil { errorMessages(in: viewer.all()).first?.code == ErrorMessage.clientTooOldCode })
                #expect(await waitUntil { viewerWS.isClosed })
                #expect(await !app.connectionHub.isViewerConnected(pairId: pairId))

                try? await viewerWS.close()
            }
        }

        @Test("With the gate off (default), every client connects regardless of version")
        func gateOffAllowsEverything() async throws {
            try await withRunningRelay(minClientVersion: nil) { app, port in
                let pairId = try await makePair(app)

                // A version that would be far too old for any plausible minimum.
                let viewer = TextCollector()
                let viewerWS = try await connectClient(
                    port: port,
                    query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-1&clientVersion=0.1",
                    collector: viewer
                )

                #expect(await waitUntil { await app.connectionHub.isViewerConnected(pairId: pairId) })
                #expect(errorMessages(in: viewer.all()).isEmpty)
                #expect(!viewerWS.isClosed)

                try? await viewerWS.close()
            }
        }

        // MARK: - Relay lifecycle

        /// Boots the real relay on an ephemeral port with the version gate configured
        /// from `minClientVersion` (nil → gate off) and `rejectUnknown`. Licensing is
        /// forced OFF so the version gate is the only thing under test.
        private func withRunningRelay(
            minClientVersion: String?,
            rejectUnknown: Bool = false,
            _ body: (Application, Int) async throws -> Void
        ) async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("claudespy-minversion-ws-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // Config is injected (never setenv — see `configure(_:env:)`): the
            // explicit dict leaves licensing and, when `minClientVersion` is nil,
            // the version gate disabled by simply omitting their keys, hermetic
            // against a developer's local `.env`.
            var env = ["DATA_DIRECTORY": tempDir.path]
            if let minClientVersion {
                env["MIN_CLIENT_VERSION"] = minClientVersion
                if rejectUnknown { env["MIN_CLIENT_VERSION_REJECT_UNKNOWN"] = "true" }
            }

            let app = try await Application.make(.testing)
            do {
                try await configure(app, env: env)
                try await app.asyncBoot()
                try await app.server.start(address: .hostname("127.0.0.1", port: 0))
                guard let port = app.http.server.shared.localAddress?.port else {
                    Issue.record("Relay did not report a bound port")
                    await app.server.shutdown()
                    try await app.asyncShutdown()
                    return
                }
                try await body(app, port)
                await app.server.shutdown()
            } catch {
                await app.server.shutdown()
                try? await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }

        /// Registers a host code and completes pairing from the viewer, yielding an
        /// active pair whose host and viewer public keys are both populated.
        private func makePair(_ app: Application) async throws -> String {
            let code = "PAIR-\(UUID().uuidString.prefix(6))"
            let register = await app.pairingService.registerCode(
                code: String(code),
                deviceId: "host-device",
                deviceName: "Test Host",
                username: "tester",
                publicKey: Self.hostPublicKey,
                publicKeyId: Self.hostKeyId
            )
            guard case let .registered(info) = register else {
                throw RelayTestError.pairingFailed("register returned \(register)")
            }
            let complete = await app.pairingService.completePairing(
                code: String(code),
                deviceId: "viewer-device",
                deviceName: "Test Viewer",
                publicKey: Self.viewerPublicKey,
                publicKeyId: Self.viewerKeyId
            )
            guard case .paired = complete else {
                throw RelayTestError.pairingFailed("complete returned \(complete)")
            }
            return info.pairId
        }

        // MARK: - WebSocket client helpers

        /// Opens a raw WebSocket client to the relay and streams every inbound text
        /// frame into `collector`. Returns the live socket so the test can close it.
        private func connectClient(
            port: Int,
            query: String,
            collector: TextCollector
        ) async throws -> WebSocket {
            let gate = ResumeGate()
            return try await withCheckedThrowingContinuation { continuation in
                WebSocket.connect(
                    to: "ws://127.0.0.1:\(port)/api/ws?\(query)",
                    on: MultiThreadedEventLoopGroup.singleton
                ) { ws in
                    ws.onText { _, text in collector.append(text) }
                    if gate.claim() { continuation.resume(returning: ws) }
                }.whenFailure { error in
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
        }

        // MARK: - Polling

        private func waitUntil(
            timeout: Duration = .seconds(3),
            _ condition: () async -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return await condition()
        }

        // MARK: - Frame inspection

        private func decodedMessages(_ texts: [String]) -> [WebSocketMessage] {
            texts.compactMap { try? JSONDecoder().decode(WebSocketMessage.self, from: Data($0.utf8)) }
        }

        private func errorMessages(in texts: [String]) -> [ErrorMessage] {
            decodedMessages(texts).compactMap { message in
                guard case let .error(errorMessage) = message else { return nil }
                return errorMessage
            }
        }
    }
}

// MARK: - Support types

private enum RelayTestError: Error {
    case pairingFailed(String)
}

/// Thread-safe accumulator of inbound WebSocket text frames. `onText` fires on a
/// NIO event loop, so appends must be synchronized.
final private class TextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []

    func append(_ text: String) {
        lock.lock()
        texts.append(text)
        lock.unlock()
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return texts
    }
}

/// One-shot guard so a continuation is resumed exactly once across the two racing
/// callbacks (successful upgrade vs. connect failure).
final private class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
