import ClaudeSpyNetworking
import SwiftUI

// MARK: - Overview Header

/// A glanceable one-line "today" total (issue #598, part B) for the top of the
/// session list (iOS) / sidebar (Mac). Renders nothing when the overview is
/// empty, so a host with no usage yet stays clean. Shared by both platforms.
public struct UsageOverviewHeader: View {
    private let overview: UsageOverview

    public init(overview: UsageOverview) {
        self.overview = overview
    }

    public var body: some View {
        if !overview.isEmpty {
            HStack(spacing: 6) {
                Symbols.chartLineUptrendXyaxis.image
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Today")
                    .font(.caption.weight(.semibold))
                Text(usageTodayLine(overview))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("usage-overview-header")
            .accessibilityLabel("Today's usage: \(usageTodayLine(overview))")
        }
    }
}

// MARK: - Full Overview

/// The full cross-session overview (issue #598): a compact "Today" header row
/// that expands in place — via the trailing disclosure chevron — to the
/// per-project ranking over the recent window and the per-day trend. Starts
/// collapsed on every appearance (transient state, no persistence). Shared by
/// both platforms: the iOS session list and the Mac sidebar.
public struct UsageOverviewView: View {
    private let overview: UsageOverview

    @State private var isExpanded: Bool

    public init(overview: UsageOverview, initiallyExpanded: Bool = false) {
        self.overview = overview
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var trendDays: [DayUsage] {
        overview.days.filter { $0.costUSD > 0 || $0.tokens > 0 }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    UsageOverviewHeader(overview: overview)
                    Symbols.chevronRight.image
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("usage-overview-toggle")
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")

            if isExpanded {
                if !overview.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionLabel("Projects", symbol: .folder)
                        ForEach(overview.projects) { project in
                            UsageProjectRow(project: project)
                        }
                    }
                }

                if !trendDays.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionLabel("Recent days", symbol: .calendar)
                        ForEach(trendDays) { day in
                            UsageDayRow(day: day)
                        }
                    }
                }
            }
        }
        // Keep the header button its own accessibility element. Without this,
        // the iOS List row merges the whole cell into one element carrying the
        // header's label, whose frame grows with the expanded sections — so a
        // centre tap on it (VoiceOver or UI tests) misses the header row.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage-overview")
    }

    private func sectionLabel(_ title: String, symbol: Symbols) -> some View {
        Label(title, symbol: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Rows

/// One project's recent-window totals: name on the left, tokens · cost · commits
/// · PRs on the right (tokens-first, matching the session meter).
struct UsageProjectRow: View {
    let project: ProjectUsage

    private var detail: String {
        var parts: [String] = []
        if project.tokens > 0 {
            parts.append(project.tokens.abbreviatedTokenCount)
        }
        // Codex emits no cost, so a `$0.00` would be misleading — omit it like the
        // recap line does.
        if project.costUSD > 0 {
            parts.append(project.costUSD.usdCostString)
        }
        if project.commits > 0 {
            parts.append(project.commits == 1 ? "1 commit" : "\(project.commits) commits")
        }
        if project.pullRequests > 0 {
            parts.append(project.pullRequests == 1 ? "1 PR" : "\(project.pullRequests) PRs")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(project.projectName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.projectName): \(detail)")
    }
}

/// One day's total across all projects: short date on the left, tokens · cost on
/// the right (tokens-first, matching the session meter). Cost is omitted when
/// zero (Codex emits none), like the project row.
struct UsageDayRow: View {
    let day: DayUsage

    private var detail: String {
        var parts: [String] = []
        if day.tokens > 0 {
            parts.append(day.tokens.abbreviatedTokenCount)
        }
        if day.costUSD > 0 {
            parts.append(day.costUSD.usdCostString)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(usageShortDay(day.day))
                .font(.caption)
                .monospacedDigit()
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(usageShortDay(day.day)): \(detail)")
    }
}

// MARK: - Previews

private let previewOverview = UsageOverview(
    generatedDay: "2026-06-16",
    todayCostUSD: 3.20,
    todayTokens: 42_100,
    todaySessionCount: 4,
    todayCommits: 2,
    todayPullRequests: 1,
    projects: [
        ProjectUsage(projectPath: "/work/Gallager", projectName: "Gallager", costUSD: 2, tokens: 28_000, commits: 2, pullRequests: 1, sessionCount: 2),
        ProjectUsage(projectPath: "/work/relay", projectName: "relay", costUSD: 1.20, tokens: 14_100, commits: 0, pullRequests: 0, sessionCount: 2),
    ],
    days: [
        DayUsage(day: "2026-06-14", costUSD: 1.10, tokens: 12_000),
        DayUsage(day: "2026-06-15", costUSD: 0, tokens: 0),
        DayUsage(day: "2026-06-16", costUSD: 3.20, tokens: 42_100),
    ]
)

#Preview("Overview header") {
    UsageOverviewHeader(overview: previewOverview)
        .padding()
        .frame(width: 320)
}

#Preview("Overview collapsed") {
    UsageOverviewView(overview: previewOverview)
        .padding()
        .frame(width: 320)
}

#Preview("Overview expanded") {
    UsageOverviewView(overview: previewOverview, initiallyExpanded: true)
        .padding()
        .frame(width: 320)
}
