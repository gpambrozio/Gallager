import Foundation
import Testing
import VaporTesting
@testable import ClaudeSpyExternalServerLib

/// Regression coverage for issue #642: after a device reconnects (e.g. a viewer
/// that switched networks), the *old* half-open socket's `onClose` fires later
/// and used to unregister the live replacement connection — evicting it from the
/// routing table and falsely telling the peer the device disconnected.
///
/// The fix (`ConnectionHub.unregisterIfCurrent`) only tears a connection down
/// when the closing socket is still the registered one, so a stale close is a
/// no-op.
///
/// These tests drive the real WebSocket lifecycle against a running relay: they
/// open two viewer sockets for the same pair (the second replaces the first in
/// `ConnectionHub`), then close the *first* and assert the live replacement keeps
/// routing and the host is never told the viewer left. `deviceId` isn't validated
/// on upgrade, so distinct viewer sockets simply model "same viewer, new socket".
///
/// `.serialized` because the helpers mutate the process-global `DATA_DIRECTORY`
/// env var (via `setenv`) to isolate each run's `pairs.json`.
@Suite("Viewer reconnect routing (#642)", .serialized)
struct ViewerReconnectRoutingTests {
    // Valid 32-byte base64 keys so `notifyConnection` has public keys to attach
    // (without them it logs "no public key available" and skips the notification,
    // which would hide the very host-notification we assert on).
    private static let hostPublicKey = "aG9zdC1wdWJsaWMta2V5LTAxMjM0NTY3ODkwMTIzNDU2Nw=="
    private static let hostKeyId = "host-key-id-1"
    private static let viewerPublicKey = "dmlld2VyLXB1YmxpYy1rZXktMDEyMzQ1Njc4OTAxMjM0NTY="
    private static let viewerKeyId = "viewer-key-id-1"

    // MARK: - Test

    @Test("A stale viewer socket closing does not evict the reconnected viewer or notify the host")
    func staleCloseKeepsLiveViewerRouting() async throws {
        try await withRunningRelay { app, port in
            let pairId = try await makePair(app)

            // Host stays connected throughout; it's the peer that would be
            // (wrongly) told "viewer disconnected".
            let host = TextCollector()
            let hostWS = try await connectClient(
                port: port,
                query: "pairId=\(pairId)&deviceType=host&deviceId=host-1",
                collector: host
            )

            // Viewer socket A — the connection that will go half-open and close late.
            let viewerA = TextCollector()
            let viewerAWS = try await connectClient(
                port: port,
                query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-A",
                collector: viewerA
            )
            // Server processed A's registration once the host is told the viewer connected.
            #expect(await waitUntil { count(of: "viewerConnected", in: host.all()) == 1 })

            // Viewer socket B — the reconnection. Registering it replaces A in the
            // hub (last-write-wins on `(pairId, .viewer)`). A stays open for now.
            let viewerB = TextCollector()
            let viewerBWS = try await connectClient(
                port: port,
                query: "pairId=\(pairId)&deviceType=viewer&deviceId=viewer-B",
                collector: viewerB
            )
            // Waiting for the *second* viewerConnected guarantees register(B) ran
            // after register(A) — so B is the current entry when A closes next.
            #expect(await waitUntil { count(of: "viewerConnected", in: host.all()) == 2 })
            #expect(await app.connectionHub.isViewerConnected(pairId: pairId))

            // Now the stale socket closes — the crux of the bug.
            try await viewerAWS.close()

            // The buggy behavior surfaces fast (a clean localhost close's onClose
            // fires in well under this window): the live viewer B gets evicted
            // and/or the host is told the viewer disconnected. Assert neither
            // happens within a generous window — this is the non-event we're proving.
            let sawRegression = await waitUntil(timeout: .seconds(2)) {
                let viewerEvicted = !(await app.connectionHub.isViewerConnected(pairId: pairId))
                let hostToldDisconnected = count(of: "viewerDisconnected", in: host.all()) > 0
                return viewerEvicted || hostToldDisconnected
            }
            #expect(
                sawRegression == false,
                "Stale viewer close evicted the live replacement and/or falsely notified the host"
            )

            // Positive confirmation the replacement is still routable: a host→viewer
            // relay lands on B. On the buggy path the viewer entry is gone, so this
            // never arrives.
            await app.connectionHub.send(.ping, to: pairId, deviceType: .viewer)
            #expect(
                await waitUntil { count(of: "ping", in: viewerB.all()) > 0 },
                "Host→viewer routing broke after the stale close (replacement viewer was evicted)"
            )

            // And A — the socket that closed — should never have received the relay.
            #expect(count(of: "ping", in: viewerA.all()) == 0)

            try await hostWS.close()
            try await viewerBWS.close()
        }
    }

    // MARK: - Relay lifecycle

    /// Boots the real relay on an ephemeral port, runs the body, and tears down
    /// both the HTTP server and the application.
    private func withRunningRelay(
        _ body: (Application, Int) async throws -> Void
    ) async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudespy-reconnect-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("DATA_DIRECTORY", tempDir.path, 1)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            unsetenv("DATA_DIRECTORY")
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
    /// (the regression) would otherwise appear.
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

    private struct Envelope: Decodable { let type: String }

    /// Counts inbound frames whose `type` discriminator matches, ignoring frames
    /// that don't decode (none are expected, but this keeps the helper total).
    private func count(of type: String, in texts: [String]) -> Int {
        texts.reduce(into: 0) { total, text in
            guard
                let data = text.data(using: .utf8),
                let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
            else { return }
            if envelope.type == type { total += 1 }
        }
    }
}

// MARK: - Support types

private enum RelayTestError: Error {
    case pairingFailed(String)
    case connectFailed(String)
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
