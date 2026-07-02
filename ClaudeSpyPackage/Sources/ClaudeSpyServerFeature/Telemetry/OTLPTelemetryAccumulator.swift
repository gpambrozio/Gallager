import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol

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
/// Agent-blind: one receiver serves Claude Code (issue #597), Codex (issue
/// #602), and any sidecar plugin that declares an OTLP namespace in its
/// manifest (issue #617), so each log record is classified by its event-name
/// namespace (`claude_code.` / `codex.` / a declared plugin namespace) — see
/// ``Agent`` — and parsed with that agent's vocabulary, funneling into the
/// same ``SessionTelemetry``.
///
/// - **Claude**: tokens, cost, latency, and model come **only** from
///   `claude_code.api_request` log events (the single source of truth); the
///   `token.usage` / `cost.usage` metrics are ignored to avoid double-counting.
///   Commit / PR milestones come from the monotonic counter metrics, tracked as
///   deltas between exports. Permission modes come from `permission_mode_changed`.
/// - **Codex**: tokens + model come from `codex.sse_event` (`response.completed`)
///   and per-turn latency from `codex.turn_ttft` (`duration_ms`, time to first
///   token). Both carry `conversation.id`; Codex metrics omit it
///   (openai/codex#15905), so they can't be joined. Note that `codex.api_request`
///   does *not* carry `conversation.id` (verified against live Codex 0.139: it is
///   the `/models` capability check, and turn calls run over websocket), so it is
///   unusable as a join source. No cost is emitted (cost stays 0). Permission/
///   approval mode is seeded from the hook channel, not OTEL.
/// - **Declared plugin namespaces** (issue #617): a sidecar plugin's manifest
///   `otlp` field maps its namespace to Claude's `api_request` vocabulary — the
///   record named `<namespace>.<tokenEvent>` carries Claude's exact attribute
///   keys, accumulates additively (per-message summation, NOT Codex's
///   cumulative-delta handling), and joins on `session.id`. The mapping table is
///   pushed in whenever the enabled-plugin set changes; no accumulator code
///   change is needed for the next agent.
struct OTLPTelemetryAccumulator {
    /// session id → accumulated telemetry snapshot. The id is Claude's `session.id`
    /// or Codex's `conversation.id`; both join to a pane's `claudeSessionID`.
    private var metricsBySession: [String: SessionTelemetry] = [:]

    /// `"<session.id>|<metric name>"` → last observed cumulative counter value,
    /// for computing milestone deltas across exports.
    private var lastCounterValue: [String: Double] = [:]

    /// Codex session id → last *cumulative* `(input, cached)` token counts seen on
    /// `codex.sse_event`. Codex re-reports the whole growing conversation context
    /// on every model call (several per turn with tool use), so token counts are
    /// accumulated as deltas against this — not summed raw — to avoid multiply-
    /// counting the same context (issue #602). Bounded with `metricsBySession` via
    /// `discardState`.
    private var lastCodexUsage: [String: (input: Int, cached: Int)] = [:]

    /// Plugin-declared namespace table (issue #617): dot-suffixed namespace
    /// prefix (`"opencode."`) → the namespace-stripped event name carrying the
    /// token/latency/model attributes. Replaced wholesale via
    /// `setPluginNamespaces` whenever the enabled-plugin set changes.
    private var pluginMappings: [String: String] = [:]

    /// Session insertion order, for bounding memory with a simple cap.
    private var sessionOrder: [String] = []

    /// Upper bound on tracked sessions; the oldest is evicted past this. Long-
    /// running hosts churn `session.id`s (every `/clear` mints a new one), so the
    /// map must not grow without bound.
    private let maxSessions = 256

    // Claude bare (namespace-stripped) log event names. Claude's OTLP *log*
    // events identify themselves inconsistently: the bare name (`api_request`)
    // lives in the `event.name` attribute, while the log body carries the
    // fully-qualified `claude_code.api_request`. We strip the namespace so both
    // forms resolve to the same case. (Metric names are always fully qualified.)
    private static let apiRequestEvent = "api_request"
    private static let permissionModeEvent = "permission_mode_changed"
    private static let toolResultEvent = "tool_result"
    private static let commitMetric = "claude_code.commit.count"
    private static let pullRequestMetric = "claude_code.pull_request.count"
    private static let activeTimeMetric = "claude_code.active_time.total"
    private static let linesOfCodeMetric = "claude_code.lines_of_code.count"
    private static let sessionIDKey = "session.id"
    private static let typeKey = "type"

    // Codex bare log event names (after stripping the `codex.` namespace).
    // `sse_event` carries token counts only on its `response.completed` kind;
    // `turn_ttft` carries the per-turn `duration_ms` (time to first token) and,
    // unlike `codex.api_request`, the `conversation.id` needed to join it.
    private static let codexTokenEvent = "sse_event"
    private static let codexTokenEventKind = "response.completed"
    private static let codexLatencyEvent = "turn_ttft"

    /// Which coding agent produced a log record, used to pick the right
    /// session-id attribute and event vocabulary. Classified by the event-name
    /// namespace so one receiver serves every agent (issues #602, #617).
    private enum Agent {
        case claude
        case codex
        /// A plugin-declared namespace (issue #617): the dot-suffixed prefix and
        /// the namespace-stripped event name that carries Claude's `api_request`
        /// attribute vocabulary.
        case declared(namespace: String, tokenEvent: String)

        /// Codex always namespaces with `codex.`; Claude uses `claude_code.` on
        /// the log body and the bare name on the `event.name` attribute, so a
        /// bare known event is Claude. A plugin-declared namespace (always fully
        /// qualified) is checked after the built-ins, so a plugin can never
        /// shadow Claude's or Codex's records. Anything else is unrecognized
        /// (`nil`).
        init?(eventName: String, pluginMappings: [String: String]) {
            if eventName.hasPrefix(Agent.codexNamespace) {
                self = .codex
            } else if eventName.hasPrefix(Agent.claudeNamespace) || Agent.bareClaudeEvents.contains(eventName) {
                self = .claude
            } else if let mapping = pluginMappings.first(where: { eventName.hasPrefix($0.key) }) {
                self = .declared(namespace: mapping.key, tokenEvent: mapping.value)
            } else {
                return nil
            }
        }

        static let claudeNamespace = "claude_code."
        static let codexNamespace = "codex."
        private static let bareClaudeEvents: Set<String> = [apiRequestEvent, permissionModeEvent, toolResultEvent]

        /// The attribute key carrying the per-session join id. Declared plugin
        /// namespaces reuse Claude's `session.id` (the opencode bridge stamps
        /// the tmux pane id there — the same key the sidecar reports as its
        /// session identity, so telemetry joins with no host-side changes).
        var sessionIDKey: String {
            switch self {
            case .claude,
                 .declared: OTLPTelemetryAccumulator.sessionIDKey
            case .codex: "conversation.id"
            }
        }

        /// Strips the agent's namespace so a fully-qualified body and a bare
        /// `event.name` attribute resolve to the same constant.
        func canonicalEventName(_ name: String) -> String {
            let namespace = switch self {
            case .claude: Agent.claudeNamespace
            case .codex: Agent.codexNamespace
            case let .declared(namespace, _): namespace
            }
            return name.hasPrefix(namespace) ? String(name.dropFirst(namespace.count)) : name
        }
    }

    /// Replaces the plugin-declared namespace table (issue #617). Declarations
    /// naming a built-in namespace (`claude_code` / `codex`) or an empty string
    /// are dropped so a plugin can never claim the built-in agents' records. A
    /// trailing dot on the declared namespace is tolerated.
    mutating func setPluginNamespaces(_ declarations: [PluginManifest.OTLP]) {
        var mappings: [String: String] = [:]
        for declaration in declarations {
            let namespace = declaration.namespace.hasSuffix(".")
                ? String(declaration.namespace.dropLast())
                : declaration.namespace
            guard !namespace.isEmpty else { continue }
            let prefix = namespace + "."
            guard prefix != Agent.claudeNamespace, prefix != Agent.codexNamespace else { continue }
            mappings[prefix] = declaration.tokenEvent
        }
        pluginMappings = mappings
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
        guard let attributes = record.attributes else { return }
        // Classify against each candidate name and take the first recognized one.
        // Exporters disagree on where the event name lives: Codex fills the
        // top-level `eventName` field with a Rust source location rather than the
        // event name, so the `event.name` attribute is the reliable source — a
        // single "resolved name" that trusted the field would drop every Codex
        // record (issue #602).
        let mappings = pluginMappings
        guard
            let (agent, rawEvent) = record.eventNameCandidates()
                .lazy
                .compactMap({ name in Agent(eventName: name, pluginMappings: mappings).map { ($0, name) } })
                .first
        else { return }
        guard let sessionID = attributes.string(for: agent.sessionIDKey), !sessionID.isEmpty else { return }
        let event = agent.canonicalEventName(rawEvent)

        switch agent {
        case .claude:
            processClaudeLog(event: event, attributes: attributes, sessionID: sessionID, into: &result)
        case .codex:
            processCodexLog(event: event, attributes: attributes, sessionID: sessionID, into: &result)
        case let .declared(_, tokenEvent):
            // A declared namespace's token event mirrors Claude's `api_request`
            // vocabulary exactly (manifest contract, issue #617); other events
            // in the namespace are ignored.
            guard event == tokenEvent else { return }
            accumulateAPIRequest(attributes: attributes, sessionID: sessionID, into: &result)
        }
    }

    /// Claude Code: tokens/cost/latency/model on `api_request`; permission-mode
    /// changes on `permission_mode_changed`.
    private mutating func processClaudeLog(
        event: String,
        attributes: [OTLPKeyValue],
        sessionID: String,
        into result: inout OTLPProcessingResult
    ) {
        switch event {
        case Self.apiRequestEvent:
            accumulateAPIRequest(attributes: attributes, sessionID: sessionID, into: &result)

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

    /// Folds one Claude-vocabulary `api_request` record — tokens, cost, latency,
    /// model, all additive per event — into the session's snapshot. Shared by
    /// Claude's own `api_request` and every declared plugin namespace's token
    /// event (issue #617), whose attribute keys mirror Claude's exactly.
    private mutating func accumulateAPIRequest(
        attributes: [OTLPKeyValue],
        sessionID: String,
        into result: inout OTLPProcessingResult
    ) {
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
    }

    /// Codex: tokens + model on `sse_event` (`response.completed`); per-turn
    /// latency on `turn_ttft` (`duration_ms`). Both carry `conversation.id`.
    private mutating func processCodexLog(
        event: String,
        attributes: [OTLPKeyValue],
        sessionID: String,
        into result: inout OTLPProcessingResult
    ) {
        switch event {
        case Self.codexTokenEvent:
            // Token counts ride only the `response.completed` kind of `sse_event`.
            guard attributes.string(for: "event.kind") == Self.codexTokenEventKind else { return }
            let input = attributes.int(for: "input_token_count") ?? 0
            let output = attributes.int(for: "output_token_count") ?? 0
            let cached = attributes.int(for: "cached_token_count") ?? 0
            // Codex's `input_token_count` / `cached_token_count` are CUMULATIVE:
            // each model call re-sends the whole growing conversation context, so a
            // single user turn with tool use fires several `response.completed`
            // events whose input climbs monotonically (e.g. 14k → 25k → 26k).
            // Summing each event's input would multiply-count the same context — a
            // 3-tool turn over-counts by ~1.5× (confirmed against live Codex 0.140,
            // issue #602). So accumulate only the positive *delta* since this
            // session's previous event; `output` is per-call (not cumulative) and
            // is summed as-is. OpenAI nests `cached` inside `input`, so the fresh
            // (newly-sent, non-cached) input for this step is `inputDelta −
            // cachedDelta`; the cached delta lands in `cacheReadTokens`, excluded
            // from the headline (the #597 cache-read exclusion).
            let previous = lastCodexUsage[sessionID] ?? (input: 0, cached: 0)
            let inputDelta = max(0, input - previous.input)
            let cachedDelta = max(0, cached - previous.cached)
            lastCodexUsage[sessionID] = (input: input, cached: cached)
            var telemetry = metricsBySession[sessionID] ?? SessionTelemetry()
            telemetry.accumulate(
                inputTokens: max(0, inputDelta - cachedDelta),
                outputTokens: output,
                cacheReadTokens: cachedDelta,
                cacheCreationTokens: 0,
                costUSD: 0, // Codex emits no cost
                durationMs: nil, // latency arrives on codex.turn_ttft
                model: attributes.string(for: "model")
            )
            store(telemetry, for: sessionID)
            result.telemetryUpdates[sessionID] = telemetry

        case Self.codexLatencyEvent:
            guard let durationMs = attributes.int(for: "duration_ms"), durationMs > 0 else { return }
            var telemetry = metricsBySession[sessionID] ?? SessionTelemetry()
            telemetry.recordTurnLatency(durationMs)
            store(telemetry, for: sessionID)
            result.telemetryUpdates[sessionID] = telemetry

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
        lastCodexUsage.removeValue(forKey: sessionID)
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
