#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyEncryption
    import ClaudeSpyNetworking
    import Foundation

    /// Manages pairing this Mac with other Mac hosts to view their sessions.
    ///
    /// This is the "viewer" side of Mac-to-Mac pairing. The Mac host generates
    /// a pairing code, and this Mac viewer enters it to establish the connection.
    @Observable
    @MainActor
    final public class HostPairingManager {
        // MARK: - Pairing State

        /// Current state of the pairing process
        public enum State: Equatable, Sendable {
            case idle
            case pairing
            case error(String)
        }

        // MARK: - Properties

        private let logger = Logger(label: "com.claudespy.hostpairing")

        /// Current pairing state
        public private(set) var state: State = .idle

        /// The app settings for storing pairing data
        private weak var settings: AppSettings?

        /// E2EE service for encryption key management
        private let e2eeService: E2EEService

        /// Callback when a new Mac host is successfully paired
        public var onHostPaired: ((PairedMacHost) -> Void)?

        // MARK: - Initialization

        public init(settings: AppSettings, e2eeService: E2EEService) {
            self.settings = settings
            self.e2eeService = e2eeService
        }

        // MARK: - Public Properties

        /// All paired Mac hosts (convenience accessor)
        public var pairedMacHosts: [PairedMacHost] {
            settings?.pairedMacHosts ?? []
        }

        /// Whether at least one Mac host is paired
        public var hasPairedMacHosts: Bool {
            settings?.hasPairedMacHosts ?? false
        }

        // MARK: - Pairing Flow

        /// Complete pairing by entering a code from a Mac host.
        ///
        /// - Parameter code: The 6-character pairing code displayed on the Mac host
        public func completePairing(code: String) async {
            guard let settings else {
                state = .error("Settings not available")
                return
            }

            state = .pairing

            do {
                let response = try await submitPairingCode(
                    code: code.uppercased(),
                    deviceId: settings.deviceId,
                    deviceName: Host.current().localizedName ?? "Mac"
                )

                switch response {
                case let .paired(info):
                    // Pairing successful - we received the Mac host's info
                    let host = PairedMacHost(
                        id: info.pairId,
                        macName: info.partnerDeviceName,
                        username: info.partnerUsername,
                        partnerPublicKey: info.partnerPublicKey,
                        partnerPublicKeyId: info.partnerPublicKeyId,
                        pairedAt: Date()
                    )

                    // Establish E2EE session with partner's public key
                    if !info.partnerPublicKey.isEmpty,
                       let partnerKeyData = Data(base64Encoded: info.partnerPublicKey) {
                        try await e2eeService.establishSession(
                            partnerPublicKey: partnerKeyData,
                            partnerKeyId: info.partnerPublicKeyId,
                            pairId: info.pairId
                        )
                    }

                    // Store the pairing
                    settings.addMacHostPairing(host)

                    state = .idle
                    onHostPaired?(host)

                    logger.info("Paired with Mac host: \(info.partnerDeviceName)")

                case .registered:
                    // The code was just registered, not completed yet
                    state = .error("Invalid pairing code")
                    logger.warning("Received registered status instead of paired")

                case let .error(errorInfo):
                    state = .error(errorInfo.message)
                    logger.error("Pairing failed: \(errorInfo.message)")
                }
            } catch {
                state = .error("Network error: \(error.localizedDescription)")
                logger.error("Pairing failed: \(error)")
            }
        }

        /// Unpair from a specific Mac host
        public func unpair(hostId: String) async {
            guard let settings else { return }

            // Notify server (best effort)
            Task {
                try? await deletePairing(pairId: hostId)
            }

            settings.removeMacHostPairing(id: hostId)
            logger.info("Mac host unpaired", metadata: ["hostId": "\(hostId)"])
        }

        /// Unpair from all Mac hosts
        public func unpairAll() async {
            guard let settings else { return }

            for host in settings.pairedMacHosts {
                Task {
                    try? await deletePairing(pairId: host.id)
                }
            }

            settings.clearAllMacHostPairings()
            state = .idle

            logger.info("All Mac hosts unpaired")
        }

        /// Clear any error state
        public func clearError() {
            if case .error = state {
                state = .idle
            }
        }

        // MARK: - Private Methods

        private func submitPairingCode(code: String, deviceId: String, deviceName: String) async throws -> PairingResponse {
            guard let settings else {
                throw HostPairingError.settingsNotAvailable
            }

            let serverURL = settings.externalServerURL
                .replacingOccurrences(of: "wss://", with: "https://")
                .replacingOccurrences(of: "ws://", with: "http://")

            guard let url = URL(string: "\(serverURL)/api/pairing/complete") else {
                throw HostPairingError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            // Use PairingCompletion - same as iOS
            let completion = PairingCompletion(
                pairingCode: code,
                deviceId: deviceId,
                deviceName: deviceName,
                publicKey: e2eeService.publicKey.base64EncodedString(),
                publicKeyId: e2eeService.keyId
            )

            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(completion)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw HostPairingError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw HostPairingError.serverError(statusCode: httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            return try decoder.decode(PairingResponse.self, from: data)
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
    }

    // MARK: - Errors

    enum HostPairingError: LocalizedError {
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
#endif
