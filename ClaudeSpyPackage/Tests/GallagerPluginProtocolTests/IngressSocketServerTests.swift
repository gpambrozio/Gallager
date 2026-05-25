import ClaudeSpyNetworking
import Foundation
import Network
import Testing
@testable import GallagerPluginProtocol

@Suite("IngressSocketServer")
struct IngressSocketServerTests {
    @Test("accepts a connection and decodes a length-prefixed JSON frame")
    func acceptAndDecodeFrame() async throws {
        let socketURL = Self.makeTempSocketURL()
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let server = IngressSocketServer(socketURL: socketURL)
        let frames = try await server.start()

        // Connect from the "host agent" side and write the framed body.
        let frame = IngressFrame(
            context: ["TMUX_PANE": "%5", "CLAUDE_PROJECT_DIR": "/tmp/proj"],
            payload: .object([
                "tool": .string("Read"),
                "input": .object(["file": .string("foo.swift")]),
            ])
        )
        let body = try frame.encodedForSocket()
        try await sendUnixSocket(path: socketURL.path, data: body)

        // Receive on the server side.
        var iter = frames.makeAsyncIterator()
        let received = try #require(await iter.next())
        #expect(received == frame)

        await server.stop()
    }

    @Test("malformed frame is dropped without breaking the server")
    func malformedFrameIsRecoverable() async throws {
        let socketURL = Self.makeTempSocketURL()
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let server = IngressSocketServer(socketURL: socketURL)
        let frames = try await server.start()
        let parseErrors = await server.parseErrors()

        // First connection: lies about length — says 100 bytes, sends 4 and EOFs.
        var garbage = Data()
        garbage.append(IngressFrame.encodeLengthPrefix(100))
        garbage.append(Data([0x7B, 0x7D, 0x20, 0x21])) // "{} !" — only 4 bytes
        try await sendUnixSocket(path: socketURL.path, data: garbage)

        // The server should surface the parse error rather than crash.
        var errorIter = parseErrors.makeAsyncIterator()
        let observedError = await errorIter.next()
        #expect(observedError != nil)

        // Second connection: valid frame. The server is still alive.
        let frame = IngressFrame(
            context: ["KEY": "VALUE"],
            payload: .object(["ok": .bool(true)])
        )
        let body = try frame.encodedForSocket()
        try await sendUnixSocket(path: socketURL.path, data: body)

        var iter = frames.makeAsyncIterator()
        let received = try #require(await iter.next())
        #expect(received == frame)

        await server.stop()
    }

    @Test("multiple connections deliver frames in arrival order")
    func multipleConnections() async throws {
        let socketURL = Self.makeTempSocketURL()
        defer { try? FileManager.default.removeItem(at: socketURL) }

        let server = IngressSocketServer(socketURL: socketURL)
        let frames = try await server.start()

        let toSend: [IngressFrame] = [
            IngressFrame(context: ["N": "1"], payload: .object(["i": .int(1)])),
            IngressFrame(context: ["N": "2"], payload: .object(["i": .int(2)])),
            IngressFrame(context: ["N": "3"], payload: .object(["i": .int(3)])),
        ]

        for frame in toSend {
            let body = try frame.encodedForSocket()
            try await sendUnixSocket(path: socketURL.path, data: body)
        }

        // Collect the same number of frames the server saw, then compare as
        // a SET — concurrent connections may arrive in any order.
        var iter = frames.makeAsyncIterator()
        var received: [IngressFrame] = []
        for _ in 0..<toSend.count {
            let frame = try #require(await iter.next())
            received.append(frame)
        }
        #expect(Set(received.map(\.contextHash)) == Set(toSend.map(\.contextHash)))

        await server.stop()
    }

    // MARK: - Helpers

    /// Returns a temp directory `.sock` URL with a UUID suffix so concurrent
    /// runs don't collide.
    private static func makeTempSocketURL() -> URL {
        // macOS sockaddr_un caps the path at 104 bytes. NSTemporaryDirectory()
        // is already short; "/tmp/ingress-<uuid>.sock" is well under the limit.
        URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("ingress-\(UUID().uuidString).sock")
    }
}

/// Send raw bytes to a Unix domain socket and close the write side so the
/// server can see EOF on the receive side. Returns once the bytes are
/// acknowledged by the kernel.
private func sendUnixSocket(path: String, data: Data) async throws {
    let endpoint = NWEndpoint.unix(path: path)
    let connection = NWConnection(to: endpoint, using: .tcp)
    let queue = DispatchQueue(label: "test.unix.send")

    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        // Resume exactly once. `stateUpdateHandler` fires repeatedly across
        // .ready → .cancelled; we need to guard against double-resume.
        let didResume = LockedBox(false)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        if didResume.compareAndSet(false, true) {
                            cont.resume(throwing: error)
                        }
                    } else {
                        // Close so the server reads EOF promptly.
                        connection.cancel()
                        if didResume.compareAndSet(false, true) {
                            cont.resume()
                        }
                    }
                })
            case let .failed(error):
                if didResume.compareAndSet(false, true) {
                    cont.resume(throwing: error)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

/// Tiny atomic boolean box used by the unix-socket test helper to avoid
/// double-resuming the continuation when `NWConnection` transitions through
/// `.ready → .cancelled` (both handlers can fire).
final private class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ initial: Bool) { self.value = initial }

    func compareAndSet(_ expected: Bool, _ new: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value == expected {
            value = new
            return true
        }
        return false
    }
}

// MARK: - IngressFrame test helpers

private extension IngressFrame {
    /// Stable identity for set comparison: context k/v pairs joined plus
    /// payload's JSON encoding. Avoids depending on `Hashable` for `JSONValue`.
    var contextHash: String {
        let ctx = context.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        let payloadBytes = (try? JSONEncoder().encode(payload)) ?? Data()
        let payloadStr = String(data: payloadBytes, encoding: .utf8) ?? ""
        return "\(ctx)|\(payloadStr)"
    }
}
