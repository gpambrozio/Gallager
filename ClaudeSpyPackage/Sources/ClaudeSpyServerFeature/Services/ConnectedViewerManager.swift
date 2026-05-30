import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Foundation
import Logging

/// Manages connections to all paired viewers.
///
/// This class coordinates multiple `ConnectedViewer` instances, handling
/// connection lifecycle, event routing, and command dispatch to all connected viewers.
@Observable
@MainActor
final public class ConnectedViewerManager {
    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.connectedviewermanager")

    /// Active connections keyed by pairId
    private var connections: [String: ConnectedViewer] = [:]

    /// The app settings
    private weak var settings: AppSettings?

    /// E2EE service for creating device-specific services
    private let e2eeService: E2EEService

    /// Stored key pair for E2EE
    private let keyPair: StoredKeyPair

    // MARK: - Public Callbacks

    /// Called when a command is received from any viewer.
    /// Returns nil if the command sends its own response.
    public var onCommand: (@MainActor @Sendable (CommandMessage) async -> CommandResponseMessage?)?

    /// Called when session state is requested by any viewer
    public var onSessionStateRequest: (@Sendable () async -> SessionStateMessage)?

    /// Called when partner's public key is received (for persisting to settings)
    public var onPartnerKeyReceived: (@MainActor @Sendable (String, String, String) async -> Void)?

    /// Called when the partner's device name is received (for persisting to settings).
    /// Parameters are: viewerId, deviceName.
    public var onPartnerDeviceNameReceived: (@MainActor @Sendable (String, String) async -> Void)?

    /// Called when a pairing was removed by the other side.
    /// Parameter is the pairId that was unpaired.
    public var onUnpaired: (@MainActor @Sendable (String) async -> Void)?

    /// Provides the current pending-attention session count. Forwarded to every
    /// `ConnectedViewer` so outgoing pushes (event and silent) carry the right
    /// APNs badge value.
    public var pendingSessionCountProvider: (@MainActor @Sendable () async -> Int)?

    /// Called when any viewer submits a plugin response (iOS→Mac). The
    /// coordinator routes it to the owning plugin core's `deliverResponse`.
    public var onAgentResponseSubmission: (@MainActor @Sendable (AgentResponseSubmissionMessage) async -> Void)?

    /// Provides the current enabled-plugin presentation set, pushed to each
    /// viewer on connect. Forwarded to every `ConnectedViewer` via its
    /// `onViewerConnected` hook (spec §7.2).
    public var presentationsProvider: (@MainActor @Sendable () async -> [PluginPresentation])?

    // MARK: - Computed Properties

    /// All active connections
    public var activeConnections: [ConnectedViewer] {
        Array(connections.values)
    }

    /// Whether any viewer is currently connected
    public var anyViewerConnected: Bool {
        connections.values.contains { $0.isViewerConnected }
    }

    /// Whether all viewers are connected
    public var allViewersConnected: Bool {
        guard !connections.isEmpty else { return false }
        return connections.values.allSatisfy { $0.isViewerConnected }
    }

    /// Whether any connection is in a connecting state
    public var isConnecting: Bool {
        connections.values.contains { $0.state == .connecting }
    }

    /// Combined connection state for UI display
    public var combinedState: ConnectedViewer.ConnectionState {
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

    /// Creates a new connected viewer manager.
    ///
    /// - Parameters:
    ///   - settings: App settings containing paired viewers
    ///   - e2eeService: E2EE service for encryption
    ///   - keyPair: Stored key pair for E2EE
    public init(settings: AppSettings, e2eeService: E2EEService, keyPair: StoredKeyPair) {
        self.settings = settings
        self.e2eeService = e2eeService
        self.keyPair = keyPair
    }

    // MARK: - Connection Management

    /// Get the connection for a specific viewer
    public func connection(for viewerId: String) -> ConnectedViewer? {
        connections[viewerId]
    }

    /// Connect to all paired viewers.
    ///
    /// Creates connections for each paired viewer and establishes WebSocket connections.
    public func connectAll() async {
        guard let settings else {
            logger.error("Settings not available")
            return
        }

        logger.info("Connecting to all \(settings.pairedViewers.count) paired viewers")

        for viewer in settings.pairedViewers {
            await connect(to: viewer)
        }
    }

    /// Connect to a specific viewer.
    ///
    /// - Parameter viewer: The paired viewer to connect to
    public func connect(to viewer: PairedViewer) async {
        guard let settings else {
            logger.error("Settings not available")
            return
        }

        // Create or reuse connection
        let connection: ConnectedViewer
        if let existing = connections[viewer.id] {
            connection = existing
            logger.info("Reusing existing connection for viewer: \(viewer.displayName)")
        } else {
            // Create new E2EE service for this viewer
            guard let viewerE2EE = await createE2EEService(for: viewer) else {
                logger.error("Failed to create E2EE service for viewer: \(viewer.displayName)")
                return
            }

            connection = ConnectedViewer(pairedViewer: viewer, e2eeService: viewerE2EE)
            setupConnectionCallbacks(connection)
            connections[viewer.id] = connection
            logger.info("Created new connection for viewer: \(viewer.displayName)")
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

    /// Disconnect from a specific viewer.
    ///
    /// - Parameter viewerId: The pair ID of the viewer to disconnect from
    public func disconnect(from viewerId: String) async {
        guard let connection = connections[viewerId] else {
            logger.warning("No connection found for viewer: \(viewerId)")
            return
        }

        await connection.disconnect()
        connections.removeValue(forKey: viewerId)
        logger.info("Disconnected from viewer: \(connection.viewerName)")
    }

    /// Disconnect from all viewers.
    public func disconnectAll() async {
        logger.info("Disconnecting from all viewers")

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

    /// Re-enable reconnection on every viewer that stopped after a terminal
    /// failure (e.g. version mismatch) and retry. Used by E2E scenarios that
    /// simulate an in-place "upgrade" of the app's reported version.
    public func enableReconnectAndRetryAll() async {
        logger.info("Enabling reconnect and retrying for all viewers")

        for connection in connections.values {
            await connection.enableReconnectAndRetry()
        }
    }

    // MARK: - Broadcasting

    /// Send a per-session working/attention status update to all connected
    /// viewers (the high-frequency badge path — spec §7.2).
    public func sendAgentSessionStatusToAll(
        sessionId: String,
        pluginId: String,
        working: Bool,
        attention: Bool
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections.values where connection.state.isConnected {
                group.addTask {
                    await connection.sendAgentSessionStatus(
                        sessionId: sessionId,
                        pluginId: pluginId,
                        working: working,
                        attention: attention
                    )
                }
            }
        }
    }

    /// Send an encrypted push notification with arbitrary title/body to every
    /// connected viewer. Used by `notification.create --push` so a single CLI
    /// call reaches all paired iOS devices.
    public func sendCustomPushNotificationToAll(
        title: String,
        body: String,
        paneId: String?
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections.values where connection.state.isConnected {
                group.addTask {
                    await connection.sendCustomPushNotification(
                        title: title,
                        body: body,
                        paneId: paneId
                    )
                }
            }
        }
    }

    /// Send terminal stream data to all connected viewers.
    public func sendTerminalStreamToAll(_ streamMessage: TerminalStreamMessage) async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections.values where connection.state.isConnected {
                group.addTask { await connection.sendTerminalStream(streamMessage) }
            }
        }
    }

    /// Push session state to all connected viewers.
    public func pushSessionStateToAll() async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections.values where connection.state.isConnected && connection.isViewerConnected {
                group.addTask { await connection.pushSessionState() }
            }
        }
    }

    /// Send a silent badge-update push to all connected viewers. Used after
    /// `markSessionHandled` to bring the iOS badge in line with the host's new
    /// (lower) pending-attention session count.
    public func broadcastBadgeUpdate(badge: Int) async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections.values where connection.state.isConnected {
                group.addTask { await connection.sendBadgeUpdate(badge: badge) }
            }
        }
    }

    /// Open or retract an iOS response form on all connected viewers. A non-nil
    /// `request` opens; `request == nil` retracts (spec §7.2).
    public func sendAgentResponseRequestToAll(
        sessionId: String,
        pluginId: String,
        requestId: String,
        request: AgentResponseRequest?
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections.values where connection.state.isConnected {
                group.addTask {
                    await connection.sendAgentResponseRequest(
                        sessionId: sessionId,
                        pluginId: pluginId,
                        requestId: requestId,
                        request: request
                    )
                }
            }
        }
    }

    /// Push the complete enabled-plugin presentation set to all connected
    /// viewers (spec §7.2/§7.3). Used on enable/disable; per-viewer connect
    /// pushes go through each `ConnectedViewer.onViewerConnected`.
    public func pushPluginPresentationsToAll(_ presentations: [PluginPresentation]) async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections.values where connection.state.isConnected {
                group.addTask { await connection.sendPluginPresentations(presentations) }
            }
        }
    }

    // MARK: - Private Helpers

    private func createE2EEService(for viewer: PairedViewer) async -> E2EEService? {
        do {
            let viewerE2EE = E2EEService(keyPair: keyPair)

            // Establish session with this viewer's public key if available
            if
                !viewer.partnerPublicKey.isEmpty,
                let partnerKeyData = Data(base64Encoded: viewer.partnerPublicKey) {
                try await viewerE2EE.establishSession(
                    partnerPublicKey: partnerKeyData,
                    partnerKeyId: viewer.partnerPublicKeyId,
                    pairId: viewer.id
                )
                logger.info("E2EE session established for viewer: \(viewer.displayName)")
            }

            return viewerE2EE
        } catch {
            logger.error("Failed to create E2EE service for viewer \(viewer.displayName): \(error)")
            return nil
        }
    }

    private func setupConnectionCallbacks(_ connection: ConnectedViewer) {
        let viewerId = connection.id

        connection.onCommand = { [weak self] command in
            await self?.onCommand?(command)
        }

        connection.onSessionStateRequest = { [weak self] in
            await self?.onSessionStateRequest?() ?? SessionStateMessage(
                pairId: "",
                paneStates: [:]
            )
        }

        connection.onPartnerKeyReceived = { [weak self, viewerId] publicKey, keyId in
            guard let self else { return }
            await self.onPartnerKeyReceived?(viewerId, publicKey, keyId)
        }

        connection.onPartnerDeviceNameReceived = { [weak self, viewerId] deviceName in
            guard let self else { return }
            await self.onPartnerDeviceNameReceived?(viewerId, deviceName)
        }

        connection.onUnpaired = { [weak self, viewerId] in
            guard let self else { return }
            self.connections.removeValue(forKey: viewerId)
            await self.onUnpaired?(viewerId)
        }

        connection.onPendingSessionCount = { [weak self] in
            await self?.pendingSessionCountProvider?() ?? 0
        }

        connection.onAgentResponseSubmission = { [weak self] submission in
            await self?.onAgentResponseSubmission?(submission)
        }

        // On connect, push the current plugin presentations to just this
        // viewer (the full set). Enable/disable re-pushes go through
        // `pushPluginPresentationsToAll`.
        connection.onViewerConnected = { [weak self, weak connection] in
            guard let self, let connection else { return }
            let presentations = await self.presentationsProvider?() ?? []
            await connection.sendPluginPresentations(presentations)
        }
    }
}
