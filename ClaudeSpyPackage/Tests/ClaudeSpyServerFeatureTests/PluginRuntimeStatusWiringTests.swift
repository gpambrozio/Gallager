#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import Darwin
    import Dependencies
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Proves the status-sink wiring that `AppCoordinator.setupPluginRuntime()`
    /// installs: a `PluginEvent`'s working/attention fields, fanned out by
    /// `PluginEventDispatcher.onStatus`, land on a pane's `AgentSession` /
    /// `cliSessionState` via `MirrorWindowManager.applyPluginStatus`. The second
    /// test drives the full ingress path (socket → `EchoPluginCore` → dispatcher
    /// → sink) so the exact closure shape the coordinator uses is exercised.
    @MainActor
    @Suite("PluginRuntimeStatusWiring")
    struct PluginRuntimeStatusWiringTests {
        // MARK: - Helpers

        /// A `MirrorWindowManager` built with throwaway collaborators. The status
        /// path only mutates `paneStates`, so the tmux/stream collaborators are
        /// never actually driven. Construction happens inside `withDependencies`
        /// because `AppSettings`/`TmuxService`/`MirrorWindowManager` resolve
        /// `@Dependency` services (PreferencesService, ProcessRunner, …) at init
        /// time; the in-memory/preview values keep the build hermetic.
        private func makeWindowManager() -> MirrorWindowManager {
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[ProcessRunner.self] = .previewValue
                $0[LoginItemService.self] = .previewValue
            } operation: {
                let tmux = TmuxService()
                let control = TmuxControlClientManager()
                let streams = PaneStreamManager(tmuxService: tmux, controlClientManager: control)
                return MirrorWindowManager(
                    settings: AppSettings(),
                    tmuxService: tmux,
                    paneStreamManager: streams,
                    editorSessionManager: EditorSessionManager()
                )
            }
        }

        /// The dispatcher wired exactly as `AppCoordinator.setupPluginRuntime`
        /// wires its status sink (the other sinks are irrelevant here).
        private func makeDispatcher(_ windowManager: MirrorWindowManager) -> PluginEventDispatcher {
            PluginEventDispatcher(
                onStatus: { pluginID, sessionID, working, attention, opensBlockingForm, tmuxPane, projectPath in
                    await windowManager.applyPluginStatus(
                        pluginID: pluginID,
                        sessionID: sessionID,
                        working: working,
                        attention: attention,
                        opensBlockingForm: opensBlockingForm,
                        tmuxPane: tmuxPane,
                        projectPath: projectPath
                    )
                }
            )
        }

        /// The dispatcher wired with BOTH the status and app-action sinks the way
        /// `AppCoordinator.setupPluginRuntime` does — the status sink updates the
        /// session, the app-action sink ends it on `.sessionEnded`. Lets a test
        /// drive a full SessionEnd envelope and assert the status-then-app-action
        /// ordering clears the session rather than leaving it resurrected.
        private func makeStatusAndAppActionDispatcher(_ windowManager: MirrorWindowManager) -> PluginEventDispatcher {
            PluginEventDispatcher(
                onStatus: { pluginID, sessionID, working, attention, opensBlockingForm, tmuxPane, projectPath in
                    await windowManager.applyPluginStatus(
                        pluginID: pluginID,
                        sessionID: sessionID,
                        working: working,
                        attention: attention,
                        opensBlockingForm: opensBlockingForm,
                        tmuxPane: tmuxPane,
                        projectPath: projectPath
                    )
                },
                onAppAction: { action in
                    if case let .sessionEnded(sessionID, _) = action {
                        await windowManager.endAgentSession(forPane: sessionID)
                    }
                }
            )
        }

        private func makeSocketPath() -> String {
            "\(NSTemporaryDirectory())gsw-\(UUID().uuidString.prefix(8)).sock"
        }

        @discardableResult
        private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
            data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, base + offset, raw.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
        }

        private func connectClient(to path: String, deadline: Date) -> Int32? {
            while Date() < deadline {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { return nil }
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                path.withCString { ptr in
                    withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                        UnsafeMutableRawPointer(sunPath).copyMemory(from: ptr, byteCount: path.utf8.count + 1)
                    }
                }
                let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let result = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        connect(fd, sockPtr, addrLen)
                    }
                }
                if result == 0 { return fd }
                close(fd)
                usleep(20_000)
            }
            return nil
        }

        /// Poll `paneStates[paneId]` until it gains a Claude session or the
        /// deadline passes. The socket read runs on a real background queue, so
        /// there is no virtual clock to advance — a sanctioned `Task.sleep` poll.
        private func waitForSession(
            _ windowManager: MirrorWindowManager,
            paneId: String
        ) async -> PaneState? {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let state = windowManager.paneStates[paneId], state.agentSession != nil {
                    return state
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return windowManager.paneStates[paneId]
        }

        // MARK: - Direct mapping

        @Test("working/attention set the session status Bools directly; attention wins")
        func applyPluginStatusMapping() {
            let windowManager = makeWindowManager()

            // working=true → session created, isWorking=true
            windowManager.applyPluginStatus(
                pluginID: "echo",
                sessionID: "s1",
                working: true,
                attention: false,
                tmuxPane: "%7",
                projectPath: "/tmp/proj"
            )
            #expect(windowManager.paneStates["%7"]?.agentSession != nil)
            #expect(windowManager.paneStates["%7"]?.agentSession?.isWorking == true)
            #expect(windowManager.paneStates["%7"]?.agentSession?.needsAttention == false)
            #expect(windowManager.paneStates["%7"]?.agentSession?.detectedProjectPath == "/tmp/proj")
            #expect(windowManager.paneStates["%7"]?.agentSession?.pluginID == "echo")

            // attention=true → needsAttention set (working still true here)
            windowManager.applyPluginStatus(
                pluginID: "echo",
                sessionID: "s1",
                working: true,
                attention: true,
                tmuxPane: "%7",
                projectPath: nil
            )
            #expect(windowManager.paneStates["%7"]?.agentSession?.needsAttention == true)

            // working=false, no attention → isWorking false, attention cleared
            windowManager.applyPluginStatus(
                pluginID: "echo",
                sessionID: "s1",
                working: false,
                attention: false,
                tmuxPane: "%7",
                projectPath: nil
            )
            #expect(windowManager.paneStates["%7"]?.agentSession?.isWorking == false)
            #expect(windowManager.paneStates["%7"]?.agentSession?.needsAttention == false)

            // no opinion (working nil) → isWorking left unchanged, session kept
            windowManager.applyPluginStatus(
                pluginID: "echo",
                sessionID: "s1",
                working: nil,
                attention: false,
                tmuxPane: "%7",
                projectPath: nil
            )
            #expect(windowManager.paneStates["%7"]?.agentSession != nil)
            #expect(windowManager.paneStates["%7"]?.agentSession?.isWorking == false)
        }

        @Test("a blocking-form attention survives mark-handled-on-view; a Stop-like one clears")
        func blockingFormGuardsAttentionAgainstViewing() {
            let windowManager = makeWindowManager()

            // AskUserQuestion / permission / plan: working + attention + opensBlockingForm.
            // The guard must be set atomically here so a later view/mark-handled can't clear it.
            windowManager.applyPluginStatus(
                pluginID: "echo",
                sessionID: "ask",
                working: true,
                attention: true,
                opensBlockingForm: true,
                tmuxPane: "%1",
                projectPath: nil
            )
            #expect(windowManager.paneStates["%1"]?.agentSession?.needsAttention == true)
            // Viewing the session would mark it handled — the open form must keep attention.
            windowManager.markSessionHandled(paneId: "%1")
            #expect(windowManager.paneStates["%1"]?.agentSession?.needsAttention == true)

            // Stop-like: attention with NO blocking form → viewing clears it (matches legacy).
            windowManager.applyPluginStatus(
                pluginID: "echo",
                sessionID: "stop",
                working: false,
                attention: true,
                opensBlockingForm: false,
                tmuxPane: "%2",
                projectPath: nil
            )
            #expect(windowManager.paneStates["%2"]?.agentSession?.needsAttention == true)
            windowManager.markSessionHandled(paneId: "%2")
            #expect(windowManager.paneStates["%2"]?.agentSession?.needsAttention == false)

            // The agent advances past the question (plain working event, no form): guard lifts,
            // so a subsequent mark-handled can clear attention again.
            windowManager.applyPluginStatus(
                pluginID: "echo",
                sessionID: "ask",
                working: true,
                attention: true,
                opensBlockingForm: false,
                tmuxPane: "%1",
                projectPath: nil
            )
            windowManager.markSessionHandled(paneId: "%1")
            #expect(windowManager.paneStates["%1"]?.agentSession?.needsAttention == false)
        }

        // MARK: - Session end

        @Test("endAgentSession removes the session and no-ops when there is none")
        func endAgentSessionDirect() {
            let windowManager = makeWindowManager()

            // An idle session on the pane (SessionEnd maps working=false).
            windowManager.applyPluginStatus(
                pluginID: "echo",
                sessionID: "s1",
                working: false,
                attention: false,
                tmuxPane: "%5",
                projectPath: nil
            )
            #expect(windowManager.paneStates["%5"]?.agentSession != nil)

            #expect(windowManager.endAgentSession(forPane: "%5") == true)
            #expect(windowManager.paneStates["%5"]?.agentSession == nil)
            #expect(!windowManager.activeSessionPaneIds.contains("%5"))

            // Already cleared, and an unknown pane → no change.
            #expect(windowManager.endAgentSession(forPane: "%5") == false)
            #expect(windowManager.endAgentSession(forPane: "%nope") == false)
        }

        @Test("the host retains open response forms for the connect snapshot, and clears them")
        func retainsOpenResponseFormsForSnapshot() {
            let windowManager = makeWindowManager()

            // A live session on the pane (so endAgentSession has something to end).
            windowManager.applyPluginStatus(
                pluginID: "claude-code",
                sessionID: "s1",
                working: true,
                attention: false,
                tmuxPane: "%5",
                projectPath: "/tmp/p"
            )

            let form = PaneOpenResponseRequest(
                sessionId: "%5",
                pluginId: "claude-code",
                requestId: "%5:AskUserQuestion",
                request: .askUserQuestion(AskUserQuestionRequest(questions: [
                    .init(
                        id: "q1",
                        question: "Which?",
                        header: "Pick",
                        options: [.init(id: "a", label: "A", description: "first")],
                        multiSelect: false
                    ),
                ]))
            )

            // Open: the form is exposed for the catch-up snapshot.
            windowManager.setOpenResponseRequest(form, for: "%5")
            #expect(windowManager.openResponseRequests == [form])

            // Retract: it stops riding the snapshot.
            windowManager.setOpenResponseRequest(nil, for: "%5")
            #expect(windowManager.openResponseRequests.isEmpty)

            // A session end also drops any still-open form (the form is moot once
            // the agent is gone).
            windowManager.setOpenResponseRequest(form, for: "%5")
            #expect(windowManager.endAgentSession(forPane: "%5") == true)
            #expect(windowManager.openResponseRequests.isEmpty)
        }

        @Test("a working tick drops a retained form so the snapshot can't resurrect it")
        func workingStatusClearsRetainedForm() {
            let windowManager = makeWindowManager()

            windowManager.applyPluginStatus(
                pluginID: "claude-code",
                sessionID: "s1",
                working: false,
                attention: true,
                tmuxPane: "%5",
                projectPath: "/tmp/p"
            )
            windowManager.setOpenResponseRequest(
                PaneOpenResponseRequest(
                    sessionId: "%5",
                    pluginId: "claude-code",
                    requestId: "%5:r1",
                    request: .prompt(PromptRequest(title: "Reply"))
                ),
                for: "%5"
            )
            #expect(windowManager.openResponseRequests.count == 1)

            // The agent advances (working, no new form) — the retained form is
            // dropped, matching iOS's working-clears-form rule.
            windowManager.applyPluginStatus(
                pluginID: "claude-code",
                sessionID: "s1",
                working: true,
                attention: false,
                tmuxPane: "%5",
                projectPath: nil
            )
            #expect(windowManager.openResponseRequests.isEmpty)
        }

        @Test("a SessionEnd envelope (working=false + .sessionEnded) clears the session → terminal glyph")
        func sessionEndClearsSessionEndToEnd() async {
            let windowManager = makeWindowManager()
            let dispatcher = makeStatusAndAppActionDispatcher(windowManager)

            // A live session exists on the pane.
            windowManager.applyPluginStatus(
                pluginID: "claude-code",
                sessionID: "s1",
                working: true,
                attention: false,
                tmuxPane: "%5",
                projectPath: "/tmp/p"
            )
            #expect(windowManager.paneStates["%5"]?.agentSession != nil)

            // The real SessionEnd envelope: status working=false (idle) carried in
            // the SAME event as the `.sessionEnded` app action. Status fans out
            // before app actions, so the appAction's clear must be the last write.
            await dispatcher.dispatch(PluginEvent(
                pluginID: "claude-code",
                sessionID: "s1",
                working: false,
                appActions: [.sessionEnded(sessionID: "%5", closePaneEligible: false)],
                tmuxPane: "%5"
            ))

            // Session gone → the row renders the plain terminal glyph, not the
            // idle moon. (Regression: previously the idle session lingered.)
            #expect(windowManager.paneStates["%5"]?.agentSession == nil)
            #expect(!windowManager.activeSessionPaneIds.contains("%5"))
        }

        @Test("status with no tmuxPane is dropped")
        func applyPluginStatusNoPaneDropped() {
            let windowManager = makeWindowManager()
            windowManager.applyPluginStatus(
                pluginID: "echo",
                sessionID: "s1",
                working: true,
                attention: false,
                tmuxPane: nil,
                projectPath: nil
            )
            #expect(windowManager.paneStates.isEmpty)
        }

        // MARK: - Full ingress round-trip

        @Test("an echo ingress frame updates the pane's session status via the dispatcher")
        func ingressFrameUpdatesSessionStatus() async throws {
            let windowManager = makeWindowManager()
            let dispatcher = makeDispatcher(windowManager)
            let core = EchoPluginCore()
            let server = IngressSocketServer(
                socketPath: makeSocketPath(),
                coreLookup: { id in id == EchoPluginCore.pluginID ? core : nil },
                dispatcher: dispatcher
            )
            try await server.start()
            defer { Task { await server.stop() } }

            let path = await server.boundSocketPath
            let fd = try #require(connectClient(to: path, deadline: Date().addingTimeInterval(5)))
            defer { close(fd) }

            // Drive a working=true status onto pane %9 via the socket.
            let directive = EchoDirective(sessionID: "sess-9", working: true, attention: true)
            let payload = try JSONEncoder().encode(directive)
            let frame = IngressFrame(
                pluginID: EchoPluginCore.pluginID,
                context: ["TMUX_PANE": "%9"],
                payload: payload
            )
            #expect(try writeAll(fd, frame.encodeFrame()))

            let state = await waitForSession(windowManager, paneId: "%9")
            #expect(state?.agentSession != nil)
            // working=true + attention=true → both status Bools set on the session.
            #expect(state?.agentSession?.isWorking == true)
            #expect(state?.agentSession?.needsAttention == true)

            await server.stop()
        }
    }
#endif
