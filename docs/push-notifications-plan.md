# Push Notifications Implementation Plan

## Overview

This document outlines the implementation plan for sending push notifications from the ClaudeSpy external server to paired iOS devices. Push notifications will alert users to important coding-agent events (Claude Code or Codex CLI) when the iOS app is not actively connected via WebSocket.

> **Note (2026-05):** Notification copy is now rendered against `CodingAgent.displayName` / `shortName`, so the sample strings below that hard-code "Claude Code" should be read as templates. The shipped behavior interpolates the agent name from the event's `agent` field (`"Claude Code"` or `"Codex"`).

## Current Architecture Context

The existing distributed system uses:
- **WebSocket connections** for real-time communication between Mac ↔ Server ↔ iOS
- **Device pairing** via 6-character codes, stored in `pairs.json`
- **Hook events** from Claude Code and Codex CLI forwarded through the relay (each tagged with a `CodingAgent`)

**Key limitation:** When the iOS app is backgrounded or closed, WebSocket connections are terminated. Users miss important events like permission requests or session completions.

## Components to Modify

### 1. Apple Developer Portal Configuration

Before any code changes, you must configure APNs in your Apple Developer account.

#### 1.1 Create APNs Authentication Key

Apple now recommends **token-based authentication** (.p8 keys) over certificate-based (.p12) authentication. Keys never expire and work across all apps in your team.

**Steps:**
1. Go to [Apple Developer Keys](https://developer.apple.com/account/resources/authkeys/list)
2. Click "+" to create a new key
3. Name it (e.g., "ClaudeSpy Push Notifications")
4. Check "Apple Push Notifications service (APNs)"
5. Select environment: **Sandbox** for development, **Production** for release
6. Click "Continue" then "Register"
7. **Download the .p8 file** (you can only download once!)
8. Note the **Key ID** (10-character string)
9. Note your **Team ID** (from Membership page or top-right of developer portal)

**Store securely:**
- `AuthKey_XXXXXXXXXX.p8` - The private key file
- Key ID: `XXXXXXXXXX`
- Team ID: `YYYYYYYYYY`

> **Important:** The .p8 key cannot be re-downloaded. Store it securely. If compromised, revoke and create a new key.

#### 1.2 Enable Push Notifications for App ID

1. Go to [Identifiers](https://developer.apple.com/account/resources/identifiers/list)
2. Select your ClaudeSpy iOS app identifier
3. Enable "Push Notifications" capability
4. Save changes

### 2. iOS App Changes

#### 2.1 Add Push Notification Entitlement

**File:** `Config/ClaudeSpy.entitlements`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>aps-environment</key>
    <string>development</string>
</dict>
</plist>
```

> **Note:** Change to `production` for App Store builds.

#### 2.2 Create Push Notification Service

**New file:** `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Services/PushNotificationService.swift`

```swift
import Foundation
import UIKit
import UserNotifications

@Observable
@MainActor
public final class PushNotificationService: NSObject {
    public static let shared = PushNotificationService()

    public private(set) var deviceToken: Data?
    public private(set) var tokenString: String?
    public private(set) var permissionStatus: UNAuthorizationStatus = .notDetermined

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Request notification permissions and register for remote notifications
    public func requestAuthorization() async throws {
        let center = UNUserNotificationCenter.current()

        let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])

        if granted {
            await UIApplication.shared.registerForRemoteNotifications()
        }

        await updatePermissionStatus()
    }

    /// Called from AppDelegate when device token is received
    public func didRegisterForRemoteNotifications(deviceToken: Data) {
        self.deviceToken = deviceToken
        self.tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    }

    /// Called from AppDelegate on registration failure
    public func didFailToRegisterForRemoteNotifications(error: Error) {
        print("Failed to register for remote notifications: \(error)")
        self.deviceToken = nil
        self.tokenString = nil
    }

    // MARK: - Private

    private func updatePermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        self.permissionStatus = settings.authorizationStatus
    }
}
```

#### 2.3 Update App Entry Point

**Modified file:** `ClaudeSpy/ClaudeSpyApp.swift`

```swift
import SwiftUI
import ClaudeSpyFeature

@main
struct ClaudeSpyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushNotificationService.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)

            // Send token to server if paired
            if let pairId = IOSSettings.shared.pairId,
               let tokenString = PushNotificationService.shared.tokenString {
                // RelayClient will need a method to send the token
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PushNotificationService.shared.didFailToRegisterForRemoteNotifications(error: error)
        }
    }
}
```

#### 2.4 Update RelayClient to Send Device Token

**Modified file:** `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Services/RelayClient.swift`

Add a method to send the device token to the server after connection:

```swift
/// Send push notification token to server
public func sendPushToken(_ token: String) async throws {
    let message = WebSocketMessage.registerPushToken(
        RegisterPushTokenMessage(deviceToken: token)
    )
    try await send(message)
}
```

#### 2.5 Add UI for Requesting Permissions

Add a prompt in the settings or after pairing to request notification permissions:

```swift
// In ContentView or SettingsView
Button("Enable Notifications") {
    Task {
        try? await PushNotificationService.shared.requestAuthorization()
    }
}
```

### 3. Networking Model Updates

#### 3.1 Add Push Token Message Types

**Modified file:** `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/WebSocketMessage.swift`

Add new message types:

```swift
// New message for registering push token
public struct RegisterPushTokenMessage: Codable, Sendable {
    public let deviceToken: String

    public init(deviceToken: String) {
        self.deviceToken = deviceToken
    }
}

// Add to WebSocketMessage enum
case registerPushToken(RegisterPushTokenMessage)
case pushTokenRegistered(PushTokenRegisteredMessage)

public struct PushTokenRegisteredMessage: Codable, Sendable {
    public let success: Bool
    public let error: String?

    public init(success: Bool, error: String? = nil) {
        self.success = success
        self.error = error
    }
}
```

### 4. External Server Changes

#### 4.1 Add APNSwift Dependency

**Modified file:** `ClaudeSpyPackage/Package.swift`

```swift
dependencies: [
    // ... existing dependencies
    .package(url: "https://github.com/vapor/apns.git", from: "4.0.0"),
],

// In ClaudeSpyExternalServer target
.executableTarget(
    name: "ClaudeSpyExternalServer",
    dependencies: [
        .claudeSpyNetworking,
        .vapor,
        .product(name: "VaporAPNS", package: "apns"),
    ]
),
```

#### 4.2 Create Push Token Storage

**New file:** `ClaudeSpyPackage/Sources/ClaudeSpyExternalServer/Services/PushTokenStore.swift`

```swift
import Foundation
import Logging

/// Stores push notification tokens associated with pair IDs
actor PushTokenStore {
    private var tokens: [String: String] = [:] // [pairId: deviceToken]
    private let dataDirectory: URL
    private let logger = Logger(label: "push-token-store")

    private var tokensFileURL: URL {
        dataDirectory.appendingPathComponent("push-tokens.json")
    }

    init(dataDirectory: URL? = nil) {
        let resolvedDirectory: URL
        if let dir = dataDirectory {
            resolvedDirectory = dir
        } else if let envPath = ProcessInfo.processInfo.environment["DATA_DIRECTORY"] {
            resolvedDirectory = URL(fileURLWithPath: envPath)
        } else {
            resolvedDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        self.dataDirectory = resolvedDirectory

        let fileURL = resolvedDirectory.appendingPathComponent("push-tokens.json")
        self.tokens = Self.loadTokensSync(from: fileURL, logger: self.logger)
    }

    private static func loadTokensSync(from url: URL, logger: Logger) -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.info("No existing push tokens file found")
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            logger.error("Failed to load push tokens: \(error)")
            return [:]
        }
    }

    func registerToken(_ token: String, for pairId: String) {
        tokens[pairId] = token
        saveTokens()
        logger.info("Registered push token for pair", metadata: ["pairId": "\(pairId)"])
    }

    func getToken(for pairId: String) -> String? {
        tokens[pairId]
    }

    func removeToken(for pairId: String) {
        tokens.removeValue(forKey: pairId)
        saveTokens()
    }

    private func saveTokens() {
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(tokens)
            try data.write(to: tokensFileURL, options: .atomic)
        } catch {
            logger.error("Failed to save push tokens: \(error)")
        }
    }
}
```

#### 4.3 Create APNs Notification Service

**New file:** `ClaudeSpyPackage/Sources/ClaudeSpyExternalServer/Services/APNsService.swift`

```swift
import APNS
import APNSCore
import ClaudeSpyNetworking
import Foundation
import Logging
import VaporAPNS

/// Sends push notifications to iOS devices via APNs
actor APNsService {
    private let client: APNSClient<JSONDecoder, JSONEncoder>?
    private let pushTokenStore: PushTokenStore
    private let connectionHub: ConnectionHub
    private let logger = Logger(label: "apns-service")
    private let bundleId: String

    init(
        pushTokenStore: PushTokenStore,
        connectionHub: ConnectionHub,
        keyPath: String? = nil,
        keyId: String? = nil,
        teamId: String? = nil,
        bundleId: String? = nil,
        environment: APNSClient.Environment = .sandbox
    ) async {
        self.pushTokenStore = pushTokenStore
        self.connectionHub = connectionHub
        self.bundleId = bundleId ?? ProcessInfo.processInfo.environment["APNS_BUNDLE_ID"] ?? "com.yourcompany.ClaudeSpy"

        // Get config from environment or parameters
        let resolvedKeyPath = keyPath ?? ProcessInfo.processInfo.environment["APNS_KEY_PATH"]
        let resolvedKeyId = keyId ?? ProcessInfo.processInfo.environment["APNS_KEY_ID"]
        let resolvedTeamId = teamId ?? ProcessInfo.processInfo.environment["APNS_TEAM_ID"]

        guard let keyPath = resolvedKeyPath,
              let keyId = resolvedKeyId,
              let teamId = resolvedTeamId else {
            logger.warning("APNs not configured - missing APNS_KEY_PATH, APNS_KEY_ID, or APNS_TEAM_ID")
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

            self.client = APNSClient(configuration: configuration)
            logger.info("APNs client initialized successfully")
        } catch {
            logger.error("Failed to initialize APNs client: \(error)")
            self.client = nil
        }
    }

    /// Send a push notification for a hook event
    func sendNotification(for event: HookEventMessage, pairId: String) async {
        // Only send if iOS is not connected via WebSocket
        let isIOSConnected = await connectionHub.isIOSConnected(pairId: pairId)
        if isIOSConnected {
            logger.debug("iOS is connected, skipping push notification")
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

        // Determine if this event should trigger a push notification
        guard let notification = buildNotification(for: event) else {
            return
        }

        do {
            try await client.sendAlertNotification(
                notification,
                deviceToken: deviceToken,
                deadline: .distantFuture
            )
            logger.info("Push notification sent", metadata: ["pairId": "\(pairId)"])
        } catch {
            logger.error("Failed to send push notification: \(error)")
        }
    }

    /// Build notification content based on event type
    private func buildNotification(for eventMessage: HookEventMessage) -> APNSAlertNotification<EmptyPayload>? {
        let event = eventMessage.event
        let projectName = eventMessage.projectName ?? "Unknown Project"

        let (title, body): (String, String)? = switch event.action {
        case .permissionRequest:
            ("Permission Required", "\(projectName): Claude needs your approval")
        case .sessionStart:
            ("Session Started", "\(projectName): Claude Code session started")
        case .sessionEnd:
            ("Session Ended", "\(projectName): Claude Code session completed")
        case .stop:
            ("Session Stopped", "\(projectName): Claude Code was stopped")
        case let .notification(notifBody):
            if let message = notifBody.message {
                ("Notification", "\(projectName): \(message)")
            } else {
                nil
            }
        default:
            nil
        }

        guard let (title, body) else { return nil }

        let alert = APNSAlertNotificationContent(
            title: .raw(title),
            body: .raw(body)
        )

        return APNSAlertNotification(
            alert: alert,
            expiration: .immediately,
            priority: .immediately,
            topic: bundleId,
            payload: EmptyPayload()
        )
    }

    func shutdown() async {
        // Graceful shutdown if needed
    }
}

/// Empty payload for simple notifications
struct EmptyPayload: Codable, Sendable {}
```

#### 4.4 Update RelayService to Trigger Push Notifications

**Modified file:** `ClaudeSpyPackage/Sources/ClaudeSpyExternalServer/Services/RelayService.swift`

Add APNs integration:

```swift
actor RelayService {
    private let pairingService: PairingService
    private let connectionHub: ConnectionHub
    private let apnsService: APNsService?
    private let pushTokenStore: PushTokenStore
    private let logger = Logger(label: "relay-service")

    init(
        pairingService: PairingService,
        connectionHub: ConnectionHub,
        apnsService: APNsService?,
        pushTokenStore: PushTokenStore
    ) {
        self.pairingService = pairingService
        self.connectionHub = connectionHub
        self.apnsService = apnsService
        self.pushTokenStore = pushTokenStore
    }

    // In handleMacMessage, after relaying hook event:
    case let .hookEvent(event):
        // Relay hook events to iOS via WebSocket
        await connectionHub.send(.hookEvent(event), to: pairId, deviceType: .ios)

        // Also try to send push notification (will only send if iOS disconnected)
        await apnsService?.sendNotification(for: event, pairId: pairId)

    // Handle push token registration from iOS
    case let .registerPushToken(tokenMessage):
        await pushTokenStore.registerToken(tokenMessage.deviceToken, for: pairId)
        let response = PushTokenRegisteredMessage(success: true)
        await connectionHub.send(.pushTokenRegistered(response), to: pairId, deviceType: .ios)
}
```

#### 4.5 Update Configuration

**Modified file:** `ClaudeSpyPackage/Sources/ClaudeSpyExternalServer/configure.swift`

Initialize APNs service:

```swift
import VaporAPNS

public func configure(_ app: Application) async throws {
    // ... existing configuration

    let pushTokenStore = PushTokenStore()

    let apnsService = await APNsService(
        pushTokenStore: pushTokenStore,
        connectionHub: connectionHub,
        environment: app.environment == .production ? .production : .sandbox
    )

    // Store in app storage for access in routes
    app.storage[APNsServiceKey.self] = apnsService
    app.storage[PushTokenStoreKey.self] = pushTokenStore

    // Update RelayService initialization
    let relayService = RelayService(
        pairingService: pairingService,
        connectionHub: connectionHub,
        apnsService: apnsService,
        pushTokenStore: pushTokenStore
    )

    // ... rest of configuration
}
```

### 5. Docker & Deployment Updates

#### 5.1 Update docker-compose.yml

```yaml
services:
  server:
    build: .
    environment:
      - LOG_LEVEL=info
      - DATA_DIRECTORY=/data
      - APNS_KEY_PATH=/secrets/AuthKey.p8
      - APNS_KEY_ID=XXXXXXXXXX
      - APNS_TEAM_ID=YYYYYYYYYY
      - APNS_BUNDLE_ID=com.yourcompany.ClaudeSpy
      - APNS_ENVIRONMENT=production  # or sandbox
    volumes:
      - ./data:/data
      - ./secrets:/secrets:ro
```

#### 5.2 Secure Key Storage

For production:
1. Store the .p8 key securely (not in git!)
2. Use Docker secrets or environment variables
3. Mount as read-only volume

```bash
# Create secrets directory
mkdir -p secrets
# Copy your .p8 key (do not commit to git!)
cp ~/path/to/AuthKey_XXXXXXXXXX.p8 secrets/AuthKey.p8
chmod 600 secrets/AuthKey.p8
```

### 6. Events That Trigger Push Notifications

Based on the existing hook events, these events should trigger push notifications when the iOS app is not connected:

| Event | Priority | Notification Content |
|-------|----------|---------------------|
| `permissionRequest` | **High** | "Permission Required: Claude needs approval" |
| `sessionStart` | Medium | "Session Started: Claude Code session began" |
| `sessionEnd` | Medium | "Session Ended: Claude Code session completed" |
| `stop` | Medium | "Session Stopped: Claude Code was interrupted" |
| `notification` | Varies | The notification message from Claude |

Events that should **NOT** trigger push notifications:
- `preToolUse`, `postToolUse` - Too frequent, not actionable
- `userPromptSubmit` - User initiated, no need to notify
- `subagentStop`, `preCompact` - Internal events

### 7. Implementation Order

#### Phase 1: Foundation (Server-Side)
1. Add APNSwift dependency to Package.swift
2. Create `PushTokenStore` actor
3. Create `APNsService` actor
4. Update `RelayService` to handle push token registration

#### Phase 2: iOS App Updates
1. Add push notification entitlement
2. Create `PushNotificationService`
3. Add AppDelegate for handling device tokens
4. Update `RelayClient` to send push token after connection
5. Add UI for requesting notification permissions

#### Phase 3: Networking Models
1. Add `RegisterPushTokenMessage` to WebSocketMessage
2. Add `PushTokenRegisteredMessage` response type

#### Phase 4: Integration & Testing
1. Configure APNs key in Apple Developer Portal
2. Update docker-compose.yml with environment variables
3. Test in sandbox environment
4. Test notification delivery when iOS app is backgrounded
5. Deploy to production

### 8. Testing Strategy

#### 8.1 Local Testing
- Use APNs sandbox environment
- Build iOS app for development (sandbox APNs)
- Test token registration flow
- Verify notifications received when app backgrounded

#### 8.2 Push Notification Console
Apple provides a [Push Notifications Console](https://developer.apple.com/notifications/push-notifications-console/) for testing:
1. Enter device token
2. Select app bundle ID
3. Send test notification
4. Verify delivery

#### 8.3 Production Testing
- Gradually roll out to beta users
- Monitor APNs error responses
- Track notification delivery rates

### 9. Error Handling

Common APNs errors to handle:
- `BadDeviceToken` - Remove invalid tokens from store
- `Unregistered` - Device uninstalled app, remove token
- `ExpiredProviderToken` - Refresh JWT token (handled by library)
- `TooManyRequests` - Implement rate limiting/backoff

### 10. Security Considerations

1. **Key Security**: Never commit .p8 keys to version control
2. **Token Validation**: Validate device tokens are hexadecimal strings
3. **Rate Limiting**: Don't send too many notifications (Apple may throttle)
4. **Environment Separation**: Use sandbox for development, production for release
5. **Token Refresh**: JWT tokens must be refreshed every 20-60 minutes (APNSwift handles this)

---

## Summary

This plan implements push notifications for ClaudeSpy with:
- **Minimal iOS changes**: Just register for notifications and send token to server
- **Server-side intelligence**: Decide when to send pushes based on iOS connection state
- **Event-based notifications**: Only important events trigger pushes
- **Secure configuration**: .p8 key stored outside codebase

The implementation follows Apple's recommended token-based authentication approach, which never expires and works across all apps in your team.

---

*Written with the weary recognition that push notifications represent yet another layer of complexity in an already distributed system. But if users insist on being notified of things—and they do insist—then we must oblige. At least Apple's token-based auth means we won't have to renew certificates annually. Small mercies.*

## References

- [Apple: Registering your app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
- [Apple: Establishing a token-based connection to APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
- [Vapor APNS Documentation](https://docs.vapor.codes/advanced/apns/)
- [APNSwift GitHub](https://github.com/swift-server-community/APNSwift)
- [Apple Push Notifications Console](https://developer.apple.com/notifications/push-notifications-console/)
