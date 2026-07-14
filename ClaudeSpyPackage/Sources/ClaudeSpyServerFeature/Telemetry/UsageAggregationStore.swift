import ClaudeSpyNetworking
import Foundation
import Logging

// MARK: - Usage Aggregation Store

/// Durable per-(project, day) cost/usage aggregation for the cross-session
/// overview (issue #598, part B).
///
/// #597's OTLP receiver holds **live** per-session state and evicts it on pane
/// close, so the rollups need a store that outlives a session. This one persists
/// a small JSON document under `~/.gallager/state/` (the same tree the plugin
/// runtime uses), so the totals survive both session end and app restart.
///
/// ## Why per-session baselines
/// OTEL token/cost/commit values are **cumulative per session** — each export
/// carries the running total. To attribute spend to the day it happened (and to
/// the right project) we add only the *delta* since we last recorded that
/// session. Baselines are persisted alongside the records, so a session that
/// spans an app restart keeps counting from where it left off instead of
/// double-counting its pre-restart total.
///
/// An `actor` because it owns file I/O; all mutation is serialized.
actor UsageAggregationStore {
    // MARK: Tuning

    /// Projects shown in the overview, ranked by recent cost.
    private static let maxProjects = 8
    /// Window (days, inclusive of today) the per-project rollup sums over.
    private static let projectWindowDays = 7
    /// Days included in the per-day trend (most recent last).
    private static let trendDays = 7
    /// Records older than this are pruned on write, bounding the file.
    private static let maxRetentionDays = 400
    /// Upper bound on retained per-session baselines (missed evictions can't grow
    /// the file without bound). Oldest-touched dropped past this.
    private static let maxBaselines = 1_024

    // MARK: State

    private let fileURL: URL
    private let calendar: Calendar

    /// `(projectPath, day)` → accumulated totals.
    private var records: [BucketKey: UsageRecord] = [:]
    /// `session.id` → last-recorded cumulative snapshot, for delta computation.
    private var baselines: [String: Baseline] = [:]
    /// Touch order for `baselines`, oldest first, for the cap.
    private var baselineOrder: [String] = []

    // MARK: Init

    /// - Parameters:
    ///   - fileURL: JSON document path (created on first write).
    ///   - calendar: Day-boundary calendar (injected as UTC in tests for
    ///     deterministic day keys; `.current` in production so "today" matches
    ///     the user's wall clock).
    init(fileURL: URL, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.calendar = calendar
        let loaded = Self.loadState(from: fileURL)
        // Trim stale records on startup so a long-lived host that only ever sees
        // path-less sessions (which never reach the `record()` → `prune()` path)
        // still ages out old buckets. Rewrite the file only when something changed.
        // (Static helpers, since an actor's synchronous init can't call its own
        // isolated methods.)
        let pruned = Self.pruning(loaded.records, asOf: Date(), calendar: calendar)
        self.records = pruned
        self.baselines = loaded.baselines
        self.baselineOrder = loaded.baselineOrder
        if pruned.count != loaded.records.count {
            Self.write(
                records: pruned,
                baselines: loaded.baselines,
                baselineOrder: loaded.baselineOrder,
                to: fileURL
            )
        }
    }

    // MARK: Recording

    /// Folds a session's latest telemetry snapshot into the (project, day)
    /// aggregate, adding only the delta since the previous snapshot for this
    /// session. Persists when something actually changed.
    func record(projectPath: String, sessionID: String, telemetry: SessionTelemetry, date: Date) {
        let trimmedPath = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty, !sessionID.isEmpty else { return }

        let current = Baseline(telemetry)
        let previous = baselines[sessionID] ?? Baseline()
        let delta = current.subtracting(previous)
        baselines[sessionID] = current
        touchBaseline(sessionID)

        let day = Self.dayKey(date, calendar: calendar)
        let key = BucketKey(projectPath: trimmedPath, day: day)
        var record = records[key] ?? UsageRecord(projectPath: trimmedPath, day: day)
        record.add(delta)
        let inserted = record.sessionIDs.insert(sessionID).inserted
        records[key] = record

        // Cumulative counters only ever grow, so a non-`nil` delta means real new
        // spend; combined with the first-seen session insert, that's the only time
        // the document changes and is worth a write.
        guard !delta.isZero || inserted else { return }
        prune(asOf: date)
        persist()
    }

    /// Drops a finished session's baseline (called on session end) so the file
    /// doesn't retain dead working state. The accrued records are untouched.
    func evictSession(_ sessionID: String) {
        guard baselines.removeValue(forKey: sessionID) != nil else { return }
        baselineOrder.removeAll { $0 == sessionID }
        persist()
    }

    // MARK: Overview

    /// Builds the wire rollup as of `date`: today's totals, a recent-window
    /// per-project ranking, and a short per-day trend.
    func overview(asOf date: Date) -> UsageOverview {
        let today = Self.dayKey(date, calendar: calendar)

        var todayCost: Double = 0
        var todayTokens = 0
        var todayCommits = 0
        var todayPullRequests = 0
        var todaySessions = Set<String>()
        for record in records.values where record.day == today {
            todayCost += record.costUSD
            todayTokens += record.tokens
            todayCommits += record.commits
            todayPullRequests += record.pullRequests
            todaySessions.formUnion(record.sessionIDs)
        }

        let projects = rankedProjects(asOf: date)
        let days = dailyTrend(asOf: date)

        return UsageOverview(
            generatedDay: today,
            todayCostUSD: todayCost,
            todayTokens: todayTokens,
            todaySessionCount: todaySessions.count,
            todayCommits: todayCommits,
            todayPullRequests: todayPullRequests,
            projects: projects,
            days: days
        )
    }

    /// Per-project totals over the recent window, ranked by cost then tokens,
    /// capped at ``maxProjects``.
    private func rankedProjects(asOf date: Date) -> [ProjectUsage] {
        let window = Set(recentDayKeys(asOf: date, count: Self.projectWindowDays))
        var byProject: [String: (cost: Double, tokens: Int, commits: Int, pullRequests: Int, sessions: Set<String>)] = [:]
        for record in records.values where window.contains(record.day) {
            var acc = byProject[record.projectPath] ?? (0, 0, 0, 0, [])
            acc.cost += record.costUSD
            acc.tokens += record.tokens
            acc.commits += record.commits
            acc.pullRequests += record.pullRequests
            acc.sessions.formUnion(record.sessionIDs)
            byProject[record.projectPath] = acc
        }
        let projects: [ProjectUsage] = byProject.map { path, acc in
            ProjectUsage(
                projectPath: path,
                projectName: Self.projectName(for: path),
                costUSD: acc.cost,
                tokens: acc.tokens,
                commits: acc.commits,
                pullRequests: acc.pullRequests,
                sessionCount: acc.sessions.count
            )
        }
        let ranked = projects.sorted { lhs, rhs in
            lhs.costUSD != rhs.costUSD ? lhs.costUSD > rhs.costUSD : lhs.tokens > rhs.tokens
        }
        return Array(ranked.prefix(Self.maxProjects))
    }

    /// Per-day cost/token totals across all projects, oldest day first.
    private func dailyTrend(asOf date: Date) -> [DayUsage] {
        let dayKeys = recentDayKeys(asOf: date, count: Self.trendDays)
        let window = Set(dayKeys)
        var totals: [String: (cost: Double, tokens: Int)] = [:]
        // Only fold records inside the trend window — the output is just these few
        // days, so scanning all history (O(all records) for a handful of rows) is
        // wasted work on a long-lived, many-project host (mirrors `rankedProjects`).
        for record in records.values where window.contains(record.day) {
            var acc = totals[record.day] ?? (0, 0)
            acc.cost += record.costUSD
            acc.tokens += record.tokens
            totals[record.day] = acc
        }
        // Oldest → newest so a chart reads left-to-right.
        return dayKeys.reversed().map { day in
            let acc = totals[day] ?? (0, 0)
            return DayUsage(day: day, costUSD: acc.cost, tokens: acc.tokens)
        }
    }

    // MARK: Day keys

    /// `yyyy-MM-dd` in the store's calendar. Zero-padded so lexical order matches
    /// chronological order (used by pruning).
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// The `count` most recent day keys, today first.
    private func recentDayKeys(asOf date: Date, count: Int) -> [String] {
        (0..<max(0, count)).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: date).map { Self.dayKey($0, calendar: calendar) }
        }
    }

    private static func projectName(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    // MARK: Maintenance

    /// Drops records older than the retention window. String comparison is valid
    /// because day keys are fixed-width zero-padded.
    private func prune(asOf date: Date) {
        records = Self.pruning(records, asOf: date, calendar: calendar)
    }

    /// Pure record-pruning, so both the instance `prune` and the synchronous
    /// `init` (which can't touch isolated state) share one implementation. String
    /// comparison is valid because day keys are fixed-width zero-padded.
    private static func pruning(
        _ records: [BucketKey: UsageRecord],
        asOf date: Date,
        calendar: Calendar
    ) -> [BucketKey: UsageRecord] {
        guard let cutoffDate = calendar.date(byAdding: .day, value: -maxRetentionDays, to: date) else { return records }
        let cutoff = dayKey(cutoffDate, calendar: calendar)
        return records.filter { $0.key.day >= cutoff }
    }

    /// Marks a baseline most-recently-used and evicts the oldest past the cap.
    private func touchBaseline(_ sessionID: String) {
        baselineOrder.removeAll { $0 == sessionID }
        baselineOrder.append(sessionID)
        while baselineOrder.count > Self.maxBaselines {
            let oldest = baselineOrder.removeFirst()
            baselines.removeValue(forKey: oldest)
        }
    }

    // MARK: Persistence

    /// Loads persisted state from disk, or returns empty state on a missing /
    /// unreadable / corrupt file. `static` + `nonisolated` so the `init` can call
    /// it before the actor is fully formed (it touches no actor state, only the
    /// passed URL).
    private static func loadState(
        from fileURL: URL
    ) -> (records: [BucketKey: UsageRecord], baselines: [String: Baseline], baselineOrder: [String]) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ([:], [:], []) }
        do {
            let data = try Data(contentsOf: fileURL)
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            let records = Dictionary(
                state.records.map { (BucketKey(projectPath: $0.projectPath, day: $0.day), $0) },
                uniquingKeysWith: { _, last in last }
            )
            var order = state.baselineOrder.filter { state.baselines[$0] != nil }
            // Any baseline not in the saved order (forward-compat) gets appended.
            for id in state.baselines.keys where !order.contains(id) {
                order.append(id)
            }
            return (records, state.baselines, order)
        } catch {
            Logger(label: "com.claudespy.usagestore")
                .warning("Failed to load usage aggregates, starting empty: \(error)")
            return ([:], [:], [])
        }
    }

    private func persist() {
        Self.write(records: records, baselines: baselines, baselineOrder: baselineOrder, to: fileURL)
    }

    /// Atomically writes the state document. `static` so the synchronous `init`
    /// can persist a startup prune without calling isolated members; touches only
    /// its arguments.
    private static func write(
        records: [BucketKey: UsageRecord],
        baselines: [String: Baseline],
        baselineOrder: [String],
        to fileURL: URL
    ) {
        let state = PersistedState(
            version: 1,
            records: Array(records.values),
            baselines: baselines,
            baselineOrder: baselineOrder
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger(label: "com.claudespy.usagestore")
                .warning("Failed to persist usage aggregates: \(error)")
        }
    }
}

// MARK: - Persisted shapes

private struct BucketKey: Hashable {
    let projectPath: String
    let day: String
}

/// One (project, day) bucket. `sessionIDs` backs the distinct session count.
private struct UsageRecord: Codable, Equatable {
    var projectPath: String
    var day: String
    var tokens = 0
    var costUSD: Double = 0
    var commits = 0
    var pullRequests = 0
    var activeTimeSeconds = 0
    var linesAdded = 0
    var linesRemoved = 0
    var sessionIDs: Set<String> = []

    mutating func add(_ delta: Baseline) {
        tokens += delta.tokens
        costUSD += delta.costUSD
        commits += delta.commits
        pullRequests += delta.pullRequests
        activeTimeSeconds += delta.activeTimeSeconds
        linesAdded += delta.linesAdded
        linesRemoved += delta.linesRemoved
    }
}

/// The cumulative-counter subset of a session's telemetry, used both as the
/// last-recorded baseline and as the delta between two baselines.
private struct Baseline: Codable, Equatable {
    var tokens = 0
    var costUSD: Double = 0
    var commits = 0
    var pullRequests = 0
    var activeTimeSeconds = 0
    var linesAdded = 0
    var linesRemoved = 0

    init() { }

    init(_ telemetry: SessionTelemetry) {
        self.tokens = telemetry.tokensUsed
        self.costUSD = telemetry.costUSD
        self.commits = telemetry.commitCount
        self.pullRequests = telemetry.pullRequestCount
        self.activeTimeSeconds = telemetry.activeTimeSeconds
        self.linesAdded = telemetry.linesAdded
        self.linesRemoved = telemetry.linesRemoved
    }

    private init(
        tokens: Int,
        costUSD: Double,
        commits: Int,
        pullRequests: Int,
        activeTimeSeconds: Int,
        linesAdded: Int,
        linesRemoved: Int
    ) {
        self.tokens = tokens
        self.costUSD = costUSD
        self.commits = commits
        self.pullRequests = pullRequests
        self.activeTimeSeconds = activeTimeSeconds
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
    }

    /// Componentwise `self - other`, clamped at 0. Clamping guards against a
    /// counter that appears to go backwards (a reused `session.id`, or a reset),
    /// which would otherwise subtract from the running totals.
    func subtracting(_ other: Baseline) -> Baseline {
        Baseline(
            tokens: max(0, tokens - other.tokens),
            costUSD: max(0, costUSD - other.costUSD),
            commits: max(0, commits - other.commits),
            pullRequests: max(0, pullRequests - other.pullRequests),
            activeTimeSeconds: max(0, activeTimeSeconds - other.activeTimeSeconds),
            linesAdded: max(0, linesAdded - other.linesAdded),
            linesRemoved: max(0, linesRemoved - other.linesRemoved)
        )
    }

    var isZero: Bool {
        tokens == 0 && costUSD == 0 && commits == 0 && pullRequests == 0
            && activeTimeSeconds == 0 && linesAdded == 0 && linesRemoved == 0
    }
}

private struct PersistedState: Codable {
    var version: Int
    var records: [UsageRecord]
    var baselines: [String: Baseline]
    var baselineOrder: [String]
}
