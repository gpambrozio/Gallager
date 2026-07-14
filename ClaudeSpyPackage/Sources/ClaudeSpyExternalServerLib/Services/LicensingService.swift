import ClaudeSpyNetworking
import Foundation
import Logging

/// Computes hosted-relay entitlements per host deviceId: auto-started trials,
/// Lemon Squeezy license activations with cached verdicts, and blocked states.
/// Follows the PairingService pattern: JSON file persistence under the data
/// directory, synchronous load in init.
///
/// When `config` is nil (self-hosted relays, E2E, local dev) every check
/// returns `.unrestricted` and nothing is ever written to disk.
actor LicensingService {
    enum BlockReason: Equatable, Sendable {
        case trialExpired
        case licenseExpired
        case licenseDisabled
        /// A previously-valid key could not be revalidated (LS unreachable)
        /// for longer than the grace window.
        case graceExpired
    }

    enum Entitlement: Equatable, Sendable {
        case unrestricted
        case trial(expiresAt: Date)
        case licensed
        case blocked(reason: BlockReason)

        var isAllowed: Bool {
            if case .blocked = self { return false }
            return true
        }
    }

    // MARK: - Persisted state

    struct TrialRecord: Codable {
        let startedAt: Date
    }

    enum LicenseVerdict: String, Codable {
        case active
        case expired
        case disabled
    }

    struct ActivationRecord: Codable {
        let licenseKey: String
        let instanceId: String
        var verdict: LicenseVerdict
        var lastValidatedAt: Date
        var expiresAt: Date?
        var activationLimit: Int?
        var activationUsage: Int?
    }

    struct LicensingState: Codable {
        var trials: [String: TrialRecord] = [:]
        var activations: [String: ActivationRecord] = [:]
    }

    // MARK: - Stored properties

    private let config: LicensingConfiguration?
    private let apiClient: any LicenseAPIClient
    private let metricsService: MetricsService?
    private let dataDirectory: URL
    private let now: @Sendable () -> Date
    private var state: LicensingState
    private let logger = Logger(label: "licensing-service")

    private var stateFileURL: URL {
        dataDirectory.appendingPathComponent("licensing.json")
    }

    // MARK: - Initialization

    init(
        config: LicensingConfiguration?,
        apiClient: any LicenseAPIClient,
        metricsService: MetricsService? = nil,
        dataDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.apiClient = apiClient
        self.metricsService = metricsService
        self.now = now

        let resolvedDirectory: URL
        if let dataDirectory {
            resolvedDirectory = dataDirectory
        } else if let envPath = ProcessInfo.processInfo.environment["DATA_DIRECTORY"] {
            resolvedDirectory = URL(fileURLWithPath: envPath)
        } else {
            resolvedDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        self.dataDirectory = resolvedDirectory

        let fileURL = resolvedDirectory.appendingPathComponent("licensing.json")
        self.state = Self.loadStateSync(from: fileURL, enabled: config != nil, logger: logger)
    }

    private static func loadStateSync(from url: URL, enabled: Bool, logger: Logger) -> LicensingState {
        guard enabled, FileManager.default.fileExists(atPath: url.path) else {
            return LicensingState()
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(LicensingState.self, from: data)
            logger.info("Loaded licensing state: \(state.trials.count) trials, \(state.activations.count) activations")
            return state
        } catch {
            logger.error("Failed to load licensing state: \(error.localizedDescription)")
            return LicensingState()
        }
    }

    // MARK: - Entitlement

    /// The single check both enforcement points use. Auto-starts a trial on
    /// first sight of a deviceId. Once a device has an activation there is no
    /// fallback to trial.
    func checkEntitlement(hostDeviceId: String) async -> Entitlement {
        guard let config else { return .unrestricted }

        if state.activations[hostDeviceId] != nil {
            await revalidateIfStale(deviceId: hostDeviceId, config: config)
            guard let activation = state.activations[hostDeviceId] else {
                // Deactivated while we awaited revalidation — treat as no license.
                return trialEntitlement(deviceId: hostDeviceId, config: config)
            }
            switch activation.verdict {
            case .active:
                let age = now().timeIntervalSince(activation.lastValidatedAt)
                if age > TimeInterval(config.graceDays) * 86_400 {
                    return .blocked(reason: .graceExpired)
                }
                return .licensed
            case .expired:
                return .blocked(reason: .licenseExpired)
            case .disabled:
                return .blocked(reason: .licenseDisabled)
            }
        }

        return trialEntitlement(deviceId: hostDeviceId, config: config)
    }

    private func trialEntitlement(deviceId: String, config: LicensingConfiguration) -> Entitlement {
        let trial: TrialRecord
        if let existing = state.trials[deviceId] {
            trial = existing
        } else {
            trial = TrialRecord(startedAt: now())
            state.trials[deviceId] = trial
            saveState()
            logger.info("Started trial", metadata: ["deviceId": "\(deviceId)"])
            Task { await metricsService?.incrementTrialStarts() }
        }
        let expiresAt = trial.startedAt.addingTimeInterval(TimeInterval(config.trialDays) * 86_400)
        return now() < expiresAt ? .trial(expiresAt: expiresAt) : .blocked(reason: .trialExpired)
    }

    /// Read-only billing status for the Mac app UI. Never starts a trial.
    func status(deviceId: String) -> LicenseStatus {
        guard let config else { return LicenseStatus(state: .notRequired) }

        if let activation = state.activations[deviceId] {
            switch activation.verdict {
            case .active:
                return LicenseStatus(
                    state: .active,
                    expiresAt: activation.expiresAt,
                    activationLimit: activation.activationLimit,
                    activationUsage: activation.activationUsage
                )
            case .expired,
                 .disabled:
                return LicenseStatus(state: .expired, expiresAt: activation.expiresAt)
            }
        }

        if let trial = state.trials[deviceId] {
            let expiresAt = trial.startedAt.addingTimeInterval(TimeInterval(config.trialDays) * 86_400)
            let state: LicenseStatus.State = now() < expiresAt ? .trial : .expired
            return LicenseStatus(state: state, expiresAt: expiresAt)
        }

        return LicenseStatus(state: .none)
    }

    /// Clear all licensing state (for tests/E2E).
    func resetState() {
        state = LicensingState()
        try? FileManager.default.removeItem(at: stateFileURL)
    }

    // MARK: - Revalidation (implemented in Task 6)

    private func revalidateIfStale(deviceId: String, config: LicensingConfiguration) async {
        // Task 6 fills this in. Until then, cached verdicts are used as-is.
    }

    // MARK: - Persistence

    private func saveState() {
        do {
            try FileManager.default.createDirectory(
                at: dataDirectory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            logger.error("Failed to save licensing state: \(error.localizedDescription)")
        }
    }
}
