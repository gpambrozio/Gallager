import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Foundation

/// Represents a connection to a single paired host, wrapping a `ViewerRelayClient`
/// with host-specific metadata.
@Observable
@MainActor
final public class ViewerConnection: Identifiable {
    // MARK: - Properties

    /// Unique identifier (same as pairId)
    public let id: String

    /// The paired host's display name
    public var hostName: String { pairedDevice.hostName }

    /// The underlying relay client
    public let relayClient: ViewerRelayClient

    /// The E2EE service for this connection
    public let e2eeService: E2EEService

    /// The paired host data
    public let pairedDevice: PairedHost

    // MARK: - Computed Properties

    /// Current connection state
    public var state: ViewerRelayClient.ConnectionState {
        relayClient.state
    }

    /// Whether the host is currently connected
    public var isHostConnected: Bool {
        relayClient.isHostConnected
    }

    /// Whether the WebSocket is connected to the relay
    public var isRelayConnected: Bool {
        relayClient.state.isConnected
    }

    // MARK: - Initialization

    /// Creates a new connection to a paired host.
    ///
    /// - Parameters:
    ///   - pairedDevice: The paired host configuration
    ///   - e2eeService: The E2EE service for this connection (pre-configured with partner key)
    public init(pairedDevice: PairedHost, e2eeService: E2EEService) {
        self.id = pairedDevice.id
        self.pairedDevice = pairedDevice
        self.e2eeService = e2eeService
        self.relayClient = ViewerRelayClient()
    }

    // MARK: - Connection Management

    /// Connect to this host via the relay server.
    ///
    /// - Parameters:
    ///   - serverURL: The relay server URL
    ///   - deviceId: This device's identifier (as viewer)
    ///   - deviceName: This device's display name
    ///   - publicKey: This device's public key (Base64)
    ///   - publicKeyId: This device's public key ID
    public func connect(
        serverURL: URL,
        deviceId: String,
        deviceName: String,
        publicKey: String,
        publicKeyId: String
    ) async {
        await relayClient.connect(
            serverURL: serverURL,
            pairId: pairedDevice.id,
            deviceId: deviceId,
            deviceName: deviceName,
            publicKey: publicKey,
            publicKeyId: publicKeyId,
            e2eeService: e2eeService,
            partnerPublicKey: pairedDevice.partnerPublicKey,
            partnerPublicKeyId: pairedDevice.partnerPublicKeyId
        )
    }

    /// Disconnect from this host
    public func disconnect() async {
        await relayClient.disconnect()
    }

    /// Immediately attempt to reconnect (used when app becomes active)
    public func reconnectImmediately() async {
        await relayClient.reconnectImmediately()
    }

    // MARK: - Commands

    /// Send a command to this host and wait for response.
    ///
    /// - Parameters:
    ///   - command: The command specification
    ///   - paneId: The tmux pane ID to target
    ///   - timeout: Maximum time to wait for response
    /// - Returns: Result containing the response or error
    public func sendCommand<C: CommandSpec>(
        _ command: C,
        paneId: String,
        timeout: TimeInterval = 15
    ) async -> Result<C.Response, Error> {
        await relayClient.sendCommand(command, paneId: paneId, timeout: timeout)
    }

    /// Request current session state from this host
    public func requestSessionState() async {
        await relayClient.requestSessionState()
    }

    /// Send push notification token to the relay server.
    ///
    /// - Parameter token: The APNs device token as a hex string
    public func sendPushToken(_ token: String) async {
        await relayClient.sendPushToken(token)
    }

    // MARK: - Callbacks Setup

    /// Configure callbacks for this connection.
    ///
    /// - Parameters:
    ///   - onHookEvent: Called when a hook event is received
    ///   - onSessionState: Called when session state is received
    ///   - onTerminalStream: Called when terminal stream data is received
    ///   - onPartnerKeyReceived: Called when partner's public key is updated
    public func setupCallbacks(
        onHookEvent: (@Sendable (HookEventMessage) -> Void)? = nil,
        onSessionState: (@Sendable (SessionStateMessage) -> Void)? = nil,
        onTerminalStream: (@MainActor @Sendable (TerminalStreamMessage) -> Void)? = nil,
        onPartnerKeyReceived: (@MainActor @Sendable (String, String) async -> Void)? = nil
    ) {
        relayClient.onHookEvent = onHookEvent
        relayClient.onSessionState = onSessionState
        relayClient.onTerminalStream = onTerminalStream
        relayClient.onPartnerKeyReceived = onPartnerKeyReceived
    }

    // MARK: - Terminal Stream Subscriptions

    /// Registered terminal stream handlers keyed by subscription UUID, with their target pane ID.
    private var terminalStreamSubscribers: [UUID: (paneId: String, handler: @MainActor (TerminalStreamMessage) -> Void)] = [:]

    /// Subscribe to terminal stream messages for a specific pane.
    ///
    /// Multiple subscribers can be active simultaneously for different panes on the same host.
    /// Each subscriber receives only messages matching its paneId.
    ///
    /// - Parameters:
    ///   - paneId: The pane ID to receive stream data for
    ///   - handler: Called on MainActor when a matching stream message arrives
    /// - Returns: Subscription ID used to unsubscribe later
    public func subscribeToTerminalStream(
        paneId: String,
        handler: @MainActor @escaping (TerminalStreamMessage) -> Void
    ) -> UUID {
        let subscriptionId = UUID()
        terminalStreamSubscribers[subscriptionId] = (paneId: paneId, handler: handler)

        // Install the multiplexing handler on the relay client if not already set up
        installTerminalStreamMultiplexer()

        return subscriptionId
    }

    /// Unsubscribe from terminal stream messages.
    ///
    /// - Parameter subscriptionId: The ID returned from `subscribeToTerminalStream`
    public func unsubscribeFromTerminalStream(_ subscriptionId: UUID) {
        terminalStreamSubscribers.removeValue(forKey: subscriptionId)
    }

    /// Installs a single onTerminalStream handler that routes messages to all matching subscribers.
    private func installTerminalStreamMultiplexer() {
        relayClient.onTerminalStream = { [weak self] message in
            guard let self else { return }
            for (_, subscriber) in self.terminalStreamSubscribers {
                if subscriber.paneId == message.paneId {
                    subscriber.handler(message)
                }
            }
        }
    }
}
