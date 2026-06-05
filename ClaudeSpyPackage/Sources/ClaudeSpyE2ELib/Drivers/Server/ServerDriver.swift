import ClaudeSpyExternalServerLib
import Foundation
import Logging
import Vapor

/// Runs the Vapor relay server in-process for E2E testing
public actor ServerDriver {
    private let logger = Logger(label: "e2e.server-driver")
    private var app: Application?
    private var serverTask: Task<Void, Error>?
    private var port = 8_765

    public init() { }

    // MARK: - Server Lifecycle

    /// Start the server on the given port
    public func start(port: Int = 8_765) async throws {
        self.port = port
        logger.info("Starting test server on port \(port)")

        // Clean up stale pairs.json from a previous aborted test run
        let pairsFile = FileManager.default.currentDirectoryPath + "/pairs.json"
        if FileManager.default.fileExists(atPath: pairsFile) {
            try? FileManager.default.removeItem(atPath: pairsFile)
            logger.info("Removed stale pairs.json before starting server")
        }

        // Wire the relay's APNs push log file. APNsService picks this up via
        // `APNS_E2E_LOG_PATH` and records every outgoing push as a JSON line
        // there, including the aggregated badge value — so scenarios can
        // assert on what the relay would have sent without needing real APNs.
        let logPath = Self.defaultAPNSLogPath
        try? FileManager.default.removeItem(atPath: logPath)
        setenv("APNS_E2E_LOG_PATH", logPath, 1)
        logger.info("APNs E2E log path: \(logPath)")

        var env = Environment.testing
        env.arguments = ["vapor", "serve", "--port", "\(port)", "--hostname", "127.0.0.1"]

        let app = try await Application.make(env)

        // Override port before configure
        app.http.server.configuration.port = port
        app.http.server.configuration.hostname = "127.0.0.1"

        try await configure(app)

        self.app = app

        // Run the server in a background task
        serverTask = Task {
            try await app.execute()
        }

        // Wait for it to be ready
        try await waitForHealthy(timeout: 10)

        logger.info("Test server started on port \(port)")
    }

    /// Stop the server
    public func stop() async throws {
        logger.info("Stopping test server")

        serverTask?.cancel()
        serverTask = nil

        if let app {
            try await app.asyncShutdown()
        }
        app = nil

        // Clean up pairs.json created by the server in the working directory
        let pairsFile = FileManager.default.currentDirectoryPath + "/pairs.json"
        if FileManager.default.fileExists(atPath: pairsFile) {
            try? FileManager.default.removeItem(atPath: pairsFile)
            logger.info("Removed pairs.json")
        }
    }

    /// Wait for the server to be healthy
    public func waitForHealthy(timeout: TimeInterval = 10) async throws {
        try await Polling.waitUntil(
            description: "server healthy on port \(port)",
            timeout: timeout,
            pollInterval: 0.5
        ) {
            await self.isHealthy()
        }
    }

    /// Check server health
    public func isHealthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard
                let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                return false
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            return json?["status"] == "ok"
        } catch {
            return false
        }
    }

    // MARK: - State Inspection

    /// Get the number of active pairings
    public func getActivePairingCount() async -> Int {
        guard let app else { return 0 }
        return await app.activePairingCount
    }

    /// Check if any host is connected via WebSocket
    public func isAnyHostConnected() async -> Bool {
        guard let app else { return false }
        return await app.isAnyHostConnected
    }

    /// Check if any viewer is connected via WebSocket
    public func isAnyViewerConnected() async -> Bool {
        guard let app else { return false }
        return await app.isAnyViewerConnected
    }

    /// Reset all server state
    public func resetState() async {
        guard let app else { return }
        await app.resetPairingState()
        logger.info("Server state reset")
    }

    /// Disconnect all WebSocket connections for a given device type
    public func disconnectDevice(type: E2EDeviceType) async {
        guard let app else { return }
        await app.disconnectDevice(deviceType: type.rawValue)
        logger.info("Disconnected all \(type.rawValue) connections")
    }

    /// Block a device type from connecting and disconnect existing connections
    public func blockDevice(type: E2EDeviceType) async {
        guard let app else { return }
        await app.blockDevice(deviceType: type.rawValue)
        logger.info("Blocked \(type.rawValue) connections")
    }

    /// Unblock a device type, allowing connections again
    public func unblockDevice(type: E2EDeviceType) async {
        guard let app else { return }
        await app.unblockDevice(deviceType: type.rawValue)
        logger.info("Unblocked \(type.rawValue) connections")
    }

    /// Wait until the server has no active pairings
    public func waitForNoPairings(timeout: TimeInterval = 15) async throws {
        try await Polling.waitUntil(
            description: "server has no active pairings",
            timeout: timeout,
            pollInterval: 1
        ) {
            await self.getActivePairingCount() == 0
        }
    }

    // MARK: - APNs E2E Log

    /// Filesystem path where `APNsService` records outgoing pushes in E2E mode.
    public static let defaultAPNSLogPath: String =
        NSTemporaryDirectory() + "claudespy-e2e-apns.log"

    /// Decode the JSON-lines push log written by the relay's `APNsService` in
    /// E2E mode. Returns one entry per outgoing push, in the order recorded.
    public func readAPNSPushLog() -> [APNsPushLogEntry] {
        let path = Self.defaultAPNSLogPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return []
        }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(APNsPushLogEntry.self, from: Data(line))
        }
    }

    /// Wait until the APNs log has at least `count` entries.
    public func waitForAPNSPushLog(count: Int, timeout: TimeInterval = 10) async throws {
        try await Polling.waitUntil(
            description: "APNs E2E log has \(count) entries",
            timeout: timeout,
            pollInterval: 0.2
        ) {
            await self.readAPNSPushLog().count >= count
        }
    }

    // MARK: - Synthetic Pairing

    /// Read the viewer identity (deviceId / public key / push token) from the
    /// first active pair on the relay. Lets a second-host pairing reuse the
    /// real iOS app's public key and APNs token, so the relay's badge
    /// aggregation treats both pairs as siblings of the same device.
    public func firstViewerIdentity() async -> ViewerIdentity? {
        guard let app else { return nil }
        guard let raw = await app.firstViewerIdentity() else { return nil }
        return ViewerIdentity(
            pairId: raw.pairId,
            deviceId: raw.deviceId,
            deviceName: raw.deviceName,
            publicKey: raw.publicKey,
            publicKeyId: raw.publicKeyId,
            pushToken: raw.pushToken
        )
    }

    /// Complete a host's pending pairing as if a viewer had submitted the code.
    /// Use after a second Mac generates a pair code to wire it to the existing
    /// iOS viewer without driving the iOS "Add Host" UI.
    @discardableResult
    public func completePairingAsViewer(
        code: String,
        viewer: ViewerIdentity,
        pushToken: String
    ) async throws -> String {
        guard let app else {
            throw ServerDriverError.notRunning
        }
        return try await app.completePairingAsViewer(
            code: code,
            deviceId: viewer.deviceId,
            deviceName: viewer.deviceName,
            publicKey: viewer.publicKey,
            publicKeyId: viewer.publicKeyId,
            pushToken: pushToken
        )
    }

    /// Inject a push as if a host had sent it. Used by badge-aggregation
    /// scenarios to fire "Mac1"'s pushes for a synthesized pair without
    /// running a second Mac host process. The placeholder ciphertext is fine
    /// because the relay's E2E path doesn't actually send to APNs.
    public func injectPush(
        pairId: String,
        hostBadge: Int?,
        silent: Bool
    ) async throws {
        guard let app else {
            throw ServerDriverError.notRunning
        }
        try await app.injectE2EPush(
            pairId: pairId,
            hostBadge: hostBadge,
            silent: silent
        )
    }
}

/// Viewer-side identity snapshot returned from `firstViewerIdentity()`.
public struct ViewerIdentity: Sendable {
    public let pairId: String
    public let deviceId: String
    public let deviceName: String
    public let publicKey: String
    public let publicKeyId: String
    public let pushToken: String?
}

/// Errors thrown by `ServerDriver` test helpers.
public enum ServerDriverError: Error, CustomStringConvertible {
    case notRunning

    public var description: String {
        switch self {
        case .notRunning:
            "ServerDriver is not running"
        }
    }
}
