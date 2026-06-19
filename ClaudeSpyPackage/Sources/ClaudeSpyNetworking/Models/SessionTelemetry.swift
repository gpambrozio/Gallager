import Foundation

// MARK: - Turn Sample

/// A single API turn's quantitative footprint, captured for the per-session
/// detail sparkline (issue #597, render surface B). Kept tiny and the array is
/// capped (last ~20) so it rides the existing `SessionStateMessage` without
/// bloating the wire.
public struct TurnSample: Codable, Sendable, Equatable {
    /// Cost in USD attributed to this turn (`cost_usd` from `api_request`).
    public let costUSD: Double

    /// End-to-end latency of this turn in milliseconds (`duration_ms`), or `nil`
    /// when the turn's `duration_ms` was absent. Kept optional so missing-latency
    /// turns can be omitted from the sparkline rather than charted as 0ms.
    public let latencyMs: Int?

    public init(costUSD: Double, latencyMs: Int?) {
        self.costUSD = costUSD
        self.latencyMs = latencyMs
    }
}

// MARK: - Session Telemetry

/// Quantitative, content-free telemetry for one coding-agent session, derived
/// from the agent's OpenTelemetry export — Claude Code's `claude_code.api_request`
/// events (issue #597) or Codex's `codex.sse_event` / `codex.api_request` events
/// (issue #602). Agent-blind once accumulated: the same fields drive the UI for
/// either agent.
///
/// This **augments** the hook channel — it never replaces it (issue #597).
/// Accumulated on the Mac by the OTLP receiver, joined to a pane by the hook
/// `session_id` (Claude) / `conversation.id` (Codex), stamped onto `PaneState`,
/// and carried to iOS viewers inside the existing `SessionStateMessage`.
///
/// The maximum number of per-turn samples retained for the sparkline. Bounds the
/// wire size of `recentTurns`.
public struct SessionTelemetry: Codable, Sendable, Equatable {
    /// The maximum number of per-turn samples kept in `recentTurns`.
    public static let maxRecentTurns = 20

    /// Headline token count for the glanceable meter: summed `input + output`
    /// across the session. Both cache *reads* and cache *writes* (creation) are
    /// deliberately excluded — Claude re-reads the whole prompt cache every turn
    /// (and Codex re-reports its cached context per turn), so summing the cache
    /// figures would re-count the same context on each turn and inflate the
    /// meter to several times the real context size (issue #597). The full
    /// cache totals are still tracked in ``cacheReadTokens`` /
    /// ``cacheCreationTokens`` and shown in the detail breakdown.
    public var tokensUsed: Int

    /// Summed `input_tokens` across the session.
    public var inputTokens: Int

    /// Summed `output_tokens` across the session.
    public var outputTokens: Int

    /// Summed `cache_read_tokens` across the session.
    public var cacheReadTokens: Int

    /// Summed `cache_creation_tokens` across the session.
    public var cacheCreationTokens: Int

    /// Cumulative cost in USD (summed `cost_usd`).
    public var costUSD: Double

    /// Latency of the most recent turn in milliseconds (latest `duration_ms`),
    /// or `nil` before the first turn completes.
    public var lastTurnLatencyMs: Int?

    /// The model the latest turn ran on (e.g. "claude-opus-4-8"), if known.
    public var model: String?

    /// Capped ring of the most recent turns for the detail sparkline (oldest
    /// first). Never longer than ``maxRecentTurns``.
    public var recentTurns: [TurnSample]

    // MARK: Aggregate counters (issue #598)

    /// Cumulative active time in seconds (`claude_code.active_time.total`), the
    /// time the user/CLI was actively engaged. Drives the recap's "N min active".
    /// `0` until the first export carries it.
    public var activeTimeSeconds: Int

    /// Lines of code added across the session (`claude_code.lines_of_code.count`
    /// with `type=added`). `0` until reported.
    public var linesAdded: Int

    /// Lines of code removed across the session (`claude_code.lines_of_code.count`
    /// with `type=removed`). `0` until reported.
    public var linesRemoved: Int

    /// Number of tool calls observed (`claude_code.tool_result` log events),
    /// counted one per event — the same per-event accumulation `api_request` uses.
    public var toolInvocations: Int

    /// Cumulative commits made this session (`claude_code.commit.count`). Carried
    /// here — beyond the one-shot milestone — so the recap can show "3 commits".
    public var commitCount: Int

    /// Cumulative pull requests opened this session (`claude_code.pull_request.count`).
    public var pullRequestCount: Int

    public init(
        tokensUsed: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        costUSD: Double = 0,
        lastTurnLatencyMs: Int? = nil,
        model: String? = nil,
        recentTurns: [TurnSample] = [],
        activeTimeSeconds: Int = 0,
        linesAdded: Int = 0,
        linesRemoved: Int = 0,
        toolInvocations: Int = 0,
        commitCount: Int = 0,
        pullRequestCount: Int = 0
    ) {
        self.tokensUsed = tokensUsed
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costUSD = costUSD
        self.lastTurnLatencyMs = lastTurnLatencyMs
        self.model = model
        self.recentTurns = recentTurns
        self.activeTimeSeconds = activeTimeSeconds
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.toolInvocations = toolInvocations
        self.commitCount = commitCount
        self.pullRequestCount = pullRequestCount
    }

    /// Folds one completed `api_request` turn into the running totals and
    /// appends a capped sample for the sparkline. Pure value mutation so the
    /// accumulator stays trivially testable.
    public mutating func accumulate(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        costUSD: Double,
        durationMs: Int?,
        model: String?
    ) {
        self.inputTokens += inputTokens
        self.outputTokens += outputTokens
        self.cacheReadTokens += cacheReadTokens
        self.cacheCreationTokens += cacheCreationTokens
        // Exclude both cache *reads* and cache *writes*: agents re-report the
        // whole cached context on every turn, so summing them would inflate the
        // headline to many times the real context size (issue #597). Both cache
        // totals stay tracked above for the detail breakdown.
        tokensUsed = self.inputTokens + self.outputTokens
        self.costUSD += costUSD
        if let durationMs {
            lastTurnLatencyMs = durationMs
        }
        if let model, !model.isEmpty {
            self.model = model
        }
        recentTurns.append(TurnSample(costUSD: costUSD, latencyMs: durationMs))
        if recentTurns.count > Self.maxRecentTurns {
            recentTurns.removeFirst(recentTurns.count - Self.maxRecentTurns)
        }
    }

    /// Counts one observed `tool_result` log event. Per-event (not cumulative),
    /// matching how `accumulate` folds each `api_request`.
    public mutating func recordToolResult() {
        toolInvocations += 1
    }

    /// Records a turn's latency that arrived on a *separate* event from its token
    /// counts. Claude Code reports tokens and `duration_ms` on one `api_request`
    /// log, so `accumulate(durationMs:)` covers it; Codex reports tokens on
    /// `codex.sse_event` (response.completed) but per-turn latency on
    /// `codex.turn_ttft` (time-to-first-token `duration_ms`, issue #602). This
    /// stamps the headline `lastTurnLatencyMs` and back-fills the most recent
    /// sample's latency when it arrived without one. The headline is authoritative;
    /// the sparkline back-fill is best-effort, since Codex can interleave the
    /// ttft and sse_event records around a turn. No-op for a non-positive duration.
    public mutating func recordTurnLatency(_ durationMs: Int) {
        guard durationMs > 0 else { return }
        lastTurnLatencyMs = durationMs
        // Back-fill assumes the turn's token event (`codex.sse_event`) already
        // appended this turn's sample before its latency event (`codex.turn_ttft`)
        // arrives — the order codex-rs emits them within a turn. If that ordering
        // ever flips (latency first) or `last` already carries a latency, this
        // no-ops and the headline `lastTurnLatencyMs` alone stays authoritative.
        if let last = recentTurns.last, last.latencyMs == nil {
            recentTurns[recentTurns.count - 1] = TurnSample(costUSD: last.costUSD, latencyMs: durationMs)
        }
    }

    // MARK: - Codable

    /// Tolerant decode so a host on a different version than the viewer
    /// round-trips without breakage if a field is added or dropped later
    /// (issue #597 wire-compat rule). Every field is optional-with-default.
    private enum CodingKeys: String, CodingKey {
        case tokensUsed
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheCreationTokens
        case costUSD
        case lastTurnLatencyMs
        case model
        case recentTurns
        case activeTimeSeconds
        case linesAdded
        case linesRemoved
        case toolInvocations
        case commitCount
        case pullRequestCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        self.cacheReadTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        self.cacheCreationTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        // `tokensUsed` is a derived sum (input + output, excluding both cache
        // reads and cache writes — see the property doc). If a peer omits it but
        // sends the components, recompute with the same definition instead of
        // showing 0.
        self.tokensUsed = try container.decodeIfPresent(Int.self, forKey: .tokensUsed)
            ?? (inputTokens + outputTokens)
        self.costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        self.lastTurnLatencyMs = try container.decodeIfPresent(Int.self, forKey: .lastTurnLatencyMs)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.recentTurns = try container.decodeIfPresent([TurnSample].self, forKey: .recentTurns) ?? []
        // Issue #598 aggregate counters — all optional-with-default so an older
        // host that omits them still decodes (the recap just shows 0s for those).
        self.activeTimeSeconds = try container.decodeIfPresent(Int.self, forKey: .activeTimeSeconds) ?? 0
        self.linesAdded = try container.decodeIfPresent(Int.self, forKey: .linesAdded) ?? 0
        self.linesRemoved = try container.decodeIfPresent(Int.self, forKey: .linesRemoved) ?? 0
        self.toolInvocations = try container.decodeIfPresent(Int.self, forKey: .toolInvocations) ?? 0
        self.commitCount = try container.decodeIfPresent(Int.self, forKey: .commitCount) ?? 0
        self.pullRequestCount = try container.decodeIfPresent(Int.self, forKey: .pullRequestCount) ?? 0
    }
}
