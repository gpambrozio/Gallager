import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Foundation

/// Manages connections to all paired Mac hosts for viewing.
///
/// This class coordinates multiple `HostConnection` instances, handling
/// connection lifecycle, event routing, and command dispatch to connected Mac hosts.
@Observable
@MainActor
final public class HostConnectionManager {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.hostconnectionmanager")

    /// Active connections keyed by pairId
    private var connections: [String: HostConnection] = [:]

    /// The app settings
    private weak var settings: AppSettings?

    /// E2EE service for creating host-specific services
    private let e2eeService: E2EEService

    /// Stored key pair for E2EE
    private let keyPair: StoredKeyPair

    // MARK: - Public Callbacks

    /// Called when a hook event is received from any Mac host
    public var onHookEvent: (@Sendable (HookEventMessage) -> Void)?

    /// Called when session state is received from any Mac host
    public var onSessionState: (@Sendable (SessionStateMessage) -> Void)?

    /// Called when terminal stream is received from any Mac host
    public var onTerminalStream: (@MainActor @Sendable (TerminalStreamMessage) -> Void)?

    /// Called when partner's public key is received (for persisting to settings)
    public var onPartnerKeyReceived: (@MainActor @Sendable (String, String, String) async -> Void)?

    // MARK: - Computed Properties

    /// All active connections
    public var activeConnections: [HostConnection] {
        Array(connections.values)
    }

    /// Whether any Mac host is currently connected
    public var anyMacHostConnected: Bool {
        connections.values.contains { $0.isMacHostConnected }
    }

    /// Whether all Mac hosts are connected
    public var allMacHostsConnected: Bool {
        guard !connections.isEmpty else { return false }
        return connections.values.allSatisfy { $0.isMacHostConnected }
    }

    /// Whether any connection is in a connecting state
    public var isConnecting: Bool {
        connections.values.contains { $0.state == .connecting }
    }

    /// Combined connection state for UI display
    public var combinedState: HostRelayClient.ConnectionState {
        if connections.isEmpty {
            return .disconnected
        }
        if connections.values.allSatisfy({ $0.state.isConnected }) {
            return .connected
        }
        if connections.values.contains(where: { $0.state == .connecting }) {
            return .connecting
        }
        if
            let reconnecting = connections.values.first(where: {
                if case .reconnecting = $0.state { return true }
                return false
            }) {
            return reconnecting.state
        }
        if connections.values.contains(where: { $0.state == .extendedBackoff }) {
            return .extendedBackoff
        }
        if
            let error = connections.values.first(where: {
                if case .error = $0.state { return true }
                return false
            }) {
            return error.state
        }
        return .disconnected
    }

    // MARK: - Initialization

    /// Creates a new host connection manager.
    ///
    /// - Parameters:
    ///   - settings: App settings containing paired Mac hosts
    ///   - e2eeService: E2EE service for encryption
    ///   - keyPair: Stored key pair for E2EE
    public init(settings: AppSettings, e2eeService: E2EEService, keyPair: StoredKeyPair) {
        self.settings = settings
        self.e2eeService = e2eeService
        self.keyPair = keyPair
    }

    // MARK: - Connection Management

    /// Get the connection for a specific Mac host
    public func connection(for hostId: String) -> HostConnection? {
        connections[hostId]
    }

    /// Connect to all paired Mac hosts.
    ///
    /// Creates connections for each paired Mac host and establishes WebSocket connections.
    public func connectAll() async {
        guard let settings else {
            logger.error("Settings not available")
            return
        }

        logger.info("Connecting to all \(settings.pairedMacHosts.count) paired Mac hosts")

        for host in settings.pairedMacHosts {
            await connect(to: host)
        }
    }

    /// Connect to a specific Mac host.
    ///
    /// - Parameter host: The paired Mac host to connect to
    public func connect(to host: PairedMacHost) async {
        guard let settings else {
            logger.error("Settings not available")
            return
        }

        // Create or reuse connection
        let connection: HostConnection
        if let existing = connections[host.id] {
            connection = existing
            logger.info("Reusing existing connection for Mac host: \(host.displayName)")
        } else {
            // Create new E2EE service for this host
            guard let hostE2EE = await createE2EEService(for: host) else {
                logger.error("Failed to create E2EE service for Mac host: \(host.displayName)")
                return
            }

            connection = HostConnection(pairedMacHost: host, e2eeService: hostE2EE)
            setupConnectionCallbacks(connection)
            connections[host.id] = connection
            logger.info("Created new connection for Mac host: \(host.displayName)")
        }

        // Connect
        guard let serverURL = URL(string: settings.externalServerURL) else {
            logger.error("Invalid server URL: \(settings.externalServerURL)")
            return
        }

        await connection.connect(
            serverURL: serverURL,
            deviceId: settings.deviceId,
            deviceName: Host.current().localizedName ?? "Mac",
            publicKey: keyPair.publicKeyData.base64EncodedString(),
            publicKeyId: keyPair.keyId
        )
    }

    /// Disconnect from a specific Mac host.
    ///
    /// - Parameter hostId: The pair ID of the Mac host to disconnect from
    public func disconnect(from hostId: String) async {
        guard let connection = connections[hostId] else {
            logger.warning("No connection found for Mac host: \(hostId)")
            return
        }

        await connection.disconnect()
        connections.removeValue(forKey: hostId)
        logger.info("Disconnected from Mac host: \(connection.macName)")
    }

    /// Disconnect from all Mac hosts.
    public func disconnectAll() async {
        logger.info("Disconnecting from all Mac hosts")

        for connection in connections.values {
            await connection.disconnect()
        }
        connections.removeAll()
    }

    /// Immediately reconnect all connections (used when system wakes from sleep).
    public func reconnectAllImmediately() async {
        logger.info("Immediate reconnection requested for all Mac host connections")

        for connection in connections.values {
            await connection.reconnectImmediately()
        }
    }

    // MARK: - Commands

    /// Send a command to a specific Mac host and wait for response.
    public func sendCommand<C: CommandSpec>(
        _ command: C,
        paneId: String,
        hostId: String,
        timeout: TimeInterval = 15
    ) async -> Result<C.Response, Error> {
        guard let connection = connections[hostId] else {
            return .failure(HostRelayClientError.notConnected)
        }

        return await connection.sendCommand(command, paneId: paneId, timeout: timeout)
    }

    /// Request session state from all connected Mac hosts.
    public func requestAllSessionStates() async {
        for connection in connections.values where connection.isMacHostConnected {
            await connection.requestSessionState()
        }
    }

    /// Request session state from a specific Mac host.
    public func requestSessionState(for hostId: String) async {
        guard let connection = connections[hostId], connection.isMacHostConnected else {
            logger.debug("Cannot request session state - Mac host not connected: \(hostId)")
            return
        }

        await connection.requestSessionState()
    }

    // MARK: - Private Helpers

    private func createE2EEService(for host: PairedMacHost) async -> E2EEService? {
        do {
            let hostE2EE = E2EEService(keyPair: keyPair)

            // Establish session with this host's public key if available
            if
                !host.partnerPublicKey.isEmpty,
                let partnerKeyData = Data(base64Encoded: host.partnerPublicKey) {
                try await hostE2EE.establishSession(
                    partnerPublicKey: partnerKeyData,
                    partnerKeyId: host.partnerPublicKeyId,
                    pairId: host.id
                )
                logger.info("E2EE session established for Mac host: \(host.displayName)")
            }

            return hostE2EE
        } catch {
            logger.error("Failed to create E2EE service for Mac host \(host.displayName): \(error)")
            return nil
        }
    }

    private func setupConnectionCallbacks(_ connection: HostConnection) {
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
            onTerminalStream: { [weak self] stream in
                self?.onTerminalStream?(stream)
            },
            onPartnerKeyReceived: { [weak self, hostId] publicKey, keyId in
                guard let self else { return }
                await self.onPartnerKeyReceived?(hostId, publicKey, keyId)
            }
        )
    }
}
