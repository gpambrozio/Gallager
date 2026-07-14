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

    /// `initiallyExpanded` exists for the expanded #Preview only — production
    /// call sites use the default and always start collapsed.
    public init(overview: UsageOverview, initiallyExpanded: Bool = false) {
        self.overview = overview
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var trendDays: [DayUsage] {
        overview.days.filter { $0.costUSD > 0 || $0.tokens > 0 }
    }

    public var body: some View {
        // Each top-level view here is its OWN List row (List flattens the
        // builder), so expanding never resizes the header's cell — the List
        // animates the detail rows in natively and the header line cannot
        // wobble. Animating the height of a single cell instead makes the
        // platform cell (UIKit/AppKit) and SwiftUI content interpolate on
        // separate tracks: the header visibly shakes on iOS, and macOS
        // reloads the row and drops the animation entirely. Separators are
        // managed per row to keep the one-card look on iOS: no divider
        // inside the expanded cell, one after it (macOS sidebars draw none).
        if !overview.isEmpty {
            headerButton
                .listRowInsets(headerRowInsets)
                .listRowSeparator(separator(visibleWhen: !isExpanded))
            if isExpanded {
                if !overview.projects.isEmpty {
                    projectsSection
                        .listRowInsets(detailRowInsets(bottom: 8))
                        .listRowSeparator(separator(visibleWhen: trendDays.isEmpty))
                }
                if !trendDays.isEmpty {
                    daysSection
                        .listRowInsets(detailRowInsets(bottom: 12))
                }
            }
        }
    }

    /// iOS keeps the one-card look (divider after the collapsed cell, none
    /// inside it); macOS sidebars draw no separators, and forcing `.visible`
    /// there paints one — so never do.
    private func separator(visibleWhen visible: Bool) -> Visibility {
        #if os(iOS)
            visible ? .visible : .hidden
        #else
            _ = visible
            return .hidden
        #endif
    }

    /// Row insets are an iOS concern (the insetGrouped card needs the header
    /// comfortably above the List's ~44pt minimum row height so it is never
    /// vertically re-centred); `nil` keeps the macOS sidebar defaults.
    private var headerRowInsets: EdgeInsets? {
        #if os(iOS)
            EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        #else
            nil
        #endif
    }

    private func detailRowInsets(bottom: CGFloat) -> EdgeInsets? {
        #if os(iOS)
            EdgeInsets(top: 0, leading: 16, bottom: bottom, trailing: 16)
        #else
            _ = bottom
            return nil
        #endif
    }

    private var headerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                UsageOverviewHeader(overview: overview)
                // Down-when-collapsed, up-when-expanded (Mail-style
                // disclosure) — a right chevron would read as navigation.
                Symbols.chevronDown.image
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Constant height + explicit identity: the header line must not
        // resize or read as new content when the cell expands.
        .frame(height: 24)
        .id("usage-overview-toggle")
        .accessibilityIdentifier("usage-overview-toggle")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Projects", symbol: .folder)
            ForEach(overview.projects) { project in
                UsageProjectRow(project: project)
            }
        }
    }

    private var daysSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Recent days", symbol: .calendar)
            ForEach(trendDays) { day in
                UsageDayRow(day: day)
            }
        }
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
    List {
        UsageOverviewView(overview: previewOverview)
    }
}

#Preview("Overview expanded") {
    List {
        UsageOverviewView(overview: previewOverview, initiallyExpanded: true)
    }
}
