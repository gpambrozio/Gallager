import APNSCore
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Vapor

/// Configures the Vapor application
public func configure(_ app: Application) async throws {
    // Configure server
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = 8_080

    // Configure JSON encoder/decoder for dates
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(decoder: decoder, for: .json)

    // Initialize core services
    let pairingService = PairingService()
    let connectionHub = ConnectionHub()
    let metricsService = MetricsService()

    // Determine APNs environment from APNS_ENVIRONMENT variable (defaults to development)
    // Use "production" only when iOS app is distributed via App Store/TestFlight
    let apnsEnvString = ProcessInfo.processInfo.environment["APNS_ENVIRONMENT"] ?? "development"
    let apnsEnvironment: APNSEnvironment = apnsEnvString == "production" ? .production : .development

    let apnsService = await APNsService(
        pairingService: pairingService,
        connectionHub: connectionHub,
        metricsService: metricsService,
        environment: apnsEnvironment
    )

    // Release per-pair badge state when a pair is unpaired (via the API or
    // `resetState` in tests). Without this hook the entry stays in
    // `APNsService.lastBadge` for the process lifetime; harmless for the
    // aggregated total (the pair stops matching the device token), but a small
    // leak we can avoid by hanging it off the canonical removal path.
    await pairingService.setOnPairRemoved { [apnsService] pairId in
        await apnsService.clearBadge(pairId: pairId)
    }

    // Initialize relay service with all dependencies
    let relayService = RelayService(
        pairingService: pairingService,
        connectionHub: connectionHub,
        apnsService: apnsService,
        metricsService: metricsService
    )

    // Store services in app storage
    app.storage[PairingServiceKey.self] = pairingService
    app.storage[ConnectionHubKey.self] = connectionHub
    app.storage[APNsServiceKey.self] = apnsService
    app.storage[RelayServiceKey.self] = relayService
    app.storage[MetricsServiceKey.self] = metricsService
    // Use ContinuousClock so /metrics uptime is monotonic (immune to wall-clock jumps).
    app.storage[ProcessStartTimeKey.self] = ContinuousClock.now

    // Bearer token for /metrics endpoint.
    //   nil  → endpoint disabled (all requests get 401)
    //   set  → must be at least 32 characters; shorter values fatalError at boot
    //          to fail-loud rather than ship a brute-forceable production deploy.
    let rawToken = (ProcessInfo.processInfo.environment["METRICS_TOKEN"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let metricsToken: String?
    if rawToken.isEmpty {
        app.logger.warning("METRICS_TOKEN not set — /metrics endpoint will reject all requests")
        metricsToken = nil
    } else if rawToken.count < 32 {
        fatalError(
            "METRICS_TOKEN must be at least 32 characters (got \(rawToken.count)). " +
                "Generate with: openssl rand -hex 32"
        )
    } else {
        metricsToken = rawToken
    }
    app.storage[MetricsTokenKey.self] = metricsToken

    // Register routes
    try routes(app)
}

// MARK: - Storage Keys

struct PairingServiceKey: StorageKey {
    typealias Value = PairingService
}

struct ConnectionHubKey: StorageKey {
    typealias Value = ConnectionHub
}

struct RelayServiceKey: StorageKey {
    typealias Value = RelayService
}

struct APNsServiceKey: StorageKey {
    typealias Value = APNsService
}

struct MetricsServiceKey: StorageKey {
    typealias Value = MetricsService
}

struct ProcessStartTimeKey: StorageKey {
    typealias Value = ContinuousClock.Instant
}

struct MetricsTokenKey: StorageKey {
    /// `nil` means the `/metrics` endpoint is disabled (all requests get 401).
    typealias Value = String?
}

// MARK: - Application Extensions (Internal)

extension Application {
    var pairingService: PairingService {
        guard let service = storage[PairingServiceKey.self] else {
            fatalError("PairingService not configured. Call configure(_:) first.")
        }
        return service
    }

    var connectionHub: ConnectionHub {
        guard let hub = storage[ConnectionHubKey.self] else {
            fatalError("ConnectionHub not configured. Call configure(_:) first.")
        }
        return hub
    }

    var relayService: RelayService {
        guard let service = storage[RelayServiceKey.self] else {
            fatalError("RelayService not configured. Call configure(_:) first.")
        }
        return service
    }

    var apnsService: APNsService? {
        storage[APNsServiceKey.self]
    }

    var metricsService: MetricsService {
        guard let service = storage[MetricsServiceKey.self] else {
            fatalError("MetricsService not configured. Call configure(_:) first.")
        }
        return service
    }

    /// `nil` when the `/metrics` endpoint is disabled (no `METRICS_TOKEN` in env).
    var metricsToken: String? {
        storage[MetricsTokenKey.self] ?? nil
    }
}

// MARK: - Public Application Extensions (for E2E test inspection)

public extension Application {
    /// Get the number of active pairings
    var activePairingCount: Int {
        get async {
            await pairingService.activePairCount
        }
    }

    /// Reset all pairing state (for testing)
    func resetPairingState() async {
        await pairingService.resetState()
        await connectionHub.clearBlockedDeviceTypes()
    }

    /// Check if a host is connected via WebSocket for any active pair
    var isAnyHostConnected: Bool {
        get async {
            let pairs = await pairingService.activePairIds
            for pairId in pairs where await connectionHub.isHostConnected(pairId: pairId) {
                return true
            }
            return false
        }
    }

    /// Disconnect all WebSocket connections for a given device type (for E2E testing)
    func disconnectDevice(deviceType: String) async {
        guard let type = DeviceType(rawValue: deviceType) else { return }
        await connectionHub.disconnectAll(deviceType: type)
    }

    /// Block a device type from connecting and disconnect existing connections (for E2E testing)
    func blockDevice(deviceType: String) async {
        guard let type = DeviceType(rawValue: deviceType) else { return }
        await connectionHub.blockDeviceType(type)
    }

    /// Unblock a device type, allowing connections again (for E2E testing)
    func unblockDevice(deviceType: String) async {
        guard let type = DeviceType(rawValue: deviceType) else { return }
        await connectionHub.unblockDeviceType(type)
    }

    /// Check if a viewer is connected via WebSocket for any active pair
    var isAnyViewerConnected: Bool {
        get async {
            let pairs = await pairingService.activePairIds
            for pairId in pairs where await connectionHub.isViewerConnected(pairId: pairId) {
                return true
            }
            return false
        }
    }

    /// Inspect the viewer-side identity stored on the first active pair. Used
    /// by E2E to "borrow" the real iOS viewer's public key when synthesizing a
    /// second-host pair completion, so the second host's E2EE session
    /// establishes successfully against real key material.
    func firstViewerIdentity() async -> (
        pairId: String,
        deviceId: String,
        deviceName: String,
        publicKey: String,
        publicKeyId: String,
        pushToken: String?
    )? {
        let ids = await pairingService.activePairIds
        for id in ids {
            if let pair = await pairingService.getPair(pairId: id) {
                return (
                    pairId: id,
                    deviceId: pair.viewerDeviceId,
                    deviceName: pair.viewerDeviceName,
                    publicKey: pair.viewerPublicKey,
                    publicKeyId: pair.viewerPublicKeyId,
                    pushToken: pair.pushToken
                )
            }
        }
        return nil
    }

    /// Complete a pending pair as if a viewer had submitted the code. Used by
    /// E2E to add a second host's pair without driving the iOS "Add Host" UI:
    /// pass the real iOS viewer's identity (looked up via
    /// `firstViewerIdentity()`) so the resulting pair record carries iOS's
    /// actual public key. Then `registerPushToken` for the same APNs token the
    /// real iOS already sent, so the relay's badge aggregation sees both pairs
    /// as siblings of one device.
    func completePairingAsViewer(
        code: String,
        deviceId: String,
        deviceName: String,
        publicKey: String,
        publicKeyId: String,
        pushToken: String
    ) async throws -> String {
        let response = await pairingService.completePairing(
            code: code,
            deviceId: deviceId,
            deviceName: deviceName,
            publicKey: publicKey,
            publicKeyId: publicKeyId
        )
        switch response {
        case let .paired(info):
            await pairingService.registerPushToken(pushToken, for: info.pairId)
            return info.pairId
        case let .error(info):
            throw E2EHelperError.completePairingFailed(info.message)
        case .registered:
            throw E2EHelperError.completePairingFailed("Unexpected `registered` response")
        }
    }

    /// Inject a push to the relay's `APNsService` as if a host had sent it.
    /// Used to fire "Mac1's" pushes for a synthesized pair where no real Mac
    /// host process is running — the badge-aggregation scenarios only care
    /// that the relay correctly aggregates across two pairs sharing one APNs
    /// device token. The encrypted body is a placeholder (iOS would decrypt
    /// nothing real, but the E2E path skips the network entirely).
    func injectE2EPush(pairId: String, hostBadge: Int?, silent: Bool) async throws {
        guard let service = apnsService else {
            throw E2EHelperError.injectPushFailed("APNsService not configured")
        }
        let placeholder = EncryptedPayload(
            ciphertext: Data(),
            senderKeyId: "e2e-synthetic"
        )
        let payload = EncryptedPushPayload(
            encryptedContent: placeholder,
            pairId: pairId,
            badge: hostBadge,
            silent: silent
        )
        await service.sendEncryptedNotificationIfNeeded(
            payload: payload,
            pairId: pairId
        )
    }
}

/// Errors thrown by the E2E-only helpers above.
public enum E2EHelperError: Error, CustomStringConvertible {
    case completePairingFailed(String)
    case injectPushFailed(String)

    public var description: String {
        switch self {
        case let .completePairingFailed(message):
            "completePairingAsViewer failed: \(message)"
        case let .injectPushFailed(message):
            "injectE2EPush failed: \(message)"
        }
    }
}
