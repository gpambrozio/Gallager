import ClaudeSpyNetworking
import Foundation
import Logging
import Vapor

/// Manages active WebSocket connections for paired devices
actor ConnectionHub {
    /// Active connections indexed by pairId and deviceType
    private var connections: [String: [DeviceType: Connection]] = [:]
    private let logger = Logger(label: "connection-hub")

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

    // MARK: - Connection Status

    /// Check if Mac is connected for a pair
    func isMacConnected(pairId: String) -> Bool {
        connections[pairId]?[.mac] != nil
    }

    /// Check if iOS is connected for a pair
    func isIOSConnected(pairId: String) -> Bool {
        connections[pairId]?[.ios] != nil
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
            logger.error("Failed to send message", metadata: [
                "pairId": "\(pairId)",
                "targetDevice": "\(deviceType)",
                "error": "\(error)",
            ])
        }
    }

    /// Broadcast a message to all devices in a pair except the sender
    func broadcast(_ message: WebSocketMessage, to pairId: String, excluding: DeviceType? = nil) async {
        guard let pairConnections = connections[pairId] else { return }

        for (deviceType, connection) in pairConnections {
            if deviceType == excluding { continue }

            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(message)
                try await connection.webSocket.send(raw: data, opcode: .text)
            } catch {
                // Connection may have closed
            }
        }
    }
}
