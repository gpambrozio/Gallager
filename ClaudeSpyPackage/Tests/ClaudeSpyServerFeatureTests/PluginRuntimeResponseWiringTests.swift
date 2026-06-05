#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Proves the Mac↔iOS response wiring that
    /// `AppCoordinator.setupPluginRuntime()` / `setupConnectedViewerManager()`
    /// install:
    ///
    /// 1. An `awaiting*` `PluginEvent.state` reaches the dispatcher's single
    ///    `onState` sink (which the coordinator wires to `applyState` + the
    ///    `agent_session_status` forward, so the open form rides the snapshot).
    ///    An auto-approvable permission on a yolo pane instead reaches
    ///    `onAutoApprove` and the session is kept `.working`.
    /// 2. An inbound `AgentResponseSubmissionMessage` routes through the manager
    ///    callback into the owning core's `deliverResponse(sessionID:requestID:_:)`,
    ///    which drives delivery back to the host agent.
    @Suite("PluginRuntimeResponseWiring")
    struct PluginRuntimeResponseWiringTests {
        // MARK: - State / auto-approve sinks

        /// Records the (sessionID, state) every `onState` fan-out and the
        /// (sessionID, requestID) of every `onAutoApprove` so a test can assert
        /// the single-sink + yolo path.
        private actor StateRecorder {
            private(set) var states: [(sid: String, state: AgentState)] = []
            private(set) var approvals: [(sid: String, rid: String)] = []

            func recordState(_ sid: String, _ state: AgentState) {
                states.append((sid, state))
            }

            func recordApproval(_ sid: String, _ rid: String) {
                approvals.append((sid, rid))
            }

            func lastState(for sid: String) -> AgentState? {
                states.last(where: { $0.sid == sid })?.state
            }
        }

        private func makeDispatcher(_ recorder: StateRecorder, yolo: Bool) -> PluginEventDispatcher {
            PluginEventDispatcher(
                onState: { _, sid, state, _, _ in await recorder.recordState(sid, state) },
                onAutoApprove: { _, sid, rid in await recorder.recordApproval(sid, rid) },
                isYoloModeEnabled: { _ in yolo }
            )
        }

        @Test("an awaiting state reaches onState")
        func awaitingStateReachesOnState() async {
            let recorder = StateRecorder()
            let dispatcher = makeDispatcher(recorder, yolo: false)

            let state = AgentState.awaitingReplies(
                AskUserQuestionRequest(questions: []), requestID: "r1"
            )
            await dispatcher.dispatch(PluginEvent(
                pluginID: "echo",
                sessionID: "s1",
                state: state,
                tmuxPane: "%1"
            ))

            #expect(await recorder.lastState(for: "s1") == state)
            #expect(await recorder.approvals.isEmpty)
        }

        @Test("a yolo permission auto-approves and stays working")
        func yoloPermissionAutoApprovesStaysWorking() async {
            let recorder = StateRecorder()
            let dispatcher = makeDispatcher(recorder, yolo: true)

            await dispatcher.dispatch(PluginEvent(
                pluginID: "echo",
                sessionID: "s1",
                state: .awaitingPermission(
                    PermissionRequest(title: "Bash", description: "ls", isAutoApprovable: true),
                    requestID: "r1"
                ),
                tmuxPane: "%1"
            ))

            // Auto-approve fired keyed by the pane; the session was kept working.
            let approvals = await recorder.approvals
            #expect(approvals.count == 1)
            #expect(approvals.first?.sid == "%1")
            #expect(approvals.first?.rid == "r1")
            #expect(await recorder.lastState(for: "s1") == .working)
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
