import ClaudeSpyNetworking
import Foundation

/// Assembles a session recap's one-line detail string (issue #598), e.g.
/// `"45k tokens · $1.20 · 3 commits · 12 min active · 28 tools"`. Shared by the
/// recap card and the end-of-session push so they read identically.
///
/// Cost is always shown (the headline number); the other components are omitted
/// when zero so a quick turn doesn't read a row of `0`s. Lives alongside the
/// other telemetry formatters so the abbreviations (`12.3k`, `$1.20`, `12 min`)
/// stay consistent with the live meter.
public func recapDetailLine(_ recap: SessionRecap) -> String {
    var parts: [String] = []
    if recap.tokensUsed > 0 {
        parts.append("\(recap.tokensUsed.abbreviatedTokenCount) tokens")
    }
    parts.append(recap.costUSD.usdCostString)
    if recap.commitCount > 0 {
        parts.append(recap.commitCount == 1 ? "1 commit" : "\(recap.commitCount) commits")
    }
    if recap.pullRequestCount > 0 {
        parts.append(recap.pullRequestCount == 1 ? "1 PR" : "\(recap.pullRequestCount) PRs")
    }
    if recap.activeTimeSeconds > 0 {
        parts.append("\(recap.activeTimeSeconds.activeTimeString) active")
    }
    if recap.toolInvocations > 0 {
        parts.append(recap.toolInvocations == 1 ? "1 tool" : "\(recap.toolInvocations) tools")
    }
    return parts.joined(separator: " · ")
}

/// One-line "today" summary for the usage overview header / Mac menu bar (issue
/// #598), e.g. `"$3.20 · 42.1k · 4 sessions"`. Cost leads (the headline number);
/// tokens and the session count are appended when non-zero.
public func usageTodayLine(_ overview: UsageOverview) -> String {
    var parts = [overview.todayCostUSD.usdCostString]
    if overview.todayTokens > 0 {
        parts.append(overview.todayTokens.abbreviatedTokenCount)
    }
    let sessions = overview.todaySessionCount
    if sessions > 0 {
        parts.append(sessions == 1 ? "1 session" : "\(sessions) sessions")
    }
    return parts.joined(separator: " · ")
}

/// The `MM-dd` tail of a `yyyy-MM-dd` day key, for compact per-day rows without
/// locale-dependent date parsing.
public func usageShortDay(_ dayKey: String) -> String {
    let parts = dayKey.split(separator: "-")
    guard parts.count == 3 else { return dayKey }
    return "\(parts[1])-\(parts[2])"
}
