import Vapor

/// Configures the Vapor application
public func configure(_ app: Application) throws {
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

    // Initialize services
    let pairingService = PairingService()
    let connectionHub = ConnectionHub()
    let relayService = RelayService(pairingService: pairingService, connectionHub: connectionHub)

    // Store services in app storage
    app.storage[PairingServiceKey.self] = pairingService
    app.storage[ConnectionHubKey.self] = connectionHub
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
}
