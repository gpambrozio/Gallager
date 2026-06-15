#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Tests for the OTEL telemetry accumulator (issue #597): OTLP/JSON decoding
    /// tolerance, per-session token/cost/latency accumulation, milestone deltas,
    /// and permission-mode changes.
    struct OTLPTelemetryAccumulatorTests {
        private func ingestLogs(_ json: String, into accumulator: inout OTLPTelemetryAccumulator) throws -> OTLPProcessingResult {
            let request = try JSONDecoder().decode(OTLPLogsRequest.self, from: Data(json.utf8))
            return accumulator.ingestLogs(request)
        }

        private func ingestMetrics(_ json: String, into accumulator: inout OTLPTelemetryAccumulator) throws -> OTLPProcessingResult {
            let request = try JSONDecoder().decode(OTLPMetricsRequest.self, from: Data(json.utf8))
            return accumulator.ingestMetrics(request)
        }

        /// Builds an `api_request` log payload. `intsAsStrings` toggles the proto3
        /// JSON int64-as-string encoding to prove both forms decode.
        private func apiRequestLogs(
            sessionID: String,
            input: Int,
            output: Int,
            cacheRead: Int,
            cacheCreation: Int,
            costUSD: Double,
            durationMs: Int,
            model: String,
            intsAsStrings: Bool,
            useEventNameField: Bool = true
        ) -> String {
            func intValue(_ value: Int) -> String {
                intsAsStrings ? "{\"intValue\": \"\(value)\"}" : "{\"intValue\": \(value)}"
            }
            let eventField = useEventNameField ? "\"eventName\": \"claude_code.api_request\"," : ""
            let eventAttr = useEventNameField
                ? ""
                : ",{\"key\": \"event.name\", \"value\": {\"stringValue\": \"claude_code.api_request\"}}"
            return """
            {
              "resourceLogs": [{
                "scopeLogs": [{
                  "logRecords": [{
                    \(eventField)
                    "attributes": [
                      {"key": "session.id", "value": {"stringValue": "\(sessionID)"}},
                      {"key": "input_tokens", "value": \(intValue(input))},
                      {"key": "output_tokens", "value": \(intValue(output))},
                      {"key": "cache_read_tokens", "value": \(intValue(cacheRead))},
                      {"key": "cache_creation_tokens", "value": \(intValue(cacheCreation))},
                      {"key": "cost_usd", "value": {"doubleValue": \(costUSD)}},
                      {"key": "duration_ms", "value": \(intValue(durationMs))},
                      {"key": "model", "value": {"stringValue": "\(model)"}}
                      \(eventAttr)
                    ]
                  }]
                }]
              }]
            }
            """
        }

        private func counterMetric(name: String, sessionID: String, value: Int, asString: Bool) -> String {
            let valueJSON = asString ? "\"asInt\": \"\(value)\"" : "\"asInt\": \(value)"
            return """
            {
              "resourceMetrics": [{
                "scopeMetrics": [{
                  "metrics": [{
                    "name": "\(name)",
                    "sum": {
                      "dataPoints": [{
                        "attributes": [{"key": "session.id", "value": {"stringValue": "\(sessionID)"}}],
                        \(valueJSON)
                      }]
                    }
                  }]
                }]
              }]
            }
            """
        }

        @Test("api_request accumulates tokens, cost, latency, and model (int-as-string)")
        func apiRequestStringInts() throws {
            var accumulator = OTLPTelemetryAccumulator()
            let result = try ingestLogs(
                apiRequestLogs(
                    sessionID: "sess-1", input: 100, output: 50, cacheRead: 10, cacheCreation: 5,
                    costUSD: 0.25, durationMs: 1_200, model: "claude-opus-4-8", intsAsStrings: true
                ),
                into: &accumulator
            )
            let telemetry = try #require(result.telemetryUpdates["sess-1"])
            #expect(telemetry.inputTokens == 100)
            #expect(telemetry.outputTokens == 50)
            #expect(telemetry.cacheReadTokens == 10)
            #expect(telemetry.cacheCreationTokens == 5)
            #expect(telemetry.tokensUsed == 165)
            #expect(telemetry.costUSD == 0.25)
            #expect(telemetry.lastTurnLatencyMs == 1_200)
            #expect(telemetry.model == "claude-opus-4-8")
            #expect(telemetry.recentTurns.count == 1)
        }

        @Test("api_request decodes int-as-number and the event.name attribute form")
        func apiRequestNumberIntsAndAttributeEvent() throws {
            var accumulator = OTLPTelemetryAccumulator()
            let result = try ingestLogs(
                apiRequestLogs(
                    sessionID: "sess-1", input: 7, output: 3, cacheRead: 0, cacheCreation: 0,
                    costUSD: 0.01, durationMs: 800, model: "claude-sonnet-4-6",
                    intsAsStrings: false, useEventNameField: false
                ),
                into: &accumulator
            )
            let telemetry = try #require(result.telemetryUpdates["sess-1"])
            #expect(telemetry.tokensUsed == 10)
            #expect(telemetry.lastTurnLatencyMs == 800)
        }

        @Test("Multiple api_requests sum and cap the per-turn samples")
        func multipleApiRequestsAccumulate() throws {
            var accumulator = OTLPTelemetryAccumulator()
            for index in 0..<(SessionTelemetry.maxRecentTurns + 5) {
                _ = try ingestLogs(
                    apiRequestLogs(
                        sessionID: "sess-1", input: 10, output: 5, cacheRead: 0, cacheCreation: 0,
                        costUSD: 0.01, durationMs: 100 + index, model: "claude-opus-4-8", intsAsStrings: true
                    ),
                    into: &accumulator
                )
            }
            let telemetry = try #require(accumulator.telemetry(for: "sess-1"))
            let turns = SessionTelemetry.maxRecentTurns + 5
            #expect(telemetry.inputTokens == 10 * turns)
            #expect(telemetry.tokensUsed == 15 * turns)
            // Ring buffer capped; latest sample retained.
            #expect(telemetry.recentTurns.count == SessionTelemetry.maxRecentTurns)
            #expect(telemetry.lastTurnLatencyMs == 100 + (turns - 1))
        }

        @Test("commit.count emits a milestone only on positive deltas")
        func commitMilestoneDeltas() throws {
            var accumulator = OTLPTelemetryAccumulator()

            // First export: cumulative 1 → one commit.
            var result = try ingestMetrics(
                counterMetric(name: "claude_code.commit.count", sessionID: "sess-1", value: 1, asString: true),
                into: &accumulator
            )
            #expect(result.milestones == [TelemetryMilestone(sessionID: "sess-1", kind: .commit, count: 1)])

            // Same cumulative value → no new milestone.
            result = try ingestMetrics(
                counterMetric(name: "claude_code.commit.count", sessionID: "sess-1", value: 1, asString: false),
                into: &accumulator
            )
            #expect(result.milestones.isEmpty)

            // Jumps to 3 → delta of 2.
            result = try ingestMetrics(
                counterMetric(name: "claude_code.commit.count", sessionID: "sess-1", value: 3, asString: false),
                into: &accumulator
            )
            #expect(result.milestones == [TelemetryMilestone(sessionID: "sess-1", kind: .commit, count: 2)])
        }

        @Test("pull_request.count emits a PR milestone")
        func pullRequestMilestone() throws {
            var accumulator = OTLPTelemetryAccumulator()
            let result = try ingestMetrics(
                counterMetric(name: "claude_code.pull_request.count", sessionID: "sess-9", value: 1, asString: true),
                into: &accumulator
            )
            #expect(result.milestones == [TelemetryMilestone(sessionID: "sess-9", kind: .pullRequest, count: 1)])
        }

        @Test("permission_mode_changed emits a mode change with trigger")
        func permissionModeChange() throws {
            var accumulator = OTLPTelemetryAccumulator()
            let json = """
            {
              "resourceLogs": [{
                "scopeLogs": [{
                  "logRecords": [{
                    "eventName": "claude_code.permission_mode_changed",
                    "attributes": [
                      {"key": "session.id", "value": {"stringValue": "sess-2"}},
                      {"key": "from_mode", "value": {"stringValue": "default"}},
                      {"key": "to_mode", "value": {"stringValue": "bypassPermissions"}},
                      {"key": "trigger", "value": {"stringValue": "shift_tab"}}
                    ]
                  }]
                }]
              }]
            }
            """
            let result = try ingestLogs(json, into: &accumulator)
            #expect(result.modeChanges == [
                TelemetryModeChange(sessionID: "sess-2", toMode: "bypassPermissions", trigger: "shift_tab"),
            ])
            #expect(result.telemetryUpdates.isEmpty)
        }

        @Test("Records without a session id are ignored")
        func missingSessionIDIgnored() throws {
            var accumulator = OTLPTelemetryAccumulator()
            let json = """
            {
              "resourceLogs": [{
                "scopeLogs": [{
                  "logRecords": [{
                    "eventName": "claude_code.api_request",
                    "attributes": [
                      {"key": "input_tokens", "value": {"intValue": "100"}}
                    ]
                  }]
                }]
              }]
            }
            """
            let result = try ingestLogs(json, into: &accumulator)
            #expect(result.isEmpty)
        }

        @Test("evict drops a session's accumulated telemetry and counters")
        func evictClearsSession() throws {
            var accumulator = OTLPTelemetryAccumulator()
            _ = try ingestLogs(
                apiRequestLogs(
                    sessionID: "sess-1", input: 100, output: 50, cacheRead: 0, cacheCreation: 0,
                    costUSD: 0.25, durationMs: 1_000, model: "claude-opus-4-8", intsAsStrings: true
                ),
                into: &accumulator
            )
            _ = try ingestMetrics(
                counterMetric(name: "claude_code.commit.count", sessionID: "sess-1", value: 2, asString: true),
                into: &accumulator
            )
            #expect(accumulator.telemetry(for: "sess-1") != nil)

            accumulator.evict(sessionID: "sess-1")
            #expect(accumulator.telemetry(for: "sess-1") == nil)

            // After eviction the counter baseline is gone, so re-seeing the
            // counter re-fires from zero (a fresh session reusing the id).
            let result = try ingestMetrics(
                counterMetric(name: "claude_code.commit.count", sessionID: "sess-1", value: 2, asString: true),
                into: &accumulator
            )
            #expect(result.milestones == [TelemetryMilestone(sessionID: "sess-1", kind: .commit, count: 2)])
        }
    }
#endif
