#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
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
            // Headline excludes both cache reads and writes: input(100) + output(50).
            #expect(telemetry.tokensUsed == 150)
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

        // MARK: - Codex (issue #602)

        /// Builds a Codex `codex.sse_event` / `response.completed` log carrying
        /// token counts, joined by `conversation.id` (Codex's key, not `session.id`).
        /// Models codex-rs's `sse_event_completed` attributes verbatim.
        private func codexSseCompletedLogs(
            conversationID: String,
            inputTokenCount: Int,
            outputTokenCount: Int,
            cachedTokenCount: Int,
            reasoningTokenCount: Int = 0,
            model: String,
            kind: String = "response.completed",
            intsAsStrings: Bool = false
        ) -> String {
            func intValue(_ value: Int) -> String {
                intsAsStrings ? "{\"intValue\": \"\(value)\"}" : "{\"intValue\": \(value)}"
            }
            // Faithful to real Codex 0.140: the top-level `eventName` field is a
            // Rust source location (NOT the event name), the real name lives only
            // in the `event.name` attribute, there is no string body, and
            // `input/output_token_count` arrive as OTLP `stringValue` (while
            // `cached_token_count` is `intValue`) — all #602.
            return """
            {
              "resourceLogs": [{
                "scopeLogs": [{
                  "logRecords": [{
                    "eventName": "event otel/src/events/session_telemetry.rs:925",
                    "attributes": [
                      {"key": "event.name", "value": {"stringValue": "codex.sse_event"}},
                      {"key": "event.kind", "value": {"stringValue": "\(kind)"}},
                      {"key": "conversation.id", "value": {"stringValue": "\(conversationID)"}},
                      {"key": "model", "value": {"stringValue": "\(model)"}},
                      {"key": "input_token_count", "value": {"stringValue": "\(inputTokenCount)"}},
                      {"key": "output_token_count", "value": {"stringValue": "\(outputTokenCount)"}},
                      {"key": "cached_token_count", "value": \(intValue(cachedTokenCount))},
                      {"key": "reasoning_token_count", "value": \(intValue(reasoningTokenCount))},
                      {"key": "tool_token_count", "value": \(intValue(0))}
                    ]
                  }]
                }]
              }]
            }
            """
        }

        /// Builds a Codex `codex.turn_ttft` log (per-turn latency only — no token
        /// counts), joined by `conversation.id`. This is the real per-turn latency
        /// source: unlike `codex.api_request` (the `/models` capability check, which
        /// carries no `conversation.id`), `turn_ttft` carries the join key. Uses the
        /// newer top-level `eventName` field.
        private func codexTurnTtftLogs(conversationID: String, durationMs: Int) -> String {
            // Faithful to real Codex 0.140: top-level `eventName` is a source
            // location; the real name is in the `event.name` attribute (#602).
            """
            {
              "resourceLogs": [{
                "scopeLogs": [{
                  "logRecords": [{
                    "eventName": "event otel/src/events/session_telemetry.rs:640",
                    "attributes": [
                      {"key": "event.name", "value": {"stringValue": "codex.turn_ttft"}},
                      {"key": "conversation.id", "value": {"stringValue": "\(conversationID)"}},
                      {"key": "duration_ms", "value": {"intValue": "\(durationMs)"}},
                      {"key": "model", "value": {"stringValue": "gpt-5-codex"}}
                    ]
                  }]
                }]
              }]
            }
            """
        }

        @Test("Codex sse_event records fresh tokens, excludes the cached re-read, emits no cost")
        func codexSseAccumulatesTokens() throws {
            var accumulator = OTLPTelemetryAccumulator()
            let result = try ingestLogs(
                codexSseCompletedLogs(
                    conversationID: "conv-1", inputTokenCount: 1_000, outputTokenCount: 200,
                    cachedTokenCount: 300, model: "gpt-5-codex"
                ),
                into: &accumulator
            )
            let telemetry = try #require(result.telemetryUpdates["conv-1"])
            // First event for the session, so the delta == the raw counts. `cached`
            // (300) is nested inside `input` (1000), so fresh input is 700. The
            // headline excludes the cached re-read (the #597 exclusion): fresh
            // input(700) + output(200) = 900, not the 1200 that would re-count the
            // per-turn cached context.
            #expect(telemetry.inputTokens == 700)
            #expect(telemetry.cacheReadTokens == 300)
            #expect(telemetry.outputTokens == 200)
            #expect(telemetry.cacheCreationTokens == 0)
            #expect(telemetry.tokensUsed == 900)
            #expect(telemetry.costUSD == 0) // Codex emits no cost
            #expect(telemetry.model == "gpt-5-codex")
            #expect(telemetry.lastTurnLatencyMs == nil) // latency rides codex.api_request
            #expect(telemetry.recentTurns.count == 1)
            #expect(telemetry.recentTurns.last?.latencyMs == nil)
        }

        @Test("Codex cumulative per-call token counts accumulate as deltas, not summed (no over-count)")
        func codexCumulativeTokensUseDeltas() throws {
            var accumulator = OTLPTelemetryAccumulator()
            // A single user turn with tool use fires several `response.completed`
            // events whose `input_token_count` / `cached_token_count` are
            // CUMULATIVE — each model call re-sends the whole growing conversation
            // context (confirmed against live Codex 0.140, issue #602). The
            // accumulator must add only the per-event delta; summing the raw
            // per-call input would multiply-count the same context.
            // (input, output, cached) per call, input/cached climbing monotonically:
            let calls = [
                (input: 1_000, output: 100, cached: 0),
                (input: 1_500, output: 50, cached: 400),
                (input: 1_600, output: 20, cached: 1_550),
            ]
            var last: OTLPProcessingResult?
            for call in calls {
                last = try ingestLogs(
                    codexSseCompletedLogs(
                        conversationID: "conv-1", inputTokenCount: call.input,
                        outputTokenCount: call.output, cachedTokenCount: call.cached,
                        model: "gpt-5-codex"
                    ),
                    into: &accumulator
                )
            }
            let telemetry = try #require(last?.telemetryUpdates["conv-1"])
            // Fresh-input deltas (inputDelta − cachedDelta, floored at 0):
            //   1000 + (500−400) + max(0, 100−1150) = 1000 + 100 + 0 = 1100
            #expect(telemetry.inputTokens == 1_100)
            // Output is per-call, summed: 100 + 50 + 20 = 170.
            #expect(telemetry.outputTokens == 170)
            // Cache-read deltas: 0 + 400 + 1150 = 1550 (the final cumulative cache).
            #expect(telemetry.cacheReadTokens == 1_550)
            // Headline excludes cache reads: 1100 + 170 = 1270 — NOT the 2320 a
            // naive per-event sum of (input−cached)+output would report.
            #expect(telemetry.tokensUsed == 1_270)
        }

        @Test("Codex tokens decode as proto3 int-as-string too")
        func codexSseStringInts() throws {
            var accumulator = OTLPTelemetryAccumulator()
            let result = try ingestLogs(
                codexSseCompletedLogs(
                    conversationID: "conv-1", inputTokenCount: 50, outputTokenCount: 25,
                    cachedTokenCount: 0, model: "gpt-5-codex", intsAsStrings: true
                ),
                into: &accumulator
            )
            let telemetry = try #require(result.telemetryUpdates["conv-1"])
            #expect(telemetry.tokensUsed == 75)
        }

        @Test("Codex turn_ttft stamps latency and back-fills the token turn's sample")
        func codexTurnTtftRecordsLatency() throws {
            var accumulator = OTLPTelemetryAccumulator()
            // Per-turn ordering: tokens (sse_event) then time-to-first-token (turn_ttft).
            _ = try ingestLogs(
                codexSseCompletedLogs(
                    conversationID: "conv-1", inputTokenCount: 100, outputTokenCount: 50,
                    cachedTokenCount: 0, model: "gpt-5-codex"
                ),
                into: &accumulator
            )
            let result = try ingestLogs(
                codexTurnTtftLogs(conversationID: "conv-1", durationMs: 1_500),
                into: &accumulator
            )
            let telemetry = try #require(result.telemetryUpdates["conv-1"])
            #expect(telemetry.lastTurnLatencyMs == 1_500)
            #expect(telemetry.tokensUsed == 150) // unchanged by the latency event
            #expect(telemetry.recentTurns.count == 1)
            #expect(telemetry.recentTurns.last?.latencyMs == 1_500) // back-filled
        }

        @Test("Codex sse_event without response.completed kind carries no tokens")
        func codexSseIgnoresNonCompletedKind() throws {
            var accumulator = OTLPTelemetryAccumulator()
            let result = try ingestLogs(
                codexSseCompletedLogs(
                    conversationID: "conv-1", inputTokenCount: 100, outputTokenCount: 50,
                    cachedTokenCount: 0, model: "gpt-5-codex", kind: "response.output_item.done"
                ),
                into: &accumulator
            )
            #expect(result.isEmpty)
        }

        @Test("Codex record whose top-level eventName is a source location still classifies via event.name")
        func codexSourceLocationEventNameField() throws {
            // Real Codex 0.140 fills the top-level `eventName` field with a Rust
            // source location, not the event name — the name is only in the
            // `event.name` attribute. Trusting the field would drop every Codex
            // record (the #602 "no meter" bug); classification must fall through
            // to the attribute.
            var accumulator = OTLPTelemetryAccumulator()
            let json = """
            {
              "resourceLogs": [{
                "scopeLogs": [{
                  "logRecords": [{
                    "eventName": "event otel/src/events/session_telemetry.rs:925",
                    "attributes": [
                      {"key": "event.name", "value": {"stringValue": "codex.sse_event"}},
                      {"key": "event.kind", "value": {"stringValue": "response.completed"}},
                      {"key": "conversation.id", "value": {"stringValue": "conv-1"}},
                      {"key": "model", "value": {"stringValue": "gpt-5.5"}},
                      {"key": "input_token_count", "value": {"stringValue": "1000"}},
                      {"key": "output_token_count", "value": {"stringValue": "200"}},
                      {"key": "cached_token_count", "value": {"intValue": "0"}}
                    ]
                  }]
                }]
              }]
            }
            """
            let result = try ingestLogs(json, into: &accumulator)
            let telemetry = try #require(result.telemetryUpdates["conv-1"])
            #expect(telemetry.tokensUsed == 1_200)
            #expect(telemetry.model == "gpt-5.5")
        }

        @Test("A Codex event lacking conversation.id is ignored")
        func codexMissingConversationIDIgnored() throws {
            var accumulator = OTLPTelemetryAccumulator()
            // session.id is Claude's key; a Codex event must carry conversation.id.
            let json = """
            {
              "resourceLogs": [{
                "scopeLogs": [{
                  "logRecords": [{
                    "eventName": "codex.sse_event",
                    "attributes": [
                      {"key": "event.kind", "value": {"stringValue": "response.completed"}},
                      {"key": "session.id", "value": {"stringValue": "sess-1"}},
                      {"key": "input_token_count", "value": {"intValue": "100"}}
                    ]
                  }]
                }]
              }]
            }
            """
            let result = try ingestLogs(json, into: &accumulator)
            #expect(result.isEmpty)
        }

        @Test("Claude and Codex sessions accumulate independently on one receiver")
        func claudeAndCodexCoexist() throws {
            var accumulator = OTLPTelemetryAccumulator()
            _ = try ingestLogs(
                apiRequestLogs(
                    sessionID: "claude-1", input: 100, output: 50, cacheRead: 0, cacheCreation: 0,
                    costUSD: 0.25, durationMs: 900, model: "claude-opus-4-8", intsAsStrings: true
                ),
                into: &accumulator
            )
            _ = try ingestLogs(
                codexSseCompletedLogs(
                    conversationID: "codex-1", inputTokenCount: 80, outputTokenCount: 20,
                    cachedTokenCount: 0, model: "gpt-5-codex"
                ),
                into: &accumulator
            )
            let claude = try #require(accumulator.telemetry(for: "claude-1"))
            let codex = try #require(accumulator.telemetry(for: "codex-1"))
            #expect(claude.tokensUsed == 150)
            #expect(claude.costUSD == 0.25)
            #expect(codex.tokensUsed == 100)
            #expect(codex.costUSD == 0)
        }

        // MARK: - Declared plugin namespaces (issue #617)

        /// Builds a log payload the way the opencode bridge emits it (issue
        /// #617): fully-qualified name in both the `event.name` attribute and
        /// the top-level `eventName` field, Claude's exact attribute keys, ints
        /// as JSON numbers, and the tmux pane id in `session.id`.
        private func declaredNamespaceLogs(
            eventName: String,
            sessionID: String,
            input: Int,
            output: Int,
            cacheRead: Int = 0,
            cacheCreation: Int = 0,
            costUSD: Double = 0,
            durationMs: Int = 0,
            model: String = "claude-sonnet-5"
        ) -> String {
            """
            {
              "resourceLogs": [{
                "scopeLogs": [{
                  "logRecords": [{
                    "eventName": "\(eventName)",
                    "attributes": [
                      {"key": "event.name", "value": {"stringValue": "\(eventName)"}},
                      {"key": "session.id", "value": {"stringValue": "\(sessionID)"}},
                      {"key": "input_tokens", "value": {"intValue": \(input)}},
                      {"key": "output_tokens", "value": {"intValue": \(output)}},
                      {"key": "cache_read_tokens", "value": {"intValue": \(cacheRead)}},
                      {"key": "cache_creation_tokens", "value": {"intValue": \(cacheCreation)}},
                      {"key": "cost_usd", "value": {"doubleValue": \(costUSD)}},
                      {"key": "duration_ms", "value": {"intValue": \(durationMs)}},
                      {"key": "model", "value": {"stringValue": "\(model)"}}
                    ]
                  }]
                }]
              }]
            }
            """
        }

        @Test("A declared namespace's token event accumulates like Claude's api_request (issue #617)")
        func declaredNamespaceAccumulates() throws {
            var accumulator = OTLPTelemetryAccumulator()
            accumulator.setPluginNamespaces([PluginManifest.OTLP(namespace: "opencode")])
            let first = try ingestLogs(
                declaredNamespaceLogs(
                    eventName: "opencode.api_request", sessionID: "%3",
                    input: 1_234, output: 567, cacheRead: 11, cacheCreation: 22,
                    costUSD: 0.0_123, durationMs: 4_200
                ),
                into: &accumulator
            )
            let telemetry = try #require(first.telemetryUpdates["%3"])
            #expect(telemetry.inputTokens == 1_234)
            #expect(telemetry.outputTokens == 567)
            #expect(telemetry.cacheReadTokens == 11)
            #expect(telemetry.cacheCreationTokens == 22)
            #expect(telemetry.costUSD == 0.0_123)
            #expect(telemetry.lastTurnLatencyMs == 4_200)
            #expect(telemetry.model == "claude-sonnet-5")

            // Per-message emission is ADDITIVE (Claude semantics, not Codex's
            // cumulative deltas): a second message sums onto the first.
            let second = try ingestLogs(
                declaredNamespaceLogs(
                    eventName: "opencode.api_request", sessionID: "%3",
                    input: 100, output: 50, costUSD: 0.001, durationMs: 800
                ),
                into: &accumulator
            )
            let updated = try #require(second.telemetryUpdates["%3"])
            #expect(updated.inputTokens == 1_334)
            #expect(updated.outputTokens == 617)
            #expect(updated.costUSD == 0.0_123 + 0.001)
            #expect(updated.lastTurnLatencyMs == 800)
        }

        @Test("An undeclared namespace stays dropped; the table applies and clears at runtime")
        func namespaceTableAppliesAndClears() throws {
            var accumulator = OTLPTelemetryAccumulator()
            let record = declaredNamespaceLogs(
                eventName: "opencode.api_request", sessionID: "%3", input: 10, output: 5
            )
            // No declaration → unclassified → dropped (the pre-#617 behavior).
            #expect(try ingestLogs(record, into: &accumulator).isEmpty)

            accumulator.setPluginNamespaces([PluginManifest.OTLP(namespace: "opencode")])
            #expect(try ingestLogs(record, into: &accumulator).telemetryUpdates["%3"] != nil)

            // Plugin disabled → table replaced without it → dropped again.
            accumulator.setPluginNamespaces([])
            #expect(try ingestLogs(record, into: &accumulator).isEmpty)
        }

        @Test("A declared namespace only recognizes its declared token event")
        func declaredNamespaceIgnoresOtherEvents() throws {
            var accumulator = OTLPTelemetryAccumulator()
            accumulator.setPluginNamespaces(
                [PluginManifest.OTLP(namespace: "myagent", tokenEvent: "turn_metrics")]
            )
            // The declared (custom-named) token event classifies and accumulates…
            let matched = try ingestLogs(
                declaredNamespaceLogs(eventName: "myagent.turn_metrics", sessionID: "s1", input: 10, output: 5),
                into: &accumulator
            )
            #expect(matched.telemetryUpdates["s1"]?.tokensUsed == 15)
            // …while other events in the namespace are ignored.
            let unmatched = try ingestLogs(
                declaredNamespaceLogs(eventName: "myagent.api_request", sessionID: "s1", input: 99, output: 99),
                into: &accumulator
            )
            #expect(unmatched.isEmpty)
        }

        @Test("Built-in namespaces cannot be claimed by a declaration; a trailing dot is tolerated")
        func builtInNamespacesProtected() throws {
            var accumulator = OTLPTelemetryAccumulator()
            // A hostile/buggy manifest declaring the built-ins (with a bogus token
            // event) — exactly OR nested under them — must not disturb Claude
            // processing; "opencode." normalizes; empty fields are dropped.
            accumulator.setPluginNamespaces([
                PluginManifest.OTLP(namespace: "claude_code", tokenEvent: "bogus"),
                PluginManifest.OTLP(namespace: "claude_code.myext", tokenEvent: "bogus"),
                PluginManifest.OTLP(namespace: "codex.", tokenEvent: "bogus"),
                PluginManifest.OTLP(namespace: "opencode."),
                PluginManifest.OTLP(namespace: ""),
                PluginManifest.OTLP(namespace: "emptytoken", tokenEvent: ""),
            ])
            let claude = try ingestLogs(
                apiRequestLogs(
                    sessionID: "claude-1", input: 100, output: 50, cacheRead: 0, cacheCreation: 0,
                    costUSD: 0.25, durationMs: 900, model: "claude-opus-4-8", intsAsStrings: false
                ),
                into: &accumulator
            )
            #expect(claude.telemetryUpdates["claude-1"]?.tokensUsed == 150)
            let opencode = try ingestLogs(
                declaredNamespaceLogs(eventName: "opencode.api_request", sessionID: "%9", input: 7, output: 3),
                into: &accumulator
            )
            #expect(opencode.telemetryUpdates["%9"]?.tokensUsed == 10)
            // An empty token_event declaration is dropped, not stored as "" —
            // a record named exactly "emptytoken." must not accumulate.
            let emptyToken = try ingestLogs(
                declaredNamespaceLogs(eventName: "emptytoken.", sessionID: "s-empty", input: 9, output: 9),
                into: &accumulator
            )
            #expect(emptyToken.isEmpty)
        }

        @Test("Overlapping declared namespaces: the longest matching prefix wins, deterministically")
        func overlappingNamespacesLongestPrefixWins() throws {
            var accumulator = OTLPTelemetryAccumulator()
            accumulator.setPluginNamespaces([
                PluginManifest.OTLP(namespace: "acme"),
                PluginManifest.OTLP(namespace: "acme.sub"),
            ])
            // A record in the NESTED namespace must classify as `acme.sub.` on
            // every launch — matching the shorter `acme.` would strip to
            // "sub.api_request", fail the token-event guard, and drop the
            // record (the pre-fix behavior varied with Dictionary order).
            let nested = try ingestLogs(
                declaredNamespaceLogs(eventName: "acme.sub.api_request", sessionID: "s-sub", input: 10, output: 5),
                into: &accumulator
            )
            #expect(nested.telemetryUpdates["s-sub"]?.tokensUsed == 15)
            // The outer namespace still classifies its own records.
            let outer = try ingestLogs(
                declaredNamespaceLogs(eventName: "acme.api_request", sessionID: "s-outer", input: 1, output: 2),
                into: &accumulator
            )
            #expect(outer.telemetryUpdates["s-outer"]?.tokensUsed == 3)
        }

        @Test("Duplicate declared namespaces resolve first-write-wins")
        func duplicateNamespacesFirstWriteWins() throws {
            var accumulator = OTLPTelemetryAccumulator()
            // Two plugins claiming one namespace: the first declaration in the
            // array wins (the app passes declarations sorted by plugin id and
            // logs the conflict), so resolution never depends on Dictionary
            // iteration order.
            accumulator.setPluginNamespaces([
                PluginManifest.OTLP(namespace: "acme", tokenEvent: "api_request"),
                PluginManifest.OTLP(namespace: "acme", tokenEvent: "other_event"),
            ])
            let winner = try ingestLogs(
                declaredNamespaceLogs(eventName: "acme.api_request", sessionID: "s1", input: 10, output: 5),
                into: &accumulator
            )
            #expect(winner.telemetryUpdates["s1"]?.tokensUsed == 15)
            let loser = try ingestLogs(
                declaredNamespaceLogs(eventName: "acme.other_event", sessionID: "s1", input: 99, output: 99),
                into: &accumulator
            )
            #expect(loser.isEmpty)
        }

        @Test("Codex records still classify with plugin mappings present")
        func codexCoexistsWithDeclaredNamespaces() throws {
            var accumulator = OTLPTelemetryAccumulator()
            accumulator.setPluginNamespaces([PluginManifest.OTLP(namespace: "opencode")])
            _ = try ingestLogs(
                codexSseCompletedLogs(
                    conversationID: "codex-1", inputTokenCount: 80, outputTokenCount: 20,
                    cachedTokenCount: 0, model: "gpt-5-codex"
                ),
                into: &accumulator
            )
            #expect(accumulator.telemetry(for: "codex-1")?.tokensUsed == 100)
        }

        @Test("evict drops a declared-namespace session like any other")
        func declaredNamespaceEvicts() throws {
            var accumulator = OTLPTelemetryAccumulator()
            accumulator.setPluginNamespaces([PluginManifest.OTLP(namespace: "opencode")])
            _ = try ingestLogs(
                declaredNamespaceLogs(eventName: "opencode.api_request", sessionID: "%3", input: 10, output: 5),
                into: &accumulator
            )
            #expect(accumulator.telemetry(for: "%3") != nil)
            accumulator.evict(sessionID: "%3")
            #expect(accumulator.telemetry(for: "%3") == nil)
        }
    }
#endif
