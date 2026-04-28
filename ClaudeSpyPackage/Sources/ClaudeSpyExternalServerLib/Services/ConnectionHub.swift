import ClaudeSpyNetworking
import Foundation
import Logging
import Vapor

/// Manages active WebSocket connections for paired devices
actor ConnectionHub {
    /// Active connections indexed by pairId and deviceType
    private var connections: [String: [DeviceType: Connection]] = [:]
    private let logger = Logger(label: "connection-hub")

    /// Device types that are blocked from connecting (for E2E testing).
    /// When a device type is blocked, new WebSocket connections for that type
    /// are immediately rejected, preventing auto-reconnection.
    private var blockedDeviceTypes: Set<DeviceType> = []

    // MARK: - Connection Management

    /// Register a new connection
    func register(_ connection: Connection) {
        if connections[connection.pairId] == nil {
            connections[connection.pairId] = [:]
        }
        connections[connection.pairId]?[connection.deviceType] = connection
    }

    /// Unregister a connection
    func unregister(pairId: String, deviceType: DeviceType) {
        connections[pairId]?[deviceType] = nil

        // Clean up empty pair entries
        if connections[pairId]?.isEmpty == true {
            connections.removeValue(forKey: pairId)
        }
    }

    /// Disconnect all connections for a pair
    func disconnectAll(pairId: String) {
        guard let pairConnections = connections[pairId] else { return }

        for (_, connection) in pairConnections {
            Task {
                try? await connection.webSocket.close()
            }
        }

        connections.removeValue(forKey: pairId)
    }

    /// Check if a device type is currently blocked from connecting (for E2E testing)
    func isBlocked(deviceType: DeviceType) -> Bool {
        blockedDeviceTypes.contains(deviceType)
    }

    /// Block a device type from connecting (for E2E testing).
    /// Existing connections are disconnected and new connections are rejected.
    func blockDeviceType(_ deviceType: DeviceType) async {
        blockedDeviceTypes.insert(deviceType)
        await disconnectAll(deviceType: deviceType)
        logger.info("Blocked device type: \(deviceType)")
    }

    /// Unblock a device type, allowing connections again (for E2E testing)
    func unblockDeviceType(_ deviceType: DeviceType) {
        blockedDeviceTypes.remove(deviceType)
        logger.info("Unblocked device type: \(deviceType)")
    }

    /// Clear all blocked device types (for E2E testing cleanup)
    func clearBlockedDeviceTypes() {
        blockedDeviceTypes.removeAll()
    }

    /// Disconnect all connections of a given device type across all pairs (for E2E testing)
    func disconnectAll(deviceType: DeviceType) async {
        for (pairId, pairConnections) in connections {
            guard let connection = pairConnections[deviceType] else { continue }
            try? await connection.webSocket.close()
            connections[pairId]?[deviceType] = nil
            if connections[pairId]?.isEmpty == true {
                connections.removeValue(forKey: pairId)
            }
        }
    }

    // MARK: - Connection Status

    /// Check if host is connected for a pair
    func isHostConnected(pairId: String) -> Bool {
        connections[pairId]?[.host] != nil
    }

    /// Check if viewer is connected for a pair
    func isViewerConnected(pairId: String) -> Bool {
        connections[pairId]?[.viewer] != nil
    }

    /// Aggregate count of active connections by device type across all pairs.
    func connectionCounts() -> (host: Int, viewer: Int) {
        var host = 0
        var viewer = 0
        for (_, pairConnections) in connections {
            if pairConnections[.host] != nil { host += 1 }
            if pairConnections[.viewer] != nil { viewer += 1 }
        }
        return (host, viewer)
    }

    /// Get connection for a specific device
    func getConnection(pairId: String, deviceType: DeviceType) -> Connection? {
        connections[pairId]?[deviceType]
    }

    // MARK: - Sending Messages

    /// Send a message to a specific device
    func send(_ message: WebSocketMessage, to pairId: String, deviceType: DeviceType) async {
        guard let connection = connections[pairId]?[deviceType] else {
            logger.warning("Cannot send message - no connection", metadata: [
                "pairId": "\(pairId)",
                "targetDevice": "\(deviceType)",
                "messageType": "\(message.messageType)",
            ])
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(message)
            try await connection.webSocket.send(raw: data, opcode: .text)
            logger.debug("Message sent", metadata: [
                "pairId": "\(pairId)",
                "targetDevice": "\(deviceType)",
                "messageType": "\(message.messageType)",
            ])
        } catch {
            logger.error("Failed to send message, cleaning up dead connection", metadata: [
                "pairId": "\(pairId)",
                "targetDevice": "\(deviceType)",
                "error": "\(error)",
            ])

            // Unregister the dead connection
            unregister(pairId: pairId, deviceType: deviceType)

            // Notify the peer device that this device disconnected
            let peerDevice: DeviceType = deviceType == .host ? .viewer : .host
            let disconnectMessage: WebSocketMessage = deviceType == .host ? .hostDisconnected : .viewerDisconnected
            await send(disconnectMessage, to: pairId, deviceType: peerDevice)
        }
    }

    /// Broadcast a message to all devices in a pair except the sender
    func broadcast(_ message: WebSocketMessage, to pairId: String, excluding: DeviceType? = nil) async {
        guard let pairConnections = connections[pairId] else { return }

        for (deviceType, _) in pairConnections {
            if deviceType == excluding { continue }
            // Use send() which handles dead connection cleanup
            await send(message, to: pairId, deviceType: deviceType)
        }
    }
}
