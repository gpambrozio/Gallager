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
            // Faithfully model Claude's real OTLP shape (verified against
            // v2.1.178): the log *body* is the fully-qualified
            // `claude_code.api_request`, while the `event.name` *attribute* is
            // the bare `api_request`. `useEventNameField` additionally sets the
            // newer top-level `eventName` field (also bare). The accumulator
            // must match regardless of which form it reads — so the default
            // (field absent, attribute + body present) reproduces production.
            let eventField = useEventNameField ? "\"eventName\": \"api_request\"," : ""
            return """
            {
              "resourceLogs": [{
                "scopeLogs": [{
                  "logRecords": [{
                    \(eventField)
                    "body": {"stringValue": "claude_code.api_request"},
                    "attributes": [
                      {"key": "event.name", "value": {"stringValue": "api_request"}},
                      {"key": "session.id", "value": {"stringValue": "\(sessionID)"}},
                      {"key": "input_tokens", "value": \(intValue(input))},
                      {"key": "output_tokens", "value": \(intValue(output))},
                      {"key": "cache_read_tokens", "value": \(intValue(cacheRead))},
                      {"key": "cache_creation_tokens", "value": \(intValue(cacheCreation))},
                      {"key": "cost_usd", "value": {"doubleValue": \(costUSD)}},
                      {"key": "duration_ms", "value": \(intValue(durationMs))},
                      {"key": "model", "value": {"stringValue": "\(model)"}}
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

        /// `lines_of_code.count` with one data point per `type` (added/removed) —
        /// the shape that needs per-type totals rather than one value per session.
        private func linesMetric(sessionID: String, added: Int, removed: Int) -> String {
            func point(type: String, value: Int) -> String {
                """
                {
                  "attributes": [
                    {"key": "session.id", "value": {"stringValue": "\(sessionID)"}},
                    {"key": "type", "value": {"stringValue": "\(type)"}}
                  ],
                  "asInt": "\(value)"
                }
                """
            }
            return """
            {
              "resourceMetrics": [{
                "scopeMetrics": [{
                  "metrics": [{
                    "name": "claude_code.lines_of_code.count",
                    "sum": {"dataPoints": [\(point(type: "added", value: added)), \(point(type: "removed", value: removed))]}
                  }]
                }]
              }]
            }
            """
        }

        /// `count` `tool_result` log records for one session, each a separate event.
        private func toolResultLogs(sessionID: String, count: Int) -> String {
            let records = (0..<count).map { _ in
                """
                {
                  "eventName": "tool_result",
                  "attributes": [{"key": "session.id", "value": {"stringValue": "\(sessionID)"}}]
                }
                """
            }.joined(separator: ",")
            return """
            {
              "resourceLogs": [{
                "scopeLogs": [{
                  "logRecords": [\(records)]
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
                    "body": {"stringValue": "claude_code.permission_mode_changed"},
                    "attributes": [
                      {"key": "event.name", "value": {"stringValue": "permission_mode_changed"}},
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

        // MARK: - Issue #598 aggregate counters

        @Test("commit.count carries the cumulative total onto the snapshot (issue #598)")
        func commitCarriesCumulativeIntoTelemetry() throws {
            var accumulator = OTLPTelemetryAccumulator()
            _ = try ingestMetrics(
                counterMetric(name: "claude_code.commit.count", sessionID: "sess-1", value: 3, asString: true),
                into: &accumulator
            )
            let telemetry = try #require(accumulator.telemetry(for: "sess-1"))
            #expect(telemetry.commitCount == 3)

            _ = try ingestMetrics(
                counterMetric(name: "claude_code.pull_request.count", sessionID: "sess-1", value: 1, asString: false),
                into: &accumulator
            )
            #expect(accumulator.telemetry(for: "sess-1")?.pullRequestCount == 1)
            // Commit total is preserved across a different counter's update.
            #expect(accumulator.telemetry(for: "sess-1")?.commitCount == 3)
        }

        @Test("active_time.total carries cumulative seconds onto the snapshot (issue #598)")
        func activeTimeAccumulates() throws {
            var accumulator = OTLPTelemetryAccumulator()
            let result = try ingestMetrics(
                counterMetric(name: "claude_code.active_time.total", sessionID: "sess-1", value: 720, asString: true),
                into: &accumulator
            )
            #expect(result.telemetryUpdates["sess-1"]?.activeTimeSeconds == 720)
            #expect(result.milestones.isEmpty) // active time is not a milestone

            // A later, larger cumulative replaces the value (not added to).
            let next = try ingestMetrics(
                counterMetric(name: "claude_code.active_time.total", sessionID: "sess-1", value: 900, asString: false),
                into: &accumulator
            )
            #expect(next.telemetryUpdates["sess-1"]?.activeTimeSeconds == 900)
        }

        @Test("lines_of_code.count splits added/removed by type (issue #598)")
        func linesOfCodeByType() throws {
            var accumulator = OTLPTelemetryAccumulator()
            let result = try ingestMetrics(linesMetric(sessionID: "sess-1", added: 120, removed: 30), into: &accumulator)
            let telemetry = try #require(result.telemetryUpdates["sess-1"])
            #expect(telemetry.linesAdded == 120)
            #expect(telemetry.linesRemoved == 30)
            #expect(result.milestones.isEmpty)
        }

        @Test("tool_result log events count one per event (issue #598)")
        func toolResultCounts() throws {
            var accumulator = OTLPTelemetryAccumulator()
            _ = try ingestLogs(toolResultLogs(sessionID: "sess-1", count: 3), into: &accumulator)
            #expect(accumulator.telemetry(for: "sess-1")?.toolInvocations == 3)
            // Subsequent events keep counting (per-event, not cumulative).
            _ = try ingestLogs(toolResultLogs(sessionID: "sess-1", count: 2), into: &accumulator)
            #expect(accumulator.telemetry(for: "sess-1")?.toolInvocations == 5)
        }

        @Test("api_request tokens and tool_result counts coexist on one snapshot (issue #598)")
        func tokensAndToolsCoexist() throws {
            var accumulator = OTLPTelemetryAccumulator()
            _ = try ingestLogs(
                apiRequestLogs(
                    sessionID: "sess-1", input: 100, output: 50, cacheRead: 0, cacheCreation: 0,
                    costUSD: 0.25, durationMs: 1_000, model: "claude-opus-4-8", intsAsStrings: true
                ),
                into: &accumulator
            )
            _ = try ingestLogs(toolResultLogs(sessionID: "sess-1", count: 4), into: &accumulator)
            let telemetry = try #require(accumulator.telemetry(for: "sess-1"))
            #expect(telemetry.tokensUsed == 150)
            #expect(telemetry.toolInvocations == 4)
        }
    }
#endif
