import ClaudeSpyNetworking
import Foundation
import Testing
@testable import ClaudeSpyCommon

/// Tests for the issue #598 recap / overview formatters.
struct RecapFormattingTests {
    // MARK: - activeTimeString

    @Test("activeTimeString formats seconds into a compact duration")
    func activeTime() {
        #expect(0.activeTimeString == "0m")
        #expect(45.activeTimeString == "45s")
        #expect(720.activeTimeString == "12 min")
        #expect(3_600.activeTimeString == "1h")
        #expect(5_400.activeTimeString == "1h 30m")
    }

    // MARK: - recapDetailLine

    @Test("recapDetailLine matches the issue's example shape")
    func recapLine() {
        let recap = SessionRecap(
            tokensUsed: 45_000, costUSD: 1.20, commitCount: 3,
            activeTimeSeconds: 720, toolInvocations: 28
        )
        #expect(recapDetailLine(recap) == "45k tokens · $1.20 · 3 commits · 12 min active · 28 tools")
    }

    @Test("recapDetailLine omits zero components, including cost")
    func recapLineOmitsZeros() {
        let recap = SessionRecap(tokensUsed: 1_200, costUSD: 0.05)
        #expect(recapDetailLine(recap) == "1.2k tokens · $0.05")

        // Codex emits no cost: tokens show, the misleading "$0.00" is dropped.
        let codex = SessionRecap(tokensUsed: 1_200, costUSD: 0)
        #expect(recapDetailLine(codex) == "1.2k tokens")

        let empty = SessionRecap()
        #expect(recapDetailLine(empty) == "")
    }

    @Test("recapDetailLine singularizes single commit / tool / PR")
    func recapLineSingular() {
        let recap = SessionRecap(
            tokensUsed: 100, costUSD: 0.01, commitCount: 1, pullRequestCount: 1, toolInvocations: 1
        )
        #expect(recapDetailLine(recap) == "100 tokens · $0.01 · 1 commit · 1 PR · 1 tool")
    }

    // MARK: - usageTodayLine / usageShortDay

    @Test("usageTodayLine leads with cost, appends tokens and sessions")
    func todayLine() {
        let overview = UsageOverview(todayCostUSD: 3.2, todayTokens: 42_100, todaySessionCount: 4)
        #expect(usageTodayLine(overview) == "$3.20 · 42.1k · 4 sessions")

        let single = UsageOverview(todayCostUSD: 0.5, todayTokens: 0, todaySessionCount: 1)
        #expect(usageTodayLine(single) == "$0.50 · 1 session")
    }

    @Test("usageShortDay drops the year")
    func shortDay() {
        #expect(usageShortDay("2026-06-16") == "06-16")
        #expect(usageShortDay("garbage") == "garbage")
    }
}
