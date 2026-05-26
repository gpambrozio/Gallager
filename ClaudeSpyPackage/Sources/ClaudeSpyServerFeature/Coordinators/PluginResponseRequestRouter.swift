#if os(macOS)
    import ClaudeSpyNetworking
    import ClaudeSpyPluginRuntime
    import Foundation
    import Logging

    /// Implements `PluginResponseRequestSink` by forwarding
    /// sidecar-emitted prompts (and dismissals) to every paired iOS
    /// viewer over the relay's encrypted channel.
    ///
    /// The legacy hook-driven flow rebroadcast full session state on
    /// every change; the plugin protocol replaces that with two narrow
    /// envelopes — `AgentResponseRequestMessage` (with `request: nil`
    /// signalling dismiss) — that travel as their own WebSocket cases.
    /// This router is the Mac-side handler that turns each sink call
    /// into the appropriate broadcast.
    @MainActor
    final public class PluginResponseRequestRouter: PluginResponseRequestSink {
        private weak var viewerManager: ConnectedViewerManager?
        private weak var mirrorManager: MirrorWindowManager?
        private let logger = Logger(label: "com.claudespy.pluginresponserouter")

        public init(
            viewerManager: ConnectedViewerManager?,
            mirrorManager: MirrorWindowManager? = nil
        ) {
            self.viewerManager = viewerManager
            self.mirrorManager = mirrorManager
        }

        // MARK: - PluginResponseRequestSink

        public func deliverRequest(
            pluginID: String,
            sessionID: String,
            tmuxPane: String?,
            projectPath: String?,
            requestID: String,
            request: AgentResponseRequest,
            isAutoApprovable _: Bool
        ) async {
            // Defensively bootstrap the agent session before broadcasting
            // so iOS has a row to attach the request to. The status sink
            // runs first in the dispatcher when `attention || working`
            // are set, but a response-request-only event (rare, but
            // possible) wouldn't trigger the status sink at all.
            mirrorManager?.bootstrapPluginSessionIfNeeded(
                pluginID: pluginID,
                sessionID: sessionID,
                tmuxPane: tmuxPane,
                projectPath: projectPath
            )
            let message = AgentResponseRequestMessage(
                sessionId: sessionID,
                pluginId: pluginID,
                requestId: requestID,
                request: request
            )
            guard let viewerManager else {
                logger.debug("No viewer manager wired up; dropping deliverRequest for \(requestID)")
                return
            }
            await viewerManager.sendAgentResponseRequestToAll(message)
        }

        public func dismissRequest(
            pluginID: String,
            sessionID: String,
            requestID: String
        ) async {
            let message = AgentResponseRequestMessage(
                sessionId: sessionID,
                pluginId: pluginID,
                requestId: requestID,
                request: nil
            )
            guard let viewerManager else {
                logger.debug("No viewer manager wired up; dropping dismissRequest for \(requestID)")
                return
            }
            await viewerManager.sendAgentResponseRequestToAll(message)
        }
    }
#endif
