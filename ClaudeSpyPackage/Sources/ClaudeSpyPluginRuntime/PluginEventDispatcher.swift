import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Logging

// MARK: - PluginEventDispatcher

/// Routes a single `PluginEvent` envelope to the appropriate Mac-side sinks.
///
/// Per Spec §17.1, the dispatcher also handles the yolo auto-approve carve-out:
/// when a plugin emits a `permission` request flagged `isAutoApprovable: true`
/// for a pane the user has set to yolo mode, the dispatcher fires the
/// `AutoApprovalDelegate` (which routes back to the owning sidecar via
/// `deliver_response`) and does NOT forward the request to the iOS UI.
///
/// The dispatcher itself is an actor so multiple concurrent
/// `dispatch(_:)` calls serialise their sink ordering — each event's sinks
/// fire in declared order (status → notification → request → app actions).
public actor PluginEventDispatcher {
    // MARK: - AutoApprovalDelegate

    /// Called when yolo mode + auto-approvable permission collide. The
    /// delegate is responsible for calling `deliver_response` on the right
    /// sidecar so the agent can proceed without bouncing through iOS.
    public protocol AutoApprovalDelegate: AnyObject, Sendable {
        func autoApprove(
            pluginID: String,
            sessionID: String,
            requestID: String
        ) async
    }

    // MARK: - State

    private let statusSink: any PluginSessionStatusSink
    private let notificationSink: any PluginNotificationSink
    private let responseRequestSink: any PluginResponseRequestSink
    private let appActionSink: any PluginAppActionSink
    private let yoloProvider: any YoloModeProvider
    private weak var autoApprovalDelegate: (any AutoApprovalDelegate)?
    private let logger: Logger

    // MARK: - Init

    public init(
        statusSink: any PluginSessionStatusSink,
        notificationSink: any PluginNotificationSink,
        responseRequestSink: any PluginResponseRequestSink,
        appActionSink: any PluginAppActionSink,
        yoloProvider: any YoloModeProvider,
        autoApprovalDelegate: (any AutoApprovalDelegate)? = nil,
        logger: Logger? = nil
    ) {
        self.statusSink = statusSink
        self.notificationSink = notificationSink
        self.responseRequestSink = responseRequestSink
        self.appActionSink = appActionSink
        self.yoloProvider = yoloProvider
        self.autoApprovalDelegate = autoApprovalDelegate
        self.logger = logger ?? Logger(label: "gallager.plugin.dispatcher")
    }

    // MARK: - Wiring

    /// Late-bound auto-approval delegate. `PluginManager` constructs the
    /// dispatcher up front and binds itself as the delegate once it's fully
    /// initialised — keeping the public init free of a chicken-and-egg
    /// circular reference.
    public func setAutoApprovalDelegate(_ delegate: any AutoApprovalDelegate) async {
        autoApprovalDelegate = delegate
    }

    // MARK: - Dispatch

    /// Route `event` to every sink that cares.
    ///
    /// Sink order (matches Spec §6.3):
    /// 1. `statusSink` — when the event carries a `working` opinion OR an
    ///    `attention` flag set to `true`.
    /// 2. `notificationSink` — when `notification` is present.
    /// 3. `responseRequestSink` — when `responseRequest` is present. Yolo
    ///    auto-approve short-circuits here for `permission` requests flagged
    ///    `isAutoApprovable`.
    /// 4. `appActionSink` — fire-and-forget once per declared `AppAction`.
    ///
    /// `event.tmuxPane` is forwarded to every sink so the Mac can bootstrap
    /// an `AgentSession` from the inbound pane when process-name detection
    /// didn't already do so.
    public func dispatch(_ event: PluginEvent) async {
        // 1. Status — emit when the sidecar expressed any opinion. `working`
        //    being `nil` AND `attention == false` means "no change", so we
        //    skip the sink call to avoid stale-state nudges.
        if event.working != nil || event.attention {
            await statusSink.updateStatus(
                pluginID: event.pluginID,
                sessionID: event.sessionID,
                tmuxPane: event.tmuxPane,
                projectPath: event.projectPath,
                working: event.working,
                attention: event.attention
            )
        }

        // 2. Notification — title + body if the sidecar shaped one.
        if let notification = event.notification {
            await notificationSink.deliverNotification(
                pluginID: event.pluginID,
                sessionID: event.sessionID,
                tmuxPane: event.tmuxPane,
                projectPath: event.projectPath,
                title: notification.title,
                body: notification.body
            )
        }

        // 3. Response request — surfaces to iOS unless yolo auto-approves.
        if let payload = event.responseRequest {
            await dispatchResponseRequest(
                payload,
                sessionID: event.sessionID,
                pluginID: event.pluginID,
                tmuxPane: event.tmuxPane,
                projectPath: event.projectPath
            )
        }

        // 4. App actions — fire each in declaration order.
        for action in event.appActions {
            await appActionSink.handle(
                pluginID: event.pluginID,
                sessionID: event.sessionID,
                tmuxPane: event.tmuxPane,
                projectPath: event.projectPath,
                action: action
            )
        }
    }

    // MARK: - Helpers

    private func dispatchResponseRequest(
        _ payload: PluginEvent.ResponseRequestPayload,
        sessionID: String,
        pluginID: String,
        tmuxPane: String?,
        projectPath: String?
    ) async {
        // Compute the auto-approvable bit once. Only `permission` requests
        // carry a self-declared safety flag — other request shapes (ask user,
        // approve plan, prompt, replyAfterStop) always reach the user.
        let isAutoApprovable: Bool
        switch payload.request {
        case let .permission(req):
            isAutoApprovable = req.isAutoApprovable
        case .prompt,
             .replyAfterStop,
             .askUserQuestion,
             .approvePlan:
            isAutoApprovable = false
        }

        // Yolo carve-out: only fires when the request is a permission AND
        // flagged auto-approvable AND the pane is in yolo mode. The
        // dispatcher consults the yolo provider lazily so we don't pay the
        // round-trip on non-permission requests.
        if isAutoApprovable {
            let yolo = await yoloProvider.isYolo(forSessionID: sessionID)
            if yolo {
                if let delegate = autoApprovalDelegate {
                    await delegate.autoApprove(
                        pluginID: pluginID,
                        sessionID: sessionID,
                        requestID: payload.requestID
                    )
                } else {
                    logger.warning(
                        "auto-approvable permission for yolo pane but no delegate; falling through to user"
                    )
                    await responseRequestSink.deliverRequest(
                        pluginID: pluginID,
                        sessionID: sessionID,
                        tmuxPane: tmuxPane,
                        projectPath: projectPath,
                        requestID: payload.requestID,
                        request: payload.request,
                        isAutoApprovable: isAutoApprovable
                    )
                }
                return
            }
        }

        await responseRequestSink.deliverRequest(
            pluginID: pluginID,
            sessionID: sessionID,
            tmuxPane: tmuxPane,
            projectPath: projectPath,
            requestID: payload.requestID,
            request: payload.request,
            isAutoApprovable: isAutoApprovable
        )
    }
}
