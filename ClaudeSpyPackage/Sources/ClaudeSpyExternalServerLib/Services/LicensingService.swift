import ClaudeSpyNetworking
import Foundation
import Logging

/// User-facing licensing failures, mapped to HTTP 400 by LicenseController.
enum LicensingError: Error, Equatable {
    case licensingDisabled
    case activationFailed(String)
    case wrongProduct

    var userMessage: String {
        switch self {
        case .licensingDisabled:
            "This relay does not require a license"
        case let .activationFailed(message):
            message
        case .wrongProduct:
            "This license key is not valid for this product"
        }
    }
}

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
                // Activation removed while we awaited (explicit deactivation) — the
                // device deliberately re-enters ordinary trial rules: deactivating
                // frees the LS slot and resets this device to as-new (status .none /
                // existing trial), matching the deactivate tests.
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
                // Mirror `checkEntitlement`'s grace math: a cached `.active`
                // verdict that's gone stale past `graceDays` (LS unreachable
                // across every revalidation attempt) is `.blocked(.graceExpired)`
                // there, so it must not read as `.active` here either — the Mac
                // app's License section would otherwise show "Active" past the
                // point the host is actually being rejected at connect time.
                let age = now().timeIntervalSince(activation.lastValidatedAt)
                if age > TimeInterval(config.graceDays) * 86_400 {
                    return LicenseStatus(state: .expired, expiresAt: activation.expiresAt)
                }
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

    // MARK: - Activation lifecycle

    func activate(licenseKey: String, deviceId: String, deviceName: String) async throws -> LicenseStatus {
        guard let config else { throw LicensingError.licensingDisabled }

        let response = try await apiClient.activate(licenseKey: licenseKey, instanceName: deviceName)
        guard response.activated == true else {
            Task { await metricsService?.incrementLicenseValidationFailures() }
            throw LicensingError.activationFailed(response.error ?? "Activation failed")
        }
        guard Self.matchesConfiguredProduct(response.meta, config: config) else {
            logger.warning("Rejected key from foreign store/product", metadata: [
                "storeId": "\(response.meta?.storeId.map(String.init) ?? "nil")",
                "productId": "\(response.meta?.productId.map(String.init) ?? "nil")",
            ])
            // Best-effort: LS already consumed an activation slot for this key —
            // release it so the user's real product key isn't left short.
            if let instanceId = response.instance?.id {
                _ = try? await apiClient.deactivate(licenseKey: licenseKey, instanceId: instanceId)
            }
            throw LicensingError.wrongProduct
        }
        guard let instanceId = response.instance?.id else {
            throw LicensingError.activationFailed("Activation response missing instance id")
        }

        state.activations[deviceId] = ActivationRecord(
            licenseKey: licenseKey,
            instanceId: instanceId,
            verdict: .active,
            lastValidatedAt: now(),
            expiresAt: LemonSqueezyAPIClient.parseLSDate(response.licenseKey?.expiresAt),
            activationLimit: response.licenseKey?.activationLimit,
            activationUsage: response.licenseKey?.activationUsage
        )
        saveState()
        logger.info("Activated license", metadata: ["deviceId": "\(deviceId)"])
        Task { await metricsService?.incrementLicenseActivations() }
        return status(deviceId: deviceId)
    }

    /// Frees one of the key's activation slots. Removes the local record even
    /// when LS errors so a user can always unstick a Mac; the slot leak (if
    /// any) is LS-side and recoverable via a fresh validate/deactivate cycle.
    func deactivate(deviceId: String) async {
        guard config != nil, let activation = state.activations[deviceId] else { return }
        do {
            _ = try await apiClient.deactivate(
                licenseKey: activation.licenseKey, instanceId: activation.instanceId
            )
        } catch {
            logger.warning("LS deactivate failed; removing local activation anyway: \(error)")
        }
        // Reentrancy: a concurrent activate() may have replaced the record while
        // we awaited — only remove the activation we actually deactivated.
        guard state.activations[deviceId]?.instanceId == activation.instanceId else { return }
        state.activations.removeValue(forKey: deviceId)
        saveState()
        logger.info("Deactivated license", metadata: ["deviceId": "\(deviceId)"])
        Task { await metricsService?.incrementLicenseDeactivations() }
    }

    private static func matchesConfiguredProduct(_ meta: LSMeta?, config: LicensingConfiguration) -> Bool {
        meta?.storeId == config.storeId && meta?.productId == config.productId
    }

    // MARK: - Revalidation

    /// Revalidates a cached verdict older than `revalidateHours` against LS.
    /// Network failures keep the previous verdict (grace is enforced by the
    /// caller from `lastValidatedAt`); hard LS answers update the verdict.
    ///
    /// Actor reentrancy note: the `await` on the API call can interleave with
    /// other checks for the same device — worst case is a duplicate validate
    /// call, never inconsistent state, because mutations happen after the
    /// await on the single actor executor.
    private func revalidateIfStale(deviceId: String, config: LicensingConfiguration) async {
        guard let activation = state.activations[deviceId] else { return }
        let age = now().timeIntervalSince(activation.lastValidatedAt)
        guard age > TimeInterval(config.revalidateHours) * 3_600 else { return }

        do {
            let response = try await apiClient.validate(
                licenseKey: activation.licenseKey, instanceId: activation.instanceId
            )
            guard var current = state.activations[deviceId] else { return }

            if !Self.matchesConfiguredProduct(response.meta, config: config) {
                current.verdict = .disabled
            } else if response.valid == true {
                current.verdict = .active
            } else if response.licenseKey?.status == "disabled" {
                current.verdict = .disabled
            } else {
                current.verdict = .expired
            }
            current.lastValidatedAt = now()
            current.expiresAt = LemonSqueezyAPIClient.parseLSDate(response.licenseKey?.expiresAt)
            current.activationLimit = response.licenseKey?.activationLimit
            current.activationUsage = response.licenseKey?.activationUsage
            state.activations[deviceId] = current
            saveState()
        } catch {
            Task { await metricsService?.incrementLicenseValidationFailures() }
            logger.warning("License revalidation failed (LS unreachable), keeping cached verdict: \(error)")
        }
    }

    // MARK: - Sweep

    /// Disconnects connected hosts whose entitlement lapsed mid-connection
    /// (connect-time checks only catch new connections). Sends the typed
    /// error to the host and `hostSubscriptionInactive` to its viewers before
    /// closing. Returns the affected pairIds.
    func sweepBlockedHosts(
        pairingService: PairingService,
        connectionHub: ConnectionHub
    ) async -> [String] {
        guard config != nil else { return [] }

        var blockedPairs: [String] = []
        for pairId in await pairingService.activePairIds {
            guard
                await connectionHub.isHostConnected(pairId: pairId),
                let pair = await pairingService.getPair(pairId: pairId) else { continue }

            let entitlement = await checkEntitlement(hostDeviceId: pair.hostDeviceId)
            guard !entitlement.isAllowed else { continue }

            blockedPairs.append(pairId)
            logger.info("Sweep disconnecting unentitled host", metadata: ["pairId": "\(pairId)"])
            Task { await metricsService?.incrementBlockedHostAttempts() }
            await connectionHub.send(.error(.subscriptionRequired()), to: pairId, deviceType: .host)
            await connectionHub.send(.hostSubscriptionInactive, to: pairId, deviceType: .viewer)
            await connectionHub.disconnect(pairId: pairId, deviceType: .host)
        }
        return blockedPairs
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
