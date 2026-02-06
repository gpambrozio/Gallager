import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Foundation

/// Represents a connection to a single paired Mac host for viewing.
///
/// This wraps a `HostRelayClient` with Mac host-specific metadata and provides
/// a cleaner interface for managing individual Mac host connections.
@Observable
@MainActor
final public class HostConnection: Identifiable {
    // MARK: - Properties

    /// Unique identifier (same as pairId)
    public let id: String

    /// The Mac host's display name
    public let macName: String

    /// The underlying relay client
    public let relayClient: HostRelayClient

    /// The E2EE service for this connection
    public let e2eeService: E2EEService

    /// The paired Mac host data
    public let pairedMacHost: PairedMacHost

    // MARK: - Computed Properties

    /// Current connection state
    public var state: HostRelayClient.ConnectionState {
        relayClient.state
    }

    /// Whether the Mac host is currently connected
    public var isMacHostConnected: Bool {
        relayClient.isMacConnected
    }

    /// Whether the WebSocket is connected to the relay
    public var isRelayConnected: Bool {
        relayClient.state.isConnected
    }

    // MARK: - Initialization

    /// Creates a new Mac host connection.
    ///
    /// - Parameters:
    ///   - pairedMacHost: The paired Mac host configuration
    ///   - e2eeService: The E2EE service for this connection (pre-configured with partner key)
    public init(pairedMacHost: PairedMacHost, e2eeService: E2EEService) {
        self.id = pairedMacHost.id
        self.macName = pairedMacHost.macName
        self.pairedMacHost = pairedMacHost
        self.e2eeService = e2eeService
        self.relayClient = HostRelayClient()
    }

    // MARK: - Connection Management

    /// Connect to this Mac host via the relay server.
    ///
    /// - Parameters:
    ///   - serverURL: The relay server URL
    ///   - deviceId: This Mac's device identifier
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
            pairId: pairedMacHost.id,
            deviceId: deviceId,
            deviceName: deviceName,
            publicKey: publicKey,
            publicKeyId: publicKeyId,
            e2eeService: e2eeService,
            partnerPublicKey: pairedMacHost.partnerPublicKey,
            partnerPublicKeyId: pairedMacHost.partnerPublicKeyId
        )
    }

    /// Disconnect from this Mac host
    public func disconnect() async {
        await relayClient.disconnect()
    }

    /// Immediately attempt to reconnect (used when Mac wakes from sleep)
    public func reconnectImmediately() async {
        await relayClient.reconnectImmediately()
    }

    // MARK: - Commands

    /// Send a command to this Mac host and wait for response.
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

    /// Request current session state from this Mac host
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
