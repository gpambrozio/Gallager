import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Foundation

/// Represents a connection to a single paired device, wrapping a `ViewerRelayClient`
/// with device-specific metadata.
///
/// Generic over the paired device type so it works with both `PairedHost` (macOS)
/// and `PairedMac` (iOS).
@Observable
@MainActor
final public class ViewerConnection<Device: ViewerPairedDevice>: Identifiable {
    // MARK: - Properties

    /// Unique identifier (same as pairId)
    public let id: String

    /// The paired device's display name
    public let deviceName: String

    /// The underlying relay client
    public let relayClient: ViewerRelayClient

    /// The E2EE service for this connection
    public let e2eeService: E2EEService

    /// The paired device data
    public let pairedDevice: Device

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

    /// Creates a new connection to a paired device.
    ///
    /// - Parameters:
    ///   - pairedDevice: The paired device configuration
    ///   - e2eeService: The E2EE service for this connection (pre-configured with partner key)
    public init(pairedDevice: Device, e2eeService: E2EEService) {
        self.id = pairedDevice.id
        self.deviceName = pairedDevice.deviceName
        self.pairedDevice = pairedDevice
        self.e2eeService = e2eeService
        self.relayClient = ViewerRelayClient()
    }

    // MARK: - Connection Management

    /// Connect to this device via the relay server.
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

    /// Disconnect from this device
    public func disconnect() async {
        await relayClient.disconnect()
    }

    /// Immediately attempt to reconnect (used when app becomes active)
    public func reconnectImmediately() async {
        await relayClient.reconnectImmediately()
    }

    // MARK: - Commands

    /// Send a command to this device and wait for response.
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

    /// Request current session state from this device
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
}
