import Foundation
import Testing
@testable import ClaudeSpyNetworking

struct SessionTelemetryTests {
    @Test("accumulate sums tokens by type and tracks latest model/latency")
    func accumulateSums() {
        var telemetry = SessionTelemetry()
        telemetry.accumulate(
            inputTokens: 100, outputTokens: 50, cacheReadTokens: 10, cacheCreationTokens: 5,
            costUSD: 0.20, durationMs: 900, model: "claude-opus-4-8"
        )
        telemetry.accumulate(
            inputTokens: 20, outputTokens: 10, cacheReadTokens: 0, cacheCreationTokens: 0,
            costUSD: 0.05, durationMs: 1_500, model: "claude-sonnet-4-6"
        )

        #expect(telemetry.inputTokens == 120)
        #expect(telemetry.outputTokens == 60)
        #expect(telemetry.cacheReadTokens == 10)
        #expect(telemetry.cacheCreationTokens == 5)
        #expect(telemetry.tokensUsed == 195)
        #expect(abs(telemetry.costUSD - 0.25) < 0.0_001)
        #expect(telemetry.lastTurnLatencyMs == 1_500)
        #expect(telemetry.model == "claude-sonnet-4-6")
        #expect(telemetry.recentTurns.count == 2)
    }

    @Test("recentTurns is capped at maxRecentTurns, keeping the newest")
    func recentTurnsCapped() {
        var telemetry = SessionTelemetry()
        for index in 0..<(SessionTelemetry.maxRecentTurns + 3) {
            telemetry.accumulate(
                inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheCreationTokens: 0,
                costUSD: 0.01, durationMs: index, model: nil
            )
        }
        #expect(telemetry.recentTurns.count == SessionTelemetry.maxRecentTurns)
        #expect(telemetry.recentTurns.last?.latencyMs == SessionTelemetry.maxRecentTurns + 2)
    }

    @Test("Codable round-trips")
    func codableRoundTrip() throws {
        var telemetry = SessionTelemetry()
        telemetry.accumulate(
            inputTokens: 100, outputTokens: 50, cacheReadTokens: 10, cacheCreationTokens: 5,
            costUSD: 0.20, durationMs: 900, model: "claude-opus-4-8"
        )
        let data = try JSONEncoder().encode(telemetry)
        let decoded = try JSONDecoder().decode(SessionTelemetry.self, from: data)
        #expect(decoded == telemetry)
    }

    @Test("Tolerant decode fills defaults for a partial payload (version skew)")
    func tolerantPartialDecode() throws {
        // Simulates a host that only sent a subset of fields.
        let json = """
        {"tokensUsed": 42, "costUSD": 0.5}
        """
        let decoded = try JSONDecoder().decode(SessionTelemetry.self, from: Data(json.utf8))
        #expect(decoded.tokensUsed == 42)
        #expect(decoded.costUSD == 0.5)
        #expect(decoded.inputTokens == 0)
        #expect(decoded.lastTurnLatencyMs == nil)
        #expect(decoded.recentTurns.isEmpty)
    }

    @Test("PaneState without telemetry fields decodes (older host)")
    func paneStateBackwardCompat() throws {
        // An older host's PaneState carries none of the #597 fields.
        let json = """
        {
          "paneId": "%0", "target": "s:0.0", "sessionName": "s", "windowIndex": 0,
          "paneIndex": 0, "width": 80, "height": 24, "isActive": true,
          "windowLayout": "", "windowName": "w", "isWindowActive": true, "yoloMode": false
        }
        """
        let pane = try JSONDecoder().decode(PaneState.self, from: Data(json.utf8))
        #expect(pane.telemetry == nil)
        #expect(pane.permissionMode == nil)
        #expect(pane.claudeSessionID == nil)
    }

    @Test("PaneState with telemetry round-trips")
    func paneStateWithTelemetry() throws {
        var telemetry = SessionTelemetry()
        telemetry.accumulate(
            inputTokens: 10, outputTokens: 5, cacheReadTokens: 0, cacheCreationTokens: 0,
            costUSD: 0.02, durationMs: 700, model: "claude-opus-4-8"
        )
        let pane = PaneState(
            paneId: "%3",
            claudeSessionID: "sess-abc",
            permissionMode: "acceptEdits",
            permissionModeTrigger: "shift_tab",
            telemetry: telemetry
        )
        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(PaneState.self, from: data)
        #expect(decoded.claudeSessionID == "sess-abc")
        #expect(decoded.permissionMode == "acceptEdits")
        #expect(decoded.permissionModeTrigger == "shift_tab")
        #expect(decoded.telemetry == telemetry)
    }
}
