#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import ClaudeSpyNetworking
    import Foundation

    /// Manages connections to all paired Mac servers.
    ///
    /// This class coordinates multiple `MacConnection` instances, handling
    /// connection lifecycle, event routing, and command dispatch to the correct Mac.
    @Observable
    @MainActor
    final public class ConnectionManager {
        // MARK: - Properties

        private let logger = Logger(label: "com.claudespy.connectionmanager")

        /// Active connections keyed by pairId
        private var connections: [String: MacConnection] = [:]

        /// Key manager for creating E2EE services
        private let keyManager: KeyManager

        /// Our stored key pair for E2EE
        private var keyPair: StoredKeyPair?

        /// Pending push token to send when connections are established
        private var pendingPushToken: String?

        // MARK: - Public Callbacks

        /// Called when a hook event is received from any Mac
        public var onHookEvent: ((HookEventMessage) -> Void)?

        /// Called when session state is received from any Mac
        public var onSessionState: ((SessionStateMessage) -> Void)?

        // MARK: - Computed Properties

        /// All active connections
        public var activeConnections: [MacConnection] {
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

        /// E2EE service for pairing operations (not tied to any specific Mac).
        ///
        /// Use this when you need to provide our public key for a new pairing,
        /// before a Mac-specific session has been established.
        public var pairingService: E2EEService? {
            guard let keyPair else { return nil }
            return E2EEService(keyPair: keyPair, keyManager: keyManager)
        }

        // MARK: - Initialization

        /// Creates a new connection manager.
        ///
        /// - Parameter keyManager: Key manager for E2EE key operations
        /// - Throws: If key pair initialization fails
        public init(keyManager: KeyManager) async throws {
            self.keyManager = keyManager

            // Load or generate key pair
            if let existing = try await keyManager.loadKeyPair() {
                self.keyPair = existing
                logger.info("Loaded existing key pair")
            } else {
                self.keyPair = try await keyManager.generateKeyPair()
                logger.info("Generated new key pair")
            }
        }

        // MARK: - Connection Management

        /// Get the connection for a specific host
        public func connection(for hostId: String) -> MacConnection? {
            connections[hostId]
        }

        /// Connect to all paired Macs.
        ///
        /// Creates connections for each paired Mac and establishes WebSocket connections.
        ///
        /// - Parameter settings: iOS settings containing server URL and device info
        public func connectAll(settings: IOSSettings) async {
            logger.info("Connecting to all \(settings.pairedMacs.count) paired Macs")

            for mac in settings.pairedMacs {
                await connect(to: mac, settings: settings)
            }
        }

        /// Connect to a specific Mac.
        ///
        /// - Parameters:
        ///   - mac: The paired Mac to connect to
        ///   - settings: iOS settings containing server URL and device info
        public func connect(to mac: PairedMac, settings: IOSSettings) async {
            guard keyPair != nil else {
                logger.error("Cannot connect - key pair not initialized")
                return
            }

            // Create or reuse connection
            let connection: MacConnection
            if let existing = connections[mac.id] {
                connection = existing
                logger.info("Reusing existing connection for Mac: \(mac.displayName)")
            } else {
                // Create new E2EE service for this Mac
                guard let e2eeService = await createE2EEService(for: mac) else {
                    logger.error("Failed to create E2EE service for Mac: \(mac.displayName)")
                    return
                }

                connection = MacConnection(pairedMac: mac, e2eeService: e2eeService)
                setupConnectionCallbacks(connection, settings: settings)
                connections[mac.id] = connection
                logger.info("Created new connection for Mac: \(mac.displayName)")
            }

            // Connect
            guard let serverURL = URL(string: settings.externalServerURL) else {
                logger.error("Invalid server URL: \(settings.externalServerURL)")
                return
            }

            guard let keyPair else {
                logger.error("Key pair not available")
                return
            }

            await connection.connect(
                serverURL: serverURL,
                deviceId: settings.deviceId,
                deviceName: settings.deviceName,
                publicKey: keyPair.publicKeyData.base64EncodedString(),
                publicKeyId: keyPair.keyId
            )

            // Send pending push token if we have one
            if let token = pendingPushToken {
                await connection.sendPushToken(token)
            }
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
            logger.info("Disconnected from host: \(connection.macName)")
        }

        /// Disconnect from all Macs.
        public func disconnectAll() async {
            logger.info("Disconnecting from all Macs")

            for connection in connections.values {
                await connection.disconnect()
            }
            connections.removeAll()
        }

        /// Immediately reconnect all connections (used when app returns to foreground).
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
        ///   - hostId: The pair ID of the Mac to send to
        ///   - timeout: Maximum time to wait for response
        /// - Returns: Result containing the response or error
        public func sendCommand<C: CommandSpec>(
            _ command: C,
            paneId: String,
            hostId: String,
            timeout: TimeInterval = 15
        ) async -> Result<C.Response, Error> {
            guard let connection = connections[hostId] else {
                return .failure(RelayClientError.notConnected)
            }

            return await connection.sendCommand(command, paneId: paneId, timeout: timeout)
        }

        /// Request session state from all connected Macs.
        public func requestAllSessionStates() async {
            for connection in connections.values where connection.isHostConnected {
                await connection.requestSessionState()
            }
        }

        /// Request session state from a specific Mac.
        public func requestSessionState(for hostId: String) async {
            guard let connection = connections[hostId], connection.isHostConnected else {
                logger.debug("Cannot request session state - Mac not connected: \(hostId)")
                return
            }

            await connection.requestSessionState()
        }

        // MARK: - Push Notifications

        /// Send push notification token to all connected Macs.
        ///
        /// - Parameter token: The APNs device token as a hex string
        public func sendPushTokenToAll(_ token: String) async {
            pendingPushToken = token

            for connection in connections.values where connection.isRelayConnected {
                await connection.sendPushToken(token)
            }
        }

        // MARK: - Private Helpers

        private func createE2EEService(for mac: PairedMac) async -> E2EEService? {
            guard let keyPair else {
                logger.error("Key pair not available for E2EE service creation")
                return nil
            }

            do {
                let e2eeService = E2EEService(keyPair: keyPair, keyManager: keyManager)

                // Establish session with this Mac's public key if available
                if
                    !mac.partnerPublicKey.isEmpty,
                    let partnerKeyData = Data(base64Encoded: mac.partnerPublicKey) {
                    try await e2eeService.establishSession(
                        partnerPublicKey: partnerKeyData,
                        partnerKeyId: mac.partnerPublicKeyId,
                        pairId: mac.id
                    )
                    logger.info("E2EE session established for Mac: \(mac.displayName)")
                }

                return e2eeService
            } catch {
                logger.error("Failed to create E2EE service for Mac \(mac.displayName): \(error)")
                return nil
            }
        }

        private func setupConnectionCallbacks(_ connection: MacConnection, settings: IOSSettings) {
            let hostId = connection.id

            connection.setupCallbacks(
                onHookEvent: { [weak self] event in
                    Task { @MainActor in
                        self?.onHookEvent?(event)
                    }
                },
                onSessionState: { [weak self] state in
                    Task { @MainActor in
                        self?.onSessionState?(state)
                    }
                },
                onTerminalStream: { _ in
                    // Terminal streams are handled by individual views
                    // The callback is set by the terminal view when it needs streaming
                },
                onPartnerKeyReceived: { [weak self, hostId] publicKey, keyId in
                    guard let self else { return }
                    // Update the stored Mac with new partner key
                    // Access IOSSettings.shared directly instead of capturing to avoid retain cycles
                    let settings = IOSSettings.shared
                    if let mac = settings.getPairing(id: hostId) {
                        let updatedMac = PairedMac(
                            id: mac.id,
                            macName: mac.macName,
                            username: mac.username,
                            partnerPublicKey: publicKey,
                            partnerPublicKeyId: keyId,
                            pairedAt: mac.pairedAt,
                            customName: mac.customName
                        )
                        settings.updatePairing(updatedMac)
                        self.logger.info("Updated partner key for Mac: \(mac.displayName)")
                    }
                }
            )
        }
    }
#endif
