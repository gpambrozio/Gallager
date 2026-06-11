import ClaudeSpyCommon
import ClaudeSpyEncryption
import Dependencies
import Foundation
import Logging

/// Manages device pairing between the host app and viewers via the external server.
///
/// Handles pairing code generation, registration, and the overall pairing flow.
/// Supports pairing with multiple viewers.
@Observable
@MainActor
final public class PairingManager {
    // MARK: - Pairing State

    /// Current state of the pairing process (for the active pairing operation)
    public enum State: Equatable, Sendable {
        case idle
        case generatingCode
        case waitingForPairing(code: String, expiresAt: Date)
        case error(String)

        public var isWaiting: Bool {
            if case .waitingForPairing = self { return true }
            return false
        }
    }

    // MARK: - Properties

    private let logger = Logger(label: "com.claudespy.pairing")

    /// Current pairing state (for adding new devices)
    public private(set) var state: State = .idle

    /// The app settings for storing pairing data
    private weak var settings: AppSettings?

    /// E2EE service for encryption key management
    private let e2eeService: E2EEService

    /// Task for polling pairing completion
    private var pollingTask: Task<Void, Never>?

    /// Code expiry duration in seconds (matches server)
    private let codeExpirySeconds: TimeInterval = 300

    /// Callback when a new viewer is successfully paired
    public var onViewerPaired: ((PairedViewer) -> Void)?

    /// This Mac's advertised device name (overridable in E2E for deterministic screenshots).
    @ObservationIgnored
    @Dependency(DeviceNameClient.self) private var deviceNameClient

    // MARK: - Initialization

    public init(settings: AppSettings, e2eeService: E2EEService) {
        self.settings = settings
        self.e2eeService = e2eeService
    }

    // MARK: - Public Properties

    /// Our public key info for E2EE
    public var publicKeyInfo: PublicKeyInfo {
        e2eeService.publicKeyInfo
    }

    /// All paired viewers (convenience accessor)
    public var pairedViewers: [PairedViewer] {
        settings?.pairedViewers ?? []
    }

    /// Whether at least one viewer is paired
    public var hasPairedViewers: Bool {
        settings?.isPaired ?? false
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
                deviceName: deviceNameClient.current()
            )

            switch response {
            case let .registered(info):
                // Code registered, now wait for iOS to complete pairing
                state = .waitingForPairing(code: code, expiresAt: expiresAt)

                // Start polling for pairing completion
                startPollingForCompletion(pairId: info.pairId)

                logger.info("Pairing code registered", metadata: ["code": "\(code)"])
            case .paired:
                // Unexpected - registration shouldn't return paired status
                state = .error("Unexpected response from server")
                logger.error("Unexpected paired response during registration")
            case let .error(errorInfo):
                state = .error(errorInfo.message)
                logger.error("Failed to register pairing code: \(errorInfo.message)")
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
        state = .idle
        logger.info("Pairing cancelled")
    }

    /// Unpair from a specific viewer
    public func unpair(deviceId: String) async {
        guard let settings else {
            return
        }

        // Notify server (best effort, don't wait for response)
        Task {
            try? await deletePairing(pairId: deviceId)
        }

        // Remove from local state
        // Note: E2EE session cleanup happens in ConnectedViewerManager when the connection is removed
        settings.removePairing(id: deviceId)

        logger.info("Viewer unpaired", metadata: ["deviceId": "\(deviceId)"])
    }

    /// Unpair from all viewers
    public func unpairAll() async {
        guard let settings else { return }

        pollingTask?.cancel()
        pollingTask = nil

        // Notify server for each viewer (best effort)
        for viewer in settings.pairedViewers {
            Task {
                try? await deletePairing(pairId: viewer.id)
            }
        }

        // Clear all local state
        // Note: E2EE session cleanup happens in ConnectedViewerManager when connections are removed
        settings.clearAllPairings()
        state = .idle

        logger.info("All viewers unpaired")
    }

    /// Update partner's public key info after receiving it via WebSocket.
    /// Called by ConnectedViewerManager when viewer connects and sends its key.
    public func updatePartnerPublicKey(deviceId: String, publicKey: String, publicKeyId: String) {
        guard let settings, var viewer = settings.getPairing(id: deviceId) else { return }

        viewer = PairedViewer(
            id: viewer.id,
            deviceName: viewer.deviceName,
            partnerPublicKey: publicKey,
            partnerPublicKeyId: publicKeyId,
            pairedAt: viewer.pairedAt,
            customName: viewer.customName
        )
        settings.updatePairing(viewer)
        logger.info("Partner public key updated for E2EE", metadata: ["deviceId": "\(deviceId)"])
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

        let serverURL = settings.externalServerURL.httpURL

        guard let url = URL(string: "\(serverURL)/api/pairing/register") else {
            throw PairingError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let registration = PairingRegistration(
            deviceId: deviceId,
            deviceName: deviceName,
            pairingCode: code,
            publicKey: e2eeService.publicKey.base64EncodedString(),
            publicKeyId: e2eeService.keyId,
            username: ProcessInfo.processInfo.userName
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

        let serverURL = settings.externalServerURL.httpURL

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

        let serverURL = settings.externalServerURL.httpURL

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

                    if status.viewerConnected {
                        // Viewer has completed pairing!
                        await completePairing(pairId: pairId, viewerDeviceName: status.viewerDeviceName)
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

    private func completePairing(pairId: String, viewerDeviceName: String?) async {
        guard let settings else { return }

        // Create new paired viewer without partner's public key.
        // The key will be received via WebSocket when both sides connect:
        // 1. Host registers → server responds with viewer public key in hostRegistered
        // 2. Viewer connects → server sends viewerConnected with viewer public key
        // Either path calls ConnectedViewer.establishE2EEWithPartner() and
        // persists the key via onPartnerKeyReceived → updatePartnerPublicKey().
        //
        // The device name comes from the server, which captured it when the
        // viewer called `/api/pairing/complete`. Falls back to "Viewer" only
        // when the server response somehow omitted it (older server, race).
        let viewer = PairedViewer(
            id: pairId,
            deviceName: viewerDeviceName ?? "Viewer",
            partnerPublicKey: "",
            partnerPublicKeyId: "",
            pairedAt: Date()
        )
        settings.addPairing(viewer)

        state = .idle

        pollingTask?.cancel()
        pollingTask = nil

        // Notify callback
        onViewerPaired?(viewer)

        logger.info("Pairing completed (partner key will be received via WebSocket)", metadata: ["pairId": "\(pairId)"])
    }

    /// Update the stored device name for a paired viewer.
    ///
    /// Called when a new viewer device name arrives over the WebSocket
    /// (`HostRegisteredMessage.viewerDeviceName` or `ViewerConnectedMessage.deviceName`)
    /// so renaming the device on iOS propagates to the macOS UI without re-pairing.
    public func updateViewerDeviceName(pairId: String, deviceName: String) {
        guard let settings, let viewer = settings.getPairing(id: pairId) else { return }
        guard viewer.deviceName != deviceName else { return }

        var updated = viewer
        updated.deviceName = deviceName
        settings.updatePairing(updated)
        logger.info("Updated paired viewer device name", metadata: [
            "pairId": "\(pairId)",
            "deviceName": "\(deviceName)",
        ])
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
