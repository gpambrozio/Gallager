import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Crypto
import UserNotifications

/// Notification Service Extension that decrypts encrypted push notification payloads.
///
/// When a push notification arrives with `mutable-content: 1` and an encrypted payload,
/// this extension decrypts the notification content and updates the notification before
/// it's displayed to the user.
///
/// ## Requirements
/// - App Group entitlement matching the main app (for Keychain sharing)
/// - Keychain Access Group entitlement matching the main app
/// - ClaudeSpyEncryption framework linked
class NotificationService: UNNotificationServiceExtension {
    /// Handler to call with the modified notification content
    var contentHandler: ((UNNotificationContent) -> Void)?

    /// The mutable copy of the notification content
    var bestAttemptContent: UNMutableNotificationContent?

    // MARK: - UNNotificationServiceExtension

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        Task {
            await decryptAndUpdateNotification(request: request)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated.
        // Deliver the best attempt content (generic or partially modified).
        if let contentHandler, let content = bestAttemptContent {
            contentHandler(content)
        }
    }

    // MARK: - Decryption

    private func decryptAndUpdateNotification(request: UNNotificationRequest) async {
        guard let content = bestAttemptContent else {
            deliverBestAttempt()
            return
        }

        // Extract encrypted payload from notification userInfo
        guard let encryptedBase64 = request.content.userInfo["encrypted"] as? String else {
            // No encrypted payload, deliver original notification
            deliverBestAttempt()
            return
        }

        // Decode the encrypted payload
        guard let encryptedData = Data(base64Encoded: encryptedBase64) else {
            deliverBestAttempt()
            return
        }

        let encryptedPayload: EncryptedPayload
        do {
            encryptedPayload = try JSONDecoder().decode(EncryptedPayload.self, from: encryptedData)
        } catch {
            deliverBestAttempt()
            return
        }

        // Load session key from Keychain
        let keyManager = KeyManager(accessGroup: sharedKeychainAccessGroup)
        let sessionKeyData: Data?
        do {
            sessionKeyData = try await keyManager.loadSessionKey()
        } catch {
            deliverBestAttempt()
            return
        }

        guard let sessionKeyData else {
            deliverBestAttempt()
            return
        }

        // Create symmetric key and decrypt
        do {
            let symmetricKey = SymmetricKey(data: sessionKeyData)
            let decryptedData = try decryptPayload(encryptedPayload, using: symmetricKey)

            // Decode the notification content
            let notificationContent = try JSONDecoder().decode(NotificationContent.self, from: decryptedData)

            // Update the notification with decrypted content
            content.title = notificationContent.title
            content.body = notificationContent.body

            // Optionally add additional context to userInfo
            content.userInfo["eventType"] = notificationContent.eventType
            content.userInfo["decrypted"] = true

            contentHandler?(content)
        } catch {
            deliverBestAttempt()
        }
    }

    private func decryptPayload(_ payload: EncryptedPayload, using symmetricKey: SymmetricKey) throws -> Data {
        // Verify protocol version
        guard payload.version == encryptionProtocolVersion else {
            throw DecryptionError.versionMismatch
        }

        // Decrypt using ChaChaPoly
        let sealedBox = try ChaChaPoly.SealedBox(combined: payload.ciphertext)
        return try ChaChaPoly.open(sealedBox, using: symmetricKey)
    }

    private func deliverBestAttempt() {
        if let contentHandler, let content = bestAttemptContent {
            contentHandler(content)
        }
    }
}

// MARK: - Errors

private enum DecryptionError: Error {
    case versionMismatch
    case invalidPayload
}
