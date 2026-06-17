import Foundation

// MARK: - Session Recap

/// A compact, retrospective summary of one coding-agent session, assembled from
/// the accumulated ``SessionTelemetry`` when a turn finishes (`doneWorking`) or
/// the session ends (`sessionEnd`) — issue #598, part A.
///
/// This is a **snapshot**: it's captured before the OTLP receiver evicts the
/// session's live state, then stamped onto the pane (for the recap card) and/or
/// pushed as a one-shot notification. Pure data — the human-readable assembly
/// (`"45k tokens · $1.20 · 3 commits · 12 min active"`) lives in `ClaudeSpyCommon`
/// alongside the other telemetry formatters, so the card and the push share it.
public struct SessionRecap: Codable, Sendable, Equatable {
    /// The project this session ran in (folder name), for the card/push title.
    public var projectName: String?

    /// The model the session ran on (e.g. "claude-opus-4-8"), if known.
    public var model: String?

    /// Total tokens across all types for the session.
    public var tokensUsed: Int

    /// Cumulative cost in USD.
    public var costUSD: Double

    /// Commits made during the session.
    public var commitCount: Int

    /// Pull requests opened during the session.
    public var pullRequestCount: Int

    /// Active time in seconds.
    public var activeTimeSeconds: Int

    /// Number of tool calls.
    public var toolInvocations: Int

    /// Lines of code added.
    public var linesAdded: Int

    /// Lines of code removed.
    public var linesRemoved: Int

    /// The agent's last message or error from `doneWorking(summary:)`, if any.
    public var summary: String?

    /// `true` for the final recap at session end; `false` for an end-of-turn
    /// recap (the agent stopped but the session is still alive).
    public var isFinal: Bool

    public init(
        projectName: String? = nil,
        model: String? = nil,
        tokensUsed: Int = 0,
        costUSD: Double = 0,
        commitCount: Int = 0,
        pullRequestCount: Int = 0,
        activeTimeSeconds: Int = 0,
        toolInvocations: Int = 0,
        linesAdded: Int = 0,
        linesRemoved: Int = 0,
        summary: String? = nil,
        isFinal: Bool = false
    ) {
        self.projectName = projectName
        self.model = model
        self.tokensUsed = tokensUsed
        self.costUSD = costUSD
        self.commitCount = commitCount
        self.pullRequestCount = pullRequestCount
        self.activeTimeSeconds = activeTimeSeconds
        self.toolInvocations = toolInvocations
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.summary = summary
        self.isFinal = isFinal
    }

    /// Builds a recap from an accumulated telemetry snapshot.
    public init(
        telemetry: SessionTelemetry,
        projectName: String?,
        summary: String?,
        isFinal: Bool
    ) {
        self.init(
            projectName: projectName,
            model: telemetry.model,
            tokensUsed: telemetry.tokensUsed,
            costUSD: telemetry.costUSD,
            commitCount: telemetry.commitCount,
            pullRequestCount: telemetry.pullRequestCount,
            activeTimeSeconds: telemetry.activeTimeSeconds,
            toolInvocations: telemetry.toolInvocations,
            linesAdded: telemetry.linesAdded,
            linesRemoved: telemetry.linesRemoved,
            summary: summary,
            isFinal: isFinal
        )
    }

    /// Whether there's enough quantitative signal to be worth surfacing — a
    /// session that ended without any telemetry (tokens/cost both zero) shouldn't
    /// produce an empty recap card or a contentless push.
    public var hasMeaningfulMetrics: Bool {
        tokensUsed > 0 || costUSD > 0
    }

    // MARK: - Codable

    /// Tolerant decode (matching ``SessionTelemetry``) so a host on a newer
    /// version than the viewer round-trips when a field is added later. Every
    /// field is optional-with-default.
    private enum CodingKeys: String, CodingKey {
        case projectName
        case model
        case tokensUsed
        case costUSD
        case commitCount
        case pullRequestCount
        case activeTimeSeconds
        case toolInvocations
        case linesAdded
        case linesRemoved
        case summary
        case isFinal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.tokensUsed = try container.decodeIfPresent(Int.self, forKey: .tokensUsed) ?? 0
        self.costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        self.commitCount = try container.decodeIfPresent(Int.self, forKey: .commitCount) ?? 0
        self.pullRequestCount = try container.decodeIfPresent(Int.self, forKey: .pullRequestCount) ?? 0
        self.activeTimeSeconds = try container.decodeIfPresent(Int.self, forKey: .activeTimeSeconds) ?? 0
        self.toolInvocations = try container.decodeIfPresent(Int.self, forKey: .toolInvocations) ?? 0
        self.linesAdded = try container.decodeIfPresent(Int.self, forKey: .linesAdded) ?? 0
        self.linesRemoved = try container.decodeIfPresent(Int.self, forKey: .linesRemoved) ?? 0
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
        self.isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? false
    }
}
