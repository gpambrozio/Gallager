#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import Darwin
    import Dependencies
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Proves the state-sink wiring that `AppCoordinator.setupPluginRuntime()`
    /// installs: a `PluginEvent.state`, fanned out by
    /// `PluginEventDispatcher.onState`, lands on a pane's `AgentSession.state` /
    /// `cliSessionState` via `MirrorWindowManager.applyState`. The last test
    /// drives the full ingress path (socket → `EchoPluginCore` → dispatcher →
    /// sink) so the exact closure shape the coordinator uses is exercised.
    @MainActor
    @Suite
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
        /// wires its state sink (the other sinks are irrelevant here).
        private func makeDispatcher(_ windowManager: MirrorWindowManager) -> PluginEventDispatcher {
            PluginEventDispatcher(
                onState: { pluginID, sessionID, state, tmuxPane, projectPath, permissionMode in
                    await windowManager.applyState(
                        pluginID: pluginID,
                        sessionID: sessionID,
                        state: state,
                        tmuxPane: tmuxPane,
                        projectPath: projectPath,
                        permissionMode: permissionMode
                    )
                }
            )
        }

        /// The dispatcher wired with BOTH the state and app-action sinks the way
        /// `AppCoordinator.setupPluginRuntime` does — the state sink updates the
        /// session, the app-action sink ends it on `.sessionEnded`. Lets a test
        /// drive a full SessionEnd envelope and assert the state-then-app-action
        /// ordering clears the session rather than leaving it resurrected.
        private func makeStateAndAppActionDispatcher(_ windowManager: MirrorWindowManager) -> PluginEventDispatcher {
            PluginEventDispatcher(
                onState: { pluginID, sessionID, state, tmuxPane, projectPath, permissionMode in
                    await windowManager.applyState(
                        pluginID: pluginID,
                        sessionID: sessionID,
                        state: state,
                        tmuxPane: tmuxPane,
                        projectPath: projectPath,
                        permissionMode: permissionMode
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
        /// The deadline is generous because the full suite runs in parallel —
        /// under CPU saturation the background read queue can be starved for
        /// several seconds; the loop still returns the instant the session
        /// appears, so a long deadline costs nothing on the happy path and only
        /// buys patience under load.
        private func waitForSession(
            _ windowManager: MirrorWindowManager,
            paneId: String
        ) async -> PaneState? {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if let state = windowManager.paneStates[paneId], state.agentSession != nil {
                    return state
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return windowManager.paneStates[paneId]
        }

        // MARK: - Direct mapping

        @Test("applyState sets the session state directly; the Bools derive from it")
        func applyStateMapping() {
            let windowManager = makeWindowManager()

            // .working → session created, isWorking=true
            windowManager.applyState(
                pluginID: "echo",
                sessionID: "s1",
                state: .working,
                tmuxPane: "%7",
                projectPath: "/tmp/proj"
            )
            #expect(windowManager.paneStates["%7"]?.agentSession != nil)
            #expect(windowManager.paneStates["%7"]?.agentSession?.state == .working)
            #expect(windowManager.paneStates["%7"]?.agentSession?.isWorking == true)
            #expect(windowManager.paneStates["%7"]?.agentSession?.needsAttention == false)
            #expect(windowManager.paneStates["%7"]?.agentSession?.detectedProjectPath == "/tmp/proj")
            #expect(windowManager.paneStates["%7"]?.agentSession?.pluginID == "echo")

            // .doneWorking → needsAttention derives true
            windowManager.applyState(
                pluginID: "echo",
                sessionID: "s1",
                state: .doneWorking(summary: "all done"),
                tmuxPane: "%7",
                projectPath: nil
            )
            #expect(windowManager.paneStates["%7"]?.agentSession?.needsAttention == true)
            #expect(windowManager.paneStates["%7"]?.agentSession?.isWorking == false)

            // .idle → neither working nor attention, session kept
            windowManager.applyState(
                pluginID: "echo",
                sessionID: "s1",
                state: .idle,
                tmuxPane: "%7",
                projectPath: nil
            )
            #expect(windowManager.paneStates["%7"]?.agentSession != nil)
            #expect(windowManager.paneStates["%7"]?.agentSession?.isWorking == false)
            #expect(windowManager.paneStates["%7"]?.agentSession?.needsAttention == false)
        }

        @Test("applyState seeds permissionMode from the hook and a nil leaves it unchanged")
        func applyStateSeedsPermissionMode() {
            let windowManager = makeWindowManager()

            // A hook carrying permission_mode stamps the pane (issue #597).
            windowManager.applyState(
                pluginID: "claude-code",
                sessionID: "s1",
                state: .working,
                tmuxPane: "%7",
                projectPath: nil,
                permissionMode: "bypassPermissions"
            )
            #expect(windowManager.paneStates["%7"]?.permissionMode == "bypassPermissions")

            // A later event without permission_mode (nil) must NOT clobber the known
            // mode — most hooks don't carry it.
            windowManager.applyState(
                pluginID: "claude-code",
                sessionID: "s1",
                state: .idle,
                tmuxPane: "%7",
                projectPath: nil,
                permissionMode: nil
            )
            #expect(windowManager.paneStates["%7"]?.permissionMode == "bypassPermissions")

            // A new session id resets the mode, but a permission_mode on the same
            // call wins (stamped after the reset).
            windowManager.applyState(
                pluginID: "claude-code",
                sessionID: "s2",
                state: .working,
                tmuxPane: "%7",
                projectPath: nil,
                permissionMode: "plan"
            )
            #expect(windowManager.paneStates["%7"]?.permissionMode == "plan")

            // A new session id with no mode resets it to nil.
            windowManager.applyState(
                pluginID: "claude-code",
                sessionID: "s3",
                state: .working,
                tmuxPane: "%7",
                projectPath: nil,
                permissionMode: nil
            )
            #expect(windowManager.paneStates["%7"]?.permissionMode == nil)
        }

        @Test("a blocking-form state survives mark-handled-on-view; a doneWorking one clears")
        func blockingFormGuardsAttentionAgainstViewing() {
            let windowManager = makeWindowManager()

            // An awaiting* state (permission / question / plan) is owed an explicit
            // response — viewing/marking-handled must not clear it (the guard now
            // lives inside AgentSession.markHandled: only doneWorking → idle).
            windowManager.applyState(
                pluginID: "echo",
                sessionID: "ask",
                state: .awaitingPermission(
                    PermissionRequest(title: "Bash", description: "ls"), requestID: "r1"
                ),
                tmuxPane: "%1",
                projectPath: nil
            )
            #expect(windowManager.paneStates["%1"]?.agentSession?.needsAttention == true)
            windowManager.markSessionHandled(paneId: "%1")
            #expect(windowManager.paneStates["%1"]?.agentSession?.needsAttention == true)

            // doneWorking: attention with NO blocking form → viewing clears it.
            windowManager.applyState(
                pluginID: "echo",
                sessionID: "stop",
                state: .doneWorking(summary: nil),
                tmuxPane: "%2",
                projectPath: nil
            )
            #expect(windowManager.paneStates["%2"]?.agentSession?.needsAttention == true)
            windowManager.markSessionHandled(paneId: "%2")
            #expect(windowManager.paneStates["%2"]?.agentSession?.needsAttention == false)

            // The agent advances past the question (plain working state): no form,
            // so a subsequent mark-handled is a no-op (already non-attention).
            windowManager.applyState(
                pluginID: "echo",
                sessionID: "ask",
                state: .working,
                tmuxPane: "%1",
                projectPath: nil
            )
            windowManager.markSessionHandled(paneId: "%1")
            #expect(windowManager.paneStates["%1"]?.agentSession?.needsAttention == false)
        }

        // MARK: - Badge decrease tracking

        @Test("pendingCountDecrease reports the lowered count only when attention clears — not on a rise or a steady count")
        func pendingCountDecreaseReportsDropsOnly() {
            let windowManager = makeWindowManager()

            // No sessions → nothing to report.
            #expect(windowManager.pendingCountDecrease() == nil)

            // A session needs attention: 0 → 1 is a RISE. No silent badge push is
            // owed — the matching notification's alert push carries the badge up.
            windowManager.applyState(
                pluginID: "echo",
                sessionID: "s1",
                state: .doneWorking(summary: nil),
                tmuxPane: "%1",
                projectPath: nil
            )
            #expect(windowManager.pendingSessionCount == 1)
            #expect(windowManager.pendingCountDecrease() == nil)

            // Steady at 1 → still nothing to report.
            #expect(windowManager.pendingCountDecrease() == nil)

            // The agent moves on (working, no notification): 1 → 0 is a DROP, so the
            // new count is returned for the host to push as a cleared badge.
            windowManager.applyState(
                pluginID: "echo",
                sessionID: "s1",
                state: .working,
                tmuxPane: "%1",
                projectPath: nil
            )
            #expect(windowManager.pendingSessionCount == 0)
            #expect(windowManager.pendingCountDecrease() == 0)

            // Already reported → not pushed twice.
            #expect(windowManager.pendingCountDecrease() == nil)
        }

        @Test("pendingCountDecrease returns the remaining count when one of several pending sessions clears")
        func pendingCountDecreasePartialDrop() {
            let windowManager = makeWindowManager()

            windowManager.applyState(
                pluginID: "echo", sessionID: "a",
                state: .doneWorking(summary: nil), tmuxPane: "%1", projectPath: nil
            )
            windowManager.applyState(
                pluginID: "echo", sessionID: "b",
                state: .doneWorking(summary: nil), tmuxPane: "%2", projectPath: nil
            )
            #expect(windowManager.pendingSessionCount == 2)
            // Seed the high-water mark at 2 (a rise → nil).
            #expect(windowManager.pendingCountDecrease() == nil)

            // One of two clears → drop to 1: the badge must show 1, not 0.
            windowManager.applyState(
                pluginID: "echo", sessionID: "a",
                state: .working, tmuxPane: "%1", projectPath: nil
            )
            #expect(windowManager.pendingCountDecrease() == 1)
        }

        // MARK: - Set State override drives the pending count (issue #702)

        @Test("pendingSessionCount honors the Set State override in both directions and counts a session once")
        func pendingSessionCountHonorsOverride() {
            let windowManager = makeWindowManager()

            // Two panes in one tmux session ("work"); the agent lives on %5.
            windowManager.updatePaneStates(from: [
                PaneInfo(
                    paneId: "%5", target: "work:0.0", sessionName: "work",
                    windowIndex: 0, paneIndex: 0, command: "zsh", currentPath: "/tmp",
                    width: 80, height: 24, isActive: true
                ),
                PaneInfo(
                    paneId: "%6", target: "work:1.0", sessionName: "work",
                    windowIndex: 1, paneIndex: 0, command: "zsh", currentPath: "/tmp",
                    width: 80, height: 24, isActive: true
                ),
            ])
            windowManager.applyState(
                pluginID: "echo", sessionID: "s1",
                state: .idle, tmuxPane: "%5", projectPath: nil
            )
            // Idle agent, no override → not pending.
            #expect(windowManager.pendingSessionCount == 0)

            // Force "Waiting for input" session-wide (the "Set State" menu path):
            // the override wins over the idle agent, so the session is pending. It
            // counts ONCE even though the override is stamped on both panes — the
            // sibling %6 owns no agent session, so it isn't a menu row (issue #702).
            windowManager.setCLISessionState(.waiting, forSession: "work")
            #expect(windowManager.pendingSessionCount == 1)

            // A fresh plugin state (doneWorking → needs attention) clears the
            // override; the count still reflects the now-authoritative agent state.
            windowManager.applyState(
                pluginID: "echo", sessionID: "s1",
                state: .doneWorking(summary: nil), tmuxPane: "%5", projectPath: nil
            )
            #expect(windowManager.paneStates["%5"]?.cliSessionState == nil)
            #expect(windowManager.pendingSessionCount == 1)

            // Force Idle over an agent that genuinely needs attention: the override
            // suppresses the bell in the other direction, so the count drops to 0.
            windowManager.setCLISessionState(.idle, forSession: "work")
            #expect(windowManager.pendingSessionCount == 0)

            // Clearing the override reverts to the agent's own state (still
            // doneWorking → needs attention), so the session is pending again.
            windowManager.setCLISessionState(nil, forSession: "work")
            #expect(windowManager.pendingSessionCount == 1)
        }

        @Test("a pinned terminal-only session counts once; unpinning drops the count and reports the decrease")
        func pendingCountCountsPinnedTerminalSession() {
            let windowManager = makeWindowManager()

            // Two windows in one tmux session, no agent anywhere.
            windowManager.updatePaneStates(from: [
                PaneInfo(
                    paneId: "%7", target: "scratch:0.0", sessionName: "scratch",
                    windowIndex: 0, paneIndex: 0, command: "zsh", currentPath: "/tmp",
                    width: 80, height: 24, isActive: true
                ),
                PaneInfo(
                    paneId: "%8", target: "scratch:1.0", sessionName: "scratch",
                    windowIndex: 1, paneIndex: 0, command: "zsh", currentPath: "/tmp",
                    width: 80, height: 24, isActive: true
                ),
            ])
            #expect(windowManager.pendingSessionCount == 0)

            // Pin the whole session to Waiting: one bell row, one count —
            // even though the override lands on both panes.
            windowManager.setCLISessionState(.waiting, forSession: "scratch")
            #expect(windowManager.pendingSessionCount == 1)
            // Advance the high-water mark (increase -> no decrease reported).
            #expect(windowManager.pendingCountDecrease() == nil)

            // Unpin: count drops and the drop is reported for the iOS badge push.
            windowManager.setCLISessionState(nil, forSession: "scratch")
            #expect(windowManager.pendingSessionCount == 0)
            #expect(windowManager.pendingCountDecrease() == 0)
        }

        @Test("pruning a pinned terminal session fires onPaneStatesPruned and reports the badge decrease")
        func pruneFiresBadgeDecrease() async {
            let windowManager = makeWindowManager()
            windowManager.updatePaneStates(from: [
                PaneInfo(
                    paneId: "%7", target: "scratch:0.0", sessionName: "scratch",
                    windowIndex: 0, paneIndex: 0, command: "zsh", currentPath: "/tmp",
                    width: 80, height: 24, isActive: true
                ),
            ])
            windowManager.setCLISessionState(.waiting, forSession: "scratch")
            #expect(windowManager.pendingSessionCount == 1)
            // Advance the high-water mark to 1 (an increase reports nothing).
            #expect(windowManager.pendingCountDecrease() == nil)

            // `tmux kill-session` has no SessionEnd hook for a terminal-only
            // session; the next scan pruning its pane is the only end signal,
            // so it must fire the pruned callback the coordinator wires to
            // `broadcastBadgeDecreaseIfNeeded` (issue #702).
            await withCheckedContinuation { continuation in
                windowManager.onPaneStatesPruned = { continuation.resume() }
                windowManager.updatePaneStates(from: [])
            }
            #expect(windowManager.pendingSessionCount == 0)
            #expect(windowManager.pendingCountDecrease() == 0)
        }

        // MARK: - Open form rides the session state

        @Test("an awaiting state exposes the open form on the session; a working state clears it")
        func openFormRidesSessionState() {
            let windowManager = makeWindowManager()

            windowManager.applyState(
                pluginID: "claude-code",
                sessionID: "s1",
                state: .awaitingReplies(
                    AskUserQuestionRequest(questions: [
                        .init(
                            id: "q1",
                            question: "Which?",
                            header: "Pick",
                            options: [.init(id: "a", label: "A", description: "first")],
                            multiSelect: false
                        ),
                    ]),
                    requestID: "%5:AskUserQuestion"
                ),
                tmuxPane: "%5",
                projectPath: "/tmp/p"
            )
            // The form rides the state → in the snapshot for free.
            #expect(windowManager.paneStates["%5"]?.agentSession?.state.openForm != nil)
            #expect(windowManager.paneStates["%5"]?.agentSession?.state.openForm?.requestID == "%5:AskUserQuestion")

            // The agent advances (working, no form) — the open form is gone.
            windowManager.applyState(
                pluginID: "claude-code",
                sessionID: "s1",
                state: .working,
                tmuxPane: "%5",
                projectPath: nil
            )
            #expect(windowManager.paneStates["%5"]?.agentSession?.state.openForm == nil)
        }

        // MARK: - Session end

        @Test("endAgentSession removes the session and no-ops when there is none")
        func endAgentSessionDirect() {
            let windowManager = makeWindowManager()

            // An idle session on the pane (SessionEnd maps to working=false → no
            // state opinion in the translator; the state sink here sets .idle).
            windowManager.applyState(
                pluginID: "echo",
                sessionID: "s1",
                state: .idle,
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

        @Test("endAgentSession clears the manual Set State override session-wide")
        func endAgentSessionClearsCLIOverride() {
            let windowManager = makeWindowManager()

            // Two panes in the same tmux session, plus one in another session.
            windowManager.updatePaneStates(from: [
                PaneInfo(
                    paneId: "%5", target: "work:0.0", sessionName: "work",
                    windowIndex: 0, paneIndex: 0, command: "zsh", currentPath: "/tmp",
                    width: 80, height: 24, isActive: true
                ),
                PaneInfo(
                    paneId: "%6", target: "work:1.0", sessionName: "work",
                    windowIndex: 1, paneIndex: 0, command: "zsh", currentPath: "/tmp",
                    width: 80, height: 24, isActive: true
                ),
                PaneInfo(
                    paneId: "%7", target: "other:0.0", sessionName: "other",
                    windowIndex: 0, paneIndex: 0, command: "zsh", currentPath: "/tmp",
                    width: 80, height: 24, isActive: true
                ),
            ])

            // A live agent on %5, then a manual override stamped session-wide
            // (the "Set State" menu path) and independently on the other session.
            windowManager.applyState(
                pluginID: "echo",
                sessionID: "s1",
                state: .working,
                tmuxPane: "%5",
                projectPath: nil
            )
            windowManager.setCLISessionState(.idle, forSession: "work")
            windowManager.setCLISessionState(.waiting, for: "%7")

            // The agent session ends → the override must not linger on the
            // now-plain terminal pane, nor on siblings the sidebar aggregates
            // across (issue #695 review follow-up).
            #expect(windowManager.endAgentSession(forPane: "%5") == true)
            #expect(windowManager.paneStates["%5"]?.cliSessionState == nil)
            #expect(windowManager.paneStates["%6"]?.cliSessionState == nil)
            // An unrelated session's override is untouched.
            #expect(windowManager.paneStates["%7"]?.cliSessionState == .waiting)
        }

        @Test("a SessionEnd envelope (working state + .sessionEnded) clears the session → terminal glyph")
        func sessionEndClearsSessionEndToEnd() async {
            let windowManager = makeWindowManager()
            let dispatcher = makeStateAndAppActionDispatcher(windowManager)

            // A live session exists on the pane.
            windowManager.applyState(
                pluginID: "claude-code",
                sessionID: "s1",
                state: .working,
                tmuxPane: "%5",
                projectPath: "/tmp/p"
            )
            #expect(windowManager.paneStates["%5"]?.agentSession != nil)

            // The real SessionEnd envelope: SessionEnd carries no state opinion
            // (working=false → nil), so this models the trailing tick that arrives
            // with the `.sessionEnded` app action. The appAction's clear is the
            // last write, so the session is removed.
            await dispatcher.dispatch(PluginEvent(
                pluginID: "claude-code",
                sessionID: "s1",
                appActions: [.sessionEnded(sessionID: "%5", closePaneEligible: false)],
                tmuxPane: "%5"
            ))

            // Session gone → the row renders the plain terminal glyph, not the
            // idle moon. (Regression: previously the idle session lingered.)
            #expect(windowManager.paneStates["%5"]?.agentSession == nil)
            #expect(!windowManager.activeSessionPaneIds.contains("%5"))
        }

        @Test("state with no tmuxPane is dropped")
        func applyStateNoPaneDropped() {
            let windowManager = makeWindowManager()
            windowManager.applyState(
                pluginID: "echo",
                sessionID: "s1",
                state: .working,
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

            // Drive a doneWorking state onto pane %9 via the socket.
            let directive = EchoDirective(sessionID: "sess-9", state: .doneWorking(summary: "done"))
            let payload = try JSONEncoder().encode(directive)
            let frame = IngressFrame(
                pluginID: EchoPluginCore.pluginID,
                context: ["TMUX_PANE": "%9"],
                payload: payload
            )
            #expect(try writeAll(fd, frame.encodeFrame()))

            let state = await waitForSession(windowManager, paneId: "%9")
            #expect(state?.agentSession != nil)
            // doneWorking → isWorking false, needsAttention true (derived).
            #expect(state?.agentSession?.isWorking == false)
            #expect(state?.agentSession?.needsAttention == true)
            #expect(state?.agentSession?.state == .doneWorking(summary: "done"))

            await server.stop()
        }
    }
#endif
