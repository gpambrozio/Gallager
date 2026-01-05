import ClaudeSpyNetworking
import Foundation

/// Manages device pairing codes and paired device records
actor PairingService {
    /// Pending pairing codes waiting for completion
    private var pendingCodes: [String: PendingPairing] = [:]

    /// Active paired devices
    private var activePairs: [String: Pair] = [:]

    /// How long a pairing code remains valid (5 minutes)
    private let codeExpirySeconds: TimeInterval = 300

    // MARK: - Public API

    /// Register a new pairing code from Mac
    func registerCode(code: String, deviceId: String, deviceName: String) -> PairingResponse {
        // Clean up expired codes first
        cleanupExpiredCodes()

        // Check if code is already in use
        if pendingCodes[code] != nil {
            return .failure("Pairing code already in use")
        }

        let pending = PendingPairing(
            code: code,
            macDeviceId: deviceId,
            macDeviceName: deviceName,
            createdAt: Date()
        )

        pendingCodes[code] = pending

        return .success(pairId: code) // Use code as temporary pairId until pairing completes
    }

    /// Complete pairing from iOS
    func completePairing(code: String, deviceId: String, deviceName: String) -> PairingResponse {
        // Clean up expired codes first
        cleanupExpiredCodes()

        guard let pending = pendingCodes[code] else {
            return .failure("Invalid or expired pairing code")
        }

        // Create the pair
        let pairId = UUID().uuidString
        let pair = Pair(
            id: pairId,
            macDeviceId: pending.macDeviceId,
            macDeviceName: pending.macDeviceName,
            iosDeviceId: deviceId,
            iosDeviceName: deviceName,
            createdAt: Date()
        )

        activePairs[pairId] = pair
        pendingCodes.removeValue(forKey: code)

        return .success(pairId: pairId, partnerDeviceName: pending.macDeviceName)
    }

    /// Check if a pair ID is valid
    func isValidPair(pairId: String) -> Bool {
        // Also accept pending codes as valid for initial connection
        activePairs[pairId] != nil || pendingCodes[pairId] != nil
    }

    /// Get pair information
    func getPair(pairId: String) -> Pair? {
        activePairs[pairId]
    }

    /// Remove a pair
    func removePair(pairId: String) {
        activePairs.removeValue(forKey: pairId)
    }

    /// Get Mac device name for a pair
    func getMacDeviceName(pairId: String) -> String? {
        activePairs[pairId]?.macDeviceName
    }

    /// Get iOS device name for a pair
    func getIOSDeviceName(pairId: String) -> String? {
        activePairs[pairId]?.iosDeviceName
    }

    // MARK: - Private Helpers

    private func cleanupExpiredCodes() {
        let now = Date()
        pendingCodes = pendingCodes.filter { _, pending in
            now.timeIntervalSince(pending.createdAt) < codeExpirySeconds
        }
    }
}

// MARK: - Supporting Types

/// A pending pairing waiting for iOS to complete
struct PendingPairing {
    let code: String
    let macDeviceId: String
    let macDeviceName: String
    let createdAt: Date
}
