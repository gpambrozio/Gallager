#if os(macOS)
    import ClaudeSpyNetworking
    import ClaudeSpyPluginRuntime
    import Foundation
    import Logging

    /// Receives the discrete `AppAction` cases emitted by plugin sidecars and
    /// routes each to the existing app-side handler.
    ///
    /// Replaces the old hook-driven branches that lived in `AppCoordinator`
    /// (markdown open-suggestion, dismiss-on-prompt, close-pane-on-session-end)
    /// — the sidecar now decides when to fire each action and the app just
    /// handles them. Reuses `MarkdownOpenSuggestionStore` for file-suggestion
    /// state and looks up the backing pane via `MirrorWindowManager` so the
    /// close-pane preference path matches the legacy behaviour.
    @MainActor
    final public class AppActionRouter: PluginAppActionSink {
        private let mirrorManager: MirrorWindowManager
        private let suggestionStore: MarkdownOpenSuggestionStore
        private let settings: AppSettings
        private let tmuxService: TmuxService
        private let logger = Logger(label: "com.claudespy.appactionrouter")

        public init(
            mirrorManager: MirrorWindowManager,
            suggestionStore: MarkdownOpenSuggestionStore,
            settings: AppSettings,
            tmuxService: TmuxService
        ) {
            self.mirrorManager = mirrorManager
            self.suggestionStore = suggestionStore
            self.settings = settings
            self.tmuxService = tmuxService
        }

        // MARK: - PluginAppActionSink

        public func handle(pluginID: String, action: AppAction) async {
            switch action {
            case let .openFileSuggestion(sessionId, path, displayName, isPlan):
                handleOpenFileSuggestion(
                    pluginID: pluginID,
                    sessionId: sessionId,
                    path: path,
                    displayName: displayName,
                    isPlan: isPlan
                )

            case let .dismissFileSuggestions(sessionId):
                handleDismissFileSuggestions(pluginID: pluginID, sessionId: sessionId)

            case let .closePaneIfPreferenceAllows(sessionId):
                await handleClosePaneIfPreferenceAllows(pluginID: pluginID, sessionId: sessionId)
            }
        }

        // MARK: - Action handlers

        private func handleOpenFileSuggestion(
            pluginID: String,
            sessionId: String,
            path: String,
            displayName: String,
            isPlan: Bool
        ) {
            // The legacy MarkdownOpenSuggestionStore keys by tmux session name,
            // not agent session id. Resolve via the pane that hosts this
            // agent session so suggestions survive switching tmux windows.
            let sessionName = resolveTmuxSessionName(forAgentSessionId: sessionId)
            guard let sessionName, !sessionName.isEmpty else {
                logger.warning(
                    "openFileSuggestion: no tmux session for agent session \(sessionId) (plugin \(pluginID))"
                )
                return
            }
            // Display name carries the filename or "plan" placeholder; we keep
            // the legacy struct shape that derives directory from the path
            // when projectPath isn't known.
            let directoryPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
            _ = displayName // legacy store derives label from path / isPlan
            suggestionStore.suggest(MarkdownOpenSuggestion(
                filePath: path,
                directoryPath: directoryPath,
                sessionName: sessionName,
                isPlan: isPlan
            ))
        }

        private func handleDismissFileSuggestions(pluginID: String, sessionId: String) {
            let sessionName = resolveTmuxSessionName(forAgentSessionId: sessionId)
            guard let sessionName, !sessionName.isEmpty else { return }
            // Mirrors the legacy "user submitted a new prompt → start the
            // 30s auto-dismiss countdown" path. The plugin sidecar is the
            // authoritative source of when a suggestion should age out.
            suggestionStore.userSubmittedPrompt(sessionName: sessionName)
        }

        private func handleClosePaneIfPreferenceAllows(pluginID: String, sessionId: String) async {
            guard settings.closePaneOnSessionEnd else { return }
            guard let paneId = resolvePaneId(forAgentSessionId: sessionId) else {
                logger.debug(
                    "closePaneIfPreferenceAllows: no pane for agent session \(sessionId) (plugin \(pluginID))"
                )
                return
            }
            // Best-effort — the pane may already be gone. tmux returns an
            // error in that case which we swallow at the call site.
            try? await tmuxService.killPane(paneId)
        }

        // MARK: - Lookup helpers

        /// Locate the pane id hosting `agentSessionId` by scanning
        /// `MirrorWindowManager.paneStates`.
        private func resolvePaneId(forAgentSessionId agentSessionId: String) -> String? {
            for (paneId, state) in mirrorManager.paneStates
                where state.agentSession?.id == agentSessionId {
                return paneId
            }
            return nil
        }

        /// Locate the tmux session name hosting `agentSessionId`.
        private func resolveTmuxSessionName(forAgentSessionId agentSessionId: String) -> String? {
            for state in mirrorManager.paneStates.values {
                if state.agentSession?.id == agentSessionId, !state.sessionName.isEmpty {
                    return state.sessionName
                }
            }
            return nil
        }
    }
#endif
