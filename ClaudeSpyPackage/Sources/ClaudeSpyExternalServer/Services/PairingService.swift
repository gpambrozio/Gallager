import ClaudeSpyNetworking
import Foundation
import Logging

/// Manages device pairing codes and paired device records
actor PairingService {
    /// Pending pairing codes waiting for completion
    private var pendingCodes: [String: PendingPairing] = [:]

    /// Active paired devices
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

    /// Register a new pairing code from Mac
    func registerCode(
        code: String,
        deviceId: String,
        deviceName: String,
        publicKey: String,
        publicKeyId: String
    ) -> PairingResponse {
        // Clean up expired codes first
        cleanupExpiredCodes()

        // Check if code is already in use
        if pendingCodes[code] != nil {
            return .failure("Pairing code already in use")
        }

        // Generate the pairId upfront so Mac and iOS use the same ID
        let pairId = UUID().uuidString

        let pending = PendingPairing(
            code: code,
            pairId: pairId,
            macDeviceId: deviceId,
            macDeviceName: deviceName,
            macPublicKey: publicKey,
            macPublicKeyId: publicKeyId,
            createdAt: Date()
        )

        pendingCodes[code] = pending

        // Mac doesn't get partner key yet (iOS hasn't paired)
        return PairingResponse(success: true, pairId: pairId)
    }

    /// Complete pairing from iOS
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
            return .failure("Invalid or expired pairing code")
        }

        // Create the pair using the pairId from registration
        let pair = Pair(
            id: pending.pairId,
            macDeviceId: pending.macDeviceId,
            macDeviceName: pending.macDeviceName,
            macPublicKey: pending.macPublicKey,
            macPublicKeyId: pending.macPublicKeyId,
            iosDeviceId: deviceId,
            iosDeviceName: deviceName,
            iosPublicKey: publicKey,
            iosPublicKeyId: publicKeyId,
            createdAt: Date()
        )

        activePairs[pending.pairId] = pair
        pendingCodes.removeValue(forKey: code)
        savePairs()

        // iOS gets Mac's public key in response
        return .success(
            pairId: pending.pairId,
            partnerDeviceName: pending.macDeviceName,
            partnerPublicKey: pending.macPublicKey,
            partnerPublicKeyId: pending.macPublicKeyId
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

    /// Get pair information
    func getPair(pairId: String) -> Pair? {
        activePairs[pairId]
    }

    /// Remove a pair
    func removePair(pairId: String) {
        activePairs.removeValue(forKey: pairId)
        savePairs()
    }

    /// Get Mac device name for a pair
    func getMacDeviceName(pairId: String) -> String? {
        activePairs[pairId]?.macDeviceName
    }

    /// Get iOS device name for a pair
    func getIOSDeviceName(pairId: String) -> String? {
        activePairs[pairId]?.iosDeviceName
    }

    /// Get Mac public key info for a pair
    func getMacPublicKey(pairId: String) -> (key: String, keyId: String)? {
        guard let pair = activePairs[pairId] else { return nil }
        return (pair.macPublicKey, pair.macPublicKeyId)
    }

    /// Get iOS public key info for a pair
    func getIOSPublicKey(pairId: String) -> (key: String, keyId: String)? {
        guard let pair = activePairs[pairId] else { return nil }
        return (pair.iosPublicKey, pair.iosPublicKeyId)
    }

    /// Update Mac public key for a pair (called when Mac reconnects)
    func updateMacPublicKey(pairId: String, publicKey: String, publicKeyId: String) {
        guard var pair = activePairs[pairId] else { return }
        pair.macPublicKey = publicKey
        pair.macPublicKeyId = publicKeyId
        activePairs[pairId] = pair
        savePairs()
        logger.debug("Updated Mac public key for pair", metadata: ["pairId": "\(pairId)"])
    }

    /// Update iOS public key for a pair (called when iOS reconnects)
    func updateIOSPublicKey(pairId: String, publicKey: String, publicKeyId: String) {
        guard var pair = activePairs[pairId] else { return }
        pair.iosPublicKey = publicKey
        pair.iosPublicKeyId = publicKeyId
        activePairs[pairId] = pair
        savePairs()
        logger.debug("Updated iOS public key for pair", metadata: ["pairId": "\(pairId)"])
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

/// A pending pairing waiting for iOS to complete
struct PendingPairing {
    let code: String
    let pairId: String
    let macDeviceId: String
    let macDeviceName: String
    let macPublicKey: String
    let macPublicKeyId: String
    let createdAt: Date
}
