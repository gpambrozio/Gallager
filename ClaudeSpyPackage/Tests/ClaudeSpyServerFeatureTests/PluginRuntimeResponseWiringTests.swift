#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Proves the Mac↔iOS response-request wiring that
    /// `AppCoordinator.setupPluginRuntime()` / `setupConnectedViewerManager()`
    /// install:
    ///
    /// 1. A `PluginEvent.responseRequest` fanned out by the dispatcher's
    ///    `onOpenResponseRequest` / `onRetractResponseRequest` sinks reaches the
    ///    coordinator's `connectedViewerManager.sendAgentResponseRequestToAll`
    ///    forward (open carries the request; retract carries `nil`).
    /// 2. An inbound `AgentResponseSubmissionMessage` routes through the manager
    ///    callback into the owning core's `deliverResponse(sessionID:requestID:_:)`,
    ///    which drives delivery back to the host agent.
    ///
    /// Both use the exact closure shapes the coordinator wires, with recording
    /// stand-ins for the WebSocket send / host agent (`ConnectedViewer` itself
    /// needs a live relay + E2EE, so it isn't unit-testable in isolation).
    @Suite("PluginRuntimeResponseWiring")
    struct PluginRuntimeResponseWiringTests {
        // MARK: - Open / retract → iOS forward

        /// Stands in for `ConnectedViewerManager.sendAgentResponseRequestToAll`:
        /// records every (sessionId, pluginId, requestId, request) the dispatcher
        /// sinks would push to viewers. `request == nil` is a retract.
        private actor SendRecorder {
            struct Sent: Equatable {
                let sessionId: String
                let pluginId: String
                let requestId: String
                let request: AgentResponseRequest?
            }

            private(set) var sent: [Sent] = []

            func record(_ item: Sent) {
                sent.append(item)
            }
        }

        /// The dispatcher wired exactly as the coordinator wires its
        /// open/retract sinks — but the iOS forward is the recorder's
        /// `record(...)` (which is what `sendAgentResponseRequestToAll` does on
        /// the wire). Mirrors `setupPluginRuntime()`'s closure shape, including
        /// the `request: nil` retract.
        private func makeDispatcher(_ recorder: SendRecorder) -> PluginEventDispatcher {
            PluginEventDispatcher(
                onOpenResponseRequest: { pluginID, sessionID, requestID, request in
                    await recorder.record(.init(
                        sessionId: sessionID,
                        pluginId: pluginID,
                        requestId: requestID,
                        request: request
                    ))
                },
                onRetractResponseRequest: { pluginID, sessionID, requestID in
                    await recorder.record(.init(
                        sessionId: sessionID,
                        pluginId: pluginID,
                        requestId: requestID,
                        request: nil
                    ))
                }
            )
        }

        @Test("a responseRequest with a request forwards an open to viewers")
        func openResponseRequestForwards() async {
            let recorder = SendRecorder()
            let dispatcher = makeDispatcher(recorder)

            let request = AgentResponseRequest.prompt(PromptRequest(title: "Ask"))
            await dispatcher.dispatch(PluginEvent(
                pluginID: "echo",
                sessionID: "s1",
                responseRequest: ResponseRequestPayload(requestID: "r1", request: request)
            ))

            let sent = await recorder.sent
            #expect(sent == [
                .init(sessionId: "s1", pluginId: "echo", requestId: "r1", request: request),
            ])
        }

        @Test("a responseRequest with nil request forwards a retract (request == nil)")
        func retractResponseRequestForwards() async {
            let recorder = SendRecorder()
            let dispatcher = makeDispatcher(recorder)

            await dispatcher.dispatch(PluginEvent(
                pluginID: "echo",
                sessionID: "s1",
                responseRequest: ResponseRequestPayload(requestID: "r1", request: nil)
            ))

            let sent = await recorder.sent
            #expect(sent == [
                .init(sessionId: "s1", pluginId: "echo", requestId: "r1", request: nil),
            ])
        }

        // MARK: - Inbound submission → core.deliverResponse

        /// Records the host-agent delivery a core makes in response to
        /// `deliverResponse`, so a round-trip test can assert the submission
        /// reached the core AND that the core drove delivery.
        private actor RecordingHost: PluginHost {
            private(set) var sentText: [(sessionID: String, text: String)] = []
            private(set) var sentKeys: [(sessionID: String, keys: [PluginTmuxKey])] = []

            func setProjects(_: [AgentProject]) async { }
            func emit(_: PluginEvent) async { }
            func sendText(sessionID: String, _ text: String) async {
                sentText.append((sessionID, text))
            }

            func sendKeys(sessionID: String, _ keys: [PluginTmuxKey]) async {
                sentKeys.append((sessionID, keys))
            }

            func log(_: LogLine) async { }
        }

        @Test("an inbound submission routes to the owning core's deliverResponse")
        @MainActor
        func submissionRoutesToDeliverResponse() async {
            // Real registry + echo core + recording host: the same chain the
            // coordinator's onAgentResponseSubmission callback drives
            // (registry.core(pluginId)?.deliverResponse(...)).
            let registry = PluginRegistry()
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-resp-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let host = RecordingHost()
            let env = PluginEnv(
                pluginRoot: URL(fileURLWithPath: "/tmp/echo-root"),
                stateDir: tmp,
                appVersion: "1.0.0",
                settings: Data(),
                marketplaceSource: URL(fileURLWithPath: "/tmp/marketplace")
            )
            await registry.enable("echo", host: host, env: env)
            #expect(registry.core("echo") != nil)

            // The exact closure the coordinator installs on
            // ConnectedViewerManager.onAgentResponseSubmission.
            let onAgentResponseSubmission: @MainActor (AgentResponseSubmissionMessage) async -> Void = { submission in
                await registry.core(submission.pluginId)?.deliverResponse(
                    sessionID: submission.sessionId,
                    requestID: submission.requestId,
                    submission.response
                )
            }

            let submission = AgentResponseSubmissionMessage(
                pairId: "pair-1",
                sessionId: "%9",
                pluginId: "echo",
                requestId: "r1",
                response: .prompt(text: "hello agent")
            )
            await onAgentResponseSubmission(submission)

            // EchoPluginCore.deliverResponse(.prompt) → host.sendText.
            let calls = await host.sentText
            #expect(calls.count == 1)
            #expect(calls.first?.sessionID == "%9")
            #expect(calls.first?.text == "hello agent")
        }

        @Test("a submission for an unknown plugin is a no-op")
        @MainActor
        func submissionForUnknownPluginIsNoOp() async {
            let registry = PluginRegistry()

            // Nothing enabled → core lookup returns nil → no delivery, no crash.
            let onAgentResponseSubmission: @MainActor (AgentResponseSubmissionMessage) async -> Void = { submission in
                await registry.core(submission.pluginId)?.deliverResponse(
                    sessionID: submission.sessionId,
                    requestID: submission.requestId,
                    submission.response
                )
            }

            let submission = AgentResponseSubmissionMessage(
                pairId: "pair-1",
                sessionId: "%9",
                pluginId: "not-enabled",
                requestId: "r1",
                response: .prompt(text: "ignored")
            )
            await onAgentResponseSubmission(submission)

            #expect(registry.core("not-enabled") == nil)
        }
    }
#endif
