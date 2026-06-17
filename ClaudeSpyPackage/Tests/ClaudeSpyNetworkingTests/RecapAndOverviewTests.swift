import Foundation
import Testing
@testable import ClaudeSpyNetworking

/// Tests for the issue #598 wire models — ``SessionRecap`` and ``UsageOverview`` —
/// plus their graceful carriage on ``PaneState`` / ``SessionStateMessage`` for
/// cross-host version skew.
struct RecapAndOverviewTests {
    // MARK: - SessionRecap

    @Test("SessionRecap maps a telemetry snapshot")
    func recapFromTelemetry() {
        var telemetry = SessionTelemetry()
        telemetry.accumulate(
            inputTokens: 30_000, outputTokens: 15_000, cacheReadTokens: 0, cacheCreationTokens: 0,
            costUSD: 1.20, durationMs: 900, model: "claude-opus-4-8"
        )
        telemetry.activeTimeSeconds = 720
        telemetry.toolInvocations = 28
        telemetry.commitCount = 3
        telemetry.linesAdded = 120
        telemetry.linesRemoved = 30

        let recap = SessionRecap(telemetry: telemetry, projectName: "Gallager", summary: "Done", isFinal: true)
        #expect(recap.tokensUsed == 45_000)
        #expect(recap.costUSD == 1.20)
        #expect(recap.activeTimeSeconds == 720)
        #expect(recap.toolInvocations == 28)
        #expect(recap.commitCount == 3)
        #expect(recap.linesAdded == 120)
        #expect(recap.projectName == "Gallager")
        #expect(recap.isFinal)
        #expect(recap.model == "claude-opus-4-8")
        #expect(recap.hasMeaningfulMetrics)
    }

    @Test("hasMeaningfulMetrics is false without tokens or cost")
    func recapEmptyMetrics() {
        let recap = SessionRecap(summary: "nothing happened")
        #expect(!recap.hasMeaningfulMetrics)
    }

    @Test("SessionRecap Codable round-trips")
    func recapRoundTrip() throws {
        let recap = SessionRecap(
            projectName: "Gallager", model: "claude-opus-4-8", tokensUsed: 45_000, costUSD: 1.2,
            commitCount: 3, pullRequestCount: 1, activeTimeSeconds: 720, toolInvocations: 28,
            linesAdded: 120, linesRemoved: 30, summary: "Done", isFinal: true
        )
        let data = try JSONEncoder().encode(recap)
        let decoded = try JSONDecoder().decode(SessionRecap.self, from: data)
        #expect(decoded == recap)
    }

    @Test("SessionRecap tolerant decode fills defaults")
    func recapTolerantDecode() throws {
        let json = """
        {"tokensUsed": 1000, "costUSD": 0.1}
        """
        let decoded = try JSONDecoder().decode(SessionRecap.self, from: Data(json.utf8))
        #expect(decoded.tokensUsed == 1_000)
        #expect(decoded.commitCount == 0)
        #expect(decoded.isFinal == false)
        #expect(decoded.summary == nil)
    }

    @Test("PaneState carries a recap and round-trips; older host decodes nil")
    func paneStateRecap() throws {
        let recap = SessionRecap(tokensUsed: 1_000, costUSD: 0.1)
        let pane = PaneState(paneId: "%1", recap: recap)
        let decoded = try JSONDecoder().decode(PaneState.self, from: JSONEncoder().encode(pane))
        #expect(decoded.recap == recap)

        // Older host's PaneState (no recap key) → nil.
        let json = """
        {
          "paneId": "%0", "target": "s:0.0", "sessionName": "s", "windowIndex": 0,
          "paneIndex": 0, "width": 80, "height": 24, "isActive": true,
          "windowLayout": "", "windowName": "w", "isWindowActive": true, "yoloMode": false
        }
        """
        let older = try JSONDecoder().decode(PaneState.self, from: Data(json.utf8))
        #expect(older.recap == nil)
    }

    // MARK: - UsageOverview

    @Test("UsageOverview Codable round-trips")
    func overviewRoundTrip() throws {
        let overview = UsageOverview(
            generatedDay: "2026-06-16",
            todayCostUSD: 3.2,
            todayTokens: 42_100,
            todaySessionCount: 4,
            todayCommits: 2,
            projects: [
                ProjectUsage(projectPath: "/a", projectName: "a", costUSD: 2, tokens: 20_000, commits: 1, sessionCount: 2),
            ],
            days: [DayUsage(day: "2026-06-16", costUSD: 3.2, tokens: 42_100)]
        )
        let decoded = try JSONDecoder().decode(UsageOverview.self, from: JSONEncoder().encode(overview))
        #expect(decoded == overview)
    }

    @Test("UsageOverview tolerant decode fills defaults")
    func overviewTolerantDecode() throws {
        let json = """
        {"todayCostUSD": 1.5}
        """
        let decoded = try JSONDecoder().decode(UsageOverview.self, from: Data(json.utf8))
        #expect(decoded.todayCostUSD == 1.5)
        #expect(decoded.todayTokens == 0)
        #expect(decoded.projects.isEmpty)
        #expect(decoded.days.isEmpty)
    }

    @Test("UsageOverview.isEmpty reflects no accrued usage")
    func overviewIsEmpty() {
        #expect(UsageOverview().isEmpty)
        #expect(!UsageOverview(todayCostUSD: 0.5).isEmpty)
    }

    @Test("SessionStateMessage carries an optional usageOverview; older message decodes nil")
    func sessionStateMessageOverview() throws {
        let overview = UsageOverview(todayCostUSD: 1, todayTokens: 100)
        let message = SessionStateMessage(pairId: "p", paneStates: [:], usageOverview: overview)
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.usageOverview == overview)

        // withPairId must forward the overview (the centralised rebuild).
        #expect(message.withPairId("p2").usageOverview == overview)

        // Older host's message (no usageOverview key) → nil.
        let json = """
        {"pairId": "p", "paneStates": {}, "homeDirectory": "/home/x"}
        """
        let older = try JSONDecoder().decode(SessionStateMessage.self, from: Data(json.utf8))
        #expect(older.usageOverview == nil)
    }
}
