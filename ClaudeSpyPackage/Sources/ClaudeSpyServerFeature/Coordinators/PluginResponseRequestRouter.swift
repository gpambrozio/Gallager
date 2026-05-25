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
        private let logger = Logger(label: "com.claudespy.pluginresponserouter")

        public init(viewerManager: ConnectedViewerManager?) {
            self.viewerManager = viewerManager
        }

        // MARK: - PluginResponseRequestSink

        public func deliverRequest(
            pluginID: String,
            sessionID: String,
            requestID: String,
            request: AgentResponseRequest,
            isAutoApprovable _: Bool
        ) async {
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
