import APNSCore
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
    app.storage[ProcessStartTimeKey.self] = Date()

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
    typealias Value = Date
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
}
