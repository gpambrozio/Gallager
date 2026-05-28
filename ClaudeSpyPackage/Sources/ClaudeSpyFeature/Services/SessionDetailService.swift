import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation
import Observation

/// Service managing state and logic for a single agent session detail view.
///
/// Wraps the live `AgentSession` for a pane (so the view can stay in sync
/// without re-reading the store) and surfaces the latest open
/// `AgentResponseRequest` for that session — picked from
/// `SessionStore.responseRequests` whenever a plugin sidecar pushes one in.
@Observable
@MainActor
final public class SessionDetailService {
    // MARK: - Dependencies

    /// The pane ID for this session.
    public let paneId: String

    /// The pair ID of the host this pane belongs to. Required to disambiguate
    /// panes with the same tmux ID (`%0`, `%1`, ...) coming from different hosts.
    public let hostId: String

    /// Reference to the session store for live session data.
    private let sessionStore: SessionStore

    /// Reference to the relay client for communication.
    private let relayClient: ViewerRelayClient

    // MARK: - Private State

    /// Task handling observation tracking (allows cancellation if needed).
    private var observationTask: Task<Void, Never>?

    // MARK: - Computed Properties

    /// Live session from store (always up-to-date via observation tracking).
    public var session: AgentSession? {
        sessionStore.session(for: paneId, hostId: hostId)
    }

    /// Whether the pane is currently active.
    public var isPaneActive: Bool {
        sessionStore.isPaneActive(paneId: paneId, hostId: hostId)
    }

    /// Whether the host is connected to the relay.
    public var isHostConnected: Bool {
        relayClient.isHostConnected
    }

    /// Whether yolo mode is enabled for this pane (as reported by the host).
    public var isYoloModeEnabled: Bool {
        sessionStore.isYoloModeEnabled(paneId: paneId, hostId: hostId)
    }

    /// The relay client for this session (needed for environment injection).
    public var client: ViewerRelayClient {
        relayClient
    }

    // MARK: - Observable State

    /// The currently open response request for this pane's session, if any.
    ///
    /// Picks the request with the matching `(hostId, sessionId, pluginId)`
    /// from `SessionStore.responseRequests`. When multiple are outstanding
    /// (shouldn't happen in practice — the sidecar shouldn't stack asks on
    /// the same session) the most recently received one wins.
    public var openResponseRequest: OpenResponseRequest?

    // MARK: - Initialization

    public init(paneId: String, hostId: String, sessionStore: SessionStore, relayClient: ViewerRelayClient) {
        self.paneId = paneId
        self.hostId = hostId
        self.sessionStore = sessionStore
        self.relayClient = relayClient

        // Perform initial update and start observation.
        updateOpenResponseRequest()
        startObservingSessionStore()
    }

    // MARK: - Observation

    /// Starts observing `SessionStore` for changes via `withObservationTracking`.
    /// Re-registers after each change because the tracking is single-shot.
    private func startObservingSessionStore() {
        observationTask?.cancel()

        observationTask = Task { [weak self] in
            guard let self else { return }

            withObservationTracking {
                _ = self.sessionStore.session(for: self.paneId, hostId: self.hostId)
                _ = self.sessionStore.responseRequests
            } onChange: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.updateOpenResponseRequest()
                    self.startObservingSessionStore()
                }
            }
        }
    }

    /// Updates `openResponseRequest` based on the current contents of
    /// `SessionStore.responseRequests`. Matches by `(hostId, sessionId,
    /// pluginId)` — pane id isn't on the response wire, so we lean on the
    /// session id from `AgentSession` to link the request to this pane.
    private func updateOpenResponseRequest() {
        guard let session else {
            openResponseRequest = nil
            return
        }

        let candidates = sessionStore.responseRequests.values.filter { entry in
            entry.hostId == hostId
                && entry.sessionId == session.id
                && entry.pluginId == session.pluginID
        }

        // Most-recent wins when multiple are open simultaneously, ordered by
        // the arrival timestamp stamped on each entry. `requestId` is only a
        // stable tiebreak for entries that arrived in the same instant.
        let latest = candidates.max(by: { lhs, rhs in
            if lhs.receivedAt != rhs.receivedAt {
                return lhs.receivedAt < rhs.receivedAt
            }
            return lhs.requestId.localizedCompare(rhs.requestId) == .orderedAscending
        })

        if let latest {
            openResponseRequest = OpenResponseRequest(entry: latest, receivedAt: latest.receivedAt)
        } else {
            openResponseRequest = nil
        }
    }

    // MARK: - Actions

    /// Marks the session as handled locally and notifies the host.
    public func markHandledIfNeeded() async {
        guard session?.attention == true else { return }
        sessionStore.markSessionHandled(paneId: paneId, hostId: hostId)
        _ = await relayClient.sendCommand(MarkHandled(), paneId: paneId)
    }

    /// Send a command to the host for this pane (fire-and-forget style).
    public func sendCommand(_ command: CommandType) async {
        await relayClient.send(command, paneId: paneId)
    }

    // MARK: - Testing Hooks

    /// Force `openResponseRequest` to re-pull from the store synchronously.
    /// Production code relies on `withObservationTracking`, which is async;
    /// tests use this to assert against the new state without waiting.
    func refreshOpenResponseRequestForTesting() {
        updateOpenResponseRequest()
    }
}
