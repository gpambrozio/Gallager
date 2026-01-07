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
    private let pushTokenStore: PushTokenStore
    private let connectionHub: ConnectionHub
    private let logger = Logger(label: "apns-service")
    private let bundleId: String

    // MARK: - Initialization

    init(
        pushTokenStore: PushTokenStore,
        connectionHub: ConnectionHub,
        keyPath: String? = nil,
        keyId: String? = nil,
        teamId: String? = nil,
        bundleId: String? = nil,
        environment: APNSEnvironment = .development
    ) async {
        self.pushTokenStore = pushTokenStore
        self.connectionHub = connectionHub
        self.bundleId = bundleId
            ?? ProcessInfo.processInfo.environment["APNS_BUNDLE_ID"]
            ?? "com.yourcompany.ClaudeSpy"

        // Get config from environment or parameters
        let resolvedKeyPath = keyPath ?? ProcessInfo.processInfo.environment["APNS_KEY_PATH"]
        let resolvedKeyId = keyId ?? ProcessInfo.processInfo.environment["APNS_KEY_ID"]
        let resolvedTeamId = teamId ?? ProcessInfo.processInfo.environment["APNS_TEAM_ID"]

        guard let keyPath = resolvedKeyPath,
              let keyId = resolvedKeyId,
              let teamId = resolvedTeamId
        else {
            logger.warning("APNs not configured - missing APNS_KEY_PATH, APNS_KEY_ID, or APNS_TEAM_ID environment variables")
            self.client = nil
            return
        }

        do {
            let keyData = try String(contentsOfFile: keyPath, encoding: .utf8)

            let configuration = APNSClientConfiguration(
                authenticationMethod: .jwt(
                    privateKey: try .loadFrom(string: keyData),
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
                "bundleId": "\(self.bundleId)"
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

    /// Send a push notification for a hook event
    /// Only sends if iOS is not currently connected via WebSocket
    func sendNotificationIfNeeded(for event: HookEventMessage, pairId: String) async {
        // Only send if iOS is not connected via WebSocket
        let isIOSConnected = await connectionHub.isIOSConnected(pairId: pairId)
        if isIOSConnected {
            logger.debug("iOS is connected via WebSocket, skipping push notification")
            return
        }

        guard let deviceToken = await pushTokenStore.getToken(for: pairId) else {
            logger.debug("No push token for pair", metadata: ["pairId": "\(pairId)"])
            return
        }

        guard let client else {
            logger.warning("APNs client not configured, cannot send notification")
            return
        }

        // Build notification content based on event type
        guard let notification = buildNotification(for: event) else {
            logger.debug("Event type does not trigger push notification")
            return
        }

        do {
            _ = try await client.sendAlertNotification(
                notification,
                deviceToken: deviceToken
            )
            logger.info("Push notification sent", metadata: [
                "pairId": "\(pairId)",
                "eventType": "\(event.event.action.eventName)"
            ])
        } catch let error as APNSError {
            handleAPNsError(error, pairId: pairId, deviceToken: deviceToken)
        } catch {
            logger.error("Failed to send push notification: \(error)")
        }
    }

    /// Graceful shutdown
    func shutdown() async {
        // APNSClient handles its own cleanup
        logger.info("APNs service shutting down")
    }

    // MARK: - Private Helpers

    /// Build notification content based on event type
    private func buildNotification(for eventMessage: HookEventMessage) -> APNSAlertNotification<ClaudeSpyPayload>? {
        guard let notification = eventMessage.buildNotification() else {
            return nil
        }
    
        let alert = APNSAlertNotificationContent(
            title: .raw(notification.title),
            body: .raw(notification.body)
        )

        let payload = ClaudeSpyPayload(
            eventType: eventMessage.event.action.eventName,
            pairId: eventMessage.pairId
        )

        return APNSAlertNotification(
            alert: alert,
            expiration: .immediately,
            priority: .immediately,
            topic: bundleId,
            payload: payload,
            badge: 1
        )
    }

    /// Handle APNs-specific errors
    private func handleAPNsError(_ error: APNSError, pairId: String, deviceToken: String) {
        logger.error("APNs error: \(error)", metadata: [
            "pairId": "\(pairId)",
            "responseStatus": "\(error.responseStatus)"
        ])

        // Check for errors that indicate the token is invalid
        if let reason = error.reason?.reason {
            // reason is a String, check for known invalid token errors
            if reason == "BadDeviceToken" || reason == "Unregistered" {
                // Device token is no longer valid, remove it
                Task {
                    await pushTokenStore.removeToken(for: pairId)
                    logger.warning("Removed invalid push token for pair", metadata: ["pairId": "\(pairId)"])
                }
            }
        }
    }
}

// MARK: - Custom Payload

/// Custom payload for ClaudeSpy push notifications
struct ClaudeSpyPayload: Codable, Sendable {
    let eventType: String
    let pairId: String
}
