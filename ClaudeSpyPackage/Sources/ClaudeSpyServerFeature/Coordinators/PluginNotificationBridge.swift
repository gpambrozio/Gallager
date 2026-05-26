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
            tmuxPane: String?,
            projectPath: String?,
            title: String,
            body: String
        ) async {
            // Bootstrap the agent session on first contact when the sidecar
            // emitted a notification before any status event mapped the
            // session to a pane. Status events typically fire first, but
            // some events (e.g. taskCompleted) carry only a notification.
            if let sessionID {
                mirrorManager.bootstrapPluginSessionIfNeeded(
                    pluginID: pluginID,
                    sessionID: sessionID,
                    tmuxPane: tmuxPane,
                    projectPath: projectPath
                )
            }
            let notification = TerminalStreamMessage.TerminalNotification(
                title: title,
                body: body
            )
            // Resolve the pane id for the banner so notification taps can
            // open the right pane. When the sidecar didn't supply a
            // session id (e.g. plugin-wide diagnostic), fall back to a
            // synthetic identifier so the local OSC notification path
            // still has something to bind to.
            let resolved = resolvePaneID(
                forSessionID: sessionID,
                fallbackTmuxPane: tmuxPane
            )
            let paneId = resolved ?? "plugin:\(pluginID)"
            notificationService.showNotification(paneId, notification)

            // Forward to paired iOS viewers. The push payload identifies
            // the pane (when known) so a tap on the iOS notification can
            // route to the corresponding session.
            if let viewerManager {
                await viewerManager.sendCustomPushNotificationToAll(
                    title: title,
                    body: body,
                    paneId: resolved
                )
            }
        }

        // MARK: - Helpers

        private func resolvePaneID(
            forSessionID sessionID: String?,
            fallbackTmuxPane: String?
        ) -> String? {
            if let sessionID {
                for (paneId, state) in mirrorManager.paneStates
                    where state.agentSession?.id == sessionID {
                    return paneId
                }
            }
            // Fall back to the sidecar's reported tmuxPane when the
            // session hasn't been mapped to a row yet — same bootstrap
            // path as the status sink. Only adopts panes already in
            // `paneStates` so closed panes drop the notification rather
            // than reviving phantom rows.
            if
                let tmuxPane = fallbackTmuxPane,
                !tmuxPane.isEmpty,
                mirrorManager.paneStates[tmuxPane] != nil {
                return tmuxPane
            }
            return nil
        }
    }
#endif
