import ClaudeSpyNetworking
import Foundation

/// Service managing state and logic for a single Claude session detail view.
///
/// This service encapsulates business logic for displaying and interacting with a session,
/// including terminal snapshots, response state management, and command sending.
/// It provides a live view of the session data from SessionStore, avoiding staleness issues.
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

    // MARK: - Computed Properties

    /// Live session from store (always up-to-date, not a stale snapshot)
    /// Automatically updates response state when latest event changes
    public var session: ClaudeSession? {
        let currentSession = sessionStore.session(for: paneId)

        // Automatically update response state if latest event changed
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

        return currentSession
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

    /// Whether a terminal snapshot is currently being loaded
    public var isLoadingSnapshot = false

    /// The loaded terminal snapshot, if any
    public var terminalSnapshot: TerminalSnapshotMessage?

    /// Error message from snapshot loading, if any
    public var snapshotError: String?

    /// Response state for the current event
    public var responseState: ResponseState?

    // MARK: - Initialization

    public init(paneId: String, sessionStore: SessionStore, relayClient: RelayClient) {
        self.paneId = paneId
        self.sessionStore = sessionStore
        self.relayClient = relayClient
        // Response state is automatically updated when session getter is accessed
    }

    // MARK: - Actions

    /// Request a terminal snapshot from the Mac
    public func requestTerminalSnapshot() async {
        isLoadingSnapshot = true
        snapshotError = nil

        let command = CommandMessage(paneId: paneId, command: .captureSnapshot(scrollbackMultiplier: 3))
        let result = await relayClient.sendSnapshotCommand(command)

        isLoadingSnapshot = false

        switch result {
        case let .success(snapshot):
            terminalSnapshot = snapshot
        case let .failure(error):
            snapshotError = error.localizedDescription
        }
    }

    /// Send a command to the Mac for this pane
    public func sendCommand(_ command: CommandType) async {
        await relayClient.sendCommand(CommandMessage(paneId: paneId, command: command))
    }
}
