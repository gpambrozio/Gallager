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

    private static let apiRequestEvent = "claude_code.api_request"
    private static let permissionModeEvent = "claude_code.permission_mode_changed"
    private static let commitMetric = "claude_code.commit.count"
    private static let pullRequestMetric = "claude_code.pull_request.count"
    private static let sessionIDKey = "session.id"

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

        switch record.resolvedEventName() {
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
        let kind: TelemetryMilestone.Kind
        switch metric.name {
        case Self.commitMetric: kind = .commit
        case Self.pullRequestMetric: kind = .pullRequest
        default: return
        }

        // Sum each session's cumulative data points, then diff against the last
        // export to get this interval's delta.
        let dataPoints = metric.sum?.dataPoints ?? metric.gauge?.dataPoints ?? []
        var totalsBySession: [String: Double] = [:]
        for point in dataPoints {
            guard let sessionID = point.attributes?.string(for: Self.sessionIDKey), !sessionID.isEmpty else {
                continue
            }
            totalsBySession[sessionID, default: 0] += point.value
        }

        for (sessionID, total) in totalsBySession {
            let counterKey = "\(sessionID)|\(metric.name ?? "")"
            let previous = lastCounterValue[counterKey] ?? 0
            lastCounterValue[counterKey] = total
            let delta = Int((total - previous).rounded())
            if delta > 0 {
                result.milestones.append(TelemetryMilestone(sessionID: sessionID, kind: kind, count: delta))
            }
        }
    }

    // MARK: Lifecycle

    /// Drops all accumulated state for a session (called on session end).
    mutating func evict(sessionID: String) {
        metricsBySession.removeValue(forKey: sessionID)
        sessionOrder.removeAll { $0 == sessionID }
        let prefix = "\(sessionID)|"
        for key in lastCounterValue.keys where key.hasPrefix(prefix) {
            lastCounterValue.removeValue(forKey: key)
        }
    }

    /// Stores a snapshot and enforces the session cap (oldest-first eviction).
    private mutating func store(_ telemetry: SessionTelemetry, for sessionID: String) {
        if metricsBySession[sessionID] == nil {
            sessionOrder.append(sessionID)
        }
        metricsBySession[sessionID] = telemetry
        while sessionOrder.count > maxSessions {
            let oldest = sessionOrder.removeFirst()
            evict(sessionID: oldest)
        }
    }

    // MARK: Test access

    func telemetry(for sessionID: String) -> SessionTelemetry? {
        metricsBySession[sessionID]
    }
}
