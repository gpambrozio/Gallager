import Foundation

// MARK: - Usage Overview

/// A cross-session cost / usage rollup for one host (issue #598, part B). Built
/// on the Mac from the durable per-(project, day) aggregation store and carried
/// to iOS viewers as an optional field on ``SessionStateMessage`` — so it
/// degrades gracefully when an older peer doesn't send or read it.
///
/// Bounded by construction (a handful of recent days and top projects) so it
/// rides the existing snapshot without bloating the wire.
public struct UsageOverview: Codable, Sendable, Equatable {
    /// The host's "today" key (`yyyy-MM-dd`, host-local) the rollup was generated
    /// for. Lets a viewer label the today totals without assuming its own clock
    /// matches the host's day boundary.
    public var generatedDay: String

    /// Total cost across all projects today.
    public var todayCostUSD: Double

    /// Total tokens across all projects today.
    public var todayTokens: Int

    /// Distinct sessions seen today (across all projects).
    public var todaySessionCount: Int

    /// Commits made today (across all projects).
    public var todayCommits: Int

    /// Pull requests opened today (across all projects).
    public var todayPullRequests: Int

    /// Per-project rollup over a recent window (newest-relevant first, capped).
    public var projects: [ProjectUsage]

    /// Per-day totals over a recent window (most recent last), for a small trend.
    public var days: [DayUsage]

    public init(
        generatedDay: String = "",
        todayCostUSD: Double = 0,
        todayTokens: Int = 0,
        todaySessionCount: Int = 0,
        todayCommits: Int = 0,
        todayPullRequests: Int = 0,
        projects: [ProjectUsage] = [],
        days: [DayUsage] = []
    ) {
        self.generatedDay = generatedDay
        self.todayCostUSD = todayCostUSD
        self.todayTokens = todayTokens
        self.todaySessionCount = todaySessionCount
        self.todayCommits = todayCommits
        self.todayPullRequests = todayPullRequests
        self.projects = projects
        self.days = days
    }

    /// Whether there's anything worth surfacing (a header/menu-bar line should
    /// stay hidden on a host that has accrued no usage yet). The `days` trend is
    /// always populated with the recent window, so it's checked by value, not by
    /// array emptiness.
    public var isEmpty: Bool {
        todayCostUSD <= 0
            && todayTokens == 0
            && projects.isEmpty
            && days.allSatisfy { $0.costUSD <= 0 && $0.tokens == 0 }
    }

    // MARK: - Codable

    /// Tolerant decode so a newer host adding a field still round-trips to an
    /// older viewer (issue #598 cross-host rule). Every field optional-with-default.
    private enum CodingKeys: String, CodingKey {
        case generatedDay
        case todayCostUSD
        case todayTokens
        case todaySessionCount
        case todayCommits
        case todayPullRequests
        case projects
        case days
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.generatedDay = try container.decodeIfPresent(String.self, forKey: .generatedDay) ?? ""
        self.todayCostUSD = try container.decodeIfPresent(Double.self, forKey: .todayCostUSD) ?? 0
        self.todayTokens = try container.decodeIfPresent(Int.self, forKey: .todayTokens) ?? 0
        self.todaySessionCount = try container.decodeIfPresent(Int.self, forKey: .todaySessionCount) ?? 0
        self.todayCommits = try container.decodeIfPresent(Int.self, forKey: .todayCommits) ?? 0
        self.todayPullRequests = try container.decodeIfPresent(Int.self, forKey: .todayPullRequests) ?? 0
        self.projects = try container.decodeIfPresent([ProjectUsage].self, forKey: .projects) ?? []
        self.days = try container.decodeIfPresent([DayUsage].self, forKey: .days) ?? []
    }
}

// MARK: - Project Usage

/// Per-project usage totals over the overview's recent window.
public struct ProjectUsage: Codable, Sendable, Equatable, Identifiable {
    /// Absolute project path — the aggregation key, and a stable identity.
    public var projectPath: String
    /// Display name (the project folder's last path component).
    public var projectName: String
    public var costUSD: Double
    public var tokens: Int
    public var commits: Int
    public var pullRequests: Int
    public var sessionCount: Int

    public var id: String {
        projectPath
    }

    public init(
        projectPath: String,
        projectName: String,
        costUSD: Double,
        tokens: Int,
        commits: Int,
        pullRequests: Int = 0,
        sessionCount: Int
    ) {
        self.projectPath = projectPath
        self.projectName = projectName
        self.costUSD = costUSD
        self.tokens = tokens
        self.commits = commits
        self.pullRequests = pullRequests
        self.sessionCount = sessionCount
    }
}

// MARK: - Day Usage

/// Per-day usage totals (across all projects) for the overview's trend.
public struct DayUsage: Codable, Sendable, Equatable, Identifiable {
    /// `yyyy-MM-dd` day key.
    public var day: String
    public var costUSD: Double
    public var tokens: Int

    public var id: String {
        day
    }

    public init(day: String, costUSD: Double, tokens: Int) {
        self.day = day
        self.costUSD = costUSD
        self.tokens = tokens
    }
}
