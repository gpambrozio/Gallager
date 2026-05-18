import ClaudeSpyNetworking
import Foundation
import Logging

/// Manages device pairing codes and paired viewer records
actor PairingService {
    /// Pending pairing codes waiting for completion
    private var pendingCodes: [String: PendingPairing] = [:]

    /// Active paired connections
    private var activePairs: [String: Pair] = [:]

    /// How long a pairing code remains valid (5 minutes)
    private let codeExpirySeconds: TimeInterval = 300

    /// Directory where pairs.json is stored
    private let dataDirectory: URL

    /// Logger for persistence operations
    private let logger = Logger(label: "pairing-service")

    /// File URL for pairs.json
    private var pairsFileURL: URL {
        dataDirectory.appendingPathComponent("pairs.json")
    }

    // MARK: - Initialization

    init(dataDirectory: URL? = nil) {
        // Use provided directory, or fall back to environment variable, or current directory
        let resolvedDirectory: URL
        if let dir = dataDirectory {
            resolvedDirectory = dir
        } else if let envPath = ProcessInfo.processInfo.environment["DATA_DIRECTORY"] {
            resolvedDirectory = URL(fileURLWithPath: envPath)
        } else {
            resolvedDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        self.dataDirectory = resolvedDirectory

        // Compute file URL before actor isolation kicks in
        let fileURL = resolvedDirectory.appendingPathComponent("pairs.json")

        // Load pairs synchronously during init
        self.activePairs = Self.loadPairsSync(from: fileURL, logger: logger)
    }

    /// Synchronous load for use during init (actors can't call async in init)
    private static func loadPairsSync(from url: URL, logger: Logger) -> [String: Pair] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.info("No existing pairs file found at \(url.path)")
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            let pairs = try JSONDecoder().decode([String: Pair].self, from: data)
            logger.info("Loaded \(pairs.count) pairs from disk")
            return pairs
        } catch {
            logger.error("Failed to load pairs: \(error.localizedDescription)")
            return [:]
        }
    }

    // MARK: - Public API

    /// Register a new pairing code from host
    func registerCode(
        code: String,
        deviceId: String,
        deviceName: String,
        username: String,
        publicKey: String,
        publicKeyId: String
    ) -> PairingResponse {
        // Clean up expired codes first
        cleanupExpiredCodes()

        // Check if code is already in use
        if pendingCodes[code] != nil {
            return .error("Pairing code already in use")
        }

        // Generate the pairId upfront so host and viewer use the same ID
        let pairId = UUID().uuidString

        let pending = PendingPairing(
            code: code,
            pairId: pairId,
            hostDeviceId: deviceId,
            hostDeviceName: deviceName,
            hostUsername: username,
            hostPublicKey: publicKey,
            hostPublicKeyId: publicKeyId,
            createdAt: Date()
        )

        pendingCodes[code] = pending

        // Host doesn't get partner key yet (viewer hasn't paired)
        return .registered(pairId: pairId)
    }

    /// Complete pairing from viewer side
    func completePairing(
        code: String,
        deviceId: String,
        deviceName: String,
        publicKey: String,
        publicKeyId: String
    ) -> PairingResponse {
        // Clean up expired codes first
        cleanupExpiredCodes()

        guard let pending = pendingCodes[code] else {
            return .error("Invalid or expired pairing code")
        }

        // Create the pair using the pairId from registration
        let pair = Pair(
            id: pending.pairId,
            hostDeviceId: pending.hostDeviceId,
            hostDeviceName: pending.hostDeviceName,
            hostUsername: pending.hostUsername,
            hostPublicKey: pending.hostPublicKey,
            hostPublicKeyId: pending.hostPublicKeyId,
            viewerDeviceId: deviceId,
            viewerDeviceName: deviceName,
            viewerPublicKey: publicKey,
            viewerPublicKeyId: publicKeyId,
            createdAt: Date()
        )

        activePairs[pending.pairId] = pair
        pendingCodes.removeValue(forKey: code)
        savePairs()

        // Viewer gets host's public key in response
        return .paired(
            pairId: pending.pairId,
            partnerDeviceName: pending.hostDeviceName,
            partnerPublicKey: pending.hostPublicKey,
            partnerPublicKeyId: pending.hostPublicKeyId,
            partnerUsername: pending.hostUsername
        )
    }

    /// Check if a pair ID is valid
    func isValidPair(pairId: String) -> Bool {
        // Check active pairs first
        if activePairs[pairId] != nil {
            return true
        }

        // Also accept pending pairings (Mac registered but iOS hasn't completed yet)
        return pendingCodes.values.contains { $0.pairId == pairId }
    }

    /// Number of active pairs (for E2E test inspection)
    var activePairCount: Int {
        activePairs.count
    }

    /// IDs of all active pairs (for E2E test inspection)
    var activePairIds: [String] {
        Array(activePairs.keys)
    }

    /// Get pair information
    func getPair(pairId: String) -> Pair? {
        activePairs[pairId]
    }

    /// Clear all state (for testing)
    func resetState() {
        pendingCodes.removeAll()
        activePairs.removeAll()
    }

    /// Remove a pair
    func removePair(pairId: String) {
        activePairs.removeValue(forKey: pairId)
        savePairs()
    }

    /// Get host device name for a pair
    func getHostDeviceName(pairId: String) -> String? {
        activePairs[pairId]?.hostDeviceName
    }

    /// Get host username for a pair
    func getHostUsername(pairId: String) -> String {
        activePairs[pairId]?.hostUsername ?? ""
    }

    /// Get viewer device name for a pair
    func getViewerDeviceName(pairId: String) -> String? {
        activePairs[pairId]?.viewerDeviceName
    }

    /// Get host public key info for a pair
    func getHostPublicKey(pairId: String) -> (key: String, keyId: String)? {
        guard let pair = activePairs[pairId] else { return nil }
        return (pair.hostPublicKey, pair.hostPublicKeyId)
    }

    /// Get viewer public key info for a pair
    func getViewerPublicKey(pairId: String) -> (key: String, keyId: String)? {
        guard let pair = activePairs[pairId] else { return nil }
        return (pair.viewerPublicKey, pair.viewerPublicKeyId)
    }

    /// Update host public key and username for a pair (called when host reconnects)
    func updateHostPublicKey(pairId: String, publicKey: String, publicKeyId: String, username: String) {
        guard var pair = activePairs[pairId] else { return }
        pair.hostPublicKey = publicKey
        pair.hostPublicKeyId = publicKeyId
        pair.hostUsername = username
        activePairs[pairId] = pair
        savePairs()
        logger.debug("Updated host public key for pair", metadata: ["pairId": "\(pairId)"])
    }

    /// Update viewer public key for a pair (called when viewer reconnects)
    func updateViewerPublicKey(pairId: String, publicKey: String, publicKeyId: String) {
        guard var pair = activePairs[pairId] else { return }
        pair.viewerPublicKey = publicKey
        pair.viewerPublicKeyId = publicKeyId
        activePairs[pairId] = pair
        savePairs()
        logger.debug("Updated viewer public key for pair", metadata: ["pairId": "\(pairId)"])
    }

    /// Update the host's device name for a pair (called when host reconnects).
    /// Lets the host change its display name without re-pairing.
    func updateHostDeviceName(pairId: String, deviceName: String) {
        guard var pair = activePairs[pairId], pair.hostDeviceName != deviceName else { return }
        pair.hostDeviceName = deviceName
        activePairs[pairId] = pair
        savePairs()
        logger.debug("Updated host device name for pair", metadata: [
            "pairId": "\(pairId)",
            "deviceName": "\(deviceName)",
        ])
    }

    /// Update the viewer's device name for a pair (called when viewer reconnects).
    /// Lets the user rename their iOS device and have hosts pick it up.
    func updateViewerDeviceName(pairId: String, deviceName: String) {
        guard var pair = activePairs[pairId], pair.viewerDeviceName != deviceName else { return }
        pair.viewerDeviceName = deviceName
        activePairs[pairId] = pair
        savePairs()
        logger.debug("Updated viewer device name for pair", metadata: [
            "pairId": "\(pairId)",
            "deviceName": "\(deviceName)",
        ])
    }

    // MARK: - Push Token Management

    /// Register a push token for a pair
    func registerPushToken(_ token: String, for pairId: String) {
        guard var pair = activePairs[pairId] else {
            logger.warning("Cannot register push token for unknown pair", metadata: ["pairId": "\(pairId)"])
            return
        }
        pair.pushToken = token
        activePairs[pairId] = pair
        savePairs()
        logger.info("Registered push token for pair", metadata: ["pairId": "\(pairId)"])
    }

    /// Get the push token for a pair
    func getPushToken(for pairId: String) -> String? {
        activePairs[pairId]?.pushToken
    }

    /// Remove the push token for a pair
    func removePushToken(for pairId: String) {
        guard var pair = activePairs[pairId] else { return }
        pair.pushToken = nil
        activePairs[pairId] = pair
        savePairs()
        logger.info("Removed push token for pair", metadata: ["pairId": "\(pairId)"])
    }

    /// Check if a pair has a registered push token
    func hasPushToken(for pairId: String) -> Bool {
        activePairs[pairId]?.pushToken != nil
    }

    /// All pairIds whose registered push token matches `token`. A single iOS
    /// device paired with multiple Macs surfaces here as multiple pairIds that
    /// share one APNs token — used to aggregate per-host badge counts into a
    /// single device-wide badge.
    func pairIds(withToken token: String) -> [String] {
        activePairs.compactMap { pairId, pair in
            pair.pushToken == token ? pairId : nil
        }
    }

    // MARK: - Private Helpers

    private func cleanupExpiredCodes() {
        let now = Date()
        pendingCodes = pendingCodes.filter { _, pending in
            now.timeIntervalSince(pending.createdAt) < codeExpirySeconds
        }
    }

    /// Save pairs to disk
    private func savePairs() {
        do {
            // Ensure directory exists
            try FileManager.default.createDirectory(
                at: dataDirectory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(activePairs)
            try data.write(to: pairsFileURL, options: .atomic)
            logger.debug("Saved \(activePairs.count) pairs to disk")
        } catch {
            logger.error("Failed to save pairs: \(error.localizedDescription)")
        }
    }
}

// MARK: - Supporting Types

/// A pending pairing waiting for viewer to complete
struct PendingPairing {
    let code: String
    let pairId: String
    let hostDeviceId: String
    let hostDeviceName: String
    let hostUsername: String
    let hostPublicKey: String
    let hostPublicKeyId: String
    let createdAt: Date
}
