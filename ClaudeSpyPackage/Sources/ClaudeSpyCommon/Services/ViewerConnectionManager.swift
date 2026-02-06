import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Foundation

/// Manages connections to all paired hosts (when acting as a viewer).
///
/// This class coordinates multiple `ViewerConnection` instances, handling
/// connection lifecycle, event routing, and command dispatch to the correct host.
/// Used by both iOS and macOS when connecting to remote Mac hosts.
@Observable
@MainActor
final public class ViewerConnectionManager {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.viewerconnectionmanager")

    /// Active connections keyed by pairId
    private var connections: [String: ViewerConnection] = [:]

    /// Hosts currently being connected to (guards against duplicate concurrent connect calls)
    private var connectingHosts: Set<String> = []

    /// Key manager for creating E2EE services
    private let keyManager: KeyManager

    /// Our stored key pair for E2EE
    private var keyPair: StoredKeyPair?

    #if os(iOS)
        /// Pending push token to send when connections are established
        private var pendingPushToken: String?
    #endif

    // MARK: - Public Callbacks

    /// Called when a hook event is received from any host
    public var onHookEvent: ((HookEventMessage) -> Void)?

    /// Called when session state is received from any host
    public var onSessionState: ((SessionStateMessage) -> Void)?

    /// Called when a partner's public key is received or updated.
    ///
    /// Parameters are: hostId, publicKey (base64), keyId
    public var onPartnerKeyReceived: ((_ hostId: String, _ publicKey: String, _ keyId: String) async -> Void)?

    // MARK: - Computed Properties

    /// All active connections
    public var activeConnections: [ViewerConnection] {
        Array(connections.values)
    }

    /// Whether any host is currently connected via WebSocket
    public var anyHostConnected: Bool {
        connections.values.contains { $0.isHostConnected }
    }

    /// Whether all hosts are connected
    public var allHostsConnected: Bool {
        guard !connections.isEmpty else { return false }
        return connections.values.allSatisfy { $0.isHostConnected }
    }

    /// Whether any connection is in a connecting state
    public var isConnecting: Bool {
        connections.values.contains { $0.state == .connecting }
    }

    /// E2EE service for pairing operations (not tied to any specific host).
    public var pairingService: E2EEService? {
        guard let keyPair else { return nil }
        return E2EEService(keyPair: keyPair, keyManager: keyManager)
    }

    // MARK: - Initialization

    /// Creates a new viewer connection manager.
    ///
    /// - Parameter keyManager: Key manager for E2EE key operations
    /// - Throws: If key pair initialization fails
    public init(keyManager: KeyManager) async throws {
        self.keyManager = keyManager

        // Load or generate key pair
        if let existing = try await keyManager.loadKeyPair() {
            self.keyPair = existing
            logger.info("Loaded existing key pair for viewer mode")
        } else {
            self.keyPair = try await keyManager.generateKeyPair()
            logger.info("Generated new key pair for viewer mode")
        }
    }

    // MARK: - Connection Management

    /// Get the connection for a specific host
    public func connection(for hostId: String) -> ViewerConnection? {
        connections[hostId]
    }

    /// Connect to all paired hosts.
    ///
    /// - Parameters:
    ///   - pairedHosts: List of paired hosts to connect to
    ///   - serverURL: The relay server URL
    ///   - deviceId: This device's ID
    ///   - deviceName: This device's display name
    public func connectAll(
        pairedHosts: [PairedHost],
        serverURL: URL,
        deviceId: String,
        deviceName: String
    ) async {
        logger.info("Connecting to all \(pairedHosts.count) paired hosts")

        for host in pairedHosts {
            await connect(to: host, serverURL: serverURL, deviceId: deviceId, deviceName: deviceName)
        }
    }

    /// Connect to a specific host.
    ///
    /// - Parameters:
    ///   - host: The paired host to connect to
    ///   - serverURL: The relay server URL
    ///   - deviceId: This device's ID
    ///   - deviceName: This device's display name
    public func connect(
        to host: PairedHost,
        serverURL: URL,
        deviceId: String,
        deviceName: String
    ) async {
        guard let keyPair else {
            logger.error("Cannot connect - key pair not initialized")
            return
        }

        guard !connectingHosts.contains(host.id) else {
            logger.debug("Already connecting to host: \(host.displayName)")
            return
        }
        connectingHosts.insert(host.id)
        defer { connectingHosts.remove(host.id) }

        // Create or reuse connection
        let connection: ViewerConnection
        if let existing = connections[host.id] {
            connection = existing
            logger.info("Reusing existing connection for host: \(host.displayName)")
        } else {
            guard let e2eeService = await createE2EEService(for: host) else {
                logger.error("Failed to create E2EE service for host: \(host.displayName)")
                return
            }

            connection = ViewerConnection(pairedDevice: host, e2eeService: e2eeService)
            setupConnectionCallbacks(connection)
            connections[host.id] = connection
            logger.info("Created new connection for host: \(host.displayName)")
        }

        await connection.connect(
            serverURL: serverURL,
            deviceId: deviceId,
            deviceName: deviceName,
            publicKey: keyPair.publicKeyData.base64EncodedString(),
            publicKeyId: keyPair.keyId
        )

        #if os(iOS)
            // Send pending push token if we have one
            if let token = pendingPushToken {
                await connection.sendPushToken(token)
            }
        #endif
    }

    /// Disconnect from a specific host.
    ///
    /// - Parameter hostId: The pair ID of the host to disconnect from
    public func disconnect(from hostId: String) async {
        guard let connection = connections[hostId] else {
            logger.warning("No connection found for host: \(hostId)")
            return
        }

        await connection.disconnect()
        connections.removeValue(forKey: hostId)
        logger.info("Disconnected from host: \(connection.hostName)")
    }

    /// Disconnect from all hosts.
    public func disconnectAll() async {
        logger.info("Disconnecting from all hosts")

        for connection in connections.values {
            await connection.disconnect()
        }
        connections.removeAll()
    }

    /// Immediately reconnect all connections (used when app becomes active).
    public func reconnectAllImmediately() async {
        logger.info("Immediate reconnection requested for all connections")

        for connection in connections.values {
            await connection.reconnectImmediately()
        }
    }

    // MARK: - Commands

    /// Send a command to a specific host.
    ///
    /// - Parameters:
    ///   - command: The command specification
    ///   - paneId: The tmux pane ID to target
    ///   - hostId: The pair ID of the host to send to
    ///   - timeout: Maximum time to wait for response
    /// - Returns: Result containing the response or error
    public func sendCommand<C: CommandSpec>(
        _ command: C,
        paneId: String,
        hostId: String,
        timeout: TimeInterval = 15
    ) async -> Result<C.Response, Error> {
        guard let connection = connections[hostId] else {
            return .failure(ViewerRelayClientError.notConnected)
        }

        return await connection.sendCommand(command, paneId: paneId, timeout: timeout)
    }

    /// Request session state from all connected hosts.
    public func requestAllSessionStates() async {
        for connection in connections.values where connection.isHostConnected {
            await connection.requestSessionState()
        }
    }

    /// Request session state from a specific host.
    public func requestSessionState(for hostId: String) async {
        guard let connection = connections[hostId], connection.isHostConnected else {
            logger.debug("Cannot request session state - host not connected: \(hostId)")
            return
        }

        await connection.requestSessionState()
    }

    // MARK: - Push Notifications

    #if os(iOS)
        /// Send push notification token to all connected hosts.
        ///
        /// - Parameter token: The APNs device token as a hex string
        public func sendPushTokenToAll(_ token: String) async {
            pendingPushToken = token

            for connection in connections.values where connection.isRelayConnected {
                await connection.sendPushToken(token)
            }
        }
    #endif

    // MARK: - Private Helpers

    private func createE2EEService(for host: PairedHost) async -> E2EEService? {
        guard let keyPair else {
            logger.error("Key pair not available for E2EE service creation")
            return nil
        }

        do {
            let e2eeService = E2EEService(keyPair: keyPair, keyManager: keyManager)

            // Establish session with this host's public key if available
            if
                !host.partnerPublicKey.isEmpty,
                let partnerKeyData = Data(base64Encoded: host.partnerPublicKey) {
                try await e2eeService.establishSession(
                    partnerPublicKey: partnerKeyData,
                    partnerKeyId: host.partnerPublicKeyId,
                    pairId: host.id
                )
                logger.info("E2EE session established for host: \(host.displayName)")
            }

            return e2eeService
        } catch {
            logger.error("Failed to create E2EE service for host \(host.displayName): \(error)")
            return nil
        }
    }

    private func setupConnectionCallbacks(_ connection: ViewerConnection) {
        let hostId = connection.id

        connection.setupCallbacks(
            onHookEvent: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.onHookEvent?(event)
                }
            },
            onSessionState: { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.onSessionState?(state)
                }
            },
            onTerminalStream: { _ in
                // Terminal streams are handled by individual views
            },
            onPartnerKeyReceived: { [weak self] publicKey, keyId in
                guard let self else { return }
                await self.onPartnerKeyReceived?(hostId, publicKey, keyId)
            }
        )
    }
}
