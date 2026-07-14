import ClaudeSpyNetworking
import Foundation
import Testing
@testable import ClaudeSpyExternalServerLib

/// Stub LS client: returns canned responses, records calls.
/// A `final class` with locked mutable state so tests can swap responses mid-test.
final class StubLicenseAPIClient: LicenseAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _activateResult: Result<LSLicenseResponse, Error>
    private var _validateResult: Result<LSLicenseResponse, Error>
    private var _deactivateResult: Result<LSDeactivateResponse, Error>
    private(set) var validateCallCount = 0
    private(set) var deactivateCallCount = 0

    init(
        activate: Result<LSLicenseResponse, Error> = .failure(DisabledLicenseAPIClient.LicensingDisabledError()),
        validate: Result<LSLicenseResponse, Error> = .failure(DisabledLicenseAPIClient.LicensingDisabledError()),
        deactivate: Result<LSDeactivateResponse, Error> = .success(LSDeactivateResponse(deactivated: true, error: nil))
    ) {
        self._activateResult = activate
        self._validateResult = validate
        self._deactivateResult = deactivate
    }

    func setValidate(_ result: Result<LSLicenseResponse, Error>) {
        lock.lock()
        defer { lock.unlock() }
        _validateResult = result
    }

    func activate(licenseKey: String, instanceName: String) async throws -> LSLicenseResponse {
        try lock.withLock { try _activateResult.get() }
    }

    func validate(licenseKey: String, instanceId: String) async throws -> LSLicenseResponse {
        try lock.withLock {
            validateCallCount += 1
            return try _validateResult.get()
        }
    }

    func deactivate(licenseKey: String, instanceId: String) async throws -> LSDeactivateResponse {
        try lock.withLock {
            deactivateCallCount += 1
            return try _deactivateResult.get()
        }
    }
}

/// Mutable clock for driving time forward in tests.
final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date
    init(_ value: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self._value = value }
    var value: Date {
        get { lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set { lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }

    func advance(bySeconds seconds: TimeInterval) { value = value.addingTimeInterval(seconds) }
}

enum LicensingTestSupport {
    static let config = LicensingConfiguration(
        storeId: 123, productId: 456,
        trialDays: 7, revalidateHours: 24, graceDays: 7,
        apiBaseURL: "http://unused.test"
    )

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudespy-licensing-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func activeResponse(
        storeId: Int = 123, productId: Int = 456,
        status: String = "active", expiresAt: String? = nil,
        activated: Bool? = nil, valid: Bool? = nil,
        instanceId: String = "inst-1", error: String? = nil
    ) -> LSLicenseResponse {
        LSLicenseResponse(
            activated: activated, valid: valid, error: error,
            licenseKey: LSLicenseKey(
                status: status, activationLimit: 3, activationUsage: 1, expiresAt: expiresAt
            ),
            instance: LSInstance(id: instanceId, name: "Test Mac"),
            meta: LSMeta(storeId: storeId, productId: productId)
        )
    }
}

@Suite("LicensingService core")
struct LicensingServiceCoreTests {
    @Test("Disabled config short-circuits to unrestricted, no trial recorded")
    func disabledIsUnrestricted() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = LicensingService(
            config: nil, apiClient: DisabledLicenseAPIClient(), dataDirectory: dir
        )
        let entitlement = await service.checkEntitlement(hostDeviceId: "host-1")
        #expect(entitlement == .unrestricted)
        #expect(await service.status(deviceId: "host-1") == LicenseStatus(state: .notRequired))
        // No licensing.json side effects when disabled
        let fileExists = FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("licensing.json").path
        )
        #expect(!fileExists)
    }

    @Test("First touch auto-starts a 7-day trial")
    func trialAutoStart() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestNow()
        let service = LicensingService(
            config: LicensingTestSupport.config, apiClient: StubLicenseAPIClient(),
            dataDirectory: dir, now: { clock.value }
        )

        let entitlement = await service.checkEntitlement(hostDeviceId: "host-1")
        let expectedExpiry = clock.value.addingTimeInterval(7 * 86_400)
        #expect(entitlement == .trial(expiresAt: expectedExpiry))
        #expect(entitlement.isAllowed)

        let status = await service.status(deviceId: "host-1")
        #expect(status.state == .trial)
        #expect(status.expiresAt == expectedExpiry)
    }

    @Test("Trial keeps its original start across repeated checks and expires")
    func trialExpires() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestNow()
        let service = LicensingService(
            config: LicensingTestSupport.config, apiClient: StubLicenseAPIClient(),
            dataDirectory: dir, now: { clock.value }
        )

        _ = await service.checkEntitlement(hostDeviceId: "host-1")
        clock.advance(bySeconds: 6 * 86_400)
        let stillTrial = await service.checkEntitlement(hostDeviceId: "host-1")
        guard case .trial = stillTrial else {
            Issue.record("Expected .trial at day 6, got \(stillTrial)")
            return
        }

        clock.advance(bySeconds: 2 * 86_400) // day 8
        let expired = await service.checkEntitlement(hostDeviceId: "host-1")
        #expect(expired == .blocked(reason: .trialExpired))
        #expect(!expired.isAllowed)
        #expect(await service.status(deviceId: "host-1").state == .expired)
    }

    @Test("status is read-only: it never starts a trial")
    func statusDoesNotStartTrial() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = LicensingService(
            config: LicensingTestSupport.config, apiClient: StubLicenseAPIClient(),
            dataDirectory: dir
        )
        #expect(await service.status(deviceId: "fresh-host") == LicenseStatus(state: .none))
        // Still .none afterwards — no trial was created by asking.
        #expect(await service.status(deviceId: "fresh-host") == LicenseStatus(state: .none))
    }

    @Test("Trials persist across service restarts")
    func trialPersistence() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestNow()

        let first = LicensingService(
            config: LicensingTestSupport.config, apiClient: StubLicenseAPIClient(),
            dataDirectory: dir, now: { clock.value }
        )
        let original = await first.checkEntitlement(hostDeviceId: "host-1")

        let second = LicensingService(
            config: LicensingTestSupport.config, apiClient: StubLicenseAPIClient(),
            dataDirectory: dir, now: { clock.value }
        )
        let reloaded = await second.checkEntitlement(hostDeviceId: "host-1")
        #expect(reloaded == original)
    }
}

@Suite("LicensingService activation and validation")
struct LicensingServiceActivationTests {
    @Test("Successful activation → licensed; status carries activation info")
    func activateSuccess() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubLicenseAPIClient(
            activate: .success(LicensingTestSupport.activeResponse(activated: true))
        )
        let service = LicensingService(
            config: LicensingTestSupport.config, apiClient: stub, dataDirectory: dir
        )

        let status = try await service.activate(
            licenseKey: "KEY-1", deviceId: "host-1", deviceName: "My Mac"
        )
        #expect(status.state == .active)
        #expect(status.activationLimit == 3)
        #expect(await service.checkEntitlement(hostDeviceId: "host-1") == .licensed)
    }

    @Test("Activation-limit failure surfaces LS's message")
    func activateLimitReached() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubLicenseAPIClient(
            activate: .success(LicensingTestSupport.activeResponse(
                activated: false, error: "This license key has reached the activation limit."
            ))
        )
        let service = LicensingService(
            config: LicensingTestSupport.config, apiClient: stub, dataDirectory: dir
        )

        await #expect(throws: LicensingError.activationFailed(
            "This license key has reached the activation limit."
        )) {
            try await service.activate(licenseKey: "KEY-1", deviceId: "host-1", deviceName: "My Mac")
        }
    }

    @Test("Foreign store/product keys are rejected")
    func activateWrongProduct() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubLicenseAPIClient(
            activate: .success(LicensingTestSupport.activeResponse(
                storeId: 999, productId: 888, activated: true
            ))
        )
        let service = LicensingService(
            config: LicensingTestSupport.config, apiClient: stub, dataDirectory: dir
        )

        await #expect(throws: LicensingError.wrongProduct) {
            try await service.activate(licenseKey: "KEY-1", deviceId: "host-1", deviceName: "My Mac")
        }
        // No activation recorded, and no trial burned by activation attempts.
        #expect(await service.status(deviceId: "host-1") == LicenseStatus(state: .none))
        // LS already consumed a slot for this key — it must be released.
        #expect(stub.deactivateCallCount == 1)
    }

    @Test("Stale verdicts revalidate after revalidateHours; fresh ones don't")
    func revalidationCadence() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestNow()
        let stub = StubLicenseAPIClient(
            activate: .success(LicensingTestSupport.activeResponse(activated: true)),
            validate: .success(LicensingTestSupport.activeResponse(valid: true))
        )
        let service = LicensingService(
            config: LicensingTestSupport.config, apiClient: stub,
            dataDirectory: dir, now: { clock.value }
        )
        _ = try await service.activate(licenseKey: "KEY-1", deviceId: "host-1", deviceName: "My Mac")

        _ = await service.checkEntitlement(hostDeviceId: "host-1")
        #expect(stub.validateCallCount == 0) // fresh — no validate call

        clock.advance(bySeconds: 25 * 3_600) // past 24h
        _ = await service.checkEntitlement(hostDeviceId: "host-1")
        #expect(stub.validateCallCount == 1)

        _ = await service.checkEntitlement(hostDeviceId: "host-1")
        #expect(stub.validateCallCount == 1) // fresh again after successful revalidation
    }

    @Test("Hard expired verdict blocks immediately")
    func expiredBlocksImmediately() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestNow()
        let stub = StubLicenseAPIClient(
            activate: .success(LicensingTestSupport.activeResponse(activated: true)),
            validate: .success(LicensingTestSupport.activeResponse(
                status: "expired", valid: false, error: "license_key expired"
            ))
        )
        let service = LicensingService(
            config: LicensingTestSupport.config, apiClient: stub,
            dataDirectory: dir, now: { clock.value }
        )
        _ = try await service.activate(licenseKey: "KEY-1", deviceId: "host-1", deviceName: "My Mac")

        clock.advance(bySeconds: 25 * 3_600)
        let entitlement = await service.checkEntitlement(hostDeviceId: "host-1")
        #expect(entitlement == .blocked(reason: .licenseExpired))
        // No trial fallback once a key was activated.
        #expect(await service.status(deviceId: "host-1").state == .expired)
    }

    @Test("LS unreachable keeps a valid key within grace, blocks after grace")
    func unreachableGrace() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestNow()
        struct NetworkDown: Error { }
        let stub = StubLicenseAPIClient(
            activate: .success(LicensingTestSupport.activeResponse(activated: true)),
            validate: .failure(NetworkDown())
        )
        let service = LicensingService(
            config: LicensingTestSupport.config, apiClient: stub,
            dataDirectory: dir, now: { clock.value }
        )
        _ = try await service.activate(licenseKey: "KEY-1", deviceId: "host-1", deviceName: "My Mac")

        clock.advance(bySeconds: 2 * 86_400) // day 2: stale, revalidation fails → still licensed
        #expect(await service.checkEntitlement(hostDeviceId: "host-1") == .licensed)

        clock.advance(bySeconds: 6 * 86_400) // day 8: past 7-day grace from lastValidatedAt
        let entitlement = await service.checkEntitlement(hostDeviceId: "host-1")
        #expect(entitlement == .blocked(reason: .graceExpired))
    }

    @Test("Disabled verdict from revalidation blocks with licenseDisabled")
    func disabledVerdict() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestNow()
        let stub = StubLicenseAPIClient(
            activate: .success(LicensingTestSupport.activeResponse(activated: true)),
            validate: .success(LicensingTestSupport.activeResponse(
                status: "disabled", valid: false, error: "license_key disabled"
            ))
        )
        let service = LicensingService(
            config: LicensingTestSupport.config, apiClient: stub,
            dataDirectory: dir, now: { clock.value }
        )
        _ = try await service.activate(licenseKey: "KEY-1", deviceId: "host-1", deviceName: "My Mac")

        clock.advance(bySeconds: 25 * 3_600)
        #expect(await service.checkEntitlement(hostDeviceId: "host-1")
            == .blocked(reason: .licenseDisabled))
    }

    @Test("Deactivate removes the activation locally even if LS errors")
    func deactivateAlwaysRemovesLocally() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        struct NetworkDown: Error { }
        let stub = StubLicenseAPIClient(
            activate: .success(LicensingTestSupport.activeResponse(activated: true)),
            deactivate: .failure(NetworkDown())
        )
        let service = LicensingService(
            config: LicensingTestSupport.config, apiClient: stub, dataDirectory: dir
        )
        _ = try await service.activate(licenseKey: "KEY-1", deviceId: "host-1", deviceName: "My Mac")

        await service.deactivate(deviceId: "host-1")
        #expect(await service.status(deviceId: "host-1") == LicenseStatus(state: .none))
    }

    @Test("Activations persist across restarts")
    func activationPersistence() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubLicenseAPIClient(
            activate: .success(LicensingTestSupport.activeResponse(activated: true))
        )
        let first = LicensingService(
            config: LicensingTestSupport.config, apiClient: stub, dataDirectory: dir
        )
        _ = try await first.activate(licenseKey: "KEY-1", deviceId: "host-1", deviceName: "My Mac")

        let second = LicensingService(
            config: LicensingTestSupport.config, apiClient: stub, dataDirectory: dir
        )
        #expect(await second.checkEntitlement(hostDeviceId: "host-1") == .licensed)
    }
}
