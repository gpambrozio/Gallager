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
            tmuxPane: String?,
            projectPath: String?,
            working: Bool?,
            attention: Bool
        ) async {
            // Find the pane that hosts this agent session. The plugin
            // protocol identifies sessions by the agent's own session id;
            // the same value lives on `AgentSession.id` (see Task 14).
            //
            // Falls back to the sidecar-reported `tmuxPane` so events from
            // non-bundled plugins (and bundled plugins running in stubbed
            // E2E panes where process-name detection didn't fire) still
            // land on the right row — see
            // `feedback_no-fire-and-forget-tasks`.
            guard
                let paneId = resolvePaneID(
                    forSessionID: sessionID,
                    fallbackTmuxPane: tmuxPane
                ) else {
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
                projectPath: projectPath,
                working: working,
                attention: attention
            )

            // Push the updated session state to viewers. The legacy
            // hook-driven path piggy-backed on tmux refreshes; the plugin
            // sink has to fan out explicitly because `paneStates` mutated
            // without a tmux event.
            await onSessionMetadataChanged?()
        }

        /// Locate the pane id hosting `sessionID` by scanning
        /// `paneStates`. When the session hasn't been mapped yet, fall
        /// back to the sidecar-reported `tmuxPane`.
        ///
        /// The bootstrap path mirrors the legacy `updateSession` flow in
        /// `MirrorWindowManager`: if `paneStates` doesn't yet have an
        /// entry for the pane (typical when an event arrives before the
        /// 5-second validation refresh has caught up to a freshly-spawned
        /// tmux pane), we still adopt the id — the caller's
        /// `applyStatus` then creates a minimal `PaneState` keyed by it
        /// and the next refresh reconciles the rest of the pane metadata
        /// (sessionName, terminal title, etc.) in place.
        ///
        /// Returns `nil` only when no fallback pane id is supplied at all.
        private func resolvePaneID(
            forSessionID sessionID: String,
            fallbackTmuxPane: String?
        ) -> String? {
            for (paneId, state) in paneStates
                where state.agentSession?.id == sessionID {
                return paneId
            }
            if
                let fallback = fallbackTmuxPane,
                !fallback.isEmpty {
                return fallback
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
            projectPath: String?,
            working: Bool?,
            attention: Bool
        ) {
            var session = paneStates[paneId]?.agentSession ?? AgentSession(
                id: sessionID,
                pluginID: pluginID,
                tmuxPane: paneId,
                projectPath: projectPath
            )
            // Adopt projectPath from the latest event if the session
            // didn't have one yet — bundled plugins push the path on
            // every hook, so the first non-empty value wins.
            if session.projectPath == nil, let projectPath, !projectPath.isEmpty {
                session.projectPath = projectPath
            }
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

    // MARK: - Cross-sink bootstrap

    public extension MirrorWindowManager {
        /// Bootstrap a minimal `AgentSession` on the pane that hosts
        /// `tmuxPane` when no row has been mapped to `sessionID` yet.
        ///
        /// Sibling sinks (`PluginNotificationBridge`,
        /// `PluginResponseRequestRouter`, `AppActionRouter`) call this
        /// before resolving the session-to-pane mapping, so events
        /// arriving in any order (notification first, status second, …)
        /// still land on the right row for non-bundled plugins.
        ///
        /// Mirrors the legacy `updateSession` flow: if `paneStates`
        /// hasn't seen the pane yet (typical when an event arrives
        /// before the 5-second validation refresh catches up), a
        /// minimal `PaneState` is created keyed by the pane id and the
        /// next refresh reconciles the rest of the metadata in place.
        ///
        /// No-op when the session is already mapped, `tmuxPane` is
        /// `nil`/empty, or an unrelated `agentSession` already lives on
        /// that pane (a stale id we don't want to clobber).
        func bootstrapPluginSessionIfNeeded(
            pluginID: String,
            sessionID: String,
            tmuxPane: String?,
            projectPath: String? = nil
        ) {
            // Already mapped — nothing to do.
            for state in paneStates.values where state.agentSession?.id == sessionID {
                return
            }
            guard let tmuxPane, !tmuxPane.isEmpty else { return }
            let newSession = AgentSession(
                id: sessionID,
                pluginID: pluginID,
                tmuxPane: tmuxPane,
                projectPath: projectPath
            )
            if var existing = paneStates[tmuxPane] {
                // Only bootstrap when the pane has no session yet; the
                // status sink will populate working/attention on the next
                // event. A pane already owning a different session id is
                // left alone.
                guard existing.agentSession == nil else { return }
                existing.agentSession = newSession
                paneStates[tmuxPane] = existing
            } else {
                paneStates[tmuxPane] = PaneState(
                    paneId: tmuxPane,
                    agentSession: newSession
                )
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
            for (paneId, state) in paneStates
                where state.agentSession?.id == sessionID {
                return state.yoloMode || isYoloModeEnabled(for: paneId)
            }
            return false
        }
    }
#endif
