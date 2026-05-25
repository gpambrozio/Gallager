#if os(macOS)
    import ClaudeSpyNetworking
    import ClaudeSpyPluginRuntime
    import Foundation
    import Logging

    /// Implements `PluginNotificationSink` by translating sidecar-emitted
    /// `request_notification` notifications into:
    ///
    ///   1. A local macOS banner via `TerminalNotificationService`
    ///      (the existing OSC 9 / 777 path).
    ///   2. An encrypted push notification fan-out to every paired iOS
    ///      viewer via `ConnectedViewerManager.sendCustomPushNotificationToAll`.
    ///
    /// `TerminalNotificationService` is a `@DependencyClient` struct so we
    /// can't conform it to the sink protocol directly; this class is the
    /// `AnyObject, Sendable` shim the protocol requires.
    @MainActor
    final public class PluginNotificationBridge: PluginNotificationSink {
        private let notificationService: TerminalNotificationService
        private weak var viewerManager: ConnectedViewerManager?
        private let mirrorManager: MirrorWindowManager
        private let logger = Logger(label: "com.claudespy.pluginnotificationbridge")

        public init(
            notificationService: TerminalNotificationService,
            viewerManager: ConnectedViewerManager?,
            mirrorManager: MirrorWindowManager
        ) {
            self.notificationService = notificationService
            self.viewerManager = viewerManager
            self.mirrorManager = mirrorManager
        }

        // MARK: - PluginNotificationSink

        public func deliverNotification(
            pluginID: String,
            sessionID: String?,
            title: String,
            body: String
        ) async {
            let notification = TerminalStreamMessage.TerminalNotification(
                title: title,
                body: body
            )
            // Resolve the pane id for the banner so notification taps can
            // open the right pane. When the sidecar didn't supply a
            // session id (e.g. plugin-wide diagnostic), fall back to a
            // synthetic identifier so the local OSC notification path
            // still has something to bind to.
            let paneId = resolvePaneID(forSessionID: sessionID) ?? "plugin:\(pluginID)"
            notificationService.showNotification(paneId, notification)

            // Forward to paired iOS viewers. The push payload identifies
            // the pane (when known) so a tap on the iOS notification can
            // route to the corresponding session.
            let viewerPaneId = resolvePaneID(forSessionID: sessionID)
            if let viewerManager {
                await viewerManager.sendCustomPushNotificationToAll(
                    title: title,
                    body: body,
                    paneId: viewerPaneId
                )
            }
        }

        // MARK: - Helpers

        private func resolvePaneID(forSessionID sessionID: String?) -> String? {
            guard let sessionID else { return nil }
            for (paneId, state) in mirrorManager.paneStates
                where state.agentSession?.id == sessionID {
                return paneId
            }
            return nil
        }
    }
#endif
