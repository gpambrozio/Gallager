import enum ClaudeSpyNetworking.JSONValue
import ConcurrencyExtras
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeSpyPluginRuntime

@Suite("JSONRPCConnection")
struct JSONRPCConnectionTests {
    // MARK: - Helpers

    /// Two pipes wired to model an in-process peer. The connection writes its
    /// outbound frames into `app→peer`'s write end and reads inbound frames
    /// from `peer→app`'s read end. The test, playing the role of the sidecar,
    /// reads frames off `app→peer.fileHandleForReading` and writes responses
    /// into `peer→app.fileHandleForWriting`.
    private struct PipePair {
        let appToPeer: Pipe
        let peerToApp: Pipe

        var connectionInput: FileHandle { appToPeer.fileHandleForWriting }
        var connectionOutput: FileHandle { peerToApp.fileHandleForReading }
        var peerInput: FileHandle { appToPeer.fileHandleForReading }
        var peerOutput: FileHandle { peerToApp.fileHandleForWriting }

        init() {
            self.appToPeer = Pipe()
            self.peerToApp = Pipe()
        }
    }

    /// Minimal collecting delegate so notification routing tests can assert
    /// the connection forwarded the payload. Uses `LockIsolated` from
    /// `ConcurrencyExtras` because `NSLock.lock()` is unavailable from
    /// async contexts under Swift 6 concurrency checking.
    final class CollectingDelegate: JSONRPCConnection.Delegate, Sendable {
        private let _notifications = LockIsolated<[JSONRPCNotification]>([])
        private let _requests = LockIsolated<[JSONRPCRequest]>([])

        var notifications: [JSONRPCNotification] { _notifications.value }
        var requests: [JSONRPCRequest] { _requests.value }

        func received(notification: JSONRPCNotification) async {
            _notifications.withValue { $0.append(notification) }
        }

        func received(request: JSONRPCRequest) async -> JSONRPCResponse {
            _requests.withValue { $0.append(request) }
            return JSONRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: .object(["ok": .bool(true)]),
                error: nil
            )
        }
    }

    /// Read one framed JSON-RPC body off the handle and decode it as
    /// `JSONRPCMessage`. Uses the same `readabilityHandler`-driven stream as
    /// the connection itself — `handle.bytes` (FileHandle.AsyncBytes) doesn't
    /// deliver pipe bytes until the writer closes, which would deadlock these
    /// tests since both sides keep the pipe open across multiple frames.
    private func readMessage(from handle: FileHandle) async throws -> JSONRPCMessage {
        let body = try await JSONRPCFramer.read(from: handle.makeAsyncByteStream())
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(JSONRPCMessage.self, from: body)
    }

    private func writeMessage(_ message: JSONRPCMessage, to handle: FileHandle) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(message)
        try handle.write(contentsOf: JSONRPCFramer.encode(body))
    }

    // MARK: - Round-trip

    @Test("send/receive round-trips a request with a typed result")
    func roundTrip() async throws {
        let pipes = PipePair()
        let delegate = CollectingDelegate()
        let connection = JSONRPCConnection(
            input: pipes.connectionInput,
            output: pipes.connectionOutput,
            delegate: delegate
        )
        await connection.start()

        // Drive a fake sidecar that reads one request and echoes back a
        // response carrying the same params under "echo".
        let peerTask = Task.detached { [pipes] in
            let message = try await readMessage(from: pipes.peerInput)
            guard case let .request(request) = message else {
                Issue.record("expected request, got \(message)")
                return
            }
            let response = JSONRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: .object(["echo": request.params ?? .null]),
                error: nil
            )
            try writeMessage(.response(response), to: pipes.peerOutput)
        }

        struct Echo: Decodable, Equatable {
            let echo: [String: Int]
        }

        let result: Echo = try await connection.send(
            method: "ping",
            params: ["x": 1, "y": 2],
            timeout: .seconds(2)
        )

        #expect(result == Echo(echo: ["x": 1, "y": 2]))
        try await peerTask.value
        await connection.stop()
    }

    // MARK: - Notification routing

    @Test("notifications from the peer are routed to the delegate")
    func notificationRouting() async throws {
        let pipes = PipePair()
        let delegate = CollectingDelegate()
        let connection = JSONRPCConnection(
            input: pipes.connectionInput,
            output: pipes.connectionOutput,
            delegate: delegate
        )
        await connection.start()

        // Peer fires an unsolicited notification.
        try writeMessage(
            .notification(JSONRPCNotification(
                jsonrpc: "2.0",
                method: "set_projects",
                params: .object(["count": .int(3)])
            )),
            to: pipes.peerOutput
        )

        // Poll briefly; the delegate hop runs in a detached Task.
        var seen: [JSONRPCNotification] = []
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            seen = delegate.notifications
            if !seen.isEmpty { break }
        }
        try #require(seen.count == 1)
        #expect(seen[0].method == "set_projects")
        #expect(seen[0].params == .object(["count": .int(3)]))

        await connection.stop()
    }

    // MARK: - Unknown-id response is dropped

    @Test("responses whose id has no outstanding request are dropped, not crash")
    func unknownIDResponseDropped() async throws {
        let pipes = PipePair()
        let delegate = CollectingDelegate()
        let connection = JSONRPCConnection(
            input: pipes.connectionInput,
            output: pipes.connectionOutput,
            delegate: delegate
        )
        await connection.start()

        // Peer sends a stray response for id=999 that the app never asked for.
        try writeMessage(
            .response(JSONRPCResponse(
                jsonrpc: "2.0",
                id: .number(999),
                result: .object(["junk": .bool(true)]),
                error: nil
            )),
            to: pipes.peerOutput
        )

        // Wait a beat to let the reader process the stray response (it
        // should log and drop, NOT terminate). Then verify a real exchange
        // still works.
        try await Task.sleep(for: .milliseconds(100))

        let peerTask = Task.detached { [pipes] in
            // Skip frames until we see a request (in case the reader echoed
            // anything weird back). For this test we know the next frame is
            // the real request.
            let message = try await readMessage(from: pipes.peerInput)
            guard case let .request(request) = message else {
                Issue.record("expected request, got \(message)")
                return
            }
            let response = JSONRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: .object(["ok": .bool(true)]),
                error: nil
            )
            try writeMessage(.response(response), to: pipes.peerOutput)
        }

        struct OK: Decodable {
            let ok: Bool
        }
        let result: OK = try await connection.send(
            method: "ping",
            params: [String: String](),
            timeout: .seconds(2)
        )
        #expect(result.ok)
        try await peerTask.value
        await connection.stop()
    }

    // MARK: - Timeout

    @Test("outbound timeout throws and removes the continuation")
    func outboundTimeout() async throws {
        let pipes = PipePair()
        let delegate = CollectingDelegate()
        let connection = JSONRPCConnection(
            input: pipes.connectionInput,
            output: pipes.connectionOutput,
            delegate: delegate
        )
        await connection.start()

        // Peer reads the request but deliberately never replies.
        let peerTask = Task.detached { [pipes] in
            _ = try? await readMessage(from: pipes.peerInput)
        }

        await #expect(throws: JSONRPCConnectionError.timeout(method: "stall")) {
            let _: [String: String] = try await connection.send(
                method: "stall",
                params: [String: String](),
                timeout: .milliseconds(100)
            )
        }

        _ = await peerTask.value
        await connection.stop()
    }

    // MARK: - stop() cancels in-flight

    @Test("stop() during an in-flight send fails it with .connectionClosed")
    func stopCancelsInFlight() async throws {
        let pipes = PipePair()
        let delegate = CollectingDelegate()
        let connection = JSONRPCConnection(
            input: pipes.connectionInput,
            output: pipes.connectionOutput,
            delegate: delegate
        )
        await connection.start()

        // Peer reads but never replies — keeps the call in flight.
        let peerTask = Task.detached { [pipes] in
            _ = try? await readMessage(from: pipes.peerInput)
        }

        // Use an unstructured Task so `#expect(throws:)` can capture its
        // result — `async let` bindings can't be referenced from inside a
        // closure (compiler rejects it).
        let sendTask = Task {
            let _: [String: String] = try await connection.send(
                method: "stall",
                params: [String: String](),
                timeout: .seconds(30)
            )
        }

        // Give the send a moment to register its continuation before we
        // tear down. Without this the stop() can race ahead of the
        // continuation being put into the table.
        try await Task.sleep(for: .milliseconds(50))
        await connection.stop()

        await #expect(throws: JSONRPCConnectionError.connectionClosed) {
            try await sendTask.value
        }
        _ = await peerTask.value
    }
}
