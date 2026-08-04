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

    /// Action-button context when the notification accompanies an open
    /// permission / question form (issue #710). The NSE turns it into a
    /// notification category and stashes it in `userInfo` so the app can
    /// submit the answer straight from the action tap. Optional and absent
    /// for plain notifications — older hosts never send it, older viewers
    /// ignore it (additive, no version bump).
    public let action: NotificationActionContext?

    public init(
        title: String,
        body: String,
        eventType: String,
        pairId: String,
        paneId: String? = nil,
        timestamp: Date = Date(),
        action: NotificationActionContext? = nil
    ) {
        self.title = title
        self.body = body
        self.eventType = eventType
        self.pairId = pairId
        self.paneId = paneId
        self.timestamp = timestamp
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case title, body, eventType, pairId, paneId, timestamp, action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decode(String.self, forKey: .title)
        self.body = try container.decode(String.self, forKey: .body)
        self.eventType = try container.decode(String.self, forKey: .eventType)
        self.pairId = try container.decode(String.self, forKey: .pairId)
        self.paneId = try container.decodeIfPresent(String.self, forKey: .paneId)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        // Lenient on purpose (cross-host version skew): a future host may add
        // a `Form` case this build can't decode. A strict decode here would
        // fail the WHOLE content — and the NSE's catch would show its scary
        // "decryption failed / re-pair" notification. Degrade to a plain
        // notification instead.
        self.action = (try? container.decodeIfPresent(NotificationActionContext.self, forKey: .action)) ?? nil
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
