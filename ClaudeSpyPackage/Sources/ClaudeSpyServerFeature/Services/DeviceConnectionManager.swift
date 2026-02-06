import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Foundation
import Logging

/// Manages connections to all paired iOS devices.
///
/// This class coordinates multiple `DeviceConnection` instances, handling
/// connection lifecycle, event routing, and command dispatch to all connected devices.
@Observable
@MainActor
final public class DeviceConnectionManager {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.deviceconnectionmanager")

    /// Active connections keyed by pairId
    private var connections: [String: DeviceConnection] = [:]

    /// The app settings
    private weak var settings: AppSettings?

    /// E2EE service for creating device-specific services
    private let e2eeService: E2EEService

    /// Stored key pair for E2EE
    private let keyPair: StoredKeyPair

    // MARK: - Public Callbacks

    /// Called when a command is received from any iOS device.
    /// Returns nil if the command sends its own response.
    public var onCommand: (@MainActor @Sendable (CommandMessage) async -> CommandResponseMessage?)?

    /// Called when session state is requested by any iOS device
    public var onSessionStateRequest: (@Sendable () async -> SessionStateMessage)?

    /// Called when partner's public key is received (for persisting to settings)
    public var onPartnerKeyReceived: (@MainActor @Sendable (String, String, String) async -> Void)?

    // MARK: - Computed Properties

    /// All active connections
    public var activeConnections: [DeviceConnection] {
        Array(connections.values)
    }

    /// Whether any iOS device is currently connected
    public var anyDeviceConnected: Bool {
        connections.values.contains { $0.isViewerConnected }
    }

    /// Whether all devices are connected
    public var allDevicesConnected: Bool {
        guard !connections.isEmpty else { return false }
        return connections.values.allSatisfy { $0.isViewerConnected }
    }

    /// Whether any connection is in a connecting state
    public var isConnecting: Bool {
        connections.values.contains { $0.state == .connecting }
    }

    /// Combined connection state for UI display
    public var combinedState: DeviceConnection.ConnectionState {
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

    /// Creates a new device connection manager.
    ///
    /// - Parameters:
    ///   - settings: App settings containing paired devices
    ///   - e2eeService: E2EE service for encryption
    ///   - keyPair: Stored key pair for E2EE
    public init(settings: AppSettings, e2eeService: E2EEService, keyPair: StoredKeyPair) {
        self.settings = settings
        self.e2eeService = e2eeService
        self.keyPair = keyPair
    }

    // MARK: - Connection Management

    /// Get the connection for a specific device
    public func connection(for deviceId: String) -> DeviceConnection? {
        connections[deviceId]
    }

    /// Connect to all paired iOS devices.
    ///
    /// Creates connections for each paired device and establishes WebSocket connections.
    public func connectAll() async {
        guard let settings else {
            logger.error("Settings not available")
            return
        }

        logger.info("Connecting to all \(settings.pairedViewers.count) paired devices")

        for device in settings.pairedViewers {
            await connect(to: device)
        }
    }

    /// Connect to a specific iOS device.
    ///
    /// - Parameter device: The paired device to connect to
    public func connect(to device: PairedDevice) async {
        guard let settings else {
            logger.error("Settings not available")
            return
        }

        // Create or reuse connection
        let connection: DeviceConnection
        if let existing = connections[device.id] {
            connection = existing
            logger.info("Reusing existing connection for device: \(device.displayName)")
        } else {
            // Create new E2EE service for this device
            guard let deviceE2EE = await createE2EEService(for: device) else {
                logger.error("Failed to create E2EE service for device: \(device.displayName)")
                return
            }

            connection = DeviceConnection(pairedDevice: device, e2eeService: deviceE2EE)
            setupConnectionCallbacks(connection)
            connections[device.id] = connection
            logger.info("Created new connection for device: \(device.displayName)")
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
            username: ProcessInfo.processInfo.userName,
            publicKey: keyPair.publicKeyData.base64EncodedString(),
            publicKeyId: keyPair.keyId
        )
    }

    /// Disconnect from a specific device.
    ///
    /// - Parameter deviceId: The pair ID of the device to disconnect from
    public func disconnect(from deviceId: String) async {
        guard let connection = connections[deviceId] else {
            logger.warning("No connection found for device: \(deviceId)")
            return
        }

        await connection.disconnect()
        connections.removeValue(forKey: deviceId)
        logger.info("Disconnected from device: \(connection.deviceName)")
    }

    /// Disconnect from all devices.
    public func disconnectAll() async {
        logger.info("Disconnecting from all devices")

        for connection in connections.values {
            await connection.disconnect()
        }
        connections.removeAll()
    }

    /// Immediately reconnect all connections (used when system wakes from sleep).
    public func reconnectAllImmediately() async {
        logger.info("Immediate reconnection requested for all connections")

        for connection in connections.values {
            await connection.reconnectImmediately()
        }
    }

    // MARK: - Broadcasting

    /// Send a hook event to all connected iOS devices.
    public func sendHookEventToAll(_ event: HookEvent) async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections.values where connection.state.isConnected {
                group.addTask { await connection.sendHookEvent(event) }
            }
        }
    }

    /// Send terminal stream data to all connected iOS devices.
    public func sendTerminalStreamToAll(_ streamMessage: TerminalStreamMessage) async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections.values where connection.state.isConnected {
                group.addTask { await connection.sendTerminalStream(streamMessage) }
            }
        }
    }

    /// Push session state to all connected iOS devices.
    public func pushSessionStateToAll() async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections.values where connection.state.isConnected && connection.isViewerConnected {
                group.addTask { await connection.pushSessionState() }
            }
        }
    }

    // MARK: - Private Helpers

    private func createE2EEService(for device: PairedDevice) async -> E2EEService? {
        do {
            let deviceE2EE = E2EEService(keyPair: keyPair)

            // Establish session with this device's public key if available
            if
                !device.partnerPublicKey.isEmpty,
                let partnerKeyData = Data(base64Encoded: device.partnerPublicKey) {
                try await deviceE2EE.establishSession(
                    partnerPublicKey: partnerKeyData,
                    partnerKeyId: device.partnerPublicKeyId,
                    pairId: device.id
                )
                logger.info("E2EE session established for device: \(device.displayName)")
            }

            return deviceE2EE
        } catch {
            logger.error("Failed to create E2EE service for device \(device.displayName): \(error)")
            return nil
        }
    }

    private func setupConnectionCallbacks(_ connection: DeviceConnection) {
        let deviceId = connection.id

        connection.onCommand = { [weak self] command in
            await self?.onCommand?(command)
        }

        connection.onSessionStateRequest = { [weak self] in
            await self?.onSessionStateRequest?() ?? SessionStateMessage(
                pairId: "",
                sessions: [:],
                activePanes: [],
                panes: []
            )
        }

        connection.onPartnerKeyReceived = { [weak self, deviceId] publicKey, keyId in
            guard let self else { return }
            await self.onPartnerKeyReceived?(deviceId, publicKey, keyId)
        }
    }
}
