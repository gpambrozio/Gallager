@preconcurrency import APNS
@preconcurrency import APNSCore
import ClaudeSpyNetworking
import Foundation
import Logging
import NIOCore
import NIOPosix
@preconcurrency import VaporAPNS

/// Sends push notifications to iOS devices via APNs
actor APNsService {
    private let client: APNSClient<JSONDecoder, JSONEncoder>?
    private let pairingService: PairingService
    private let connectionHub: ConnectionHub
    private let logger = Logger(label: "apns-service")
    private let bundleId: String

    // MARK: - Initialization

    init(
        pairingService: PairingService,
        connectionHub: ConnectionHub,
        keyPath: String? = nil,
        keyId: String? = nil,
        teamId: String? = nil,
        bundleId: String? = nil,
        environment: APNSEnvironment = .development
    ) async {
        self.pairingService = pairingService
        self.connectionHub = connectionHub
        self.bundleId = bundleId
            ?? ProcessInfo.processInfo.environment["APNS_BUNDLE_ID"]
            ?? "com.yourcompany.ClaudeSpy"

        // Get config from environment or parameters
        let resolvedKeyPath = keyPath ?? ProcessInfo.processInfo.environment["APNS_KEY_PATH"]
        let resolvedKeyId = keyId ?? ProcessInfo.processInfo.environment["APNS_KEY_ID"]
        let resolvedTeamId = teamId ?? ProcessInfo.processInfo.environment["APNS_TEAM_ID"]

        guard
            let keyPath = resolvedKeyPath,
            let keyId = resolvedKeyId,
            let teamId = resolvedTeamId
        else {
            logger.warning("APNs not configured - missing APNS_KEY_PATH, APNS_KEY_ID, or APNS_TEAM_ID environment variables")
            self.client = nil
            return
        }

        do {
            let keyData = try String(contentsOfFile: keyPath, encoding: .utf8)

            let configuration = try APNSClientConfiguration(
                authenticationMethod: .jwt(
                    privateKey: .loadFrom(string: keyData),
                    keyIdentifier: keyId,
                    teamIdentifier: teamId
                ),
                environment: environment
            )

            self.client = APNSClient(
                configuration: configuration,
                eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
                responseDecoder: JSONDecoder(),
                requestEncoder: JSONEncoder()
            )
            logger.info("APNs client initialized successfully", metadata: [
                "environment": "\(environment)",
                "bundleId": "\(self.bundleId)",
            ])
        } catch {
            logger.error("Failed to initialize APNs client: \(error)")
            self.client = nil
        }
    }

    // MARK: - Public API

    /// Check if APNs is configured and ready
    var isConfigured: Bool {
        client != nil
    }

    /// Send an encrypted push notification.
    /// Only sends if iOS is not currently connected via WebSocket.
    ///
    /// The notification is sent with `mutable-content: 1` so the iOS Notification
    /// Service Extension can intercept it, decrypt the payload, and update the
    /// notification with the decrypted title/body.
    ///
    /// - Parameters:
    ///   - payload: The encrypted push payload from Mac
    ///   - pairId: The pair ID for token lookup
    func sendEncryptedNotificationIfNeeded(payload: EncryptedPushPayload, pairId: String) async {
        // Only send if iOS is not connected via WebSocket
        let isIOSConnected = await connectionHub.isIOSConnected(pairId: pairId)
        if isIOSConnected {
            logger.debug("iOS is connected via WebSocket, skipping encrypted push notification")
            return
        }

        guard let deviceToken = await pairingService.getPushToken(for: pairId) else {
            logger.debug("No push token for pair", metadata: ["pairId": "\(pairId)"])
            return
        }

        guard let client else {
            logger.warning("APNs client not configured, cannot send notification")
            return
        }

        // Build notification with generic placeholder text
        // The iOS Notification Service Extension will decrypt and replace with actual content
        let alert = APNSAlertNotificationContent(
            title: .raw("Claude Code"),
            body: .raw("New activity") // Placeholder - extension replaces this
        )

        // Encode the encrypted content for the payload
        let encryptedPayload: EncryptedClaudeSpyPayload
        do {
            let encoder = JSONEncoder()
            let encryptedData = try encoder.encode(payload.encryptedContent)
            encryptedPayload = EncryptedClaudeSpyPayload(
                encrypted: encryptedData.base64EncodedString(),
                pairId: pairId
            )
        } catch {
            logger.error("Failed to encode encrypted payload: \(error)")
            return
        }

        // Create notification with mutable-content flag for extension processing
        let notification = APNSAlertNotification(
            alert: alert,
            expiration: .immediately,
            priority: .immediately,
            topic: bundleId,
            payload: encryptedPayload,
            badge: 1,
            mutableContent: 1 // Triggers Notification Service Extension
        )

        do {
            _ = try await client.sendAlertNotification(
                notification,
                deviceToken: deviceToken
            )
            logger.info("Encrypted push notification sent", metadata: [
                "pairId": "\(pairId)",
            ])
        } catch let error as APNSError {
            handleAPNsError(error, pairId: pairId, deviceToken: deviceToken)
        } catch {
            logger.error("Failed to send encrypted push notification: \(error)")
        }
    }

    /// Graceful shutdown
    func shutdown() async {
        // APNSClient handles its own cleanup
        logger.info("APNs service shutting down")
    }

    // MARK: - Private Helpers

    /// Handle APNs-specific errors
    private func handleAPNsError(_ error: APNSError, pairId: String, deviceToken: String) {
        logger.error("APNs error: \(error)", metadata: [
            "pairId": "\(pairId)",
            "responseStatus": "\(error.responseStatus)",
        ])

        // Check for errors that indicate the token is invalid
        if let reason = error.reason?.reason {
            // reason is a String, check for known invalid token errors
            if reason == "BadDeviceToken" || reason == "Unregistered" {
                // Device token is no longer valid, remove it
                Task {
                    await pairingService.removePushToken(for: pairId)
                    logger.warning("Removed invalid push token for pair", metadata: ["pairId": "\(pairId)"])
                }
            }
        }
    }
}

// MARK: - Custom Payloads

/// Custom payload for encrypted ClaudeSpy push notifications.
///
/// The `encrypted` field contains a Base64-encoded JSON representation of
/// `EncryptedPayload` from ClaudeSpyEncryption. The iOS Notification Service
/// Extension decodes and decrypts this to get the actual notification content.
struct EncryptedClaudeSpyPayload: Codable, Sendable {
    /// Base64-encoded JSON of EncryptedPayload
    let encrypted: String

    /// Pair ID for reference (also in encrypted content)
    let pairId: String
}
