import APNSCore
import Vapor

/// Configures the Vapor application
public func configure(_ app: Application) async throws {
    // Configure server
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = 8080

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

    // Initialize push notification services
    let pushTokenStore = PushTokenStore()

    // Determine APNs environment from APNS_ENVIRONMENT variable (defaults to development)
    // Use "production" only when iOS app is distributed via App Store/TestFlight
    let apnsEnvString = ProcessInfo.processInfo.environment["APNS_ENVIRONMENT"] ?? "development"
    let apnsEnvironment: APNSEnvironment = apnsEnvString == "production" ? .production : .development

    let apnsService = await APNsService(
        pushTokenStore: pushTokenStore,
        connectionHub: connectionHub,
        environment: apnsEnvironment
    )

    // Initialize relay service with all dependencies
    let relayService = RelayService(
        pairingService: pairingService,
        connectionHub: connectionHub,
        pushTokenStore: pushTokenStore,
        apnsService: apnsService
    )

    // Store services in app storage
    app.storage[PairingServiceKey.self] = pairingService
    app.storage[ConnectionHubKey.self] = connectionHub
    app.storage[PushTokenStoreKey.self] = pushTokenStore
    app.storage[APNsServiceKey.self] = apnsService
    app.storage[RelayServiceKey.self] = relayService

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

struct PushTokenStoreKey: StorageKey {
    typealias Value = PushTokenStore
}

struct APNsServiceKey: StorageKey {
    typealias Value = APNsService
}

// MARK: - Application Extensions

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

    var pushTokenStore: PushTokenStore {
        guard let store = storage[PushTokenStoreKey.self] else {
            fatalError("PushTokenStore not configured. Call configure(_:) first.")
        }
        return store
    }

    var apnsService: APNsService? {
        storage[APNsServiceKey.self]
    }
}
