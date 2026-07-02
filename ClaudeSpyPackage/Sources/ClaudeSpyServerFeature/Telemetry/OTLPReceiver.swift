import ClaudeSpyNetworking
import Foundation
import Logging
import Network

/// Mac-local OTLP/JSON receiver (issue #597, #602). A loopback-only HTTP listener
/// that accepts `POST /v1/metrics` and `POST /v1/logs` from the coding-agent
/// instances the app launches — Claude Code (pointed here via injected `OTEL_*`
/// env vars) and Codex (via injected `-c otel.…` launch overrides, since Codex
/// doesn't read `OTEL_*`) — accumulates per-session telemetry, and pushes the
/// results out via injected callbacks.
///
/// This is a one-way push channel — it never sends anything back into the agent.
/// It **augments** the hook channel and changes nothing about it.
///
/// Bound to the loopback interface only, so it never triggers Local Network
/// Privacy and is unreachable off-host. Modeled on `TestAccessibilityServer`'s
/// `NWListener` HTTP handling, generalized for production use with keep-alive
/// and exact request-boundary parsing.
actor OTLPReceiver {
    typealias TelemetryHandler = @Sendable (_ sessionID: String, _ telemetry: SessionTelemetry) async -> Void
    typealias MilestoneHandler = @Sendable (_ milestone: TelemetryMilestone) async -> Void
    typealias ModeChangeHandler = @Sendable (_ change: TelemetryModeChange) async -> Void

    /// The default loopback port. Deliberately NOT the OTLP-standard `4318`:
    /// that port is the first thing any local OTLP collector binds (a Docker
    /// collector container was observed holding `127.0.0.1:4318` and silently
    /// swallowing every export meant for this receiver), so the app claims an
    /// unassigned port of its own. Both ends of the pipe are app-controlled —
    /// the receiver binds it and the env/config injection advertises it — so
    /// nothing external ever needs the standard port.
    static let defaultPort: UInt16 = 24_318

    /// The port the receiver tries FIRST. Honors an `--otlp-port <port>` launch
    /// override: E2E gives each app instance its own port so concurrent
    /// instances — and a developer's real app on `defaultPort` off to the
    /// side — never share a loopback receiver. Falls back to `defaultPort` in
    /// production. The port actually bound can differ when this one is taken
    /// (see `portCandidates(startingAt:)`); everything that advertises the
    /// endpoint must read `advertisedPort` instead.
    static var preferredPort: UInt16 {
        if
            let idx = CommandLine.arguments.firstIndex(of: "--otlp-port"),
            idx + 1 < CommandLine.arguments.count,
            let parsed = UInt16(CommandLine.arguments[idx + 1]) {
            return parsed
        }
        return defaultPort
    }

    /// The loopback port the receiver actually bound this launch — the single
    /// value every advertisement (the `OTEL_*` env injection in `TmuxService`,
    /// the `otlpReceiverEndpoint` in `PluginEnv`, the E2E `/otlp-port` query)
    /// must read, so the bind and the advertisements can never drift even when
    /// the preferred port was taken and a fallback candidate won. `nil` until
    /// `start()` succeeds, and stays `nil` when every candidate was taken —
    /// consumers then skip OTEL configuration entirely rather than point
    /// agents at a dead (or worse, foreign) endpoint.
    @MainActor static var advertisedPort: UInt16?

    /// Distance between fallback candidates. Large enough that an E2E sibling
    /// instance (preferred ports are `base + instance`, spacing 1) can never
    /// sit inside another instance's fallback chain.
    static let portProbeStride: UInt16 = 100

    /// How many candidate ports `start()` probes before giving up.
    static let portProbeAttempts = 5

    /// The ports `start()` tries in order: the preferred port, then fallbacks
    /// at `portProbeStride` steps, clamped at the UInt16 boundary.
    static func portCandidates(startingAt preferred: UInt16) -> [UInt16] {
        (0..<portProbeAttempts).compactMap { attempt in
            let (candidate, overflow) = preferred
                .addingReportingOverflow(UInt16(attempt) * portProbeStride)
            return overflow ? nil : candidate
        }
    }

    /// Hard cap on a single buffered request, guarding against a misbehaving
    /// local client. OTLP batches are small (KBs); 32 MB is generous.
    private static let maxRequestBytes = 32 * 1_024 * 1_024

    /// The preferred port — the first candidate `start()` probes.
    private let port: UInt16
    /// The port actually bound, once `start()` has succeeded.
    private(set) var boundPort: UInt16?
    private var listener: NWListener?
    private var accumulator = OTLPTelemetryAccumulator()
    private let decoder = JSONDecoder()
    private let logger = Logger(label: "com.claudespy.otlpreceiver")

    private let onTelemetry: TelemetryHandler
    private let onMilestone: MilestoneHandler
    private let onModeChange: ModeChangeHandler

    /// Ordered hand-off from the (nonisolated) connection callbacks to a single
    /// actor-isolated consumer, so request bodies are processed strictly in
    /// arrival order. Spawning one independent `Task` per request did not
    /// guarantee that — tasks awaiting the same actor can run out of submission
    /// order, which would scramble `recentTurns` (the sparkline X-axis) and
    /// miscompute commit/PR counter deltas (diffed against `lastCounterValue`).
    /// This is the project's "Ingress Event Ordering" rule: one FIFO consumer.
    private let requestStream: AsyncStream<(path: String, body: Data)>
    private nonisolated let requestContinuation: AsyncStream<(path: String, body: Data)>.Continuation
    private var consumerTask: Task<Void, Never>?

    init(
        port: UInt16 = OTLPReceiver.defaultPort,
        onTelemetry: @escaping TelemetryHandler,
        onMilestone: @escaping MilestoneHandler,
        onModeChange: @escaping ModeChangeHandler
    ) {
        self.port = port
        self.onTelemetry = onTelemetry
        self.onMilestone = onMilestone
        self.onModeChange = onModeChange
        let (stream, continuation) = AsyncStream<(path: String, body: Data)>.makeStream()
        self.requestStream = stream
        self.requestContinuation = continuation
    }

    // MARK: Lifecycle

    /// Binds the first free candidate port (the preferred port, then fallbacks
    /// — see `portCandidates(startingAt:)`) and returns the port actually
    /// bound. Throws only when every candidate is taken.
    @discardableResult
    func start() async throws -> UInt16 {
        if listener != nil, let boundPort { return boundPort }
        var attempted: [UInt16] = []
        for candidate in Self.portCandidates(startingAt: port) {
            guard let nwPort = NWEndpoint.Port(rawValue: candidate) else { continue }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Loopback only: unreachable off-host and exempt from Local Network Privacy.
            params.requiredInterfaceType = .loopback
            // Bind the IPv4 loopback address EXPLICITLY. A port-only bind
            // creates a dual-stack IPv6 wildcard socket that happily coexists
            // with another process's IPv4-specific `127.0.0.1` listener on the
            // same port — the kernel then routes all IPv4 traffic (exporters
            // dial `127.0.0.1`) to the more-specific socket, and the meter
            // silently starves (observed live with an OTLP collector container
            // holding `127.0.0.1:4318`). An explicit IPv4 bind turns that
            // silent hijack into an `EADDRINUSE` we can react to by probing
            // the next candidate.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            attempted.append(candidate)
            if let error = await Self.bindOutcome(listener) {
                logger.info("OTLP candidate port \(candidate) unavailable: \(error)")
                listener.cancel()
                continue
            }
            // Bound: swap in the long-lived handler (bind-time states were
            // consumed by `bindOutcome`); later failures are log-only.
            listener.stateUpdateHandler = { [logger] state in
                if case let .failed(error) = state {
                    logger.error("OTLP listener failed: \(error)")
                }
            }
            self.listener = listener
            boundPort = candidate
            startConsumer()
            logger.info("OTLP receiver listening on 127.0.0.1:\(candidate)")
            return candidate
        }
        throw OTLPReceiverError.allCandidatePortsUnavailable(attempted)
    }

    /// Starts `listener` and waits for the bind to settle: `nil` on `.ready`,
    /// the error on `.failed`/`.cancelled` — and on `.waiting`, which some
    /// macOS versions use to surface a port-in-use bind instead of `.failed`.
    /// A loopback-only listener has no transient network condition to wait
    /// out, so any `.waiting` IS a bind failure; treating it as terminal also
    /// keeps `start()` (which gates `setupPluginRuntime()`) from hanging app
    /// startup. States after the first terminal one are ignored (the caller
    /// installs the long-lived handler).
    private static func bindOutcome(_ listener: NWListener) async -> NWError? {
        let states = AsyncStream<NWListener.State> { continuation in
            listener.stateUpdateHandler = { state in
                continuation.yield(state)
                switch state {
                case .ready,
                     .waiting,
                     .failed,
                     .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .utility))
        }
        for await state in states {
            switch state {
            case .ready:
                return nil
            case let .waiting(error),
                 let .failed(error):
                return error
            case .cancelled:
                return NWError.posix(.ECANCELED)
            default:
                continue
            }
        }
        return NWError.posix(.ECANCELED) // stream ended without a terminal state
    }

    /// Single FIFO consumer: drains buffered request bodies and processes them
    /// in arrival order on the actor (see `requestStream`).
    private func startConsumer() {
        guard consumerTask == nil else { return }
        consumerTask = Task { [weak self, stream = requestStream] in
            for await item in stream {
                await self?.process(path: item.path, body: item.body)
            }
        }
    }

    func stop() {
        requestContinuation.finish()
        consumerTask?.cancel()
        consumerTask = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    /// Drops accumulated state for a session (called when its pane's session ends),
    /// so a long-running host doesn't retain telemetry for finished sessions.
    func evictSession(_ sessionID: String) {
        accumulator.evict(sessionID: sessionID)
    }

    // MARK: Connection handling (nonisolated — runs on the listener queue)

    private nonisolated func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive(on: connection, buffer: Data())
            case .failed,
                 .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    private nonisolated func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var current = buffer
            if let data { current.append(data) }

            if let error {
                self.logger.debug("OTLP connection receive error: \(error)")
                connection.cancel()
                return
            }
            if current.count > Self.maxRequestBytes {
                self.logger.debug("OTLP request exceeded size cap; dropping connection")
                connection.cancel()
                return
            }

            self.pump(connection, buffer: current, isComplete: isComplete)
        }
    }

    /// Parses as many complete requests as are buffered, dispatching each, then
    /// either reads more (keep-alive) or closes when the peer is done.
    private nonisolated func pump(_ connection: NWConnection, buffer: Data, isComplete: Bool) {
        guard let parsed = Self.parseRequest(buffer) else {
            if isComplete {
                connection.cancel() // peer closed mid-request
            } else {
                receive(on: connection, buffer: buffer) // need more bytes
            }
            return
        }

        // Hand the body to the single ordered consumer, then ack immediately —
        // the 200 isn't gated on processing, but processing stays in arrival
        // order (see `requestStream`).
        requestContinuation.yield((path: parsed.path, body: parsed.body))
        respond(connection)

        let remainder = buffer.count > parsed.consumed
            ? buffer.subdata(in: parsed.consumed..<buffer.count)
            : Data()
        if remainder.isEmpty {
            // Keep-alive: await the next request on a fresh buffer. If the peer
            // has already closed, that receive returns `isComplete` and we close
            // then — after this response has flushed, never truncating it.
            receive(on: connection, buffer: Data())
        } else {
            // Drain a pipelined request already sitting in the buffer.
            pump(connection, buffer: remainder, isComplete: isComplete)
        }
    }

    private nonisolated func respond(_ connection: NWConnection) {
        // OTLP/HTTP success is `200` with an empty JSON object body.
        let response = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8
        )
        connection.send(content: response, completion: .contentProcessed { _ in })
    }

    /// Extracts the first complete HTTP request from `buffer`: `(path, body,
    /// bytesConsumed)`, or `nil` if the headers or full body haven't arrived.
    ///
    /// Supports both body framings a real exporter uses: `Content-Length` and
    /// `Transfer-Encoding: chunked`. Claude Code's OTLP exporter (observed on
    /// 2.1.198) streams every export chunked with NO `Content-Length` header —
    /// a length-only parser sees an empty body (dropping every record while
    /// still acking 200) and then misreads the chunk bytes as the next
    /// request's headers.
    private nonisolated static func parseRequest(_ buffer: Data) -> (path: String, body: Data, consumed: Int)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard
            let requestLine = lines.first,
            case let lineParts = requestLine.split(separator: " "),
            lineParts.count >= 2
        else { return nil }
        let path = String(lineParts[1])

        let bodyStart = headerRange.upperBound
        if isChunked(headerLines: lines) {
            guard let (body, bodyEnd) = dechunkBody(buffer, from: bodyStart) else {
                return nil // chunk stream not fully arrived
            }
            return (path, body, bodyEnd)
        }

        let contentLength = contentLength(from: lines)
        let bodyEnd = bodyStart + contentLength
        guard buffer.count >= bodyEnd else { return nil } // body not fully arrived
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        return (path, body, bodyEnd)
    }

    private nonisolated static func contentLength(from headerLines: [String]) -> Int {
        for line in headerLines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private nonisolated static func isChunked(headerLines: [String]) -> Bool {
        for line in headerLines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].lowercased() == "transfer-encoding" else { continue }
            return parts[1].lowercased().contains("chunked")
        }
        return false
    }

    /// Decodes a `Transfer-Encoding: chunked` body starting at `start`:
    /// `size-hex[;ext]\r\n<data>\r\n` repeated, terminated by a zero-size chunk
    /// and (empty here — exporters don't send trailers) trailer section. Returns
    /// the concatenated chunk data and the index one past the terminator, or
    /// `nil` while the stream is incomplete (or malformed — the caller then
    /// waits for more bytes until the peer closes or the size cap trips, the
    /// same terminal path as any garbage request).
    private nonisolated static func dechunkBody(_ buffer: Data, from start: Int) -> (body: Data, consumed: Int)? {
        let crlf = Data("\r\n".utf8)
        var body = Data()
        var cursor = start
        while true {
            guard
                cursor < buffer.count,
                let sizeLineEnd = buffer.range(of: crlf, in: cursor..<buffer.count)
            else { return nil }
            let sizeLine = buffer.subdata(in: cursor..<sizeLineEnd.lowerBound)
            guard
                let sizeText = String(data: sizeLine, encoding: .utf8),
                let sizeHex = sizeText.split(separator: ";").first,
                let size = Int(sizeHex.trimmingCharacters(in: .whitespaces), radix: 16),
                size >= 0
            else { return nil }

            if size == 0 {
                // Last chunk. An empty trailer section is just the closing CRLF;
                // a non-empty one (never seen from a real exporter, but legal)
                // ends at the next blank line.
                let trailerStart = sizeLineEnd.upperBound
                if
                    buffer.count >= trailerStart + 2,
                    buffer.subdata(in: trailerStart..<(trailerStart + 2)) == crlf {
                    return (body, trailerStart + 2)
                }
                let crlfcrlf = Data("\r\n\r\n".utf8)
                guard
                    trailerStart < buffer.count,
                    let terminator = buffer.range(of: crlfcrlf, in: trailerStart..<buffer.count)
                else { return nil }
                return (body, terminator.upperBound)
            }

            let dataStart = sizeLineEnd.upperBound
            let dataEnd = dataStart + size
            guard buffer.count >= dataEnd + 2 else { return nil } // chunk + its CRLF not arrived
            body.append(buffer.subdata(in: dataStart..<dataEnd))
            cursor = dataEnd + 2
        }
    }

    // MARK: Processing (actor-isolated)

    func process(path: String, body: Data) async {
        let result: OTLPProcessingResult
        if path.hasPrefix("/v1/metrics") {
            guard let request = try? decoder.decode(OTLPMetricsRequest.self, from: body) else {
                logger.debug("Failed to decode OTLP metrics payload (\(body.count) bytes)")
                return
            }
            result = accumulator.ingestMetrics(request)
        } else if path.hasPrefix("/v1/logs") {
            guard let request = try? decoder.decode(OTLPLogsRequest.self, from: body) else {
                logger.debug("Failed to decode OTLP logs payload (\(body.count) bytes)")
                return
            }
            result = accumulator.ingestLogs(request)
        } else {
            return // /v1/traces and anything else: accepted (200) but ignored
        }

        guard !result.isEmpty else { return }
        for (sessionID, telemetry) in result.telemetryUpdates {
            await onTelemetry(sessionID, telemetry)
        }
        for milestone in result.milestones {
            await onMilestone(milestone)
        }
        for change in result.modeChanges {
            await onModeChange(change)
        }
    }
}

enum OTLPReceiverError: Error {
    /// Every candidate port (preferred + fallbacks) was already taken.
    case allCandidatePortsUnavailable([UInt16])
}
