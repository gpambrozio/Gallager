#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import ClaudeSpyNetworking
    import Foundation

    /// Represents a connection to a single paired Mac server.
    ///
    /// This wraps a `RelayClient` with Mac-specific metadata and provides
    /// a cleaner interface for managing individual Mac connections.
    @Observable
    @MainActor
    final public class MacConnection: Identifiable {
        // MARK: - Properties

        /// Unique identifier (same as pairId)
        public let id: String

        /// The paired Mac's display name
        public let macName: String

        /// The underlying relay client
        public let relayClient: RelayClient

        /// The E2EE service for this connection
        public let e2eeService: E2EEService

        /// The paired Mac data
        public let pairedMac: PairedMac

        // MARK: - Computed Properties

        /// Current connection state
        public var state: RelayClient.ConnectionState {
            relayClient.state
        }

        /// Whether the Mac (host) is currently connected
        public var isHostConnected: Bool {
            relayClient.isHostConnected
        }

        /// Whether the WebSocket is connected to the relay
        public var isRelayConnected: Bool {
            relayClient.state.isConnected
        }

        // MARK: - Initialization

        /// Creates a new Mac connection.
        ///
        /// - Parameters:
        ///   - pairedMac: The paired Mac configuration
        ///   - e2eeService: The E2EE service for this connection (pre-configured with partner key)
        public init(pairedMac: PairedMac, e2eeService: E2EEService) {
            self.id = pairedMac.id
            self.macName = pairedMac.macName
            self.pairedMac = pairedMac
            self.e2eeService = e2eeService
            self.relayClient = RelayClient()
        }

        // MARK: - Connection Management

        /// Connect to this Mac via the relay server.
        ///
        /// - Parameters:
        ///   - serverURL: The relay server URL
        ///   - deviceId: This iOS device's identifier
        ///   - deviceName: This iOS device's display name
        ///   - publicKey: This iOS device's public key (Base64)
        ///   - publicKeyId: This iOS device's public key ID
        public func connect(
            serverURL: URL,
            deviceId: String,
            deviceName: String,
            publicKey: String,
            publicKeyId: String
        ) async {
            await relayClient.connect(
                serverURL: serverURL,
                pairId: pairedMac.id,
                deviceId: deviceId,
                deviceName: deviceName,
                publicKey: publicKey,
                publicKeyId: publicKeyId,
                e2eeService: e2eeService,
                partnerPublicKey: pairedMac.partnerPublicKey,
                partnerPublicKeyId: pairedMac.partnerPublicKeyId
            )
        }

        /// Disconnect from this Mac
        public func disconnect() async {
            await relayClient.disconnect()
        }

        /// Immediately attempt to reconnect (used when app returns to foreground)
        public func reconnectImmediately() async {
            await relayClient.reconnectImmediately()
        }

        // MARK: - Commands

        /// Send a command to this Mac and wait for response.
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

        /// Request current session state from this Mac
        public func requestSessionState() async {
            await relayClient.requestSessionState()
        }

        /// Send push notification token to the relay server
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
#endif
