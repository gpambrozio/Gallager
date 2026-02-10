import Foundation
import Vapor

/// Represents an active WebSocket connection
struct Connection: Sendable {
    /// Unique identifier for this specific connection instance.
    /// Used to prevent stale close handlers from unregistering newer connections
    /// when a device reconnects before the old WebSocket close is processed.
    let connectionId: UUID

    /// The pair this connection belongs to
    let pairId: String

    /// Type of device (host or viewer)
    let deviceType: DeviceType

    /// Unique identifier for the device
    let deviceId: String

    /// The WebSocket connection
    let webSocket: WebSocket
}
