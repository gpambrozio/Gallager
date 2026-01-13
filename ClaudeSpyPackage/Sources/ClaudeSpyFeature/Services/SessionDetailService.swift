import ClaudeSpyNetworking
import Foundation
import Observation

/// Service managing state and logic for a single Claude session detail view.
///
/// This service encapsulates business logic for displaying and interacting with a session,
/// including response state management and command sending.
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

    /// Reference to the session store for live session data
    private let sessionStore: SessionStore

    /// Reference to the relay client for communication
    private let relayClient: RelayClient

    // MARK: - Private State

    /// Tracks the last event ID we processed for response state
    private var lastProcessedEventId: UUID?

    /// Task handling observation tracking (allows cancellation if needed)
    private var observationTask: Task<Void, Never>?

    // MARK: - Computed Properties

    /// Live session from store (always up-to-date via observation tracking)
    public var session: ClaudeSession? {
        sessionStore.session(for: paneId)
    }

    /// Whether the pane is currently active
    public var isPaneActive: Bool {
        sessionStore.isPaneActive(paneId)
    }

    /// Whether the Mac is connected to the relay
    public var isMacConnected: Bool {
        relayClient.isMacConnected
    }

    // MARK: - Observable State

    /// Response state for the current event
    public var responseState: ResponseState?

    /// Whether to show the live terminal view
    public var showLiveTerminal = false

    // MARK: - Initialization

    public init(paneId: String, sessionStore: SessionStore, relayClient: RelayClient) {
        self.paneId = paneId
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
                // Access the properties we want to observe
                _ = self.sessionStore.session(for: self.paneId)
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

    /// Updates response state based on current session's latest event
    private func updateResponseState() {
        let currentSession = sessionStore.session(for: paneId)

        if let latestEvent = currentSession?.latestEvent {
            if latestEvent.id != lastProcessedEventId {
                lastProcessedEventId = latestEvent.id
                responseState = ResponseState(event: latestEvent)
            }
        } else if lastProcessedEventId != nil {
            // Session has no events anymore, clear state
            lastProcessedEventId = nil
            responseState = nil
        }
    }

    // MARK: - Actions

    /// Open the live terminal streaming view
    public func openLiveTerminal() {
        showLiveTerminal = true
    }

    /// Send a command to the Mac for this pane (fire-and-forget style)
    public func sendCommand(_ command: CommandType) async {
        // Extract the spec from the CommandType and send it
        switch command {
        case let .sendKeystroke(spec):
            _ = await relayClient.sendCommand(spec, paneId: paneId)
        case let .cancelOperation(spec):
            _ = await relayClient.sendCommand(spec, paneId: paneId)
        case let .startTerminalStream(spec):
            _ = await relayClient.sendCommand(spec, paneId: paneId)
        case let .stopTerminalStream(spec):
            _ = await relayClient.sendCommand(spec, paneId: paneId)
        }
    }
}
