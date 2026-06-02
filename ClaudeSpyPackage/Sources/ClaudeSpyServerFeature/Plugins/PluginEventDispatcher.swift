#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation

    /// The single, agent-blind consumer of every `PluginEvent` (spec §5). A core
    /// returns one from `handleIngress` or pushes one via `host.emit`; this
    /// dispatcher fans its fields out to injected sink closures. There is exactly
    /// one path — no second mechanism, no per-field callbacks on the host.
    ///
    /// It depends on **nothing** in `AppCoordinator`: the wiring phase supplies the
    /// real sink closures (status → `AgentSession`, notification → Mac + iOS push,
    /// response request → iOS form, app actions → Mac features). For now the
    /// closures default to no-ops and the unit tests inject recording closures.
    ///
    /// An `actor` so it can track per-session attention state (to detect *changes*)
    /// without locks while remaining `Sendable`.
    public actor PluginEventDispatcher {
        // MARK: - Sink closure signatures
        //
        // The wiring phase (AppCoordinator) supplies these. Keep them flat and
        // value-typed so the dispatcher never reaches back into app state.

        /// Session status changed — drives `AgentSession.isWorking` / `needsAttention`
        /// and the `agent_session_status` push. `working == nil` means "no opinion".
        public typealias StatusSink = @Sendable (
            _ pluginID: String,
            _ sessionID: String,
            _ working: Bool?,
            _ attention: Bool,
            _ opensBlockingForm: Bool,
            _ tmuxPane: String?,
            _ projectPath: String?
        ) async -> Void

        /// A pre-baked notification to surface Mac-side and push to iOS.
        /// `paneID` is the tmux pane (falling back to the agent session id) so the
        /// push can be associated with its session — same pane-keying as the
        /// response-request sinks.
        public typealias NotificationSink = @Sendable (
            _ pluginID: String,
            _ paneID: String,
            _ notification: NotificationSpec
        ) async -> Void

        /// Open an iOS response form for `requestID`.
        public typealias OpenResponseRequestSink = @Sendable (
            _ pluginID: String,
            _ sessionID: String,
            _ requestID: String,
            _ request: AgentResponseRequest
        ) async -> Void

        /// Retract the iOS response form for `requestID` (agent advanced, or the
        /// user answered Mac-side first).
        public typealias RetractResponseRequestSink = @Sendable (
            _ pluginID: String,
            _ sessionID: String,
            _ requestID: String
        ) async -> Void

        /// One discrete agent-blind Mac-side trigger (markdown suggestion, pane close…).
        public typealias AppActionSink = @Sendable (_ action: AppAction) async -> Void

        /// Whether the pane is in yolo mode (queried Mac-side). Used to suppress the
        /// user-facing signals of an auto-approvable permission the app will approve
        /// silently. The core never learns about yolo — this is purely app state.
        public typealias AutoApproveCheck = @Sendable (_ paneID: String) async -> Bool

        // MARK: - Stored sinks

        private let onStatus: StatusSink
        private let onNotification: NotificationSink
        private let onOpenResponseRequest: OpenResponseRequestSink
        private let onRetractResponseRequest: RetractResponseRequestSink
        private let onAppAction: AppActionSink
        private let isYoloModeEnabled: AutoApproveCheck

        /// Last-seen attention bit per `pluginID:sessionID`, so a status push fires
        /// when attention *changes* even if `working` is `nil`.
        private var lastAttention: [String: Bool] = [:]

        // MARK: - Initialization

        public init(
            onStatus: @escaping StatusSink = { _, _, _, _, _, _, _ in },
            onNotification: @escaping NotificationSink = { _, _, _ in },
            onOpenResponseRequest: @escaping OpenResponseRequestSink = { _, _, _, _ in },
            onRetractResponseRequest: @escaping RetractResponseRequestSink = { _, _, _ in },
            onAppAction: @escaping AppActionSink = { _ in },
            isYoloModeEnabled: @escaping AutoApproveCheck = { _ in false }
        ) {
            self.onStatus = onStatus
            self.onNotification = onNotification
            self.onOpenResponseRequest = onOpenResponseRequest
            self.onRetractResponseRequest = onRetractResponseRequest
            self.onAppAction = onAppAction
            self.isYoloModeEnabled = isYoloModeEnabled
        }

        // MARK: - Dispatch

        /// Fan one envelope out to the sinks (spec §5).
        public func dispatch(_ event: PluginEvent) async {
            let key = statusKey(pluginID: event.pluginID, sessionID: event.sessionID)
            let paneID = event.tmuxPane ?? event.sessionID

            // Yolo auto-approve (spec §6, #338): an auto-approvable permission on a
            // yolo pane is approved silently. The app delivers the approval (the
            // `onOpenResponseRequest` sink's yolo path) AND suppresses every
            // user-facing signal — no attention (the row stays "Working"), no
            // notification push, no iOS form. Without this, attention and the
            // notification fire independently of the form and leak past the silent
            // approval.
            var isYoloAutoApprove = false
            if
                case let .permission(permission)? = event.responseRequest?.request,
                permission.isAutoApprovable {
                isYoloAutoApprove = await isYoloModeEnabled(paneID)
            }

            // A yolo auto-approve forces attention off so the row reads "Working".
            let effectiveAttention = isYoloAutoApprove ? false : event.attention
            let attentionChanged = lastAttention[key] != effectiveAttention
            lastAttention[key] = effectiveAttention

            // Whether this event leaves a blocking form (permission / question /
            // plan approval) open. The status sink sets the "don't auto-clear on
            // view" guard atomically with the attention bit, so a viewer marking
            // the session handled can't race ahead of the form and clear it
            // (#…). Suppressed under a yolo auto-approve — no form is shown.
            let opensBlockingForm = !isYoloAutoApprove && (event.responseRequest?.request?.isBlocking == true)

            // Status: fire when working has an opinion OR attention changed.
            if event.working != nil || attentionChanged {
                await onStatus(
                    event.pluginID,
                    event.sessionID,
                    event.working,
                    effectiveAttention,
                    opensBlockingForm,
                    event.tmuxPane,
                    event.projectPath
                )
            }

            // Notification — suppressed for a silent yolo auto-approve. Keyed by the
            // PANE (like the response-request sinks) so the push targets the right
            // session, not the agent's internal id.
            if let notification = event.notification, !isYoloAutoApprove {
                await onNotification(event.pluginID, paneID, notification)
            }

            // Response request — three-state table (spec §5).
            //
            // iOS is pane-centric: it keys open response forms (and submits
            // responses) by the tmux pane id, and the owning core delivers the
            // response's keystrokes via `host.sendText`/`sendKeys`, whose
            // sessionID is resolved to a pane. So the whole response round-trip
            // is keyed by the PANE, not the agent's internal session id. Fall
            // back to the session id only when no pane is known.
            if let payload = event.responseRequest {
                let responseKey = paneID
                if let request = payload.request {
                    await onOpenResponseRequest(event.pluginID, responseKey, payload.requestID, request)
                } else {
                    await onRetractResponseRequest(event.pluginID, responseKey, payload.requestID)
                }
            }

            // App actions.
            for action in event.appActions {
                // Cap `lastAttention` growth: a session end drops this session's
                // entry so the map doesn't accumulate one key per session for the
                // lifetime of the app.
                if case .sessionEnded = action {
                    lastAttention.removeValue(forKey: key)
                }
                await onAppAction(action)
            }
        }

        private func statusKey(pluginID: String, sessionID: String) -> String {
            "\(pluginID):\(sessionID)"
        }
    }
#endif
