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

    /// Tracks the last event ID we processed for response state
    private var lastProcessedEventId: UUID?

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
                // Access the properties we want to observe — both the session
                // and the latest-event bridge so we re-fire when a fresh
                // HookEvent lands even without a session-shape change.
                _ = self.sessionStore.session(for: self.paneId, hostId: self.hostId)
                _ = self.sessionStore.latestEvent(for: self.paneId, hostId: self.hostId)
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

    /// Updates response state based on the latest hook event for this pane.
    ///
    /// TODO(plugin-system): Reads the transitional `latestEventByPane` cache
    /// on `SessionStore`. Task 19 reroutes this onto `AgentResponseRequest`
    /// push messages emitted by plugin sidecars; Task 20 then deletes the
    /// `HookEvent` decode path on iOS entirely.
    private func updateResponseState() {
        let latestEvent = sessionStore.latestEvent(for: paneId, hostId: hostId)
        if let latestEvent {
            if latestEvent.id != lastProcessedEventId {
                lastProcessedEventId = latestEvent.id
                // Pass sessionStore so ResponseState can persist/restore responses
                responseState = ResponseState(event: latestEvent, sessionStore: sessionStore)
            }
        } else if lastProcessedEventId != nil {
            // Session has no events anymore, clear state
            lastProcessedEventId = nil
            responseState = nil
        }
    }

    // MARK: - Actions

    /// Marks the session as handled locally and notifies the host
    public func markHandledIfNeeded() async {
        guard session?.attention == true else { return }
        sessionStore.markSessionHandled(paneId: paneId, hostId: hostId)
        _ = await relayClient.sendCommand(MarkHandled(), paneId: paneId)
    }

    /// Send a command to the host for this pane (fire-and-forget style)
    public func sendCommand(_ command: CommandType) async {
        await relayClient.send(command, paneId: paneId)
    }
}
