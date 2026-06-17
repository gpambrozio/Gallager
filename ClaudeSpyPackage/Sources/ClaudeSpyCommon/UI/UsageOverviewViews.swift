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

/// The full cross-session overview (issue #598): today's total, a per-project
/// ranking over the recent window, and a per-day trend. Used in the iOS session
/// list's overview section. Shared by both platforms.
public struct UsageOverviewView: View {
    private let overview: UsageOverview

    public init(overview: UsageOverview) {
        self.overview = overview
    }

    private var trendDays: [DayUsage] {
        overview.days.filter { $0.costUSD > 0 || $0.tokens > 0 }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UsageOverviewHeader(overview: overview)

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
        .accessibilityIdentifier("usage-overview")
    }

    private func sectionLabel(_ title: String, symbol: Symbols) -> some View {
        Label(title, symbol: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Rows

/// One project's recent-window totals: name on the left, cost · tokens · commits
/// on the right.
struct UsageProjectRow: View {
    let project: ProjectUsage

    private var detail: String {
        var parts = [project.costUSD.usdCostString]
        if project.tokens > 0 {
            parts.append(project.tokens.abbreviatedTokenCount)
        }
        if project.commits > 0 {
            parts.append(project.commits == 1 ? "1 commit" : "\(project.commits) commits")
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

/// One day's total across all projects: short date on the left, cost · tokens on
/// the right.
struct UsageDayRow: View {
    let day: DayUsage

    private var detail: String {
        var parts = [day.costUSD.usdCostString]
        if day.tokens > 0 {
            parts.append(day.tokens.abbreviatedTokenCount)
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
