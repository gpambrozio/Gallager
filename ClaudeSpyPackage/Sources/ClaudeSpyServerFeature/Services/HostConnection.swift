import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Foundation

/// Represents a connection to a single paired Mac host (as viewed from another Mac).
///
/// This wraps a `HostRelayClient` with host-specific metadata and provides
/// a cleaner interface for managing individual host connections. This is the
/// Mac-side equivalent of `MacConnection` on iOS.
@Observable
@MainActor
final public class HostConnection: Identifiable {
    // MARK: - Properties

    /// Unique identifier (same as pairId)
    public let id: String

    /// The paired host's display name
    public let hostName: String

    /// The underlying relay client
    public let relayClient: HostRelayClient

    /// The E2EE service for this connection
    public let e2eeService: E2EEService

    /// The paired host data
    public let pairedHost: PairedHost

    // MARK: - Computed Properties

    /// Current connection state
    public var state: HostRelayClient.ConnectionState {
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

    /// Creates a new host connection.
    ///
    /// - Parameters:
    ///   - pairedHost: The paired host configuration
    ///   - e2eeService: The E2EE service for this connection (pre-configured with partner key)
    public init(pairedHost: PairedHost, e2eeService: E2EEService) {
        self.id = pairedHost.id
        self.hostName = pairedHost.hostName
        self.pairedHost = pairedHost
        self.e2eeService = e2eeService
        self.relayClient = HostRelayClient()
    }

    // MARK: - Connection Management

    /// Connect to this host via the relay server.
    ///
    /// - Parameters:
    ///   - serverURL: The relay server URL
    ///   - deviceId: This Mac's identifier (as viewer)
    ///   - deviceName: This Mac's display name
    ///   - publicKey: This Mac's public key (Base64)
    ///   - publicKeyId: This Mac's public key ID
    public func connect(
        serverURL: URL,
        deviceId: String,
        deviceName: String,
        publicKey: String,
        publicKeyId: String
    ) async {
        await relayClient.connect(
            serverURL: serverURL,
            pairId: pairedHost.id,
            deviceId: deviceId,
            deviceName: deviceName,
            publicKey: publicKey,
            publicKeyId: publicKeyId,
            e2eeService: e2eeService,
            partnerPublicKey: pairedHost.partnerPublicKey,
            partnerPublicKeyId: pairedHost.partnerPublicKeyId
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
}
