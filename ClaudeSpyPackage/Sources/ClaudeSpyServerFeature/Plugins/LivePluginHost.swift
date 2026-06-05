#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import GallagerPluginProtocol

    /// The live `PluginHost` the runtime hands each core at `initialize` (spec §4).
    /// One instance per active plugin (it carries its own `pluginID`).
    ///
    /// It owns no app state of its own: every method forwards to an injected sink
    /// or to shared collaborators (`PluginEventDispatcher`, `PluginLogSink`) so the
    /// host stays agent-blind and the wiring phase decides where the calls land.
    /// `Sendable` (a `struct` of `@Sendable` closures + shared actors) so a core
    /// actor can retain and call it freely.
    public struct LivePluginHost: PluginHost {
        /// The plugin this host serves; stamped onto `setProjects` / `sendText` /
        /// `sendKeys` so the wiring layer can resolve session→pane per plugin.
        public let pluginID: String

        /// Full project-list replacement for this plugin (push-based).
        public typealias SetProjectsSink = @Sendable (_ pluginID: String, _ projects: [AgentProject]) async -> Void
        /// Write text to the pane backing a session (verbatim).
        public typealias SendTextSink = @Sendable (_ pluginID: String, _ sessionID: String, _ text: String) async -> Void
        /// Send a key sequence to the pane backing a session.
        public typealias SendKeysSink = @Sendable (_ pluginID: String, _ sessionID: String, _ keys: [PluginTmuxKey]) async -> Void
        /// Resolve the panes currently running this plugin's agent process.
        public typealias AgentPanesSink = @Sendable (_ pluginID: String) async -> [String]

        private let dispatcher: PluginEventDispatcher
        private let logSink: PluginLogSink
        private let onSetProjects: SetProjectsSink
        private let onSendText: SendTextSink
        private let onSendKeys: SendKeysSink
        private let onAgentPanes: AgentPanesSink

        public init(
            pluginID: String,
            dispatcher: PluginEventDispatcher,
            logSink: PluginLogSink,
            onSetProjects: @escaping SetProjectsSink = { _, _ in },
            onSendText: @escaping SendTextSink = { _, _, _ in },
            onSendKeys: @escaping SendKeysSink = { _, _, _ in },
            onAgentPanes: @escaping AgentPanesSink = { _ in [] }
        ) {
            self.pluginID = pluginID
            self.dispatcher = dispatcher
            self.logSink = logSink
            self.onSetProjects = onSetProjects
            self.onSendText = onSendText
            self.onSendKeys = onSendKeys
            self.onAgentPanes = onAgentPanes
        }

        // MARK: - PluginHost

        public func setProjects(_ projects: [AgentProject]) async {
            await onSetProjects(pluginID, projects)
        }

        public func emit(_ event: PluginEvent) async {
            await dispatcher.dispatch(event)
        }

        public func sendText(sessionID: String, _ text: String) async {
            await onSendText(pluginID, sessionID, text)
        }

        public func sendKeys(sessionID: String, _ keys: [PluginTmuxKey]) async {
            await onSendKeys(pluginID, sessionID, keys)
        }

        public func agentPanes() async -> [String] {
            await onAgentPanes(pluginID)
        }

        public func log(_ line: LogLine) async {
            await logSink.append(line)
        }
    }
#endif
