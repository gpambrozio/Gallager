import Foundation
import GallagerPluginProtocol
import Logging

// `JSONValue` lives in `ClaudeSpyNetworking`; the rest of the JSON-RPC
// envelope types live in `GallagerPluginProtocol`. Both modules unfortunately
// declare types named `JSONRPCRequest` / `JSONRPCResponse` / `JSONRPCError`,
// so we narrow `ClaudeSpyNetworking` to just `JSONValue` to keep references
// in this file unambiguous.
import enum ClaudeSpyNetworking.JSONValue

// MARK: - JSONRPCConnectionError

/// Errors that can flow out of `JSONRPCConnection.send(...)` and friends.
public enum JSONRPCConnectionError: Error, Equatable, Sendable {
    /// The peer never produced a response within the supplied deadline.
    /// The continuation has already been removed from the table.
    case timeout(method: String)

    /// The peer returned a structured JSON-RPC error payload.
    case rpcError(JSONRPCError)

    /// The connection was stopped (locally) or the read loop hit EOF before
    /// the response arrived. All in-flight calls are torn down with this.
    case connectionClosed

    /// Encoder threw while serialising `params`.
    case encodingFailed(String)

    /// Decoder threw while turning the response `result` into `R`.
    case decodingFailed(String)
}

// MARK: - JSONRPCConnection

// swiftlint:disable:next custom_no_number_decimals
/// Full-duplex JSON-RPC 2.0 transport over a pair of `FileHandle`s.
///
/// Used by `SidecarSupervisor` to talk to a child process via its stdin
/// (`input`) and stdout (`output`), but the actor accepts any pair of handles
/// so tests can wire two `Pipe`s together without spawning a real process.
///
/// Framing is LSP-style (`Content-Length: N\r\n\r\n<body>`), handled by
/// `JSONRPCFramer`. The actor:
///
/// - Serialises all outbound writes through its own queue.
/// - Runs a single reader `Task` that pulls framed messages off `output.bytes`,
///   then routes them to either an outstanding continuation (response) or to
///   the delegate (request / notification).
/// - Tracks in-flight requests keyed by `JSONRPCID` so unmatched responses can
///   be logged and dropped without crashing.
public actor JSONRPCConnection {
    // MARK: - Delegate

    /// Inbound traffic from the peer that the connection can't satisfy on its
    /// own (i.e. requests and notifications). The delegate is held weakly to
    /// avoid retain cycles between supervisor/connection.
    public protocol Delegate: AnyObject, Sendable {
        /// A notification arrived from the peer — fire-and-forget on the wire.
        func received(notification: JSONRPCNotification) async

        /// A request arrived from the peer. The returned response is written
        /// back on the same connection. Delegate is responsible for matching
        /// the request's `id`.
        func received(request: JSONRPCRequest) async -> JSONRPCResponse
    }

    // MARK: - State

    private let input: FileHandle
    private let output: FileHandle
    private weak var delegate: (any Delegate)?
    private let logger: Logger

    private var nextID = 1
    /// Pending request slots. Switched from `CheckedContinuation` to
    /// `AsyncThrowingStream.Continuation` so callers can register
    /// synchronously on the actor *before* the wire write, closing the race
    /// where a fast peer's reply landed before the continuation existed.
    private var pending: [JSONRPCID: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private var readerTask: Task<Void, Never>?
    private var isStopped = false

    /// Serial queue that owns `input.write(contentsOf:)`. Writes are offloaded
    /// so a full child stdin pipe doesn't pin the actor's executor and starve
    /// every other call (Spec §12's heartbeat in particular).
    private nonisolated let writeQueue = DispatchQueue(
        label: "gallager.plugin.rpc.write"
    )

    /// JSON encoders/decoders configured to match the wire convention
    /// (snake_case keys, ISO-8601 dates). Reused across calls so we don't
    /// re-allocate strategies every time `send` fires.
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Init

    public init(
        input: FileHandle,
        output: FileHandle,
        delegate: any Delegate,
        logger: Logger? = nil
    ) {
        self.input = input
        self.output = output
        self.delegate = delegate
        self.logger = logger ?? Logger(label: "gallager.plugin.rpc")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Lifecycle

    /// Start the inbound reader loop. Idempotent — calling twice is a no-op.
    public func start() {
        guard readerTask == nil, !isStopped else { return }
        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    /// Stop the reader loop and fail every outstanding call with
    /// `.connectionClosed`. Safe to call multiple times.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        readerTask?.cancel()
        readerTask = nil

        let outstanding = pending
        pending.removeAll()
        for (_, continuation) in outstanding {
            continuation.finish(throwing: JSONRPCConnectionError.connectionClosed)
        }
    }

    // MARK: - Outbound: requests

    /// Send a request and decode the response `result` payload as `R`.
    public func send<P: Encodable & Sendable, R: Decodable & Sendable>(
        method: String,
        params: P,
        timeout: Duration = .seconds(30)
    ) async throws -> R {
        let resultData = try await sendAndWaitForResult(
            method: method,
            params: params,
            timeout: timeout
        )
        do {
            return try decoder.decode(R.self, from: resultData)
        } catch {
            throw JSONRPCConnectionError.decodingFailed(String(describing: error))
        }
    }

    /// Send a request expecting an empty/null response — used when the caller
    /// doesn't care about the result body, only that the RPC completed.
    public func send<P: Encodable & Sendable>(
        method: String,
        params: P,
        timeout: Duration = .seconds(30)
    ) async throws {
        _ = try await sendAndWaitForResult(
            method: method,
            params: params,
            timeout: timeout
        )
    }

    // MARK: - Outbound: notifications

    /// Fire-and-forget on the wire — but the local write itself awaits so the
    /// actor doesn't block on a full child stdin pipe.
    public func notify<P: Encodable & Sendable>(method: String, params: P) async throws {
        let paramsValue = try encodeParams(params)
        let notification = JSONRPCNotification(
            jsonrpc: "2.0",
            method: method,
            params: paramsValue
        )
        let body = try encodeMessage(.notification(notification))
        try await writeFrame(body)
    }

    // MARK: - Outbound: implementation

    /// Builds a request, registers a response slot synchronously, writes the
    /// frame, then races a timeout against the response. On any failure the
    /// pending slot is removed.
    private func sendAndWaitForResult<P: Encodable & Sendable>(
        method: String,
        params: P,
        timeout: Duration
    ) async throws -> Data {
        if isStopped {
            throw JSONRPCConnectionError.connectionClosed
        }

        let id = JSONRPCID.number(nextID)
        nextID += 1

        let paramsValue = try encodeParams(params)
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: id,
            method: method,
            params: paramsValue
        )
        let body = try encodeMessage(.request(request))

        // Register the response slot synchronously, BEFORE writing, so a fast
        // peer's reply can never beat us to `pending`. The actor's serial
        // execution guarantees no other call sees an intermediate state.
        let resultStream = registerPending(id: id)

        do {
            try await writeFrame(body)
        } catch {
            cancelPending(id: id, error: error)
            throw error
        }

        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    var iterator = resultStream.makeAsyncIterator()
                    guard let data = try await iterator.next() else {
                        throw JSONRPCConnectionError.connectionClosed
                    }
                    return data
                }
                group.addTask { [weak self] in
                    try await Task.sleep(for: timeout)
                    let timeoutError = JSONRPCConnectionError.timeout(method: method)
                    await self?.cancelPending(id: id, error: timeoutError)
                    throw timeoutError
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            // Defensive: in the connectionClosed / cancelled paths the slot
            // may still be present. `cancelPending` is idempotent.
            cancelPending(id: id, error: JSONRPCConnectionError.connectionClosed)
            throw error
        }
    }

    /// Synchronously add a pending slot keyed by `id` and return its stream.
    /// Runs entirely on the actor — no suspension between insert and write.
    private func registerPending(id: JSONRPCID) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        if isStopped {
            continuation.finish(throwing: JSONRPCConnectionError.connectionClosed)
            return stream
        }
        pending[id] = continuation
        return stream
    }

    /// Remove and fail a pending slot if it's still there. Idempotent so the
    /// timeout branch, the writeFrame failure path, and the catch-all can all
    /// call it without coordinating.
    private func cancelPending(id: JSONRPCID, error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.finish(throwing: error)
    }

    // MARK: - Inbound

    /// Reader loop: read framed JSON, decode `JSONRPCMessage`, dispatch.
    /// Exits on stream EOF, decode error, or task cancellation.
    private func readLoop() async {
        // NB: Don't use `output.bytes` — `FileHandle.AsyncBytes` doesn't
        // deliver pipe bytes until the writer closes its end. We need each
        // framed message to land as soon as the peer flushes it. See
        // `FileHandle.makeAsyncByteStream()` for the readabilityHandler-based
        // implementation.
        let bytes = output.makeAsyncByteStream()
        while !Task.isCancelled, !isStopped {
            do {
                let body = try await JSONRPCFramer.read(from: bytes)
                let message = try decoder.decode(JSONRPCMessage.self, from: body)
                await handleMessage(message, rawBody: body)
            } catch is CancellationError {
                break
            } catch {
                logger.warning("rpc read loop ending: \(error)")
                break
            }
        }
        // Stream ended (peer closed stdout). Tear down outstanding calls so
        // callers see `.connectionClosed` instead of hanging forever.
        teardownOnReaderExit()
    }

    /// Dispatch one inbound message. Inbound notifications + requests are
    /// awaited inline so back-to-back wire messages reach the delegate in
    /// arrival order — `Task.detached` / `Task { … }` here would break the
    /// ordering the wire establishes (CLAUDE.md
    /// `feedback_no-fire-and-forget-tasks.md`).
    private func handleMessage(_ message: JSONRPCMessage, rawBody: Data) async {
        switch message {
        case let .response(response):
            handleResponse(response, rawBody: rawBody)

        case let .notification(notification):
            if let delegate = delegate {
                await delegate.received(notification: notification)
            } else {
                logger.debug(
                    "dropping notification \(notification.method) — no delegate"
                )
            }

        case let .request(request):
            let response: JSONRPCResponse
            if let delegate = delegate {
                response = await delegate.received(request: request)
            } else {
                // No delegate to ask — synthesize a "method not found" reply
                // so the peer doesn't hang waiting.
                response = JSONRPCResponse(
                    jsonrpc: "2.0",
                    id: request.id,
                    result: nil,
                    error: JSONRPCError(
                        code: -32_601,
                        message: "Method not handled: \(request.method)"
                    )
                )
            }
            await writeResponse(response)
        }
    }

    private func handleResponse(_ response: JSONRPCResponse, rawBody: Data) {
        guard let continuation = pending.removeValue(forKey: response.id) else {
            // Unknown id — log and drop. Could be a duplicate, a late reply
            // after a timeout fired, or a peer bug. Either way, no crash.
            logger.debug("dropping response for unknown id: \(response.id)")
            return
        }
        if let rpcError = response.error {
            continuation.finish(throwing: JSONRPCConnectionError.rpcError(rpcError))
            return
        }
        // The `result` we hand back to the typed `send<R>` is encoded fresh
        // from the JSONValue so the snake_case strategy applies on decode.
        let resultBody: Data
        do {
            resultBody = try encoder.encode(response.result ?? JSONValue.null)
        } catch {
            continuation.finish(
                throwing: JSONRPCConnectionError.decodingFailed(
                    "could not re-encode result: \(error)"
                )
            )
            return
        }
        continuation.yield(resultBody)
        continuation.finish()
    }

    /// Send a response (built by the delegate) back over the wire.
    private func writeResponse(_ response: JSONRPCResponse) async {
        do {
            let body = try encodeMessage(.response(response))
            try await writeFrame(body)
        } catch {
            logger.warning("failed to write response \(response.id): \(error)")
        }
    }

    /// Called when the reader exits (EOF or unrecoverable decode). Wakes up
    /// any in-flight callers so they don't hang.
    private func teardownOnReaderExit() {
        guard !isStopped else { return }
        isStopped = true
        let outstanding = pending
        pending.removeAll()
        for (_, continuation) in outstanding {
            continuation.finish(throwing: JSONRPCConnectionError.connectionClosed)
        }
    }

    // MARK: - Encoding helpers

    /// Encode `params` first as `Data`, then re-decode into `JSONValue` so the
    /// envelope's heterogeneous params slot accepts it. Avoids leaking the
    /// caller's concrete type into the on-wire form.
    private func encodeParams<P: Encodable>(_ params: P) throws -> JSONValue {
        do {
            let data = try encoder.encode(params)
            return try decoder.decode(JSONValue.self, from: data)
        } catch {
            throw JSONRPCConnectionError.encodingFailed(String(describing: error))
        }
    }

    private func encodeMessage(_ message: JSONRPCMessage) throws -> Data {
        do {
            return try encoder.encode(message)
        } catch {
            throw JSONRPCConnectionError.encodingFailed(String(describing: error))
        }
    }

    /// Write one framed JSON-RPC body to the input handle on `writeQueue`,
    /// suspending the actor only across the I/O itself. A backed-up child
    /// stdin (e.g. sidecar stalled in `initialize`) blocks the write queue
    /// alone instead of the actor's mailbox.
    private func writeFrame(_ body: Data) async throws {
        let frame = JSONRPCFramer.encode(body)
        let input = self.input
        let queue = writeQueue
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try input.write(contentsOf: frame)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            throw JSONRPCConnectionError.connectionClosed
        }
    }
}
