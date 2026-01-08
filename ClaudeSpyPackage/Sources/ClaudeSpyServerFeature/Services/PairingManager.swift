import ClaudeSpyCommon
import Foundation
import Logging

/// Manages device pairing between the Mac app and iOS app via the external server.
///
/// Handles pairing code generation, registration, and the overall pairing flow.
@Observable
@MainActor
final public class PairingManager {
    // MARK: - Pairing State

    /// Current state of the pairing process
    public enum State: Equatable, Sendable {
        case unpaired
        case generatingCode
        case waitingForPairing(code: String, expiresAt: Date)
        case paired(pairId: String, deviceName: String)
        case error(String)

        public var isPaired: Bool {
            if case .paired = self { return true }
            return false
        }

        public var isWaiting: Bool {
            if case .waitingForPairing = self { return true }
            return false
        }
    }

    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.pairing")

    /// Current pairing state
    public private(set) var state: State = .unpaired

    /// The app settings for storing pairing data
    private weak var settings: AppSettings?

    /// Task for polling pairing completion
    private var pollingTask: Task<Void, Never>?

    /// Code expiry duration in seconds (matches server)
    private let codeExpirySeconds: TimeInterval = 300

    // MARK: - Initialization

    public init(settings: AppSettings) {
        self.settings = settings

        // Restore state from settings
        if let pairId = settings.pairId {
            let deviceName = settings.pairedDeviceName ?? "iOS Device"
            self.state = .paired(pairId: pairId, deviceName: deviceName)
        }
    }

    // MARK: - Pairing Flow

    /// Generate a new pairing code and register it with the server
    public func generatePairingCode() async {
        guard let settings else {
            state = .error("Settings not available")
            return
        }

        state = .generatingCode

        // Generate a 6-character alphanumeric code
        let code = generateCode()
        let expiresAt = Date().addingTimeInterval(codeExpirySeconds)

        // Register with server
        do {
            let response = try await registerCode(
                code: code,
                deviceId: settings.deviceId,
                deviceName: Host.current().localizedName ?? "Mac"
            )

            if response.success, let pairId = response.pairId {
                // Code registered, now wait for iOS to complete pairing
                state = .waitingForPairing(code: code, expiresAt: expiresAt)

                // Start polling for pairing completion
                startPollingForCompletion(pairId: pairId)

                logger.info("Pairing code registered", metadata: ["code": "\(code)"])
            } else {
                state = .error(response.error ?? "Failed to register pairing code")
                logger.error("Failed to register pairing code: \(response.error ?? "unknown")")
            }
        } catch {
            state = .error("Network error: \(error.localizedDescription)")
            logger.error("Failed to register pairing code: \(error)")
        }
    }

    /// Cancel the current pairing attempt
    public func cancelPairing() {
        pollingTask?.cancel()
        pollingTask = nil
        state = .unpaired
        logger.info("Pairing cancelled")
    }

    /// Unpair from the current iOS device
    public func unpair() async {
        guard let settings, let pairId = settings.pairId else {
            return
        }

        pollingTask?.cancel()
        pollingTask = nil

        // Notify server (best effort, don't wait for response)
        Task {
            try? await deletePairing(pairId: pairId)
        }

        // Clear local state
        settings.clearPairing()
        state = .unpaired

        logger.info("Device unpaired")
    }

    // MARK: - Private Methods

    private func generateCode() -> String {
        // Generate 6-character letter-only code (uppercase, excludes confusing I and O)
        let characters = "ABCDEFGHJKLMNPQRSTUVWXYZ"
        return String((0..<6).map { _ in characters.randomElement()! })
    }

    private func registerCode(code: String, deviceId: String, deviceName: String) async throws -> PairingResponse {
        guard let settings else {
            throw PairingError.settingsNotAvailable
        }

        let serverURL = settings.externalServerURL
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")

        guard let url = URL(string: "\(serverURL)/api/pairing/register") else {
            throw PairingError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let registration = PairingRegistration(
            deviceId: deviceId,
            deviceName: deviceName,
            pairingCode: code
        )

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(registration)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PairingError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw PairingError.serverError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(PairingResponse.self, from: data)
    }

    private func checkPairingStatus(pairId: String) async throws -> PairingStatus {
        guard let settings else {
            throw PairingError.settingsNotAvailable
        }

        let serverURL = settings.externalServerURL
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")

        guard let url = URL(string: "\(serverURL)/api/pairing/\(pairId)/status") else {
            throw PairingError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PairingError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw PairingError.serverError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(PairingStatus.self, from: data)
    }

    private func deletePairing(pairId: String) async throws {
        guard let settings else { return }

        let serverURL = settings.externalServerURL
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")

        guard let url = URL(string: "\(serverURL)/api/pairing/\(pairId)") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        _ = try await URLSession.shared.data(for: request)
    }

    private func startPollingForCompletion(pairId: String) {
        pollingTask?.cancel()

        pollingTask = Task { [weak self] in
            guard let self else { return }

            // Poll every 2 seconds until paired or timeout
            while !Task.isCancelled {
                // Check if code has expired
                if case let .waitingForPairing(_, expiresAt) = self.state {
                    if Date() > expiresAt {
                        await MainActor.run {
                            self.state = .error("Pairing code expired")
                        }
                        break
                    }
                }

                do {
                    let status = try await checkPairingStatus(pairId: pairId)

                    if status.iosConnected {
                        // iOS has completed pairing!
                        await completePairing(pairId: pairId)
                        break
                    }
                } catch {
                    // Continue polling on transient errors
                    logger.debug("Polling error: \(error)")
                }

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func completePairing(pairId: String) async {
        guard let settings else { return }

        // Save to settings
        settings.pairId = pairId
        // We'll get the device name when they connect via WebSocket
        settings.pairedDeviceName = "iOS Device"

        state = .paired(pairId: pairId, deviceName: "iOS Device")

        pollingTask?.cancel()
        pollingTask = nil

        logger.info("Pairing completed", metadata: ["pairId": "\(pairId)"])
    }
}

// MARK: - Errors

enum PairingError: LocalizedError {
    case settingsNotAvailable
    case invalidURL
    case invalidResponse
    case serverError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .settingsNotAvailable:
            "Settings not available"
        case .invalidURL:
            "Invalid server URL"
        case .invalidResponse:
            "Invalid server response"
        case let .serverError(statusCode):
            "Server error (status \(statusCode))"
        }
    }
}
