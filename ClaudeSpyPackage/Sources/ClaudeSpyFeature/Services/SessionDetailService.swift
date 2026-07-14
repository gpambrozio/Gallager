import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation
import Observation

/// Service managing state and logic for a single Claude session detail view.
///
/// This service encapsulates business logic for displaying and interacting with a session,
/// including terminal snapshots, response state management, and command sending.
/// It provides a live view of the session data from SessionStore, avoiding staleness issues.
///
/// The service uses `withObservationTracking` to reactively observe changes in `SessionStore`
/// and automatically update response state when the session's latest event changes.
@Observable
@MainActor
final public class SessionDetailService {
    // MARK: - Dependencies

    /// The pane ID for this session
    public let paneId: String

    /// The pair ID of the host this pane belongs to. Required to disambiguate
    /// panes with the same tmux ID (`%0`, `%1`, ...) coming from different hosts.
    public let hostId: String

    /// Reference to the session store for live session data
    private let sessionStore: SessionStore

    /// Reference to the relay client for communication
    private let relayClient: ViewerRelayClient

    // MARK: - Private State

    /// Tracks the last request ID we built response state for.
    private var lastProcessedRequestID: String?

    /// Task handling observation tracking (allows cancellation if needed)
    private var observationTask: Task<Void, Never>?

    // MARK: - Computed Properties

    /// Live session from store (always up-to-date via observation tracking)
    public var session: AgentSession? {
        sessionStore.session(for: paneId, hostId: hostId)
    }

    /// Whether the pane is currently active
    public var isPaneActive: Bool {
        sessionStore.isPaneActive(paneId: paneId, hostId: hostId)
    }

    /// Live OTEL telemetry for this pane (issue #597), or `nil` if none has
    /// arrived yet.
    public var telemetry: SessionTelemetry? {
        sessionStore.paneState(for: paneId, hostId: hostId)?.telemetry
    }

    /// Live permission mode for this pane (issue #597), or `nil` if no mode
    /// change has been observed.
    public var permissionMode: String? {
        sessionStore.paneState(for: paneId, hostId: hostId)?.permissionMode
    }

    /// What triggered the latest permission-mode change, if known.
    public var permissionModeTrigger: String? {
        sessionStore.paneState(for: paneId, hostId: hostId)?.permissionModeTrigger
    }

    /// End-of-turn recap for this pane (issue #598), or `nil` when the agent is
    /// mid-turn or has produced no telemetry.
    public var recap: SessionRecap? {
        sessionStore.paneState(for: paneId, hostId: hostId)?.recap
    }

    /// Whether the host is connected to the relay
    public var isHostConnected: Bool {
        relayClient.isHostConnected
    }

    /// Whether yolo mode is enabled for this pane (as reported by the host)
    public var isYoloModeEnabled: Bool {
        sessionStore.isYoloModeEnabled(paneId: paneId, hostId: hostId)
    }

    /// The relay client for this session (needed for environment injection)
    public var client: ViewerRelayClient {
        relayClient
    }

    // MARK: - Observable State

    /// Response state for the current event
    public var responseState: ResponseState?

    // MARK: - Initialization

    public init(paneId: String, hostId: String, sessionStore: SessionStore, relayClient: ViewerRelayClient) {
        self.paneId = paneId
        self.hostId = hostId
        self.sessionStore = sessionStore
        self.relayClient = relayClient

        // Perform initial update and start observation
        updateResponseState()
        startObservingSessionStore()
    }

    // MARK: - Observation

    /// Starts observing SessionStore for changes using withObservationTracking
    private func startObservingSessionStore() {
        // Cancel any existing observation task
        observationTask?.cancel()

        observationTask = Task { [weak self] in
            guard let self else { return }

            withObservationTracking {
                // Observe the session; its `state` carries the open response form.
                _ = self.sessionStore.session(for: self.paneId, hostId: self.hostId)
            } onChange: {
                // Schedule update on main actor when store changes
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.updateResponseState()
                    // Re-register for next change (withObservationTracking is single-shot)
                    self.startObservingSessionStore()
                }
            }
        }
    }

    /// Stable request id for the synthesized reply-after-stop box (see
    /// `updateResponseState`). Keyed per `(host, pane)` so it survives the brief
    /// `doneWorking → idle` flip that viewing triggers — keeping the reply field,
    /// its summary, and any typed text in place — and resets only when the agent
    /// resumes working.
    private var replyAfterStopRequestID: String {
        "\(hostId):\(paneId):reply-after-stop"
    }

    /// Updates response state from the session's `state`. Blocking forms ride the
    /// `awaiting*` cases' `openForm` (spec §5/§7.2). When the agent is stopped
    /// (`doneWorking`) or idle at the prompt, we synthesize a non-blocking
    /// reply-after-stop box so a remote user can reply or send a prompt — this is
    /// iOS-side only and deliberately does NOT ride `openForm`, which is reserved
    /// for blocking forms that gate host-side attention.
    private func updateResponseState() {
        let session = sessionStore.session(for: paneId, hostId: hostId)
        if let open = session?.state.openForm {
            applyForm(open.request, requestID: open.requestID, pluginID: session?.pluginID ?? "")
        } else if let session, let reply = Self.replyForm(for: session.state) {
            applyForm(.replyAfterStop(reply), requestID: replyAfterStopRequestID, pluginID: session.pluginID)
        } else {
            clearResponseState()
        }
    }

    /// Builds the reply-after-stop box for the states that wait at the prompt.
    /// `doneWorking` carries the agent's last-message summary; a plain `idle`
    /// session (fresh, or one that was viewed after stopping) has none. Working
    /// and blocking-form states get no reply box.
    private static func replyForm(for state: AgentState) -> ReplyAfterStopRequest? {
        switch state {
        case let .doneWorking(summary):
            return ReplyAfterStopRequest(title: "Reply", summary: summary)
        case .idle:
            return ReplyAfterStopRequest(title: "Reply")
        case .working,
             .awaitingPlanApproval,
             .awaitingPermission,
             .awaitingReplies:
            return nil
        }
    }

    /// Builds `ResponseState` for a form, but only when the request id changes so
    /// the view (and its per-request `@State`) is preserved across no-op updates.
    private func applyForm(_ request: AgentResponseRequest, requestID: String, pluginID: String) {
        guard requestID != lastProcessedRequestID else { return }
        lastProcessedRequestID = requestID
        // Pass sessionStore so ResponseState can persist/restore responses.
        responseState = ResponseState(
            request: request,
            pluginID: pluginID,
            requestID: requestID,
            sessionStore: sessionStore
        )
    }

    /// Clears the open form (the agent advanced to `working`, or the session is
    /// gone). Also drops any persisted reply for the synthesized box so the next
    /// stop starts with a fresh, empty reply field rather than the prior "sent"
    /// state.
    private func clearResponseState() {
        guard lastProcessedRequestID != nil else { return }
        #if os(iOS)
            sessionStore.setResponse(nil, forRequestID: replyAfterStopRequestID)
        #endif
        lastProcessedRequestID = nil
        responseState = nil
    }

    // MARK: - Actions

    /// Marks the session as handled locally and notifies the host
    public func markHandledIfNeeded() async {
        guard session?.needsAttention == true else { return }
        sessionStore.markSessionHandled(paneId: paneId, hostId: hostId)
        _ = await relayClient.sendCommand(MarkHandled(), paneId: paneId)
    }

    /// Send a command to the host for this pane (fire-and-forget style)
    public func sendCommand(_ command: CommandType) async {
        await relayClient.send(command, paneId: paneId)
    }

    /// Submit a structured `AgentResponse` for the open request. The host matches
    /// `requestID` and calls `core.deliverResponse(...)` (spec §7.2).
    public func submitResponse(_ response: AgentResponse, pluginID: String, requestID: String) async {
        await relayClient.submitAgentResponse(
            sessionId: paneId,
            pluginId: pluginID,
            requestId: requestID,
            response: response
        )
    }
}
