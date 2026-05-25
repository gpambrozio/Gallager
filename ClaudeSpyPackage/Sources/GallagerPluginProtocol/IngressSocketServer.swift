import Foundation
import Network

// MARK: - IngressSocketServer

/// Listens on a Unix domain socket for plugin-host-agent bridge connections
/// and yields each parsed ``IngressFrame`` on an async stream.
///
/// Per Spec §8, each connecting peer writes a single length-prefixed JSON
/// frame (`UInt32` big-endian length + JSON body) and then closes the
/// connection. This matches the contract used by the Python bridge script
/// shipped with every plugin.
///
/// The server lives inside each sidecar process — the Mac app never opens
/// these sockets directly. A sidecar typically creates the server during
/// `initialize`, consumes its frame stream from its main RPC loop, and tears
/// it down on `shutdown`.
///
/// Concurrency: the actor coordinates listener state and continuation
/// lifetimes. The `NWListener`/`NWConnection` callbacks fire on the internal
/// dispatch queue, so handler entrypoints re-enter the actor via short
/// `Task` hops.
public actor IngressSocketServer {
    // MARK: - Storage

    private let socketURL: URL
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var frameContinuation: AsyncStream<IngressFrame>.Continuation?
    private var parseErrorContinuation: AsyncStream<Error>.Continuation?
    /// Active connections kept alive while they read their length-prefixed
    /// frame. Without retaining them here `NWConnection` is deallocated as
    /// soon as `handleConnection(_:)` returns and the receive callback never
    /// fires.
    private var liveConnections: [ObjectIdentifier: NWConnection] = [:]

    // MARK: - Init

    public init(socketURL: URL) {
        self.socketURL = socketURL
        // One queue per server keeps connection callbacks ordered and lets
        // the actor's continuation resumes funnel through a stable executor.
        self.queue = DispatchQueue(
            label: "gallager.plugin.ingress.\(socketURL.lastPathComponent)"
        )
    }

    // MARK: - Lifecycle

    /// Start listening. Returns the stream of parsed frames. Throws on
    /// listener startup error (socket path occupied, permission, etc.).
    /// Subscribe to ``parseErrors()`` before calling `start()` if you need
    /// to observe malformed-frame errors; otherwise they are dropped.
    public func start() throws -> AsyncStream<IngressFrame> {
        // Remove any stale socket file before binding. The kernel will refuse
        // `bind()` on a path that already exists, so a previous run's socket
        // file would prevent us from coming back up cleanly.
        try? FileManager.default.removeItem(at: socketURL)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // NWParameters.tcp gives byte-stream semantics; pairing it with a
        // unix-path `requiredLocalEndpoint` binds the listener to AF_UNIX.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: socketURL.path)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        self.listener = listener

        let (stream, continuation) = AsyncStream.makeStream(of: IngressFrame.self)
        frameContinuation = continuation

        listener.newConnectionHandler = { [weak self] connection in
            // Hop back onto the actor to register and drain the connection.
            // The connection is retained by `liveConnections` before any
            // `receive` is issued so the callback fires reliably.
            Task { [weak self] in
                await self?.accept(connection: connection)
            }
        }
        listener.start(queue: queue)

        return stream
    }

    /// Optional secondary stream of parse errors (truncated frame, invalid
    /// JSON body, oversized length prefix, …). Call once and hold the
    /// returned stream for the lifetime of the server; subsequent calls
    /// finish the previously-returned stream.
    public func parseErrors() -> AsyncStream<Error> {
        // Finish any previous parseErrors subscriber so a late re-subscriber
        // doesn't leave a dangling continuation.
        parseErrorContinuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: Error.self)
        parseErrorContinuation = continuation
        return stream
    }

    /// Stop listening, finish the frame stream, and remove the socket file.
    /// Safe to call multiple times.
    public func stop() {
        listener?.cancel()
        listener = nil
        frameContinuation?.finish()
        frameContinuation = nil
        parseErrorContinuation?.finish()
        parseErrorContinuation = nil
        for (_, connection) in liveConnections {
            connection.cancel()
        }
        liveConnections.removeAll()
        try? FileManager.default.removeItem(at: socketURL)
    }

    // MARK: - Connection handling

    private func accept(connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        liveConnections[id] = connection
        connection.start(queue: queue)
        Task { [weak self] in
            await self?.drain(connectionID: id, connection: connection)
        }
    }

    private func drain(connectionID id: ObjectIdentifier, connection: NWConnection) async {
        defer {
            connection.cancel()
            liveConnections.removeValue(forKey: id)
        }

        do {
            let lengthBytes = try await receiveExactly(4, on: connection)
            let length = lengthBytes.withUnsafeBytes { raw in
                raw.load(as: UInt32.self).bigEndian
            }
            // Reject pathological lengths to avoid OOM from a hostile peer.
            // 32 MiB is far larger than any legitimate hook payload but small
            // enough to refuse out-of-band garbage cheaply.
            guard length > 0, length <= 32 * 1_024 * 1_024 else {
                parseErrorContinuation?.yield(
                    IngressSocketServerError.lengthOutOfRange(length)
                )
                return
            }

            let body = try await receiveExactly(Int(length), on: connection)
            let frame = try IngressFrame.decode(from: body)
            frameContinuation?.yield(frame)
        } catch {
            parseErrorContinuation?.yield(error)
        }
    }

    // MARK: - Low-level receive helpers

    /// Receive exactly `n` bytes from the connection. Throws on EOF before
    /// reaching `n` bytes.
    private func receiveExactly(_ n: Int, on connection: NWConnection) async throws -> Data {
        var collected = Data()
        collected.reserveCapacity(n)
        while collected.count < n {
            let chunk = try await receiveSome(
                connection: connection,
                minimum: 1,
                maximum: n - collected.count
            )
            if chunk.isEmpty {
                throw IngressSocketServerError.eofBeforeFrame
            }
            collected.append(chunk)
        }
        return collected
    }

    private nonisolated func receiveSome(
        connection: NWConnection,
        minimum: Int,
        maximum: Int
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(
                minimumIncompleteLength: minimum,
                maximumLength: maximum
            ) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    // Peer closed cleanly. Empty Data signals EOF to the
                    // caller; `receiveExactly` translates that into
                    // `.eofBeforeFrame` if the requested count was not met.
                    cont.resume(returning: Data())
                } else {
                    cont.resume(
                        throwing: IngressSocketServerError.unexpectedReceiveOutcome
                    )
                }
            }
        }
    }
}

// MARK: - IngressSocketServerError

public enum IngressSocketServerError: Error, Equatable, Sendable {
    /// The peer closed before delivering the full length-prefix + body.
    case eofBeforeFrame
    /// The length prefix was zero or exceeded the 32 MiB safety cap.
    case lengthOutOfRange(UInt32)
    /// `NWConnection.receive` returned no data, no error, and `isComplete=false`
    /// — should never happen on a healthy connection, but bail out rather
    /// than spinning if it ever does.
    case unexpectedReceiveOutcome
}
