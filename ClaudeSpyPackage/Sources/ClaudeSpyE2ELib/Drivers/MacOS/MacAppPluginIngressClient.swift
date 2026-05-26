import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Logging
import Network

/// Connects to a plugin's `ingress.sock` and writes a single length-prefixed
/// JSON frame.
///
/// Per Spec §8 the sidecar's ingress socket accepts one frame per peer
/// connection: a 4-byte big-endian `UInt32` length prefix followed by a JSON
/// body of shape `{"context": {…}, "payload": <raw>}`. The Mac app's plugin
/// sidecars create these sockets during `initialize`; the e2e DSL injects
/// synthetic hook payloads through them.
///
/// This replaces the legacy HTTP `MacAppHTTPClient.sendHook(...)` path that
/// targeted the now-deleted `HookServerService`.
public actor MacAppPluginIngressClient {
    // MARK: - Storage

    private let socketURL: URL
    private let logger: Logger

    // MARK: - Init

    public init(socketURL: URL) {
        self.socketURL = socketURL
        self.logger = Logger(label: "e2e.plugin-ingress")
    }

    // MARK: - API

    /// Send a single ``IngressFrame`` to the socket and close the connection.
    ///
    /// - Parameters:
    ///   - payload: Raw hook payload — whatever shape the host agent would
    ///     have produced. Passed through verbatim as `frame.payload`.
    ///   - env: Environment map attached as `frame.context` (e.g.
    ///     `["TMUX_PANE": "%0", "CLAUDE_PROJECT_DIR": "/proj"]`).
    ///
    /// Throws if the socket isn't accepting connections, the write fails, or
    /// the encoded frame can't be produced.
    public func send(payload: JSONValue, env: [String: String]) async throws {
        let frame = IngressFrame(context: env, payload: payload)
        let body = try frame.encodedForSocket()

        let connection = NWConnection(
            to: .unix(path: socketURL.path),
            using: .tcp
        )
        let queue = DispatchQueue(label: "e2e.plugin-ingress.send")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // `stateUpdateHandler` fires repeatedly across .ready → .cancelled;
            // guard against double-resume.
            let didResume = SendableBox(false)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: body, completion: .contentProcessed { error in
                        if let error {
                            if didResume.compareAndSet(false, true) {
                                connection.cancel()
                                cont.resume(throwing: error)
                            }
                        } else {
                            // Close the write side so the server reads EOF
                            // promptly and the next test step doesn't race
                            // with a lingering socket.
                            connection.cancel()
                            if didResume.compareAndSet(false, true) {
                                cont.resume()
                            }
                        }
                    })
                case let .failed(error):
                    if didResume.compareAndSet(false, true) {
                        connection.cancel()
                        cont.resume(throwing: error)
                    }
                case let .waiting(error):
                    // `.waiting` means the connection is stuck (e.g. the
                    // socket file exists but no listener is bound, or the
                    // listener queue is full). Surface it so the test fails
                    // fast rather than hanging until the orchestrator's
                    // outer step timeout.
                    if didResume.compareAndSet(false, true) {
                        connection.cancel()
                        cont.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        logger.info(
            "Sent ingress frame (\(body.count) bytes) to \(socketURL.path)"
        )
    }
}

// MARK: - SendableBox

/// Tiny atomic-mutate helper used to guard against double-resume of the
/// `send` continuation when `NWConnection` transitions through
/// `.ready → .cancelled` (both handlers can fire). Patterned after the box
/// in `IngressSocketServerTests`.
final private class SendableBox: @unchecked Sendable {
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
