import Foundation
import Vapor

/// Represents an active WebSocket connection
struct Connection: Sendable {
    /// The pair this connection belongs to
    let pairId: String

    /// Type of device (host or viewer)
    let deviceType: DeviceType

    /// Unique identifier for the device
    let deviceId: String

    /// The WebSocket connection
    let webSocket: WebSocket
}
