import ClaudeSpyEncryption
import Foundation

// MARK: - Notification Content

/// The notification content that gets encrypted by the host and decrypted by iOS Notification Service Extension.
///
/// This struct contains the actual notification text that will be displayed to the user.
/// It travels encrypted through the server and APNs infrastructure.
public struct NotificationContent: Codable, Sendable, Equatable {
    /// The notification title (e.g., "ClaudeSpy" or project name)
    public let title: String

    /// The notification body text describing the event
    public let body: String

    /// The event type for categorization (e.g., "SessionStart", "SessionEnd")
    public let eventType: String

    /// The pair ID for routing (also included unencrypted for server routing)
    public let pairId: String

    /// The tmux pane ID for deep linking to the specific session
    public let paneId: String?

    /// When the event occurred
    public let timestamp: Date

    public init(
        title: String,
        body: String,
        eventType: String,
        pairId: String,
        paneId: String? = nil,
        timestamp: Date = Date()
    ) {
        self.title = title
        self.body = body
        self.eventType = eventType
        self.pairId = pairId
        self.paneId = paneId
        self.timestamp = timestamp
    }
}

// MARK: - Encrypted Push Payload

/// The payload sent through APNs containing encrypted notification content.
///
/// The server receives this and forwards it to APNs. The iOS Notification Service Extension
/// decrypts `encryptedContent` and updates the notification with the decrypted title/body.
///
/// ## Flow
/// 1. Host creates `NotificationContent` with title, body, etc.
/// 2. Host encrypts it using E2EEService to produce `EncryptedPayload`
/// 3. Host wraps it in `EncryptedPushPayload` and sends to server
/// 4. Server sends to APNs with generic placeholder text + this payload
/// 5. iOS Notification Service Extension receives push, decrypts, and displays
public struct EncryptedPushPayload: Codable, Sendable, Equatable {
    /// The encrypted notification content (contains encrypted NotificationContent)
    public let encryptedContent: EncryptedPayload

    /// The pair ID for routing (unencrypted, needed by server for push token lookup)
    /// This is intentionally duplicated from NotificationContent for server access.
    public let pairId: String

    /// Absolute APNs badge value to set on the iOS app, or `nil` to leave the
    /// badge unchanged. Unencrypted because the APS payload needs it in the clear.
    public let badge: Int?

    /// When `true`, server sends a background (silent) APNs push: no alert, no
    /// sound, no Notification Service Extension — only the `badge` is applied.
    /// Used to update the badge after `markSessionHandled` clears a session.
    public let silent: Bool

    public init(
        encryptedContent: EncryptedPayload,
        pairId: String,
        badge: Int? = nil,
        silent: Bool = false
    ) {
        self.encryptedContent = encryptedContent
        self.pairId = pairId
        self.badge = badge
        self.silent = silent
    }
}
