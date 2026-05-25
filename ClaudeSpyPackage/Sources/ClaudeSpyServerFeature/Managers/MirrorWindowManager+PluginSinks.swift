#if os(macOS)
    import ClaudeSpyNetworking
    import ClaudeSpyPluginRuntime
    import Foundation

    // MARK: - PluginSessionStatusSink

    /// Bridges plugin-emitted `update_session_status` callbacks onto the
    /// pane-state mutations that previously came from `HookEvent`-driven
    /// `applyEvent`. The sidecar pushes the post-translation result, so we
    /// just locate the pane hosting `sessionID` and stamp the new flags.
    extension MirrorWindowManager: PluginSessionStatusSink {
        public func updateStatus(
            pluginID: String,
            sessionID: String,
            working: Bool?,
            attention: Bool
        ) async {
            // Find the pane that hosts this agent session. The plugin
            // protocol identifies sessions by the agent's own session id;
            // the same value lives on `AgentSession.id` (see Task 14).
            guard let paneId = resolvePaneID(forSessionID: sessionID) else {
                // No tracked pane for this session id yet. This is normal
                // when status arrives before a refresh has caught up with
                // a freshly-spawned pane — the next `applyEvent`-style
                // pathway (or a refresh) will fill it in.
                return
            }

            // Mirrors the working/attention reset path in
            // `MirrorWindowManager.handleHookEvent`: when working flips or
            // attention rises, the CLI session-state override has to be
            // cleared on every sibling pane in the same tmux session so
            // the sidebar stops reading from a stale sibling.
            if working != nil || attention {
                let sessionName = paneStates[paneId]?.sessionName
                if let sessionName, !sessionName.isEmpty {
                    for (otherId, state) in paneStates where state.sessionName == sessionName {
                        paneStates[otherId]?.cliSessionState = nil
                    }
                } else {
                    paneStates[paneId]?.cliSessionState = nil
                }
            }

            // Apply the status to the agent session — create a minimal
            // session record if the pane has none yet so subsequent
            // updates land on the same row.
            applyStatus(
                paneId: paneId,
                sessionID: sessionID,
                pluginID: pluginID,
                working: working,
                attention: attention
            )
        }

        /// Locate the pane id hosting `sessionID` by scanning
        /// `paneStates`. Returns `nil` when no pane has been tagged with
        /// that session yet.
        private func resolvePaneID(forSessionID sessionID: String) -> String? {
            for (paneId, state) in paneStates {
                if state.agentSession?.id == sessionID {
                    return paneId
                }
            }
            return nil
        }

        /// Apply working/attention to the pane's agent session, creating a
        /// minimal record if needed. Mirrors the assignment path inside
        /// `applyEvent` (Task 14 transitional bridge) so the on-screen
        /// behaviour is identical regardless of which producer fired the
        /// update.
        private func applyStatus(
            paneId: String,
            sessionID: String,
            pluginID: String,
            working: Bool?,
            attention: Bool
        ) {
            var session = paneStates[paneId]?.agentSession ?? AgentSession(
                id: sessionID,
                pluginID: pluginID,
                tmuxPane: paneId
            )
            if let working {
                session.working = working
            }
            // attention is a fire-and-forget signal: the sidecar sets `true`
            // when the user needs to look at the session, and the host
            // clears it via `markSessionHandled`. We never receive an
            // explicit "attention cleared" via this sink; setting `false`
            // here would race with iOS's tap-to-handle path.
            if attention {
                session.attention = true
            }
            if working != nil || attention {
                session.lastEventTimestamp = Date()
            }
            if paneStates[paneId] != nil {
                paneStates[paneId]?.agentSession = session
            } else {
                paneStates[paneId] = PaneState(paneId: paneId, agentSession: session)
            }
        }
    }

    // MARK: - YoloModeProvider

    /// `PluginEventDispatcher.dispatch` consults this provider before
    /// auto-approving an auto-approvable permission request. The legacy
    /// `MirrorWindowManager.isYoloModeEnabled(for: paneId)` is keyed by
    /// pane id, while the plugin protocol uses agent session id — bridge
    /// via the same pane lookup the status sink uses.
    extension MirrorWindowManager: YoloModeProvider {
        public func isYolo(forSessionID sessionID: String) async -> Bool {
            for (paneId, state) in paneStates {
                if state.agentSession?.id == sessionID {
                    return state.yoloMode || isYoloModeEnabled(for: paneId)
                }
            }
            return false
        }
    }
#endif
