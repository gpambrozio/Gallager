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
            // Headline excludes cache reads: input(100) + output(50) + cache write(5).
            #expect(telemetry.tokensUsed == 155)
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
    }
#endif
