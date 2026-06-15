import Foundation

// MARK: - Turn Sample

/// A single API turn's quantitative footprint, captured for the per-session
/// detail sparkline (issue #597, render surface B). Kept tiny and the array is
/// capped (last ~20) so it rides the existing `SessionStateMessage` without
/// bloating the wire.
public struct TurnSample: Codable, Sendable, Equatable {
    /// Cost in USD attributed to this turn (`cost_usd` from `api_request`).
    public let costUSD: Double

    /// End-to-end latency of this turn in milliseconds (`duration_ms`).
    public let latencyMs: Int

    public init(costUSD: Double, latencyMs: Int) {
        self.costUSD = costUSD
        self.latencyMs = latencyMs
    }
}

// MARK: - Session Telemetry

/// Quantitative, content-free telemetry for one coding-agent session, derived
/// from Claude Code's OpenTelemetry export (`claude_code.api_request` events).
///
/// This **augments** the hook channel — it never replaces it (issue #597).
/// Accumulated on the Mac by the OTLP receiver, joined to a pane by the hook
/// `session_id`, stamped onto `PaneState`, and carried to iOS viewers inside the
/// existing `SessionStateMessage`.
///
/// The maximum number of per-turn samples retained for the sparkline. Bounds the
/// wire size of `recentTurns`.
public struct SessionTelemetry: Codable, Sendable, Equatable {
    /// The maximum number of per-turn samples kept in `recentTurns`.
    public static let maxRecentTurns = 20

    /// Total tokens across all types (input + output + cache read + creation).
    /// The single glanceable number for the row meter.
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

    public init(
        tokensUsed: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        costUSD: Double = 0,
        lastTurnLatencyMs: Int? = nil,
        model: String? = nil,
        recentTurns: [TurnSample] = []
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
        tokensUsed = self.inputTokens + self.outputTokens + self.cacheReadTokens + self.cacheCreationTokens
        self.costUSD += costUSD
        if let durationMs {
            lastTurnLatencyMs = durationMs
        }
        if let model, !model.isEmpty {
            self.model = model
        }
        recentTurns.append(TurnSample(costUSD: costUSD, latencyMs: durationMs ?? 0))
        if recentTurns.count > Self.maxRecentTurns {
            recentTurns.removeFirst(recentTurns.count - Self.maxRecentTurns)
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
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tokensUsed = try container.decodeIfPresent(Int.self, forKey: .tokensUsed) ?? 0
        self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        self.cacheReadTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        self.cacheCreationTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        self.costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        self.lastTurnLatencyMs = try container.decodeIfPresent(Int.self, forKey: .lastTurnLatencyMs)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.recentTurns = try container.decodeIfPresent([TurnSample].self, forKey: .recentTurns) ?? []
    }
}
