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

    /// Whether a terminal snapshot is currently being loaded
    public var isLoadingSnapshot = false

    /// The loaded terminal snapshot, if any
    public var terminalSnapshot: TerminalSnapshotMessage?

    /// Error message from snapshot loading, if any
    public var snapshotError: String?

    /// Response state for the current event
    public var responseState: ResponseState?

    // MARK: - Streaming State

    /// Whether terminal streaming is currently active
    public var isStreaming = false

    /// Whether we're currently trying to start streaming
    public var isStartingStream = false

    /// Current terminal width during streaming
    public var streamWidth = 80

    /// Current terminal height during streaming
    public var streamHeight = 24

    /// Error message from streaming, if any
    public var streamError: String?

    /// Callback for streaming data - set by the view to receive live updates
    public var onStreamData: ((Data) -> Void)?

    /// Whether auto-reconnect is enabled for streaming
    public var autoReconnectEnabled = true

    /// Number of reconnection attempts
    private var reconnectAttempts = 0

    /// Maximum number of reconnection attempts
    private let maxReconnectAttempts = 5

    /// Task for reconnection delay
    private var reconnectTask: Task<Void, Never>?

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

    // MARK: - Streaming

    /// Start streaming terminal content from the Mac
    public func startStreaming() async {
        guard !isStreaming, !isStartingStream else { return }

        isStartingStream = true
        streamError = nil
        autoReconnectEnabled = true

        // Set up streaming callbacks before starting the stream
        setupStreamingCallbacks()

        let result = await relayClient.startStream(paneId: paneId)

        switch result {
        case .success:
            // Stream started - isStreaming will be set to true when we receive
            // the terminalStreamStarted message
            break
        case let .failure(error):
            isStartingStream = false
            streamError = error.localizedDescription
            clearStreamingCallbacks()
        }
    }

    /// Stop streaming terminal content
    public func stopStreaming() async {
        guard isStreaming || isStartingStream else { return }

        // Disable auto-reconnect to prevent immediate reconnection
        autoReconnectEnabled = false
        reconnectTask?.cancel()
        reconnectTask = nil

        _ = await relayClient.stopStream(paneId: paneId)

        isStreaming = false
        isStartingStream = false
        reconnectAttempts = 0
        clearStreamingCallbacks()
    }

    /// Set up callbacks to receive streaming data from RelayClient
    private func setupStreamingCallbacks() {
        let paneId = self.paneId

        relayClient.onTerminalStreamStarted = { [weak self] message in
            guard message.paneId == paneId else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isStreaming = true
                self.isStartingStream = false
                self.streamWidth = message.width
                self.streamHeight = message.height
                self.streamError = nil

                // Reset reconnect state on successful connection
                self.resetReconnectState()

                // Feed initial content if present
                if let initialContent = message.initialContent, !initialContent.isEmpty {
                    self.onStreamData?(initialContent)
                }
            }
        }

        relayClient.onTerminalStreamData = { [weak self] message in
            guard message.paneId == paneId else { return }
            guard let data = message.data else { return }
            Task { @MainActor [weak self] in
                self?.onStreamData?(data)
            }
        }

        relayClient.onTerminalStreamStopped = { [weak self] message in
            guard message.paneId == paneId else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isStreaming = false
                self.isStartingStream = false
                if let reason = message.reason {
                    self.streamError = reason
                }

                // Attempt auto-reconnect if enabled
                if self.autoReconnectEnabled {
                    await self.attemptReconnect()
                }
            }
        }

        relayClient.onTerminalStreamDimensionChange = { [weak self] message in
            guard message.paneId == paneId else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.streamWidth = message.width
                self.streamHeight = message.height
            }
        }
    }

    /// Clear streaming callbacks
    private func clearStreamingCallbacks() {
        relayClient.onTerminalStreamStarted = nil
        relayClient.onTerminalStreamData = nil
        relayClient.onTerminalStreamStopped = nil
        relayClient.onTerminalStreamDimensionChange = nil
    }

    /// Attempt to reconnect the stream with exponential backoff
    private func attemptReconnect() async {
        guard
            autoReconnectEnabled,
            !isStreaming,
            !isStartingStream,
            reconnectAttempts < maxReconnectAttempts
        else {
            if reconnectAttempts >= maxReconnectAttempts {
                streamError = "Connection lost. Max reconnection attempts reached."
            }
            return
        }

        reconnectAttempts += 1

        // Calculate delay with exponential backoff: 1s, 2s, 4s, 8s, 16s
        let delay = pow(Double(2), Double(reconnectAttempts - 1))

        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))

            guard !Task.isCancelled, autoReconnectEnabled else { return }

            // Check if Mac is still connected
            guard relayClient.isMacConnected else {
                streamError = "Mac disconnected. Waiting for reconnection..."
                return
            }

            await startStreaming()
        }
    }

    /// Reset reconnection state (call when streaming successfully starts)
    private func resetReconnectState() {
        reconnectAttempts = 0
        reconnectTask?.cancel()
        reconnectTask = nil
    }
}
