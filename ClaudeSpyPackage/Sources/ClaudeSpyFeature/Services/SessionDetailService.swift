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

    /// Updates response state from the session's `state`, whose `awaiting*` cases
    /// carry the open response form (spec §5/§7.2). A non-awaiting state has no
    /// `openForm`, so the form is cleared.
    private func updateResponseState() {
        let session = sessionStore.session(for: paneId, hostId: hostId)
        if let open = session?.state.openForm {
            if open.requestID != lastProcessedRequestID {
                lastProcessedRequestID = open.requestID
                // Pass sessionStore so ResponseState can persist/restore responses.
                // The pluginID comes from the session that owns the form.
                responseState = ResponseState(
                    request: open.request,
                    pluginID: session?.pluginID ?? "",
                    requestID: open.requestID,
                    sessionStore: sessionStore
                )
            }
        } else if lastProcessedRequestID != nil {
            // The form was retracted (the agent advanced, or answered Mac-side).
            lastProcessedRequestID = nil
            responseState = nil
        }
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
