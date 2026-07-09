import Dependencies
import Foundation
import Testing
import Vapor
@testable import ClaudeSpyCommon
@testable import ClaudeSpyEncryption

/// Regression coverage for the client half of issue #642: a network switch leaves
/// the viewer's WebSocket **half-open** (dead TCP, no `receive()` error), so the
/// client sat in `.connected` (green dot) forever while nothing flowed.
///
/// The fix is a pong-timeout watchdog in `pingLoop`: each keep-alive ping sets an
/// `awaitingPong` flag that any inbound frame clears; if nothing arrives within
/// the timeout the socket is cancelled and the normal reconnection path runs.
///
/// This test models a half-open socket with a **mute** relay — it accepts the
/// WebSocket upgrade and then sends nothing (no pong, no data), which is exactly
/// how a half-open socket looks to the client. A live watchdog must notice the
/// dead cycle and reconnect; the mute server counts the reconnection as a second
/// upgrade. Without the watchdog the client stays connected forever and only ever
/// opens one socket.
///
/// `ViewerRelayClient` is `@MainActor`, so the test is too. Intervals are injected
/// (1s/1s) so the watchdog fires in seconds rather than the production 20s/10s.
@Suite("ViewerRelayClient liveness watchdog (#642)")
@MainActor
struct ViewerRelayClientLivenessTests {
    @Test("A half-open (mute) socket is detected and the client reconnects")
    func muteSocketTriggersReconnect() async throws {
        let upgrades = UpgradeCounter()
        let server = try await MuteRelay.start(countingUpgradesInto: upgrades)
        defer { server.stop() }

        // E2EE is required by `connect` but inert here: with no partner key it
        // establishes no session, and the mute server never sends anything to
        // decrypt. In-memory secrets keep the real Keychain untouched.
        let e2eeService = try await withDependencies {
            $0[SecretsService.self] = .inMemory()
        } operation: {
            try await E2EEService()
        }

        // 1s/1s intervals: watchdog cancels the mute socket ~2s in, then the
        // backoff reconnect (~1s) opens the second socket.
        let client = ViewerRelayClient(pingIntervalSeconds: 1, pongTimeoutSeconds: 1)

        await client.connect(
            serverURL: URL(string: "ws://127.0.0.1:\(server.port)")!,
            pairId: "test-pair",
            deviceId: "viewer-device",
            deviceName: "Test Viewer",
            publicKey: "dGVzdC1wdWJsaWMta2V5LTAxMjM0NTY3ODkwMTIzNDU2Nw==",
            publicKeyId: "viewer-key-id",
            e2eeService: e2eeService,
            partnerPublicKey: nil,
            partnerPublicKeyId: nil
        )
        defer { Task { await client.disconnect() } }

        // The client reports connected immediately after the upgrade — that's the
        // "green dot" that used to persist forever on a half-open socket.
        #expect(await waitUntil { client.state.isConnected })
        #expect(await waitUntil { upgrades.value >= 1 })

        // The crux: a second upgrade means the watchdog detected the mute socket
        // and drove a reconnect. Without the fix this never happens.
        let reconnected = await waitUntil(timeout: .seconds(8)) { upgrades.value >= 2 }
        #expect(
            reconnected,
            "Half-open socket was never detected — the client never reconnected (only one upgrade seen)"
        )
    }

    // MARK: - Polling

    private func waitUntil(
        timeout: Duration = .seconds(4),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }
}

// MARK: - Mute relay

/// A minimal Vapor server that accepts the relay's `/api/ws` upgrade and then
/// stays silent — the client's constructed URL is `<serverURL>/api/ws`, so the
/// route path must match. Each successful upgrade bumps the counter.
private struct MuteRelay {
    let app: Application
    let port: Int

    static func start(countingUpgradesInto counter: UpgradeCounter) async throws -> MuteRelay {
        let app = try await Application.make(.testing)
        app.webSocket("api", "ws") { _, ws in
            counter.increment()
            // Deliberately never send a pong or any frame: model a half-open socket.
            // Swallow inbound frames so nothing echoes back to clear `awaitingPong`.
            ws.onText { _, _ in }
            ws.onBinary { _, _ in }
        }
        do {
            try await app.asyncBoot()
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            guard let port = app.http.server.shared.localAddress?.port else {
                await app.server.shutdown()
                try await app.asyncShutdown()
                throw MuteRelayError.noPort
            }
            return MuteRelay(app: app, port: port)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    func stop() {
        let app = app
        Task {
            await app.server.shutdown()
            try? await app.asyncShutdown()
        }
    }
}

private enum MuteRelayError: Error {
    case noPort
}

/// Thread-safe counter of successful WebSocket upgrades (the route closure runs
/// on a NIO event loop).
final private class UpgradeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
