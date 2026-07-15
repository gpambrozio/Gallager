import ClaudeSpyNetworking
import Foundation
import Testing
import VaporTesting
@testable import ClaudeSpyExternalServerLib

/// Coverage for the WebSocket-connect-time licensing gate (issue #392): a host
/// whose entitlement is blocked (expired trial, lapsed license) is rejected
/// with `.error(.subscriptionRequired())` and the socket is closed; a viewer
/// already connected on the same pair is told `.hostSubscriptionInactive`.
/// Also covers the periodic sweep (`LicensingService.sweepBlockedHosts`) that
/// evicts a host whose entitlement lapses *mid-connection*.
///
/// These tests drive the real WebSocket lifecycle against a running relay
/// (modeled on `ViewerReconnectRoutingTests`), with `LEMONSQUEEZY_STORE_ID` /
/// `LEMONSQUEEZY_PRODUCT_ID` / `TRIAL_DAYS` set so licensing enforcement is
/// active at boot. Pairs are created directly through the real
/// `app.pairingService` actor (register + complete), the same pattern
/// `ViewerReconnectRoutingTests.makePair` uses, since driving the HTTP pairing
/// endpoints isn't the thing under test here.
///
/// Nested under `EnvSerializedSuites` so it also serializes against the other
/// suites that mutate process-global environment variables (this one sets
/// `LEMONSQUEEZY_STORE_ID` / `LEMONSQUEEZY_PRODUCT_ID` / `TRIAL_DAYS` /
/// `DATA_DIRECTORY`).
extension EnvSerializedSuites {
    @Suite("License enforcement over WebSocket (#392)", .serialized)
    struct LicenseEnforcementWebSocketTests {
        // Valid 32-byte base64 keys so `notifyConnection` has public keys to attach
        // (mirrors ViewerReconnectRoutingTests; unused by the assertions here but
        // keeps the pair record realistic).
        private static let hostPublicKey = "aG9zdC1wdWJsaWMta2V5LTAxMjM0NTY3ODkwMTIzNDU2Nw=="
        private static let hostKeyId = "host-key-id-1"
        private static let viewerPublicKey = "dmlld2VyLXB1YmxpYy1rZXktMDEyMzQ1Njc4OTAxMjM0NTY="
        private static let viewerKeyId = "viewer-key-id-1"

        // MARK: - Tests

        @Test("Expired-trial host connect is rejected with SUBSCRIPTION_REQUIRED and the socket closes")
        func expiredTrialHostRejected() async throws {
            try await withRunningRelay(licensingTrialDays: "0") { app, port in
                let pairId = try await makePair(app)

                let host = TextCollector()
                let hostWS = try await connectClient(
                    port: port,
                    query: "pairId=\(pairId)&deviceType=host&deviceId=host-1",
                    collector: host
                )

                #expect(await waitUntil { errorMessages(in: host.all()).count == 1 })
                #expect(errorMessages(in: host.all()).first?.code == ErrorMessage.subscriptionRequiredCode)
                #expect(errorMessages(in: host.all()).first?.recoverable == false)

                // The server closes the socket itself right after the error frame —
                // don't rely on the client-initiated close below to prove this.
                #expect(await waitUntil { hostWS.isClosed })

                try? await hostWS.close()
            }
        }

        @Test("A viewer connected on the same pair is told hostSubscriptionInactive when the host is rejected")
        func viewerToldHostSubscriptionInactive() async throws {
            try await withRunningRelay(licensingTrialDays: "0") { app, port in
                let pairId = try await makePair(app)

                // Viewer connects first (viewers are never gated) and stays up.
                let viewer = TextCollector()
                let viewerWS = try await connectClient(
                    port: port,
                    query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-1",
                    collector: viewer
                )

                // Host's trial already expired (TRIAL_DAYS=0) — rejected on connect.
                let host = TextCollector()
                let hostWS = try await connectClient(
                    port: port,
                    query: "pairId=\(pairId)&deviceType=host&deviceId=host-1",
                    collector: host
                )

                #expect(await waitUntil { hasHostSubscriptionInactive(in: viewer.all()) })

                try? await hostWS.close()
                try? await viewerWS.close()
            }
        }

        @Test("Sweep disconnects a live host whose entitlement lapses mid-connection and notifies its viewer")
        func sweepDisconnectsHostWhoseEntitlementLapses() async throws {
            // Licensing is OFF for the app's own connect-time gate here (no
            // LEMONSQUEEZY_* env), so both host and viewer connect and stay
            // connected unconditionally — this test is about the periodic
            // *sweep* path (`LicensingService.sweepBlockedHosts`, normally run
            // once daily from `configure.swift`), not the connect gate already
            // covered above.
            //
            // The app's own bound `licensingService` can't be used to produce a
            // "connect while valid, then expire" sequence live: its trial
            // length is fixed at boot from `TRIAL_DAYS` and `configure(_:)`
            // takes no injectable clock, so there is no in-process way to
            // fast-forward it short of a real 24h wait. Instead this
            // constructs a SEPARATE `LicensingService` with a fake clock
            // (same actor type, same pattern as `LicensingServiceTests`) and
            // runs the real `sweepBlockedHosts` on it against the app's REAL
            // `pairingService` / `connectionHub` — so the pair it looks up and
            // the sockets it evicts/messages are the genuine live ones from
            // this test's WebSocket connections. This exercises the actual
            // sweep code path end-to-end without contorting app boot. See the
            // fix-wave report for the alternatives considered.
            try await withRunningRelay(licensingTrialDays: nil) { app, port in
                let pairId = try await makePair(app)

                let viewer = TextCollector()
                let viewerWS = try await connectClient(
                    port: port,
                    query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-1",
                    collector: viewer
                )
                // `sweepBlockedHosts` (unlike the connect-time gate) checks
                // entitlement by the PAIR's persisted `hostDeviceId` — not the
                // WS connection's `deviceId` query param — so this must match
                // `makePair`'s `"host-device"`, not an arbitrary connection id.
                let host = TextCollector()
                let hostWS = try await connectClient(
                    port: port,
                    query: "pairId=\(pairId)&deviceType=host&deviceId=host-device",
                    collector: host
                )
                #expect(await waitUntil { await app.connectionHub.isHostConnected(pairId: pairId) })
                #expect(await waitUntil { await app.connectionHub.isViewerConnected(pairId: pairId) })

                let sweepDir = try tempDirectory()
                defer { try? FileManager.default.removeItem(at: sweepDir) }
                let clock = TestNow()
                let sweepConfig = LicensingConfiguration(
                    storeId: 123, productId: 456,
                    trialDays: 1, revalidateHours: 24, graceDays: 7,
                    apiBaseURL: "http://unused.test"
                )
                let sweepLicensingService = LicensingService(
                    config: sweepConfig, apiClient: StubLicenseAPIClient(),
                    dataDirectory: sweepDir, now: { clock.value }
                )
                // Auto-starts a 1-day trial for the pair's hostDeviceId.
                _ = await sweepLicensingService.checkEntitlement(hostDeviceId: "host-device")
                clock.advance(bySeconds: 2 * 86_400) // past the 1-day trial

                let blockedPairs = await sweepLicensingService.sweepBlockedHosts(
                    pairingService: app.pairingService,
                    connectionHub: app.connectionHub
                )
                #expect(blockedPairs == [pairId])

                #expect(await waitUntil { errorMessages(in: host.all()).first?.code == ErrorMessage.subscriptionRequiredCode })
                #expect(await waitUntil { hasHostSubscriptionInactive(in: viewer.all()) })
                #expect(await waitUntil { await !app.connectionHub.isHostConnected(pairId: pairId) })
                // Sweep only evicts the host; the viewer stays connected so it
                // can actually receive the notice above.
                #expect(await app.connectionHub.isViewerConnected(pairId: pairId))

                try? await hostWS.close()
                try? await viewerWS.close()
            }
        }

        // MARK: - Relay lifecycle

        /// Boots the real relay on an ephemeral port, runs the body, and tears down
        /// both the HTTP server and the application. When `licensingTrialDays` is
        /// non-nil, `LEMONSQUEEZY_STORE_ID`/`LEMONSQUEEZY_PRODUCT_ID`/`TRIAL_DAYS`
        /// are set so the app's own connect-time licensing gate is active; `nil`
        /// leaves licensing disabled (unrestricted) for that gate.
        private func withRunningRelay(
            licensingTrialDays: String?,
            _ body: (Application, Int) async throws -> Void
        ) async throws {
            if let licensingTrialDays {
                setenv("LEMONSQUEEZY_STORE_ID", "123", 1)
                setenv("LEMONSQUEEZY_PRODUCT_ID", "456", 1)
                setenv("TRIAL_DAYS", licensingTrialDays, 1)
            } else {
                // Force the connect-time gate OFF, hermetic against a developer's
                // local `.env`: `Application.make(.testing)` loads `.env` with
                // `overwrite: false`, so a staging `.env` setting LEMONSQUEEZY_*
                // would otherwise ENABLE licensing here. Empty ids read as unset
                // (trimmed to nil) and the `.env` load can't overwrite them.
                setenv("LEMONSQUEEZY_STORE_ID", "", 1)
                setenv("LEMONSQUEEZY_PRODUCT_ID", "", 1)
            }
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("claudespy-license-ws-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            setenv("DATA_DIRECTORY", tempDir.path, 1)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
                unsetenv("DATA_DIRECTORY")
                unsetenv("LEMONSQUEEZY_STORE_ID")
                unsetenv("LEMONSQUEEZY_PRODUCT_ID")
                unsetenv("TRIAL_DAYS")
            }

            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                // Match the framework's own test flow (`testing()` calls `boot()` before
                // starting a live server): run lifecycle handlers before binding.
                try await app.asyncBoot()
                // Bind to 127.0.0.1:0 so the OS picks a free port; the explicit address
                // overrides configure()'s 0.0.0.0:8080 default.
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

        private func tempDirectory() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("claudespy-license-ws-sweep-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        // MARK: - WebSocket client helpers

        /// Opens a raw WebSocket client to the relay and streams every inbound text
        /// frame into `collector`. Returns the live socket so the test can close it.
        private func connectClient(
            port: Int,
            query: String,
            collector: TextCollector
        ) async throws -> WebSocket {
            // Resume inside `onUpgrade` (not on the connect future) so we only proceed
            // once the socket exists: websocket-kit succeeds the connect future from a
            // completion handler that can run before `onUpgrade` sets up the socket.
            // A one-shot guard makes the two resume paths (upgrade vs. connect failure)
            // mutually safe.
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

        /// Polls `condition` until it's true or the timeout elapses. Used both to
        /// wait for a positive signal and to bound the window in which a non-event
        /// would otherwise appear.
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

        /// Decodes every inbound text frame as a `WebSocketMessage`, dropping any
        /// that don't decode (none are expected, but keeps the helper total).
        private func decodedMessages(_ texts: [String]) -> [WebSocketMessage] {
            texts.compactMap { try? JSONDecoder().decode(WebSocketMessage.self, from: Data($0.utf8)) }
        }

        private func errorMessages(in texts: [String]) -> [ErrorMessage] {
            decodedMessages(texts).compactMap { message in
                guard case let .error(errorMessage) = message else { return nil }
                return errorMessage
            }
        }

        private func hasHostSubscriptionInactive(in texts: [String]) -> Bool {
            decodedMessages(texts).contains {
                if case .hostSubscriptionInactive = $0 { return true }
                return false
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

    /// Returns `true` for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
