import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Logging

// MARK: - Protocol

/// Receives inbound messages the transport routes from the peer.
public protocol SidecarTransportDelegate: AnyObject, Sendable {
    /// Called inline in the read loop — do not block indefinitely.
    func handleNotification(_ method: String, _ params: JSONValue?) async
    /// Called inline in the read loop for peer-initiated requests. Return a result; the
    /// transport writes the response.
    func handleInboundRequest(_ method: String, _ params: JSONValue?) async -> Result<JSONValue, RPCError>
}

// MARK: - Error

public enum TransportError: Error, Equatable {
    case timeout(String)
    case peerClosed
    case rpc(RPCError)
    case encodeFailed
}

// MARK: - Actor

/// Bidirectional JSON-RPC-over-stdio transport.
///
/// Wire framing: `Content-Length`-delimited JSON bodies via `StdioFramer`/`FrameDecoder`.
///
/// Binding constraints implemented:
/// - Pending-request slot registered SYNCHRONOUSLY (inside `withCheckedThrowingContinuation`)
///   before the write task fires, so a fast response can never race past registration.
/// - Inbound notifications are awaited INLINE in the read loop to preserve wire order.
/// - Writes are offloaded to a serial `DispatchQueue` via a continuation; a full stdin pipe
///   never stalls the actor.
/// - Per-RPC timeout is mandatory (default 30 s); timeout task is always cancelled on success.
/// - Read loop handles responses, inbound requests, and inbound notifications.
/// - Peer-close / framing error fails all pending continuations exactly once.
public actor SidecarTransport {
    private let writeHandle: FileHandle
    private weak var delegate: (any SidecarTransportDelegate)?
    private let logger = Logger(label: "com.claudespy.sidecar.transport")

    private var decoder = FrameDecoder()
    /// Pending outbound requests keyed by message id. Each continuation is resumed
    /// exactly once: on response arrival, timeout, or peer-closed.
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var counter = 0
    private var closed = false
    private var loop: Task<Void, Never>?

    /// Serialises writes; a full stdin buffer must not stall the actor.
    private let writeQueue = DispatchQueue(label: "com.claudespy.sidecar.write", qos: .userInitiated)

    public init(writeHandle: FileHandle, delegate: any SidecarTransportDelegate) {
        self.writeHandle = writeHandle
        self.delegate = delegate
    }

    // MARK: - Lifecycle

    /// Starts the ordered read loop. Call once; idempotent after the first call.
    public func start(reading bytes: AsyncStream<Data>) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            for await chunk in bytes {
                guard let self else { return }
                await self.ingest(chunk)
            }
            await self?.handlePeerClosed()
        }
    }

    /// Fails all pending requests with `.peerClosed` and stops the read loop.
    public func close() async {
        await handlePeerClosed()
    }

    // MARK: - Public API

    /// Sends a request and waits for a correlated response.
    ///
    /// The pending slot is registered inside `withCheckedThrowingContinuation` — before
    /// any `await` — ensuring even a response that arrives before the first suspension
    /// is never lost.
    public func request(
        _ method: String,
        _ params: JSONValue?,
        timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        if closed { throw TransportError.peerClosed }
        counter += 1
        let id = "rpc-\(counter)"

        // Start the timeout race. On expiry it removes the pending slot and resumes
        // the continuation with .timeout. On success we cancel it.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failPending(id, with: TransportError.timeout(method))
        }

        do {
            // CRITICAL: register the slot synchronously inside the continuation callback,
            // then dispatch the write. This ordering ensures no response can slip through
            // before we are listening.
            let value = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<JSONValue, any Error>) in
                // M1: Re-check closed synchronously before registering the slot. Because this
                // body and handlePeerClosed() are both actor-isolated with no await between
                // entry and the assignment, this closes the race where close() is called
                // between the entry-level guard and here.
                if closed { cont.resume(throwing: TransportError.peerClosed)
                    return
                }
                // Actor-isolated assignment — we are inside the actor here because
                // withCheckedThrowingContinuation's body runs synchronously on the caller.
                pending[id] = cont
                // Dispatch the write off-actor so a blocked pipe doesn't deadlock us.
                // I1: Propagate write/encode errors back to the caller immediately rather
                // than swallowing them with try?, which would leave the caller blocked
                // until the 30s timeout fires.
                Task { [weak self] in
                    do { try await self?.send(.request(id: id, method: method, params: params)) }
                    catch { await self?.failPending(id, with: error) }
                }
            }
            timeoutTask.cancel()
            return value
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    /// Sends a one-way notification (App→Sidecar).
    public func notify(_ method: String, _ params: JSONValue?) async throws {
        if closed { throw TransportError.peerClosed }
        try await send(.notification(method: method, params: params))
    }

    // MARK: - Read loop internals

    private func ingest(_ chunk: Data) async {
        let bodies: [Data]
        do {
            bodies = try decoder.push(chunk)
        } catch {
            logger.error("framing error — dropping connection: \(error)")
            await handlePeerClosed()
            return
        }
        // Each message is awaited inline, preserving wire order. No fire-and-forget.
        for body in bodies {
            guard let msg = try? JSONDecoder().decode(RPCMessage.self, from: body) else {
                logger.debug("dropping malformed RPC frame (not valid RPCMessage)")
                continue
            }
            await route(msg)
        }
    }

    private func route(_ msg: RPCMessage) async {
        if msg.isResponse, let id = msg.id {
            guard let cont = pending.removeValue(forKey: id) else {
                logger.debug("no pending request for id \(id) — duplicate/late response")
                return
            }
            if let error = msg.error {
                cont.resume(throwing: TransportError.rpc(error))
            } else {
                cont.resume(returning: msg.result ?? .object([:]))
            }
        } else if msg.isRequest, let id = msg.id, let method = msg.method {
            // Inbound request from peer (e.g. agent_panes). Route to delegate, write response.
            let outcome = await delegate?.handleInboundRequest(method, msg.params)
                ?? .failure(.methodNotFound(method))
            switch outcome {
            case let .success(value):
                try? await send(.response(id: id, result: value))
            case let .failure(error):
                try? await send(.failure(id: id, error: error))
            }
        } else if msg.isNotification, let method = msg.method {
            // Awaited inline — preserves wire order, no detached Task per notification.
            await delegate?.handleNotification(method, msg.params)
        }
    }

    // MARK: - Write

    private func send(_ msg: RPCMessage) async throws {
        guard let body = try? JSONEncoder().encode(msg) else {
            throw TransportError.encodeFailed
        }
        let frame = StdioFramer.encode(body)
        let handle = writeHandle
        // Offload to the serial queue so a full pipe never blocks the actor.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            writeQueue.async {
                do {
                    try handle.write(contentsOf: frame)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Called by the timeout task. No-ops if the id was already resolved.
    private func failPending(_ id: String, with error: any Error) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(throwing: error)
    }

    /// Fails all pending continuations exactly once and stops the read loop.
    private func handlePeerClosed() async {
        guard !closed else { return }
        closed = true
        let waiters = pending
        pending.removeAll()
        for (_, cont) in waiters {
            cont.resume(throwing: TransportError.peerClosed)
        }
        loop?.cancel()
    }
}
