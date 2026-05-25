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
    private var pending: [JSONRPCID: CheckedContinuation<Data, Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var isStopped = false

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
            continuation.resume(throwing: JSONRPCConnectionError.connectionClosed)
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

    /// Fire-and-forget: encode + frame + write a JSON-RPC notification.
    public func notify<P: Encodable & Sendable>(method: String, params: P) async throws {
        let paramsValue = try encodeParams(params)
        let notification = JSONRPCNotification(
            jsonrpc: "2.0",
            method: method,
            params: paramsValue
        )
        let body = try encodeMessage(.notification(notification))
        try writeFrame(body)
    }

    // MARK: - Outbound: implementation

    /// Builds a request, registers a continuation, writes the frame, then
    /// races a timeout against the response. On any failure the continuation
    /// is removed from the table.
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

        return try await withThrowingTaskGroup(of: Data.self) { group in
            // Response branch — registers a continuation that the reader will
            // resume when the matching response arrives. The continuation
            // resolves to the raw `result` bytes so the typed decode happens
            // outside the actor's critical section.
            group.addTask { [weak self] in
                guard let self else {
                    throw JSONRPCConnectionError.connectionClosed
                }
                return try await self.waitForResponse(id: id)
            }

            // Send the frame AFTER the continuation is registered so a fast
            // peer can't reply before we're listening. With cooperative
            // multitasking the registration runs synchronously inside the
            // child task; the actor's serial queue keeps writes from racing.
            try writeFrame(body)

            // Timeout branch — drops the continuation on fire so a late reply
            // doesn't try to resume an already-resumed continuation.
            group.addTask { [weak self] in
                try await Task.sleep(for: timeout)
                if let self {
                    await self.failIfPending(
                        id: id,
                        error: JSONRPCConnectionError.timeout(method: method)
                    )
                }
                throw JSONRPCConnectionError.timeout(method: method)
            }

            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// Register a continuation under `id` and suspend until the reader resumes
    /// it. The continuation is removed from `pending` inside the reader.
    private func waitForResponse(id: JSONRPCID) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            // If we were stopped between the caller's check and us getting
            // here, fail immediately instead of orphaning the continuation.
            if isStopped {
                continuation.resume(throwing: JSONRPCConnectionError.connectionClosed)
                return
            }
            pending[id] = continuation
        }
    }

    /// Cancel the continuation for `id` with the given error if it's still
    /// pending. Used by the timeout branch so a late reply finds no entry.
    private func failIfPending(id: JSONRPCID, error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
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
                handleMessage(message, rawBody: body)
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

    private func handleMessage(_ message: JSONRPCMessage, rawBody: Data) {
        switch message {
        case let .response(response):
            handleResponse(response, rawBody: rawBody)

        case let .notification(notification):
            // Notification handling is allowed to be async — hop into a
            // detached Task so the reader doesn't stall on slow delegates.
            // Capture the delegate once on the actor and pass it in.
            if let delegate = delegate {
                Task.detached {
                    await delegate.received(notification: notification)
                }
            } else {
                logger.debug(
                    "dropping notification \(notification.method) — no delegate"
                )
            }

        case let .request(request):
            if let delegate = delegate {
                Task { [weak self] in
                    let response = await delegate.received(request: request)
                    await self?.writeResponse(response)
                }
            } else {
                // No delegate to ask — synthesize a "method not found" reply
                // so the peer doesn't hang waiting.
                let response = JSONRPCResponse(
                    jsonrpc: "2.0",
                    id: request.id,
                    result: nil,
                    error: JSONRPCError(
                        code: -32_601,
                        message: "Method not handled: \(request.method)"
                    )
                )
                Task { [weak self] in
                    await self?.writeResponse(response)
                }
            }
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
            continuation.resume(
                throwing: JSONRPCConnectionError.rpcError(rpcError)
            )
            return
        }
        // The `result` we hand back to the typed `send<R>` is encoded fresh
        // from the JSONValue so the snake_case strategy applies on decode.
        let resultBody: Data
        do {
            resultBody = try encoder.encode(response.result ?? JSONValue.null)
        } catch {
            continuation.resume(
                throwing: JSONRPCConnectionError.decodingFailed(
                    "could not re-encode result: \(error)"
                )
            )
            return
        }
        continuation.resume(returning: resultBody)
    }

    /// Send a response (built by the delegate) back over the wire.
    private func writeResponse(_ response: JSONRPCResponse) {
        do {
            let body = try encodeMessage(.response(response))
            try writeFrame(body)
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
            continuation.resume(throwing: JSONRPCConnectionError.connectionClosed)
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

    /// Write one framed JSON-RPC body to the input handle. Serialised because
    /// every call is on the actor.
    private func writeFrame(_ body: Data) throws {
        let frame = JSONRPCFramer.encode(body)
        do {
            try input.write(contentsOf: frame)
        } catch {
            throw JSONRPCConnectionError.connectionClosed
        }
    }
}
