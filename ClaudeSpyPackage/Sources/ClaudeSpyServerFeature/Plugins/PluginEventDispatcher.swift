#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation

    /// The single, agent-blind consumer of every `PluginEvent` (spec §5). A core
    /// returns one from `handleIngress` or pushes one via `host.emit`; this
    /// dispatcher fans its fields out to injected sink closures. There is exactly
    /// one path — no second mechanism, no per-field callbacks on the host.
    ///
    /// It depends on **nothing** in `AppCoordinator`: the wiring phase supplies the
    /// real sink closures (state → `AgentSession`, notification → Mac + iOS push,
    /// app actions → Mac features). For now the closures default to no-ops and the
    /// unit tests inject recording closures.
    ///
    /// An `actor` so it stays `Sendable` while it owns the (now stateless) fan-out.
    public actor PluginEventDispatcher {
        // MARK: - Sink closure signatures
        //
        // The wiring phase (AppCoordinator) supplies these. Keep them flat and
        // value-typed so the dispatcher never reaches back into app state.

        /// The session's state changed. Drives `AgentSession.state` and the
        /// `agent_session_status` push. Also the sole open/retract-form signal: an
        /// `awaiting*` state opens the form, any other state retracts it.
        public typealias StateSink = @Sendable (
            _ pluginID: String,
            _ sessionID: String,
            _ state: AgentState,
            _ tmuxPane: String?,
            _ projectPath: String?,
            _ permissionMode: String?
        ) async -> Void

        /// A pre-baked notification to surface Mac-side and push to iOS.
        /// `paneID` is the tmux pane (falling back to the agent session id) so the
        /// push can be associated with its session.
        public typealias NotificationSink = @Sendable (
            _ pluginID: String,
            _ paneID: String,
            _ notification: NotificationSpec
        ) async -> Void

        /// Silently approve an auto-approvable permission on a yolo pane: deliver
        /// `.permission(.allow)` to the owning core. The session is kept `.working`
        /// (the awaiting transition is dropped) and the notification is suppressed.
        public typealias AutoApproveSink = @Sendable (
            _ pluginID: String,
            _ sessionID: String,
            _ requestID: String
        ) async -> Void

        /// One discrete agent-blind Mac-side trigger (markdown suggestion, pane close…).
        public typealias AppActionSink = @Sendable (_ action: AppAction) async -> Void

        /// Whether the pane is in yolo mode (queried Mac-side). Used to decide
        /// whether to auto-approve an auto-approvable permission silently. The core
        /// never learns about yolo — this is purely app state.
        public typealias AutoApproveCheck = @Sendable (_ paneID: String) async -> Bool

        // MARK: - Stored sinks

        private let onState: StateSink
        private let onNotification: NotificationSink
        private let onAutoApprove: AutoApproveSink
        private let onAppAction: AppActionSink
        private let isYoloModeEnabled: AutoApproveCheck

        // MARK: - Initialization

        public init(
            onState: @escaping StateSink = { _, _, _, _, _, _ in },
            onNotification: @escaping NotificationSink = { _, _, _ in },
            onAutoApprove: @escaping AutoApproveSink = { _, _, _ in },
            onAppAction: @escaping AppActionSink = { _ in },
            isYoloModeEnabled: @escaping AutoApproveCheck = { _ in false }
        ) {
            self.onState = onState
            self.onNotification = onNotification
            self.onAutoApprove = onAutoApprove
            self.onAppAction = onAppAction
            self.isYoloModeEnabled = isYoloModeEnabled
        }

        // MARK: - Dispatch

        /// Fan one envelope out to the sinks (spec §5).
        public func dispatch(_ event: PluginEvent) async {
            let paneID = event.tmuxPane ?? event.sessionID

            if let state = event.state {
                // Yolo auto-approve (spec §6): an auto-approvable permission on a
                // yolo pane is approved silently — deliver .allow, keep the session
                // working, and suppress the notification. The form is never shown.
                // A non-awaiting state IS the retract: there is no separate signal.
                var effectiveState = state
                var suppressNotification = false
                if
                    case let .awaitingPermission(permission, requestID) = state,
                    permission.isAutoApprovable,
                    await isYoloModeEnabled(paneID) {
                    await onAutoApprove(event.pluginID, paneID, requestID)
                    effectiveState = .working
                    suppressNotification = true
                }
                await onState(
                    event.pluginID,
                    event.sessionID,
                    effectiveState,
                    event.tmuxPane,
                    event.projectPath,
                    event.permissionMode
                )
                if let notification = event.notification, !suppressNotification {
                    await onNotification(event.pluginID, paneID, notification)
                }
            } else if let notification = event.notification {
                // No state opinion — a bare notification push (decoupled, spec §5).
                await onNotification(event.pluginID, paneID, notification)
            }

            // App actions.
            for action in event.appActions {
                await onAppAction(action)
            }
        }
    }
#endif
