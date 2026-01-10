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
            deliverWithFailure(reason: .noContent)
            return
        }

        // Extract encrypted payload from notification userInfo
        guard let encryptedBase64 = request.content.userInfo["encrypted"] as? String else {
            // Server should always send encrypted payloads - this is unexpected
            deliverWithFailure(reason: .missingEncryptedPayload)
            return
        }

        // Decode the encrypted payload
        guard let encryptedData = Data(base64Encoded: encryptedBase64) else {
            deliverWithFailure(reason: .base64DecodeFailed)
            return
        }

        let encryptedPayload: EncryptedPayload
        do {
            encryptedPayload = try JSONDecoder().decode(EncryptedPayload.self, from: encryptedData)
        } catch {
            deliverWithFailure(reason: .payloadDecodeFailed)
            return
        }

        // Load session key from Keychain
        let keyManager = KeyManager(accessGroup: sharedKeychainAccessGroup)
        let sessionKeyData: Data?
        do {
            sessionKeyData = try await keyManager.loadSessionKey()
        } catch {
            deliverWithFailure(reason: .keychainError)
            return
        }

        guard let sessionKeyData else {
            deliverWithFailure(reason: .noSessionKey)
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
        } catch let error as DecryptionError {
            switch error {
            case .versionMismatch:
                deliverWithFailure(reason: .versionMismatch)
            case .invalidPayload:
                deliverWithFailure(reason: .decryptionFailed)
            }
        } catch {
            deliverWithFailure(reason: .decryptionFailed)
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

    private func deliverWithFailure(reason: DecryptionFailureReason) {
        guard let contentHandler, let content = bestAttemptContent else {
            return
        }

        content.title = "Encrypted Message"
        content.body = reason.userMessage
        content.userInfo["decrypted"] = false
        content.userInfo["failureReason"] = reason.rawValue

        contentHandler(content)
    }
}

// MARK: - Errors

private enum DecryptionError: Error {
    case versionMismatch
    case invalidPayload
}

/// Reasons why decryption failed, with user-facing messages for debugging
private enum DecryptionFailureReason: String {
    case noContent = "no_content"
    case missingEncryptedPayload = "missing_encrypted_payload"
    case base64DecodeFailed = "base64_decode_failed"
    case payloadDecodeFailed = "payload_decode_failed"
    case keychainError = "keychain_error"
    case noSessionKey = "no_session_key"
    case versionMismatch = "version_mismatch"
    case decryptionFailed = "decryption_failed"

    var userMessage: String {
        switch self {
        case .noContent:
            return "Unable to process notification"
        case .missingEncryptedPayload:
            return "Missing encrypted payload"
        case .base64DecodeFailed:
            return "Corrupted payload (base64)"
        case .payloadDecodeFailed:
            return "Corrupted payload (format)"
        case .keychainError:
            return "Keychain access failed"
        case .noSessionKey:
            return "No encryption session - re-pair devices"
        case .versionMismatch:
            return "Protocol version mismatch - update app"
        case .decryptionFailed:
            return "Decryption failed - re-pair devices"
        }
    }
}
