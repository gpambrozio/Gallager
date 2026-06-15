import ClaudeSpyNetworking
import Foundation
import Logging
import Network

/// Mac-local OTLP/JSON receiver (issue #597). A loopback-only HTTP listener that
/// accepts `POST /v1/metrics` and `POST /v1/logs` from the Claude Code instances
/// the app launches (which are pointed here via injected `OTEL_*` env vars),
/// accumulates per-session telemetry, and pushes the results out via injected
/// callbacks.
///
/// This is a one-way push channel — it never sends anything back into Claude. It
/// **augments** the hook channel and changes nothing about it.
///
/// Bound to the loopback interface only, so it never triggers Local Network
/// Privacy and is unreachable off-host. Modeled on `TestAccessibilityServer`'s
/// `NWListener` HTTP handling, generalized for production use with keep-alive
/// and exact request-boundary parsing.
actor OTLPReceiver {
    typealias TelemetryHandler = @Sendable (_ sessionID: String, _ telemetry: SessionTelemetry) async -> Void
    typealias MilestoneHandler = @Sendable (_ milestone: TelemetryMilestone) async -> Void
    typealias ModeChangeHandler = @Sendable (_ change: TelemetryModeChange) async -> Void

    /// The default loopback port Claude Code is pointed at via
    /// `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318`.
    static let defaultPort: UInt16 = 4_318

    /// Hard cap on a single buffered request, guarding against a misbehaving
    /// local client. OTLP batches are small (KBs); 32 MB is generous.
    private static let maxRequestBytes = 32 * 1_024 * 1_024

    private let port: UInt16
    private var listener: NWListener?
    private var accumulator = OTLPTelemetryAccumulator()
    private let decoder = JSONDecoder()
    private let logger = Logger(label: "com.claudespy.otlpreceiver")

    private let onTelemetry: TelemetryHandler
    private let onMilestone: MilestoneHandler
    private let onModeChange: ModeChangeHandler

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
    }

    // MARK: Lifecycle

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only: unreachable off-host and exempt from Local Network Privacy.
        params.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw OTLPReceiverError.invalidPort(port)
        }
        let listener = try NWListener(using: params, on: nwPort)
        listener.stateUpdateHandler = { [logger] state in
            if case let .failed(error) = state {
                logger.error("OTLP listener failed: \(error)")
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
        logger.info("OTLP receiver listening on 127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
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

        let body = parsed.body
        let path = parsed.path
        Task { [weak self] in
            await self?.process(path: path, body: body)
        }
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

        let contentLength = contentLength(from: lines)
        let bodyStart = headerRange.upperBound
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
    case invalidPort(UInt16)
}
