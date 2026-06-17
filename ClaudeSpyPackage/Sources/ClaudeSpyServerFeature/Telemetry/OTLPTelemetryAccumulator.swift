import ClaudeSpyNetworking
import Foundation

// MARK: - Effects

/// A reached milestone derived from a counter delta (issue #597, signal #2).
struct TelemetryMilestone: Equatable {
    enum Kind: Equatable {
        case commit
        case pullRequest
    }

    let sessionID: String
    let kind: Kind
    /// How many occurred since the last export (the counter delta).
    let count: Int
}

/// A permission-mode change derived from a `permission_mode_changed` event
/// (issue #597, signal #3).
struct TelemetryModeChange: Equatable {
    let sessionID: String
    let toMode: String
    let trigger: String?
}

/// The result of folding one OTLP payload into the accumulators: which sessions'
/// telemetry snapshots changed, and any one-shot milestones / mode changes to
/// dispatch.
struct OTLPProcessingResult: Equatable {
    /// `session.id` → latest accumulated snapshot, for sessions touched here.
    var telemetryUpdates: [String: SessionTelemetry] = [:]
    var milestones: [TelemetryMilestone] = []
    var modeChanges: [TelemetryModeChange] = []

    var isEmpty: Bool {
        telemetryUpdates.isEmpty && milestones.isEmpty && modeChanges.isEmpty
    }
}

// MARK: - Accumulator

/// Accumulates per-session OTEL telemetry from decoded OTLP payloads. Pure value
/// logic with no I/O, so the parsing/accumulation rules are unit-testable in
/// isolation from the network transport.
///
/// Tokens, cost, latency, and model come **only** from `claude_code.api_request`
/// log events (the issue's single source of truth); the `token.usage` /
/// `cost.usage` metrics are intentionally ignored to avoid double-counting.
/// Commit / PR milestones come from the monotonic counter metrics, tracked as
/// deltas between exports. Permission modes come from `permission_mode_changed`
/// events.
struct OTLPTelemetryAccumulator {
    /// `session.id` → accumulated telemetry snapshot.
    private var metricsBySession: [String: SessionTelemetry] = [:]

    /// `"<session.id>|<metric name>"` → last observed cumulative counter value,
    /// for computing milestone deltas across exports.
    private var lastCounterValue: [String: Double] = [:]

    /// Session insertion order, for bounding memory with a simple cap.
    private var sessionOrder: [String] = []

    /// Upper bound on tracked sessions; the oldest is evicted past this. Long-
    /// running hosts churn `session.id`s (every `/clear` mints a new one), so the
    /// map must not grow without bound.
    private let maxSessions = 256

    // Claude's OTLP *log* events identify themselves inconsistently: the bare
    // name (`api_request`) lives in the `event.name` attribute, while the log
    // body carries the fully-qualified `claude_code.api_request`. We match on
    // the bare name and strip the `claude_code.` namespace from whatever
    // `resolvedEventName()` surfaces, so both forms resolve to the same case.
    // (Metric names, by contrast, are always fully qualified on the wire.)
    private static let apiRequestEvent = "api_request"
    private static let permissionModeEvent = "permission_mode_changed"
    private static let toolResultEvent = "tool_result"
    private static let eventNamespace = "claude_code."
    private static let commitMetric = "claude_code.commit.count"
    private static let pullRequestMetric = "claude_code.pull_request.count"
    private static let activeTimeMetric = "claude_code.active_time.total"
    private static let linesOfCodeMetric = "claude_code.lines_of_code.count"
    private static let sessionIDKey = "session.id"
    private static let typeKey = "type"

    /// Strips the `claude_code.` namespace so the bare-name `event.name`
    /// attribute and the fully-qualified log body both match the same constant.
    private static func canonicalEventName(_ name: String) -> String {
        name.hasPrefix(eventNamespace) ? String(name.dropFirst(eventNamespace.count)) : name
    }

    // MARK: Logs

    /// Folds a decoded `/v1/logs` payload into per-session telemetry and emits
    /// any permission-mode changes.
    mutating func ingestLogs(_ request: OTLPLogsRequest) -> OTLPProcessingResult {
        var result = OTLPProcessingResult()
        for resource in request.resourceLogs ?? [] {
            for scope in resource.scopeLogs ?? [] {
                for record in scope.logRecords ?? [] {
                    process(logRecord: record, into: &result)
                }
            }
        }
        return result
    }

    private mutating func process(logRecord record: OTLPLogRecord, into result: inout OTLPProcessingResult) {
        guard
            let attributes = record.attributes,
            let sessionID = attributes.string(for: Self.sessionIDKey),
            !sessionID.isEmpty
        else { return }

        switch Self.canonicalEventName(record.resolvedEventName() ?? "") {
        case Self.apiRequestEvent:
            var telemetry = metricsBySession[sessionID] ?? SessionTelemetry()
            telemetry.accumulate(
                inputTokens: attributes.int(for: "input_tokens") ?? 0,
                outputTokens: attributes.int(for: "output_tokens") ?? 0,
                cacheReadTokens: attributes.int(for: "cache_read_tokens") ?? 0,
                cacheCreationTokens: attributes.int(for: "cache_creation_tokens") ?? 0,
                costUSD: attributes.double(for: "cost_usd") ?? 0,
                durationMs: attributes.int(for: "duration_ms"),
                model: attributes.string(for: "model")
            )
            store(telemetry, for: sessionID)
            result.telemetryUpdates[sessionID] = telemetry

        case Self.toolResultEvent:
            // One `tool_result` log per completed tool call — count it (issue
            // #598). Per-event accumulation, like `api_request` above.
            var telemetry = metricsBySession[sessionID] ?? SessionTelemetry()
            telemetry.recordToolResult()
            store(telemetry, for: sessionID)
            result.telemetryUpdates[sessionID] = telemetry

        case Self.permissionModeEvent:
            guard let toMode = attributes.string(for: "to_mode"), !toMode.isEmpty else { return }
            result.modeChanges.append(TelemetryModeChange(
                sessionID: sessionID,
                toMode: toMode,
                trigger: attributes.string(for: "trigger")
            ))

        default:
            break
        }
    }

    // MARK: Metrics

    /// Folds a decoded `/v1/metrics` payload, emitting milestone deltas for the
    /// commit / pull-request counters.
    mutating func ingestMetrics(_ request: OTLPMetricsRequest) -> OTLPProcessingResult {
        var result = OTLPProcessingResult()
        for resource in request.resourceMetrics ?? [] {
            for scope in resource.scopeMetrics ?? [] {
                for metric in scope.metrics ?? [] {
                    process(metric: metric, into: &result)
                }
            }
        }
        return result
    }

    private mutating func process(metric: OTLPMetric, into result: inout OTLPProcessingResult) {
        let dataPoints = metric.sum?.dataPoints ?? metric.gauge?.dataPoints ?? []
        switch metric.name {
        case Self.commitMetric:
            processCounter(name: Self.commitMetric, kind: .commit, dataPoints: dataPoints, into: &result)
        case Self.pullRequestMetric:
            processCounter(name: Self.pullRequestMetric, kind: .pullRequest, dataPoints: dataPoints, into: &result)
        case Self.activeTimeMetric:
            // Cumulative active seconds; carry the latest total onto the snapshot
            // (no milestone). Summed across the `type=user/cli` data points.
            updateCumulative(dataPoints: dataPoints, into: &result) { telemetry, total in
                telemetry.activeTimeSeconds = Int(total.rounded())
            }
        case Self.linesOfCodeMetric:
            processLinesOfCode(dataPoints: dataPoints, into: &result)
        default:
            return
        }
    }

    /// Sums `value` per session across `dataPoints` (ignoring points with no
    /// `session.id`), returning a `session.id → total` map. Shared by every
    /// counter metric.
    private static func totalsBySession(_ dataPoints: [OTLPNumberDataPoint]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for point in dataPoints {
            guard let sessionID = point.attributes?.string(for: sessionIDKey), !sessionID.isEmpty else { continue }
            totals[sessionID, default: 0] += point.value
        }
        return totals
    }

    /// A commit / PR counter: diff against the last export for the milestone
    /// delta, and carry the cumulative total onto the session snapshot so the
    /// recap (issue #598) can report "N commits".
    private mutating func processCounter(
        name: String,
        kind: TelemetryMilestone.Kind,
        dataPoints: [OTLPNumberDataPoint],
        into result: inout OTLPProcessingResult
    ) {
        for (sessionID, total) in Self.totalsBySession(dataPoints) {
            let counterKey = "\(sessionID)|\(name)"
            let previous = lastCounterValue[counterKey] ?? 0
            lastCounterValue[counterKey] = total

            var telemetry = metricsBySession[sessionID] ?? SessionTelemetry()
            let cumulative = Int(total.rounded())
            switch kind {
            case .commit: telemetry.commitCount = cumulative
            case .pullRequest: telemetry.pullRequestCount = cumulative
            }
            // `store` also `track`s the session, so a counter-only session (never
            // an `api_request` log) still counts against the cap rather than
            // growing unbounded until `evict()` at session end.
            store(telemetry, for: sessionID)
            result.telemetryUpdates[sessionID] = telemetry

            let delta = Int((total - previous).rounded())
            if delta > 0 {
                result.milestones.append(TelemetryMilestone(sessionID: sessionID, kind: kind, count: delta))
            }
        }
    }

    /// Updates the session snapshot from a cumulative counter (no milestone),
    /// applying `apply` with the latest summed total.
    private mutating func updateCumulative(
        dataPoints: [OTLPNumberDataPoint],
        into result: inout OTLPProcessingResult,
        apply: (inout SessionTelemetry, Double) -> Void
    ) {
        for (sessionID, total) in Self.totalsBySession(dataPoints) {
            var telemetry = metricsBySession[sessionID] ?? SessionTelemetry()
            apply(&telemetry, total)
            store(telemetry, for: sessionID)
            result.telemetryUpdates[sessionID] = telemetry
        }
    }

    /// `lines_of_code.count` splits added / removed via the `type` attribute, so
    /// it needs per-type totals rather than one number per session.
    private mutating func processLinesOfCode(
        dataPoints: [OTLPNumberDataPoint],
        into result: inout OTLPProcessingResult
    ) {
        var addedBySession: [String: Double] = [:]
        var removedBySession: [String: Double] = [:]
        for point in dataPoints {
            guard let sessionID = point.attributes?.string(for: Self.sessionIDKey), !sessionID.isEmpty else { continue }
            switch point.attributes?.string(for: Self.typeKey) {
            case "added": addedBySession[sessionID, default: 0] += point.value
            case "removed": removedBySession[sessionID, default: 0] += point.value
            default: break
            }
        }
        for sessionID in Set(addedBySession.keys).union(removedBySession.keys) {
            var telemetry = metricsBySession[sessionID] ?? SessionTelemetry()
            if let added = addedBySession[sessionID] { telemetry.linesAdded = Int(added.rounded()) }
            if let removed = removedBySession[sessionID] { telemetry.linesRemoved = Int(removed.rounded()) }
            store(telemetry, for: sessionID)
            result.telemetryUpdates[sessionID] = telemetry
        }
    }

    // MARK: Lifecycle

    /// Drops all accumulated state for a session (called on session end).
    mutating func evict(sessionID: String) {
        sessionOrder.removeAll { $0 == sessionID }
        discardState(for: sessionID)
    }

    /// Removes the snapshot and counter baselines for a session without touching
    /// `sessionOrder` — callers that already popped the id own that bookkeeping.
    private mutating func discardState(for sessionID: String) {
        metricsBySession.removeValue(forKey: sessionID)
        let prefix = "\(sessionID)|"
        for key in lastCounterValue.keys where key.hasPrefix(prefix) {
            lastCounterValue.removeValue(forKey: key)
        }
    }

    /// Stores a snapshot and registers the session in the bounded cap.
    private mutating func store(_ telemetry: SessionTelemetry, for sessionID: String) {
        metricsBySession[sessionID] = telemetry
        track(sessionID: sessionID)
    }

    /// Registers a session in the insertion-ordered cap (idempotent) and evicts
    /// the oldest beyond `maxSessions`. Both the logs (`store`) and metrics
    /// (`process(metric:)`) paths funnel through here, so every tracked session —
    /// including counter-only ones — is bounded, and a session can't be appended
    /// twice if it arrives first via a metric and later via a log.
    private mutating func track(sessionID: String) {
        if !sessionOrder.contains(sessionID) {
            sessionOrder.append(sessionID)
        }
        while sessionOrder.count > maxSessions {
            let oldest = sessionOrder.removeFirst()
            discardState(for: oldest)
        }
    }

    // MARK: Test access

    func telemetry(for sessionID: String) -> SessionTelemetry? {
        metricsBySession[sessionID]
    }
}
