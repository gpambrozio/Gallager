# Hosted Relay Monetization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate hosted-relay use for host Macs behind a Lemon Squeezy subscription ($5/mo / $50/yr, 3 activations, 7-day relay-side trial), leaving viewers, self-hosting, and everything else free.

**Architecture:** A new `LicensingService` actor on the Vapor relay validates license keys against Lemon Squeezy's public License API with cached verdicts (24h revalidation, 7-day unreachable-grace), auto-starts 7-day trials keyed by host deviceId, and persists to `licensing.json` beside `pairs.json`. Two enforcement points (pairing registration + host WebSocket connect) plus a daily sweep. Licensing is entirely disabled unless `LEMONSQUEEZY_STORE_ID` + `LEMONSQUEEZY_PRODUCT_ID` are set — self-hosting and E2E are provably unchanged. The Mac app gets a License section in Remote Access settings (activate/deactivate/buy/manage) and 48h/24h trial-expiry notifications; the iOS/Mac viewers get a one-line "Host's subscription expired" row.

**Tech Stack:** Swift 6.3, Vapor 4 (relay), AsyncHTTPClient (LS calls), Swift Testing, Point-Free Dependencies (Mac app), SwiftUI, UserNotifications.

**Spec:** `docs/superpowers/specs/2026-07-13-hosted-relay-monetization-design.md` (issue #392). Branch: `monetization-392`.

## Global Constraints

- Licensing MUST be a no-op when `LEMONSQUEEZY_STORE_ID`/`LEMONSQUEEZY_PRODUCT_ID` are unset/empty; exactly one set (or non-integer) → throw at boot (fail-loud, like `METRICS_TOKEN`).
- Env defaults: `TRIAL_DAYS=7`, `LICENSE_REVALIDATE_HOURS=24`, `LICENSE_GRACE_DAYS=7`, `LEMONSQUEEZY_API_BASE=https://api.lemonsqueezy.com`.
- Every activate/validate response MUST verify `meta.store_id`/`meta.product_id` match configuration; mismatches are treated as invalid keys.
- Hard LS verdicts (`expired`/`disabled`) block immediately; LS-unreachable keeps a previously-valid key working for `LICENSE_GRACE_DAYS` from `lastValidatedAt`.
- Once a device has an activation, there is NO fallback to trial.
- Pairs are never deleted for entitlement reasons.
- Viewer connections are never gated. E2EE paths untouched.
- New wire fields are optional (`decodeIfPresent` via optional properties) for cross-version skew.
- All new cross-boundary types `Sendable`; actors for I/O; no GCD; `@MainActor` UI.
- SF Symbols only via `ClaudeSpyCommon/UI/Symbols.swift` (never string literals).
- Swift Testing (`@Test`, `#expect`), NOT XCTest. Build/test via XcodeBuildTools skills (`swift-package` skill for `swift test`).
- Run package tests with: `swift test --package-path ClaudeSpyPackage --filter <SuiteName>` (via the XcodeBuildTools `swift-package` skill).
- Commit after every green task; never `--no-verify`.

---

### Task 0: Lemon Squeezy store setup (MANUAL — requires the user)

No code. The user performs this in the Lemon Squeezy dashboard; later tasks consume its outputs. Can run in parallel with Tasks 1–9 but MUST be complete before Task 15 (needs real URLs) and before production enablement.

- [ ] **Step 1: Create store + product.** One subscription product ("Gallager Remote Access"), two variants: $5/month, $50/year.
- [ ] **Step 2: Enable license keys** on the product: activation limit **3**, key expires with subscription.
- [ ] **Step 3: Create capped 100%-off-forever discount codes** for early testers (limit redemptions per code).
- [ ] **Step 4: Test-mode dry run.** Test-card purchase → key email arrives → key visible in dashboard → cancel → key expires. Verify a 100%-off subscription checkout skips card entry and still creates subscription + key.
- [ ] **Step 5: Record outputs** in the team notes / `.env` on the relay host (NOT in git): numeric `LEMONSQUEEZY_STORE_ID`, numeric `LEMONSQUEEZY_PRODUCT_ID`, hosted-checkout URL (`https://<store>.lemonsqueezy.com/buy/<variant-uuid>`), customer-portal URL (`https://<store>.lemonsqueezy.com/billing`).

---

### Task 1: Networking — `LicenseStatus` + `LicenseActivationRequest` models

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/LicenseModels.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/LicenseModelsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `LicenseStatus` (struct: `state: LicenseStatus.State` [`none|trial|active|expired|notRequired`], `expiresAt: Date?`, `activationLimit: Int?`, `activationUsage: Int?`), `LicenseActivationRequest` (struct: `licenseKey`, `deviceId`, `deviceName`, all `String`). Used by relay (Tasks 6–8) and Mac app (Tasks 12–15).

- [ ] **Step 1: Write the failing tests**

```swift
// ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/LicenseModelsTests.swift
import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("License models")
struct LicenseModelsTests {
    @Test("LicenseStatus round-trips through ISO8601 JSON")
    func statusRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let status = LicenseStatus(
            state: .trial,
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            activationLimit: 3,
            activationUsage: 1
        )
        let decoded = try decoder.decode(LicenseStatus.self, from: encoder.encode(status))
        #expect(decoded == status)
    }

    @Test("LicenseStatus decodes with only state present (cross-version skew)")
    func statusMinimalDecode() throws {
        let json = Data(#"{"state":"active"}"#.utf8)
        let decoded = try JSONDecoder().decode(LicenseStatus.self, from: json)
        #expect(decoded.state == .active)
        #expect(decoded.expiresAt == nil)
        #expect(decoded.activationLimit == nil)
    }

    @Test("LicenseActivationRequest round-trips")
    func activationRequestRoundTrip() throws {
        let request = LicenseActivationRequest(
            licenseKey: "ABCD-1234", deviceId: "dev-1", deviceName: "My Mac"
        )
        let decoded = try JSONDecoder().decode(
            LicenseActivationRequest.self, from: JSONEncoder().encode(request)
        )
        #expect(decoded.licenseKey == "ABCD-1234")
        #expect(decoded.deviceId == "dev-1")
        #expect(decoded.deviceName == "My Mac")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter LicenseModelsTests`
Expected: FAIL — `cannot find 'LicenseStatus' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/LicenseModels.swift
import Foundation

/// Request body for `POST /api/license/activate` on the relay.
public struct LicenseActivationRequest: Codable, Sendable {
    public let licenseKey: String
    public let deviceId: String
    public let deviceName: String

    public init(licenseKey: String, deviceId: String, deviceName: String) {
        self.licenseKey = licenseKey
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}

/// Billing state for one host device, returned by the relay's license endpoints.
public struct LicenseStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Device has never started a trial and has no license.
        case none
        /// In the free trial window; `expiresAt` is the trial end.
        case trial
        /// Active license key; `expiresAt` is the subscription expiry when known.
        case active
        /// Trial over or license lapsed/disabled.
        case expired
        /// This relay has licensing disabled (self-hosted); no subscription needed.
        case notRequired
    }

    public let state: State
    public let expiresAt: Date?
    public let activationLimit: Int?
    public let activationUsage: Int?

    public init(
        state: State,
        expiresAt: Date? = nil,
        activationLimit: Int? = nil,
        activationUsage: Int? = nil
    ) {
        self.state = state
        self.expiresAt = expiresAt
        self.activationLimit = activationLimit
        self.activationUsage = activationUsage
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ClaudeSpyPackage --filter LicenseModelsTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/LicenseModels.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/LicenseModelsTests.swift
git commit -m "Add LicenseStatus and LicenseActivationRequest wire models (#392)"
```

---

### Task 2: Networking — typed license errors + `hostSubscriptionInactive` WS message

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/WebSocketMessage.swift` (enum case + `ErrorMessage` factory; the enum's five exhaustive switches — `WebSocketMessage` cases near line 66, `MessageType` near line 184, `init(from:)` near line 243, `encode(to:)` near line 322, `messageType` near line 374 — the compiler flags every spot)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/PairingModels.swift:131-137` (`ErrorInfo`)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/LicenseModelsTests.swift` (extend)

**Interfaces:**
- Consumes: existing `ErrorMessage`, `ErrorInfo`, `WebSocketMessage`.
- Produces: `ErrorMessage.subscriptionRequiredCode: String` (= `"SUBSCRIPTION_REQUIRED"`), `ErrorMessage.subscriptionRequired() -> ErrorMessage` (recoverable: false), `WebSocketMessage.hostSubscriptionInactive` (payload-less case), `ErrorInfo.code: String?` with `init(message: String, code: String? = nil)`. Used by Tasks 8, 9, 15, 16.

- [ ] **Step 1: Write the failing tests** (append to `LicenseModelsTests.swift`)

```swift
    @Test("subscriptionRequired error factory is non-recoverable with stable code")
    func subscriptionRequiredFactory() {
        let error = ErrorMessage.subscriptionRequired()
        #expect(error.code == ErrorMessage.subscriptionRequiredCode)
        #expect(error.code == "SUBSCRIPTION_REQUIRED")
        #expect(error.recoverable == false)
    }

    @Test("hostSubscriptionInactive round-trips over the wire")
    func hostSubscriptionInactiveRoundTrip() throws {
        let data = try JSONEncoder().encode(WebSocketMessage.hostSubscriptionInactive)
        let decoded = try JSONDecoder().decode(WebSocketMessage.self, from: data)
        guard case .hostSubscriptionInactive = decoded else {
            Issue.record("Expected .hostSubscriptionInactive, got \(decoded)")
            return
        }
    }

    @Test("ErrorInfo decodes legacy payloads without a code")
    func errorInfoLegacyDecode() throws {
        let json = Data(#"{"message":"boom"}"#.utf8)
        let decoded = try JSONDecoder().decode(ErrorInfo.self, from: json)
        #expect(decoded.message == "boom")
        #expect(decoded.code == nil)
    }

    @Test("ErrorInfo round-trips a code")
    func errorInfoCodeRoundTrip() throws {
        let info = ErrorInfo(message: "sub required", code: ErrorMessage.subscriptionRequiredCode)
        let decoded = try JSONDecoder().decode(ErrorInfo.self, from: JSONEncoder().encode(info))
        #expect(decoded == info)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter LicenseModelsTests`
Expected: FAIL — `type 'ErrorMessage' has no member 'subscriptionRequired'`.

- [ ] **Step 3: Implement**

In `WebSocketMessage.swift`, add to `ErrorMessage` (below `invalidPair()`, near line 150):

```swift
    /// Error code sent to a host whose trial/subscription no longer allows
    /// use of the hosted relay.
    public static let subscriptionRequiredCode = "SUBSCRIPTION_REQUIRED"

    public static func subscriptionRequired() -> ErrorMessage {
        ErrorMessage(
            code: subscriptionRequiredCode,
            message: "An active subscription is required to use the hosted relay",
            recoverable: false
        )
    }
```

Add the enum case (in the `// MARK: - Server → Viewer` block, after `case hostDisconnected`):

```swift
    /// Server notifies viewers that their host is blocked from the hosted
    /// relay for lack of an active subscription (trial expired or license
    /// lapsed). Carries no session content.
    case hostSubscriptionInactive
```

Then let the compiler drive the four remaining switches (all exhaustive, no `default`):
- `MessageType`: add `case hostSubscriptionInactive`
- `init(from:)`: `case .hostSubscriptionInactive: self = .hostSubscriptionInactive`
- `encode(to:)`: `case .hostSubscriptionInactive: try container.encode(MessageType.hostSubscriptionInactive, forKey: .type)` (mirror `.hostDisconnected` exactly)
- `messageType` property: mirror `.hostDisconnected`

In `PairingModels.swift`, replace `ErrorInfo`:

```swift
/// Error info for failed pairing operations
public struct ErrorInfo: Codable, Sendable, Equatable {
    public let message: String
    /// Optional machine-readable code (e.g. `ErrorMessage.subscriptionRequiredCode`).
    /// Absent from older peers — synthesized Codable decodes a missing key as nil.
    public let code: String?

    public init(message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }
}
```

- [ ] **Step 4: Build the whole package and run the networking tests**

Run: `swift build --package-path ClaudeSpyPackage` then `swift test --package-path ClaudeSpyPackage --filter LicenseModelsTests`
Expected: build succeeds (compiler-forced switch updates complete), 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/WebSocketMessage.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/PairingModels.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/LicenseModelsTests.swift
git commit -m "Add subscriptionRequired error code and hostSubscriptionInactive message (#392)"
```

---

### Task 3: Relay — `LicensingConfiguration` env parsing

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LicensingConfiguration.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicensingConfigurationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `LicensingConfiguration` (struct: `storeId: Int`, `productId: Int`, `trialDays: Int`, `revalidateHours: Int`, `graceDays: Int`, `apiBaseURL: String`) with `static func fromEnvironment(_ env: [String: String]) throws -> LicensingConfiguration?` and `enum LicensingConfigurationError: Error, CustomStringConvertible`. Used by Tasks 5–7.

- [ ] **Step 1: Write the failing tests**

```swift
// ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicensingConfigurationTests.swift
import Testing
@testable import ClaudeSpyExternalServerLib

@Suite("LicensingConfiguration")
struct LicensingConfigurationTests {
    @Test("Both unset → nil (licensing disabled)")
    func bothUnset() throws {
        #expect(try LicensingConfiguration.fromEnvironment([:]) == nil)
    }

    @Test("Empty strings count as unset")
    func emptyStrings() throws {
        let env = ["LEMONSQUEEZY_STORE_ID": "", "LEMONSQUEEZY_PRODUCT_ID": " "]
        #expect(try LicensingConfiguration.fromEnvironment(env) == nil)
    }

    @Test("Both set → config with defaults")
    func bothSet() throws {
        let env = ["LEMONSQUEEZY_STORE_ID": "123", "LEMONSQUEEZY_PRODUCT_ID": "456"]
        let config = try #require(try LicensingConfiguration.fromEnvironment(env))
        #expect(config.storeId == 123)
        #expect(config.productId == 456)
        #expect(config.trialDays == 7)
        #expect(config.revalidateHours == 24)
        #expect(config.graceDays == 7)
        #expect(config.apiBaseURL == "https://api.lemonsqueezy.com")
    }

    @Test("Overrides are honored")
    func overrides() throws {
        let env = [
            "LEMONSQUEEZY_STORE_ID": "123", "LEMONSQUEEZY_PRODUCT_ID": "456",
            "TRIAL_DAYS": "14", "LICENSE_REVALIDATE_HOURS": "6",
            "LICENSE_GRACE_DAYS": "3", "LEMONSQUEEZY_API_BASE": "http://127.0.0.1:9999",
        ]
        let config = try #require(try LicensingConfiguration.fromEnvironment(env))
        #expect(config.trialDays == 14)
        #expect(config.revalidateHours == 6)
        #expect(config.graceDays == 3)
        #expect(config.apiBaseURL == "http://127.0.0.1:9999")
    }

    @Test("Half-set throws (fail-loud at boot)")
    func halfSetThrows() {
        #expect(throws: LicensingConfigurationError.self) {
            try LicensingConfiguration.fromEnvironment(["LEMONSQUEEZY_STORE_ID": "123"])
        }
    }

    @Test("Non-integer ids throw")
    func nonIntegerThrows() {
        #expect(throws: LicensingConfigurationError.self) {
            try LicensingConfiguration.fromEnvironment(
                ["LEMONSQUEEZY_STORE_ID": "abc", "LEMONSQUEEZY_PRODUCT_ID": "456"]
            )
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter LicensingConfigurationTests`
Expected: FAIL — `cannot find 'LicensingConfiguration' in scope`.

- [ ] **Step 3: Implement**

```swift
// ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LicensingConfiguration.swift
import Foundation

/// Thrown at boot for misconfigured licensing env — fail-loud rather than
/// silently running a production relay with enforcement half-configured.
enum LicensingConfigurationError: Error, CustomStringConvertible {
    case incomplete(String)

    var description: String {
        switch self {
        case let .incomplete(detail):
            "Licensing misconfigured: \(detail). Set BOTH LEMONSQUEEZY_STORE_ID and " +
                "LEMONSQUEEZY_PRODUCT_ID to integers, or neither."
        }
    }
}

/// Relay-side licensing configuration. `nil` from `fromEnvironment` means
/// licensing is disabled and every entitlement check short-circuits to allowed.
struct LicensingConfiguration: Sendable, Equatable {
    let storeId: Int
    let productId: Int
    let trialDays: Int
    let revalidateHours: Int
    let graceDays: Int
    let apiBaseURL: String

    static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LicensingConfiguration? {
        func trimmed(_ key: String) -> String? {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return raw
        }

        let storeRaw = trimmed("LEMONSQUEEZY_STORE_ID")
        let productRaw = trimmed("LEMONSQUEEZY_PRODUCT_ID")

        if storeRaw == nil, productRaw == nil { return nil }

        guard let storeRaw, let productRaw else {
            throw LicensingConfigurationError.incomplete("only one of the two ids is set")
        }
        guard let storeId = Int(storeRaw), let productId = Int(productRaw) else {
            throw LicensingConfigurationError.incomplete("ids must be integers")
        }

        return LicensingConfiguration(
            storeId: storeId,
            productId: productId,
            trialDays: trimmed("TRIAL_DAYS").flatMap(Int.init) ?? 7,
            revalidateHours: trimmed("LICENSE_REVALIDATE_HOURS").flatMap(Int.init) ?? 24,
            graceDays: trimmed("LICENSE_GRACE_DAYS").flatMap(Int.init) ?? 7,
            apiBaseURL: trimmed("LEMONSQUEEZY_API_BASE") ?? "https://api.lemonsqueezy.com"
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ClaudeSpyPackage --filter LicensingConfigurationTests`
Expected: 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LicensingConfiguration.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicensingConfigurationTests.swift
git commit -m "Add LicensingConfiguration env parsing for the relay (#392)"
```

---

### Task 4: Relay — Lemon Squeezy API client (protocol, DTOs, live implementation)

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LemonSqueezyAPIClient.swift`
- Modify: `ClaudeSpyPackage/Package.swift` (add `async-http-client` as a direct package + target dependency — it is already resolved transitively via Vapor at 1.30.2, so this adds no new pin)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LemonSqueezyAPIClientTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (all internal to `ClaudeSpyExternalServerLib`):
  - `protocol LicenseAPIClient: Sendable` with
    `func activate(licenseKey: String, instanceName: String) async throws -> LSLicenseResponse`,
    `func validate(licenseKey: String, instanceId: String) async throws -> LSLicenseResponse`,
    `func deactivate(licenseKey: String, instanceId: String) async throws -> LSDeactivateResponse`
  - `struct LSLicenseResponse` (`activated: Bool?`, `valid: Bool?`, `error: String?`, `licenseKey: LSLicenseKey?`, `instance: LSInstance?`, `meta: LSMeta?`)
  - `struct LSLicenseKey` (`status: String`, `activationLimit: Int?`, `activationUsage: Int?`, `expiresAt: String?`)
  - `struct LSInstance` (`id: String`, `name: String`), `struct LSMeta` (`storeId: Int?`, `productId: Int?`)
  - `struct LSDeactivateResponse` (`deactivated: Bool?`, `error: String?`)
  - `struct LemonSqueezyAPIClient: LicenseAPIClient` (live, `init(baseURL: String)`)
  - `LemonSqueezyAPIClient.parseLSDate(_ string: String?) -> Date?` and `static func formEncode(_ fields: [(String, String)]) -> String`
  - `struct DisabledLicenseAPIClient: LicenseAPIClient` — every method throws; used when licensing is disabled.
- Used by Tasks 5–7.

- [ ] **Step 1: Add the package dependency**

In `ClaudeSpyPackage/Package.swift`: add to the top-level `dependencies:` array (near the `vapor` entry):

```swift
.package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
```

and to the `ClaudeSpyExternalServerLib` target's `dependencies` (currently `.claudeSpyNetworking, .claudeSpyEncryption, .vapor, .vaporAPNS` at Package.swift:394-401):

```swift
.product(name: "AsyncHTTPClient", package: "async-http-client"),
```

Run: `swift build --package-path ClaudeSpyPackage --target ClaudeSpyExternalServerLib`
Expected: builds (no source changes yet). If SPM reports a resolution conflict, match the version already in `Package.resolved` (1.30.2).

- [ ] **Step 2: Write the failing tests**

```swift
// ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LemonSqueezyAPIClientTests.swift
import Foundation
import Testing
@testable import ClaudeSpyExternalServerLib

@Suite("LemonSqueezyAPIClient")
struct LemonSqueezyAPIClientTests {
    @Test("Decodes an activation success response")
    func decodeActivationSuccess() throws {
        let json = Data("""
        {
          "activated": true,
          "error": null,
          "license_key": {
            "id": 1, "status": "active", "key": "TEST-KEY",
            "activation_limit": 3, "activation_usage": 1,
            "created_at": "2026-07-13T10:00:00.000000Z",
            "expires_at": null
          },
          "instance": { "id": "inst-uuid-1", "name": "My Mac", "created_at": "2026-07-13T10:00:00.000000Z" },
          "meta": { "store_id": 123, "order_id": 9, "product_id": 456, "customer_id": 7 }
        }
        """.utf8)
        let response = try JSONDecoder().decode(LSLicenseResponse.self, from: json)
        #expect(response.activated == true)
        #expect(response.licenseKey?.status == "active")
        #expect(response.licenseKey?.activationLimit == 3)
        #expect(response.instance?.id == "inst-uuid-1")
        #expect(response.meta?.storeId == 123)
        #expect(response.meta?.productId == 456)
    }

    @Test("Decodes an activation-limit failure response")
    func decodeActivationLimit() throws {
        let json = Data("""
        {
          "activated": false,
          "error": "This license key has reached the activation limit.",
          "license_key": { "id": 1, "status": "active", "key": "TEST-KEY",
                           "activation_limit": 3, "activation_usage": 3, "expires_at": null },
          "meta": { "store_id": 123, "product_id": 456 }
        }
        """.utf8)
        let response = try JSONDecoder().decode(LSLicenseResponse.self, from: json)
        #expect(response.activated == false)
        #expect(response.error == "This license key has reached the activation limit.")
    }

    @Test("Decodes an expired validation response")
    func decodeExpiredValidation() throws {
        let json = Data("""
        {
          "valid": false,
          "error": "license_key expired",
          "license_key": { "id": 1, "status": "expired", "key": "TEST-KEY",
                           "activation_limit": 3, "activation_usage": 1,
                           "expires_at": "2026-08-13T10:00:00.000000Z" },
          "instance": { "id": "inst-uuid-1", "name": "My Mac" },
          "meta": { "store_id": 123, "product_id": 456 }
        }
        """.utf8)
        let response = try JSONDecoder().decode(LSLicenseResponse.self, from: json)
        #expect(response.valid == false)
        #expect(response.licenseKey?.status == "expired")
        #expect(response.licenseKey?.expiresAt == "2026-08-13T10:00:00.000000Z")
    }

    @Test("parseLSDate handles microsecond fractions and nil")
    func parseDates() {
        let parsed = LemonSqueezyAPIClient.parseLSDate("2026-08-13T10:00:00.000000Z")
        #expect(parsed != nil)
        let noFraction = LemonSqueezyAPIClient.parseLSDate("2026-08-13T10:00:00Z")
        #expect(parsed == noFraction)
        #expect(LemonSqueezyAPIClient.parseLSDate(nil) == nil)
        #expect(LemonSqueezyAPIClient.parseLSDate("garbage") == nil)
    }

    @Test("formEncode percent-encodes values")
    func formEncoding() {
        let encoded = LemonSqueezyAPIClient.formEncode([
            ("license_key", "AB+C 1"), ("instance_name", "Gustavo's Mac"),
        ])
        #expect(encoded == "license_key=AB%2BC%201&instance_name=Gustavo%27s%20Mac")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter LemonSqueezyAPIClientTests`
Expected: FAIL — `cannot find 'LSLicenseResponse' in scope`.

- [ ] **Step 4: Implement**

```swift
// ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LemonSqueezyAPIClient.swift
import AsyncHTTPClient
import Foundation
import NIOCore

// MARK: - Protocol

/// Abstraction over Lemon Squeezy's public License API
/// (https://docs.lemonsqueezy.com/api/license-api) so LicensingService tests
/// can stub responses. These endpoints are keyed by the license key itself —
/// no API secret is required or stored on the relay.
protocol LicenseAPIClient: Sendable {
    func activate(licenseKey: String, instanceName: String) async throws -> LSLicenseResponse
    func validate(licenseKey: String, instanceId: String) async throws -> LSLicenseResponse
    func deactivate(licenseKey: String, instanceId: String) async throws -> LSDeactivateResponse
}

/// Placeholder client used when licensing is disabled — LicensingService
/// short-circuits before ever calling it, so any call is a programmer error.
struct DisabledLicenseAPIClient: LicenseAPIClient {
    struct LicensingDisabledError: Error {}
    func activate(licenseKey: String, instanceName: String) async throws -> LSLicenseResponse {
        throw LicensingDisabledError()
    }
    func validate(licenseKey: String, instanceId: String) async throws -> LSLicenseResponse {
        throw LicensingDisabledError()
    }
    func deactivate(licenseKey: String, instanceId: String) async throws -> LSDeactivateResponse {
        throw LicensingDisabledError()
    }
}

// MARK: - Response DTOs (snake_case per LS docs)

struct LSLicenseResponse: Codable, Sendable {
    let activated: Bool?
    let valid: Bool?
    let error: String?
    let licenseKey: LSLicenseKey?
    let instance: LSInstance?
    let meta: LSMeta?

    enum CodingKeys: String, CodingKey {
        case activated, valid, error, instance, meta
        case licenseKey = "license_key"
    }
}

struct LSLicenseKey: Codable, Sendable {
    /// "inactive" | "active" | "expired" | "disabled"
    let status: String
    let activationLimit: Int?
    let activationUsage: Int?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case status
        case activationLimit = "activation_limit"
        case activationUsage = "activation_usage"
        case expiresAt = "expires_at"
    }
}

struct LSInstance: Codable, Sendable {
    let id: String
    let name: String
}

struct LSMeta: Codable, Sendable {
    let storeId: Int?
    let productId: Int?

    enum CodingKeys: String, CodingKey {
        case storeId = "store_id"
        case productId = "product_id"
    }
}

struct LSDeactivateResponse: Codable, Sendable {
    let deactivated: Bool?
    let error: String?
}

// MARK: - Live client

struct LemonSqueezyAPIClient: LicenseAPIClient {
    let baseURL: String

    func activate(licenseKey: String, instanceName: String) async throws -> LSLicenseResponse {
        try await send(path: "/v1/licenses/activate", fields: [
            ("license_key", licenseKey), ("instance_name", instanceName),
        ])
    }

    func validate(licenseKey: String, instanceId: String) async throws -> LSLicenseResponse {
        try await send(path: "/v1/licenses/validate", fields: [
            ("license_key", licenseKey), ("instance_id", instanceId),
        ])
    }

    func deactivate(licenseKey: String, instanceId: String) async throws -> LSDeactivateResponse {
        try await send(path: "/v1/licenses/deactivate", fields: [
            ("license_key", licenseKey), ("instance_id", instanceId),
        ])
    }

    /// POSTs form-encoded fields and decodes the JSON body regardless of HTTP
    /// status — LS returns 400/404 with the same JSON shape carrying `error`,
    /// which LicensingService maps to verdicts rather than treating as
    /// transport failure.
    private func send<Response: Decodable>(
        path: String, fields: [(String, String)]
    ) async throws -> Response {
        var request = HTTPClientRequest(url: baseURL + path)
        request.method = .POST
        request.headers.add(name: "Accept", value: "application/json")
        request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        request.body = .bytes(ByteBuffer(string: Self.formEncode(fields)))

        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(15))
        var body = try await response.body.collect(upTo: 1 << 20)
        let data = body.readData(length: body.readableBytes) ?? Data()
        return try JSONDecoder().decode(Response.self, from: data)
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }

    /// LS timestamps carry microsecond fractions ("2026-08-13T10:00:00.000000Z"),
    /// which ISO8601DateFormatter cannot parse — strip the fraction first.
    static func parseLSDate(_ string: String?) -> Date? {
        guard var value = string else { return nil }
        if let dot = value.firstIndex(of: ".") {
            let afterFraction = value[value.index(after: dot)...].drop(while: \.isNumber)
            value = String(value[..<dot]) + afterFraction
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path ClaudeSpyPackage --filter LemonSqueezyAPIClientTests`
Expected: 5 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Package.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LemonSqueezyAPIClient.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LemonSqueezyAPIClientTests.swift
git commit -m "Add Lemon Squeezy License API client to the relay (#392)"
```

---

### Task 5: Relay — `LicensingService` core (trials, persistence, disabled short-circuit)

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LicensingService.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicensingServiceTests.swift`

**Interfaces:**
- Consumes: `LicensingConfiguration` (Task 3), `LicenseAPIClient`/`LSLicenseResponse` (Task 4), `LicenseStatus` (Task 1), `MetricsService` (existing actor; counters added in Task 8).
- Produces:
  - `actor LicensingService` with `init(config: LicensingConfiguration?, apiClient: any LicenseAPIClient, metricsService: MetricsService? = nil, dataDirectory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() })` (dataDirectory resolution mirrors `PairingService.init` at PairingService.swift:35-52: explicit param → `DATA_DIRECTORY` env → cwd)
  - `func checkEntitlement(hostDeviceId: String) async -> Entitlement`
  - `func status(deviceId: String) -> LicenseStatus`
  - `func resetState()` (for tests/E2E)
  - `enum Entitlement: Equatable, Sendable { case unrestricted, trial(expiresAt: Date), licensed, blocked(reason: BlockReason); var isAllowed: Bool }`
  - `enum BlockReason: Equatable, Sendable { case trialExpired, licenseExpired, licenseDisabled, graceExpired }`
- Task 6 adds `activate`/`deactivate`/revalidation to this same actor. Tasks 7–9 consume it.

- [ ] **Step 1: Write the failing tests**

```swift
// ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicensingServiceTests.swift
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

    init(
        activate: Result<LSLicenseResponse, Error> = .failure(DisabledLicenseAPIClient.LicensingDisabledError()),
        validate: Result<LSLicenseResponse, Error> = .failure(DisabledLicenseAPIClient.LicensingDisabledError()),
        deactivate: Result<LSDeactivateResponse, Error> = .success(LSDeactivateResponse(deactivated: true, error: nil))
    ) {
        _activateResult = activate
        _validateResult = validate
        _deactivateResult = deactivate
    }

    func setValidate(_ result: Result<LSLicenseResponse, Error>) {
        lock.lock(); defer { lock.unlock() }
        _validateResult = result
    }

    func activate(licenseKey: String, instanceName: String) async throws -> LSLicenseResponse {
        lock.lock(); defer { lock.unlock() }
        return try _activateResult.get()
    }

    func validate(licenseKey: String, instanceId: String) async throws -> LSLicenseResponse {
        lock.lock(); defer { lock.unlock() }
        validateCallCount += 1
        return try _validateResult.get()
    }

    func deactivate(licenseKey: String, instanceId: String) async throws -> LSDeactivateResponse {
        lock.lock(); defer { lock.unlock() }
        return try _deactivateResult.get()
    }
}

/// Mutable clock for driving time forward in tests.
final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date
    init(_ value: Date = Date(timeIntervalSince1970: 1_800_000_000)) { _value = value }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter LicensingServiceCoreTests`
Expected: FAIL — `cannot find 'LicensingService' in scope`.

- [ ] **Step 3: Implement the actor (trial + persistence + disabled paths; license verdict paths land in Task 6)**

```swift
// ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LicensingService.swift
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
        case active, expired, disabled
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
            case .expired, .disabled:
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
```

Note: `MetricsService.incrementTrialStarts()` doesn't exist until Task 8 — for this task, add the single empty-bodied counter now to keep the build green:
in `MetricsService.swift`, next to `incrementPushNotifications()`:

```swift
    private(set) var trialStartsTotal = 0

    func incrementTrialStarts() {
        trialStartsTotal &+= 1
    }
```

(Task 8 adds the remaining counters and the Prometheus render lines for all of them.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ClaudeSpyPackage --filter LicensingServiceCoreTests`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LicensingService.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/MetricsService.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicensingServiceTests.swift
git commit -m "Add LicensingService with trial auto-start and persistence (#392)"
```

---

### Task 6: Relay — activation, revalidation, grace, deactivation

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LicensingService.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicensingServiceTests.swift` (new suite in same file)

**Interfaces:**
- Consumes: Task 5's actor + Task 4's `LicenseAPIClient`.
- Produces (on `LicensingService`):
  - `func activate(licenseKey: String, deviceId: String, deviceName: String) async throws -> LicenseStatus`
  - `func deactivate(deviceId: String) async`
  - `enum LicensingError: Error, Equatable { case licensingDisabled, activationFailed(String), wrongProduct; var userMessage: String }`
  - working `revalidateIfStale` (fills Task 5's stub)
- Used by Tasks 7–9.

- [ ] **Step 1: Write the failing tests** (append to `LicensingServiceTests.swift`)

```swift
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
        struct NetworkDown: Error {}
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
        struct NetworkDown: Error {}
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter LicensingServiceActivationTests`
Expected: FAIL — `value of type 'LicensingService' has no member 'activate'`.

- [ ] **Step 3: Implement**

Add to `LicensingService.swift` (file-level, below the actor or above it):

```swift
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
```

Add to the actor:

```swift
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
        state.activations.removeValue(forKey: deviceId)
        saveState()
        logger.info("Deactivated license", metadata: ["deviceId": "\(deviceId)"])
    }

    private static func matchesConfiguredProduct(_ meta: LSMeta?, config: LicensingConfiguration) -> Bool {
        meta?.storeId == config.storeId && meta?.productId == config.productId
    }
```

Replace the Task 5 `revalidateIfStale` stub:

```swift
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
```

Add the two metrics counters used above to `MetricsService.swift` (next to `incrementTrialStarts` from Task 5):

```swift
    private(set) var licenseActivationsTotal = 0
    private(set) var licenseValidationFailuresTotal = 0

    func incrementLicenseActivations() {
        licenseActivationsTotal &+= 1
    }

    func incrementLicenseValidationFailures() {
        licenseValidationFailuresTotal &+= 1
    }
```

- [ ] **Step 4: Run the full relay test suite**

Run: `swift test --package-path ClaudeSpyPackage --filter "LicensingService|LemonSqueezy|LicensingConfiguration"`
Expected: all licensing tests PASS (5 + 9 + 5 + 6).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LicensingService.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/MetricsService.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicensingServiceTests.swift
git commit -m "Add license activation, revalidation, grace, and deactivation (#392)"
```

---

### Task 7: Relay — `LicenseController` endpoints + configure wiring

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/LicenseController.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/configure.swift` (service creation, storage key, accessor, E2E reset helper)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/routes.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Extensions/VaporContentConformance.swift` (add `extension LicenseStatus: Content {}`, mirroring the existing conformances in that file)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicenseEndpointTests.swift`

**Interfaces:**
- Consumes: `LicensingService` (Tasks 5–6), `LicenseStatus`/`LicenseActivationRequest` (Task 1), `LicensingConfiguration.fromEnvironment` (Task 3), `LemonSqueezyAPIClient`/`DisabledLicenseAPIClient` (Task 4).
- Produces:
  - HTTP: `POST /api/license/activate` (body `LicenseActivationRequest` → `LicenseStatus`, 400 + `{"reason": …}` on `LicensingError`), `DELETE /api/license/activation?deviceId=x` → 204, `GET /api/license/status?deviceId=x` → `LicenseStatus`
  - `app.licensingService: LicensingService` accessor (fatalError if unconfigured, like `app.pairingService`)
  - `public func resetLicensingState() async` on `Application` (E2E helper, next to `resetPairingState`)
- Used by Tasks 8, 12, 17.

- [ ] **Step 1: Write the failing endpoint tests** (mirror `MetricsEndpointTests.withConfiguredApp`'s setenv + temp-dir + `.serialized` pattern exactly — env mutation races under parallel execution)

```swift
// ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicenseEndpointTests.swift
import ClaudeSpyNetworking
import Foundation
import Testing
import VaporTesting
@testable import ClaudeSpyExternalServerLib

/// Endpoint tests exercise only trial/status paths so no Lemon Squeezy stub
/// server is needed (activation flows are covered at the actor level in
/// LicensingServiceTests; the full loop is covered by the E2E scenario).
@Suite("License endpoints", .serialized)
struct LicenseEndpointTests {
    private func withLicensingApp(
        trialDays: String = "7",
        _ test: (Application) async throws -> Void
    ) async throws {
        setenv("LEMONSQUEEZY_STORE_ID", "123", 1)
        setenv("LEMONSQUEEZY_PRODUCT_ID", "456", 1)
        setenv("TRIAL_DAYS", trialDays, 1)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudespy-license-endpoint-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("DATA_DIRECTORY", tempDir.path, 1)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            unsetenv("DATA_DIRECTORY")
            unsetenv("LEMONSQUEEZY_STORE_ID")
            unsetenv("LEMONSQUEEZY_PRODUCT_ID")
            unsetenv("TRIAL_DAYS")
        }
        try await withApp(configure: configure, test)
    }

    @Test("GET /api/license/status returns none for a fresh device and starts no trial")
    func statusFreshDevice() async throws {
        try await withLicensingApp { app in
            try await app.testing().test(.GET, "api/license/status?deviceId=fresh-1") { res in
                #expect(res.status == .ok)
                let status = try res.content.decode(LicenseStatus.self)
                #expect(status.state == .none)
            }
            // Second read still .none — status must not auto-start trials.
            try await app.testing().test(.GET, "api/license/status?deviceId=fresh-1") { res in
                let status = try res.content.decode(LicenseStatus.self)
                #expect(status.state == .none)
            }
        }
    }

    @Test("GET /api/license/status returns notRequired when licensing is disabled")
    func statusDisabledRelay() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudespy-license-endpoint-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("DATA_DIRECTORY", tempDir.path, 1)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            unsetenv("DATA_DIRECTORY")
        }
        try await withApp(configure: configure) { app in
            try await app.testing().test(.GET, "api/license/status?deviceId=any") { res in
                #expect(res.status == .ok)
                let status = try res.content.decode(LicenseStatus.self)
                #expect(status.state == .notRequired)
            }
        }
    }

    @Test("Status endpoint requires deviceId")
    func statusMissingDeviceId() async throws {
        try await withLicensingApp { app in
            try await app.testing().test(.GET, "api/license/status") { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("DELETE /api/license/activation with no activation is a 204 no-op")
    func deactivateNoop() async throws {
        try await withLicensingApp { app in
            try await app.testing().test(.DELETE, "api/license/activation?deviceId=fresh-1") { res in
                #expect(res.status == .noContent)
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter LicenseEndpointTests`
Expected: FAIL — 404s (routes don't exist) / `app.licensingService` fatalError.

- [ ] **Step 3: Implement the controller**

```swift
// ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/LicenseController.swift
import ClaudeSpyNetworking
import Vapor

/// HTTP endpoints for host license management. These return billing state
/// only — never session data — and are keyed by deviceId, the same trust
/// model as pairing registration.
struct LicenseController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let license = routes.grouped("license")

        license.post("activate", use: activate)
        license.delete("activation", use: deactivate)
        license.get("status", use: status)
    }

    /// POST /api/license/activate
    @Sendable
    func activate(req: Request) async throws -> LicenseStatus {
        let request = try req.content.decode(LicenseActivationRequest.self)
        do {
            return try await req.application.licensingService.activate(
                licenseKey: request.licenseKey,
                deviceId: request.deviceId,
                deviceName: request.deviceName
            )
        } catch let error as LicensingError {
            throw Abort(.badRequest, reason: error.userMessage)
        }
    }

    /// DELETE /api/license/activation?deviceId=x
    @Sendable
    func deactivate(req: Request) async throws -> HTTPStatus {
        guard let deviceId = req.query[String.self, at: "deviceId"] else {
            throw Abort(.badRequest, reason: "Missing deviceId parameter")
        }
        await req.application.licensingService.deactivate(deviceId: deviceId)
        return .noContent
    }

    /// GET /api/license/status?deviceId=x — read-only, never starts a trial.
    @Sendable
    func status(req: Request) async throws -> LicenseStatus {
        guard let deviceId = req.query[String.self, at: "deviceId"] else {
            throw Abort(.badRequest, reason: "Missing deviceId parameter")
        }
        return await req.application.licensingService.status(deviceId: deviceId)
    }
}
```

In `routes.swift`, after `try api.register(collection: PairingController())`:

```swift
    try api.register(collection: LicenseController())
```

In `VaporContentConformance.swift`, add (mirroring the file's existing style):

```swift
extension LicenseStatus: Content {}
```

In `configure.swift`, after `let metricsService = MetricsService()` (line 24):

```swift
    // Licensing: enabled only when LEMONSQUEEZY_STORE_ID + LEMONSQUEEZY_PRODUCT_ID
    // are both set. Self-hosted relays leave them unset and run unrestricted.
    // Misconfiguration (half-set / non-integer) throws here — fail-loud at boot.
    let licensingConfig = try LicensingConfiguration.fromEnvironment()
    let licenseAPIClient: any LicenseAPIClient
    if let licensingConfig {
        licenseAPIClient = LemonSqueezyAPIClient(baseURL: licensingConfig.apiBaseURL)
    } else {
        licenseAPIClient = DisabledLicenseAPIClient()
    }
    let licensingService = LicensingService(
        config: licensingConfig,
        apiClient: licenseAPIClient,
        metricsService: metricsService
    )
    if licensingConfig != nil {
        app.logger.info("Licensing ENABLED — hosted-relay hosts require a trial or license")
    }
```

Store it with the other services (next to line 56-60):

```swift
    app.storage[LicensingServiceKey.self] = licensingService
```

Add the storage key + accessor (next to the existing ones):

```swift
struct LicensingServiceKey: StorageKey {
    typealias Value = LicensingService
}
```

```swift
    var licensingService: LicensingService {
        guard let service = storage[LicensingServiceKey.self] else {
            fatalError("LicensingService not configured. Call configure(_:) first.")
        }
        return service
    }
```

Add the E2E helper in the existing `public extension Application` block (next to `resetPairingState`):

```swift
    /// Reset all licensing state (for testing)
    func resetLicensingState() async {
        await licensingService.resetState()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ClaudeSpyPackage --filter LicenseEndpointTests`
Expected: 4 tests PASS. Also run `swift test --package-path ClaudeSpyPackage --filter MetricsEndpointTests` — must still PASS (configure changes are additive when env is unset).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/LicenseController.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/routes.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Extensions/VaporContentConformance.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/configure.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicenseEndpointTests.swift
git commit -m "Add license endpoints and configure wiring to the relay (#392)"
```

---

### Task 8: Relay — enforcement at pairing register + host WS connect, metrics

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/PairingController.swift:17-29` (`registerPairingCode`)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/WebSocketController.swift:117-127` (after the `isValidPair` guard)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/MetricsService.swift` (remaining counters + render lines)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicenseEndpointTests.swift` (extend) and `MetricsServiceTests.swift` (extend, mirroring its existing counter tests)

**Interfaces:**
- Consumes: `app.licensingService` (Task 7), `Entitlement.isAllowed` (Task 5), `ErrorMessage.subscriptionRequired()` / `ErrorInfo(message:code:)` / `.hostSubscriptionInactive` (Task 2), `ConnectionHub.send(_:to:deviceType:)` (existing, ConnectionHub.swift:174).
- Produces: blocked hosts get `PairingResponse.error` with `code == "SUBSCRIPTION_REQUIRED"` on register, and `WebSocketMessage.error(.subscriptionRequired())` + socket close on WS connect (viewers of that pair get `.hostSubscriptionInactive`). `MetricsService` gains `licenseDeactivationsTotal`, `blockedHostAttemptsTotal` (+ increments) and renders all licensing counters.

- [ ] **Step 1: Write the failing tests** (append to `LicenseEndpointTests.swift`; reuse `withLicensingApp`)

```swift
    private static let testPublicKey = "dGVzdC1tYWMtcHVibGljLWtleS0wMTIzNDU2Nzg5MDEyMw=="

    @Test("Pairing register auto-starts a trial and succeeds")
    func registerStartsTrial() async throws {
        try await withLicensingApp { app in
            try await app.testing().test(.POST, "api/pairing/register", beforeRequest: { req in
                try req.content.encode(PairingRegistration(
                    deviceId: "host-1", deviceName: "My Mac", pairingCode: "ABC123",
                    publicKey: Self.testPublicKey, publicKeyId: "key-1", username: "tester"
                ))
            }) { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(PairingResponse.self)
                guard case .registered = response else {
                    Issue.record("Expected .registered, got \(response)")
                    return
                }
            }
            // The register touched the relay → trial exists now.
            try await app.testing().test(.GET, "api/license/status?deviceId=host-1") { res in
                let status = try res.content.decode(LicenseStatus.self)
                #expect(status.state == .trial)
            }
        }
    }

    @Test("Pairing register is blocked with SUBSCRIPTION_REQUIRED after trial expiry")
    func registerBlockedAfterTrial() async throws {
        // TRIAL_DAYS=0 → the auto-started trial is already expired.
        try await withLicensingApp(trialDays: "0") { app in
            try await app.testing().test(.POST, "api/pairing/register", beforeRequest: { req in
                try req.content.encode(PairingRegistration(
                    deviceId: "host-1", deviceName: "My Mac", pairingCode: "ABC123",
                    publicKey: Self.testPublicKey, publicKeyId: "key-1", username: "tester"
                ))
            }) { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(PairingResponse.self)
                guard case let .error(info) = response else {
                    Issue.record("Expected .error, got \(response)")
                    return
                }
                #expect(info.code == ErrorMessage.subscriptionRequiredCode)
            }
        }
    }

    @Test("Pairing register is untouched when licensing is disabled")
    func registerUnrestrictedWhenDisabled() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudespy-license-endpoint-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("DATA_DIRECTORY", tempDir.path, 1)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            unsetenv("DATA_DIRECTORY")
        }
        try await withApp(configure: configure) { app in
            try await app.testing().test(.POST, "api/pairing/register", beforeRequest: { req in
                try req.content.encode(PairingRegistration(
                    deviceId: "host-1", deviceName: "My Mac", pairingCode: "ABC123",
                    publicKey: Self.testPublicKey, publicKeyId: "key-1", username: "tester"
                ))
            }) { res in
                let response = try res.content.decode(PairingResponse.self)
                guard case .registered = response else {
                    Issue.record("Expected .registered, got \(response)")
                    return
                }
            }
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter LicenseEndpointTests`
Expected: `registerStartsTrial` FAILS on the status assertion (`.none`, no enforcement touch yet) and `registerBlockedAfterTrial` FAILS (gets `.registered`).

- [ ] **Step 3: Implement enforcement**

In `PairingController.registerPairingCode`, between the decode and the `registerCode` call:

```swift
        let registration = try req.content.decode(PairingRegistration.self)

        // Hosted-relay gate: hosts need a trial or active license. First touch
        // auto-starts the trial, so a fresh host sails through.
        let entitlement = await req.application.licensingService
            .checkEntitlement(hostDeviceId: registration.deviceId)
        guard entitlement.isAllowed else {
            await req.application.metricsService.incrementBlockedHostAttempts()
            return .error(ErrorInfo(
                message: "An active subscription is required to use the hosted relay",
                code: ErrorMessage.subscriptionRequiredCode
            ))
        }
```

(`ErrorMessage` comes from `ClaudeSpyNetworking`, already imported. The `.error(ErrorInfo(...))` form needs `PairingResponse.error(ErrorInfo(...))` — use the enum case directly: `return .error(ErrorInfo(message: ..., code: ...))`.)

In `WebSocketController.handleWebSocketUpgrade`, immediately after the `isValidPair` guard block (line 118-127), mirroring the invalid-pair flow:

```swift
        // Hosted-relay gate for hosts (viewers are never gated). Mirrors the
        // invalidPair rejection flow above.
        if deviceType == .host {
            let entitlement = await req.application.licensingService
                .checkEntitlement(hostDeviceId: deviceId)
            if !entitlement.isAllowed {
                req.logger.info("WebSocket host rejected: subscription required for pair \(pairId)")
                await req.application.metricsService.incrementBlockedHostAttempts()
                await connectionHub.unregister(pairId: pairId, deviceType: deviceType)
                let errorMessage = WebSocketMessage.error(.subscriptionRequired())
                if let data = try? JSONEncoder().encode(errorMessage) {
                    try? await ws.send(raw: data, opcode: .text)
                }
                await connectionHub.send(.hostSubscriptionInactive, to: pairId, deviceType: .viewer)
                try? await ws.close(code: .policyViolation)
                return
            }
        }
```

In `MetricsService.swift`, add the remaining counters:

```swift
    private(set) var licenseDeactivationsTotal = 0
    private(set) var blockedHostAttemptsTotal = 0

    func incrementLicenseDeactivations() {
        licenseDeactivationsTotal &+= 1
    }

    func incrementBlockedHostAttempts() {
        blockedHostAttemptsTotal &+= 1
    }
```

and in `render(snapshot:buildVersion:)`, after the push-notifications block:

```swift
        lines.append("# HELP claudespy_trial_starts_total Hosted-relay trials auto-started since process start.")
        lines.append("# TYPE claudespy_trial_starts_total counter")
        lines.append("claudespy_trial_starts_total \(trialStartsTotal)")

        lines.append("# HELP claudespy_license_activations_total License keys activated since process start.")
        lines.append("# TYPE claudespy_license_activations_total counter")
        lines.append("claudespy_license_activations_total \(licenseActivationsTotal)")

        lines.append("# HELP claudespy_license_deactivations_total License activations released since process start.")
        lines.append("# TYPE claudespy_license_deactivations_total counter")
        lines.append("claudespy_license_deactivations_total \(licenseDeactivationsTotal)")

        lines.append("# HELP claudespy_license_validation_failures_total Failed license validations/activations since process start.")
        lines.append("# TYPE claudespy_license_validation_failures_total counter")
        lines.append("claudespy_license_validation_failures_total \(licenseValidationFailuresTotal)")

        lines.append("# HELP claudespy_blocked_host_attempts_total Host connections/registrations rejected for lack of entitlement.")
        lines.append("# TYPE claudespy_blocked_host_attempts_total counter")
        lines.append("claudespy_blocked_host_attempts_total \(blockedHostAttemptsTotal)")
```

In `LicensingService.deactivate`, after `saveState()`, add the increment (it was deferred until the counter existed):

```swift
        Task { await metricsService?.incrementLicenseDeactivations() }
```

Extend `MetricsServiceTests.swift` with a counter test mirroring its existing ones (increment each new counter once, assert the rendered text contains `claudespy_trial_starts_total 1` etc.).

- [ ] **Step 4: Run the relay test suite**

Run: `swift test --package-path ClaudeSpyPackage --filter "License|Metrics|PairingService"`
Expected: all PASS, including the pre-existing pairing and metrics suites.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/PairingController.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/WebSocketController.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/MetricsService.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LicensingService.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicenseEndpointTests.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsServiceTests.swift
git commit -m "Enforce hosted-relay entitlement at pairing and host connect (#392)"
```

---

### Task 9: Relay — daily sweep for mid-connection lapses

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/ConnectionHub.swift` (add `disconnect(pairId:deviceType:)`)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LicensingService.swift` (add `sweepBlockedHosts`)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/configure.swift` (start the loop when enabled)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicensingServiceTests.swift` (new suite)

**Interfaces:**
- Consumes: `PairingService.activePairIds`/`getPair(pairId:)` (existing), `ConnectionHub.isHostConnected(pairId:)`/`send` (existing).
- Produces:
  - `ConnectionHub.disconnect(pairId: String, deviceType: DeviceType) async` — closes and removes one device's socket.
  - `LicensingService.sweepBlockedHosts(pairingService: PairingService, connectionHub: ConnectionHub) async -> [String]` — returns blocked pairIds (for logging/tests).
  - A daily background `Task` started in `configure` only when licensing is enabled, cancelled on shutdown.

- [ ] **Step 1: Write the failing test** (append to `LicensingServiceTests.swift`)

```swift
@Suite("LicensingService sweep")
struct LicensingServiceSweepTests {
    @Test("Sweep flags pairs whose connected host lost entitlement")
    func sweepFindsBlockedHosts() async throws {
        let dir = try LicensingTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestNow()
        let service = LicensingService(
            config: LicensingTestSupport.config, apiClient: StubLicenseAPIClient(),
            dataDirectory: dir, now: { clock.value }
        )

        // Real PairingService + ConnectionHub, no sockets: send() to
        // unconnected devices is a logged no-op, so the sweep's message sends
        // are safe; isHostConnected is false, so first verify the
        // nothing-connected case…
        let pairingService = PairingService(dataDirectory: dir)
        let hub = ConnectionHub()

        _ = await pairingService.registerCode(
            code: "ABC123", deviceId: "host-1", deviceName: "Mac",
            username: "u", publicKey: "pk", publicKeyId: "pkid"
        )
        _ = await pairingService.completePairing(
            code: "ABC123", deviceId: "viewer-1", deviceName: "iPhone",
            publicKey: "vpk", publicKeyId: "vpkid"
        )

        // Expire host-1's trial.
        _ = await service.checkEntitlement(hostDeviceId: "host-1")
        clock.advance(bySeconds: 8 * 86_400)

        // No host connected → sweep reports nothing.
        let quiet = await service.sweepBlockedHosts(pairingService: pairingService, connectionHub: hub)
        #expect(quiet.isEmpty)
    }
}
```

(The connected-host disconnect path needs a live WebSocket, which unit tests can't fabricate — `Connection` wraps a real `WebSocket`. The entitlement-resolution logic the sweep uses is already covered by the core/activation suites; the live disconnect is exercised by the E2E scenario in Task 17. This test pins the pair-iteration/guard logic.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path ClaudeSpyPackage --filter LicensingServiceSweepTests`
Expected: FAIL — no member `sweepBlockedHosts`.

- [ ] **Step 3: Implement**

In `ConnectionHub.swift`, next to `disconnectAll(pairId:)` (line 74):

```swift
    /// Close and remove a single device's connection for a pair (used by the
    /// licensing sweep to evict hosts whose entitlement lapsed mid-connection).
    func disconnect(pairId: String, deviceType: DeviceType) async {
        guard let connection = connections[pairId]?[deviceType] else { return }
        try? await connection.webSocket.close()
        connections[pairId]?[deviceType] = nil
        if connections[pairId]?.isEmpty == true {
            connections.removeValue(forKey: pairId)
        }
    }
```

In `LicensingService.swift`, add to the actor:

```swift
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
            guard await connectionHub.isHostConnected(pairId: pairId),
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
```

In `configure.swift`, after the licensing service is stored (Task 7 block):

```swift
    if licensingConfig != nil {
        let sweepLogger = app.logger
        let sweepTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(86_400))
                guard !Task.isCancelled else { break }
                let blocked = await licensingService.sweepBlockedHosts(
                    pairingService: pairingService,
                    connectionHub: connectionHub
                )
                if !blocked.isEmpty {
                    sweepLogger.info("Licensing sweep disconnected \(blocked.count) host(s)")
                }
            }
        }
        app.storage.set(LicensingSweepTaskKey.self, to: sweepTask, onShutdown: { $0.cancel() })
    }
```

with the storage key:

```swift
struct LicensingSweepTaskKey: StorageKey {
    typealias Value = Task<Void, Never>
}
```

- [ ] **Step 4: Run the relay suite**

Run: `swift test --package-path ClaudeSpyPackage --filter "License|Metrics|Pairing|ViewerReconnect"`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/ConnectionHub.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LicensingService.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/configure.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicensingServiceTests.swift
git commit -m "Add daily licensing sweep for mid-connection lapses (#392)"
```

---

### Task 10: Ops & docs — docker-compose, .env.example, self-hosting.md, monitoring.md

**Files:**
- Modify: `ClaudeSpyPackage/docker-compose.yml` (environment block, lines 9-21)
- Modify: `ClaudeSpyPackage/.env.example`
- Modify: `docs/self-hosting.md`
- Modify: `docs/monitoring.md`

No code — verify with `docker compose config` if Docker is available locally, otherwise YAML-lint by eye and rely on the deploy dry-run (`./deploy.sh test`) at rollout.

- [ ] **Step 1: docker-compose.yml** — add to `environment:` after the `PAIRING_CODE_EXPIRY_SECONDS` line:

```yaml
      # Licensing (hosted-relay monetization) — leave BOTH unset for self-hosting.
      # Setting only one of the two ids fails the boot on purpose.
      - LEMONSQUEEZY_STORE_ID=${LEMONSQUEEZY_STORE_ID:-}
      - LEMONSQUEEZY_PRODUCT_ID=${LEMONSQUEEZY_PRODUCT_ID:-}
      - TRIAL_DAYS=${TRIAL_DAYS:-7}
      - LICENSE_REVALIDATE_HOURS=${LICENSE_REVALIDATE_HOURS:-24}
      - LICENSE_GRACE_DAYS=${LICENSE_GRACE_DAYS:-7}
```

(Empty strings are treated as unset by `LicensingConfiguration.fromEnvironment` — Task 3 tests pin this.)

- [ ] **Step 2: .env.example** — add a section after MONITORING:

```bash
# ============================================================================
# LICENSING (HOSTED-RELAY MONETIZATION — OPTIONAL)
# ============================================================================
# Self-hosting? Leave this whole section unset: the relay runs unrestricted.
#
# On the official hosted relay these gate host Macs behind a Lemon Squeezy
# subscription (7-day trial auto-starts on first use). Both ids come from the
# Lemon Squeezy dashboard; setting only one of them fails boot on purpose.

# Numeric store id from Lemon Squeezy → Settings → Stores
LEMONSQUEEZY_STORE_ID=

# Numeric product id of the subscription product
LEMONSQUEEZY_PRODUCT_ID=

# Trial length in days (default 7)
TRIAL_DAYS=7

# How often cached license verdicts are revalidated against Lemon Squeezy (default 24)
LICENSE_REVALIDATE_HOURS=24

# How long a previously-valid key keeps working while Lemon Squeezy is
# unreachable (default 7). Hard expired/disabled verdicts block immediately.
LICENSE_GRACE_DAYS=7
```

- [ ] **Step 3: self-hosting.md** — in the Overview section (after the E2EE sentence, line 12), add:

```markdown
Self-hosted relays are free and require no license configuration: the hosted-relay
licensing gate is entirely disabled unless `LEMONSQUEEZY_STORE_ID` and
`LEMONSQUEEZY_PRODUCT_ID` are set in the environment. Leave them unset (the
default) and the relay behaves exactly as before licensing existed.
```

Also add the five new env vars to the Configuration section's example block with the same comments as `.env.example` (condensed).

- [ ] **Step 4: monitoring.md** — document the five new counters (`claudespy_trial_starts_total`, `claudespy_license_activations_total`, `claudespy_license_deactivations_total`, `claudespy_license_validation_failures_total`, `claudespy_blocked_host_attempts_total`) in the metrics list, one line each, noting they stay 0 when licensing is disabled.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/docker-compose.yml ClaudeSpyPackage/.env.example \
        docs/self-hosting.md docs/monitoring.md
git commit -m "Document and wire licensing env for relay deployments (#392)"
```

---

### Task 11: Keychain — generic secret storage for the license key

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyEncryption/KeyManager.swift` (three methods, mirroring `storeSessionKey`/`loadSessionKey`/`deleteSessionKey` at lines 319-380)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyEncryption/SecretsService.swift` (three closures + `inMemory()` + `liveValue`)

**Interfaces:**
- Consumes: existing `KeyManager` private helpers (`storeAttributes(account:data:)`, the query/`SecItem` patterns) and `CryptoError.keychainError(status:)`.
- Produces:
  - `KeyManager.storeSecret(_ value: String, account: String) throws`, `loadSecret(account: String) throws -> String?`, `deleteSecret(account: String) throws`
  - `SecretsService.storeSecret: @Sendable (String, String) async throws -> Void` (value, account), `loadSecret: @Sendable (String) async throws -> String?`, `deleteSecret: @Sendable (String) async throws -> Void` — wired in `liveValue` and `inMemory()`.
  - Account name constant used by Task 13: `LicenseKeychainAccounts.licenseKey = "lemonsqueezy-license-key"` (define in Task 13's `LicenseManager.swift`, not here — this task stays generic).
- Used by Task 13.

- [ ] **Step 1: Implement KeyManager methods** — copy the exact body shape of `storeSessionKey(_:for:)` / `loadSessionKey(for:)` / `deleteSessionKey(for:)` (KeyManager.swift:319-380) but take `account: String` directly instead of deriving it from a pairId, and convert `String` ↔ `Data(value.utf8)`:

```swift
    // MARK: - Generic Secrets

    /// Store an arbitrary secret string under `account` (upsert).
    public func storeSecret(_ value: String, account: String) throws {
        // Mirror storeSessionKey's SecItemUpdate-then-SecItemAdd upsert with
        // Data(value.utf8) as the payload and `account` used verbatim.
    }

    /// Load a secret stored via `storeSecret`. Returns nil when absent.
    public func loadSecret(account: String) throws -> String? {
        // Mirror loadSessionKey's SecItemCopyMatching; decode String(decoding:as:).
    }

    /// Delete a secret stored via `storeSecret` (missing item is not an error).
    public func deleteSecret(account: String) throws {
        // Mirror deleteSessionKey.
    }
```

(The comment bodies above are instructions to the implementer, not shippable code: transplant the exact `SecItem` query dictionaries from the session-key methods, replacing the account expression with the `account` parameter and the payload with `Data(value.utf8)`. Keep `kSecAttrService = keychainService` and the same accessibility attribute.)

- [ ] **Step 2: Extend SecretsService** — add three closures to the `@DependencyClient` struct:

```swift
    /// Store an arbitrary secret string under a keychain account (value, account).
    public var storeSecret: @Sendable (String, String) async throws -> Void
    /// Load a secret by account; nil when absent.
    public var loadSecret: @Sendable (String) async throws -> String?
    /// Delete a secret by account.
    public var deleteSecret: @Sendable (String) async throws -> Void
```

Wire them in `liveValue` (calling the `KeyManager` methods from Step 1, same actor instance the other closures use) and in `inMemory()` (a locked `[String: String]` dictionary in the existing in-memory backing object, mirroring how session keys are stored there).

- [ ] **Step 3: Build both platforms' packages**

Run: `swift build --package-path ClaudeSpyPackage --target ClaudeSpyEncryption`
Expected: builds. (Live keychain behavior is not unit-tested — existing `ClaudeSpyEncryptionTests` covers E2EE flows only; the `inMemory()` path is exercised by Task 13's tests.)

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyEncryption/KeyManager.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyEncryption/SecretsService.swift
git commit -m "Add generic keychain secret storage to SecretsService (#392)"
```

---

### Task 12: Mac — `LicensingClient` dependency client

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/LicensingClient.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/LicensingClientTests.swift`

**Interfaces:**
- Consumes: `LicenseStatus`/`LicenseActivationRequest` (Task 1), relay endpoints (Task 7), `String.httpURL` (`ClaudeSpyCommon/Utilities/String+URL.swift`).
- Produces:

```swift
@DependencyClient
public struct LicensingClient: Sendable {
    public var activate: @Sendable (
        _ serverURL: String, _ licenseKey: String, _ deviceId: String, _ deviceName: String
    ) async throws -> LicenseStatus
    public var deactivate: @Sendable (_ serverURL: String, _ deviceId: String) async throws -> Void
    public var status: @Sendable (_ serverURL: String, _ deviceId: String) async throws -> LicenseStatus
}
```

plus `enum LicensingClientError: LocalizedError, Equatable { case invalidURL, invalidResponse, server(String) }`. Used by Task 13.

- [ ] **Step 1: Write the failing test** (pure logic only — the URLSession live path is covered by E2E; the test pins error mapping through a stubbed client used exactly as `LicenseManager` will)

```swift
// ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/LicensingClientTests.swift
import ClaudeSpyNetworking
import Testing
@testable import ClaudeSpyServerFeature

@Suite("LicensingClient")
@MainActor
struct LicensingClientTests {
    @Test("Relay error body maps to a readable message")
    func serverErrorMapping() {
        let error = LicensingClientError.server("This license key has reached the activation limit.")
        #expect(error.errorDescription == "This license key has reached the activation limit.")
    }

    @Test("parseRelayError extracts Vapor's reason field")
    func parseRelayError() {
        let body = Data(#"{"error":true,"reason":"This license key is not valid for this product"}"#.utf8)
        let parsed = LicensingClient.parseRelayError(from: body, statusCode: 400)
        #expect(parsed == .server("This license key is not valid for this product"))
    }

    @Test("parseRelayError falls back to the status code")
    func parseRelayErrorFallback() {
        let parsed = LicensingClient.parseRelayError(from: Data(), statusCode: 500)
        #expect(parsed == .server("Server error (HTTP 500)"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter LicensingClientTests`
Expected: FAIL — `cannot find 'LicensingClient' in scope`.

- [ ] **Step 3: Implement** (mirror `PairingManager.registerCode`'s URLSession style, PairingManager.swift:198-237; decode with `.iso8601` because `LicenseStatus` carries dates)

```swift
// ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/LicensingClient.swift
#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation

    /// Vapor's default error body: {"error": true, "reason": "…"}.
    private struct RelayErrorResponse: Codable {
        let reason: String
    }

    public enum LicensingClientError: LocalizedError, Equatable {
        case invalidURL
        case invalidResponse
        case server(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "Invalid server URL"
            case .invalidResponse: "Invalid server response"
            case let .server(message): message
            }
        }
    }

    /// HTTP client for the relay's /api/license endpoints.
    @DependencyClient
    public struct LicensingClient: Sendable {
        public var activate: @Sendable (
            _ serverURL: String, _ licenseKey: String, _ deviceId: String, _ deviceName: String
        ) async throws -> LicenseStatus
        public var deactivate: @Sendable (_ serverURL: String, _ deviceId: String) async throws -> Void
        public var status: @Sendable (_ serverURL: String, _ deviceId: String) async throws -> LicenseStatus

        static func parseRelayError(from data: Data, statusCode: Int) -> LicensingClientError {
            if let parsed = try? JSONDecoder().decode(RelayErrorResponse.self, from: data) {
                return .server(parsed.reason)
            }
            return .server("Server error (HTTP \(statusCode))")
        }
    }

    extension LicensingClient: DependencyKey {
        public static var previewValue: LicensingClient {
            LicensingClient(
                activate: { _, _, _, _ in LicenseStatus(state: .trial) },
                deactivate: { _, _ in },
                status: { _, _ in LicenseStatus(state: .trial) }
            )
        }

        public static var liveValue: LicensingClient {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            @Sendable func request(
                serverURL: String, path: String, method: String, body: Data? = nil
            ) async throws -> Data {
                guard let url = URL(string: "\(serverURL.httpURL)\(path)") else {
                    throw LicensingClientError.invalidURL
                }
                var request = URLRequest(url: url)
                request.httpMethod = method
                if let body {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = body
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw LicensingClientError.invalidResponse
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    throw parseRelayError(from: data, statusCode: httpResponse.statusCode)
                }
                return data
            }

            return LicensingClient(
                activate: { serverURL, licenseKey, deviceId, deviceName in
                    let body = try JSONEncoder().encode(LicenseActivationRequest(
                        licenseKey: licenseKey, deviceId: deviceId, deviceName: deviceName
                    ))
                    let data = try await request(
                        serverURL: serverURL, path: "/api/license/activate", method: "POST", body: body
                    )
                    return try decoder.decode(LicenseStatus.self, from: data)
                },
                deactivate: { serverURL, deviceId in
                    _ = try await request(
                        serverURL: serverURL,
                        path: "/api/license/activation?deviceId=\(deviceId)",
                        method: "DELETE"
                    )
                },
                status: { serverURL, deviceId in
                    let data = try await request(
                        serverURL: serverURL,
                        path: "/api/license/status?deviceId=\(deviceId)",
                        method: "GET"
                    )
                    return try decoder.decode(LicenseStatus.self, from: data)
                }
            )
        }
    }
#endif
```

(`deviceId` is a UUID string from `AppSettings.deviceId` — URL-safe, no percent-encoding needed.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ClaudeSpyPackage --filter LicensingClientTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/LicensingClient.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/LicensingClientTests.swift
git commit -m "Add Mac LicensingClient for relay license endpoints (#392)"
```

---

### Task 13: Mac — `LicenseManager` observable

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/LicenseManager.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Models/Settings.swift` (persisted `trialAlertsFired` — the four-touch pattern: property+didSet, `Keys` case, `Defaults` value, `init()` load)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/LicenseManagerTests.swift`

**Interfaces:**
- Consumes: `LicensingClient` (Task 12), `SecretsService.storeSecret/loadSecret/deleteSecret` (Task 11), `AppSettings` (`externalServerURL`, `deviceId`, new `trialAlertsFired`).
- Produces:

```swift
@Observable @MainActor
public final class LicenseManager {
    public enum ActionState: Equatable { case idle, working, error(String) }
    public private(set) var status: LicenseStatus?
    public private(set) var actionState: ActionState
    public var licenseKeyField: String
    public init(settings: AppSettings)
    public func loadStoredKey() async
    public func refreshStatus() async
    public func activate() async
    public func deactivate() async
    public var trialDaysLeft: Int?  // ceil of remaining days, nil unless state == .trial
}
```

Keychain account constant: `enum LicenseKeychainAccounts { static let licenseKey = "lemonsqueezy-license-key" }`. Task 14 adds trial-alert checking to this class; Task 15 renders it.

- [ ] **Step 1: Write the failing tests**

```swift
// ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/LicenseManagerTests.swift
import ClaudeSpyEncryption
import ClaudeSpyNetworking
import Dependencies
import Foundation
import Testing
@testable import ClaudeSpyServerFeature

@Suite("LicenseManager")
@MainActor
struct LicenseManagerTests {
    private func makeManager(
        client: LicensingClient,
        secrets: SecretsService = .inMemory()
    ) -> (LicenseManager, AppSettings) {
        withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[LicensingClient.self] = client
            $0[SecretsService.self] = secrets
        } operation: {
            let settings = AppSettings()
            settings.deviceId = "device-1"
            let manager = LicenseManager(settings: settings)
            return (manager, settings)
        }
    }

    @Test("refreshStatus populates status")
    func refresh() async {
        let (manager, _) = makeManager(client: LicensingClient(
            activate: { _, _, _, _ in LicenseStatus(state: .active) },
            deactivate: { _, _ in },
            status: { _, _ in LicenseStatus(state: .trial, expiresAt: Date().addingTimeInterval(86_400)) }
        ))
        await manager.refreshStatus()
        #expect(manager.status?.state == .trial)
        #expect(manager.trialDaysLeft == 1)
    }

    @Test("activate stores the key in secrets and updates status")
    func activateStoresKey() async throws {
        let secrets = SecretsService.inMemory()
        let (manager, _) = makeManager(
            client: LicensingClient(
                activate: { _, key, _, _ in
                    #expect(key == "KEY-42")
                    return LicenseStatus(state: .active, activationLimit: 3, activationUsage: 1)
                },
                deactivate: { _, _ in },
                status: { _, _ in LicenseStatus(state: .active) }
            ),
            secrets: secrets
        )
        manager.licenseKeyField = "  KEY-42  " // trimmed before send
        await manager.activate()
        #expect(manager.status?.state == .active)
        #expect(manager.actionState == .idle)
        let stored = try await secrets.loadSecret(LicenseKeychainAccounts.licenseKey)
        #expect(stored == "KEY-42")
    }

    @Test("activation failure surfaces the server message")
    func activateFailure() async {
        let (manager, _) = makeManager(client: LicensingClient(
            activate: { _, _, _, _ in
                throw LicensingClientError.server("This license key has reached the activation limit.")
            },
            deactivate: { _, _ in },
            status: { _, _ in LicenseStatus(state: .none) }
        ))
        manager.licenseKeyField = "KEY-42"
        await manager.activate()
        #expect(manager.actionState
            == .error("This license key has reached the activation limit."))
    }

    @Test("deactivate clears the stored key and refreshes")
    func deactivateClears() async throws {
        let secrets = SecretsService.inMemory()
        try await secrets.storeSecret("KEY-42", LicenseKeychainAccounts.licenseKey)
        let (manager, _) = makeManager(
            client: LicensingClient(
                activate: { _, _, _, _ in LicenseStatus(state: .active) },
                deactivate: { _, _ in },
                status: { _, _ in LicenseStatus(state: .none) }
            ),
            secrets: secrets
        )
        await manager.deactivate()
        #expect(manager.status?.state == LicenseStatus.State.none)
        let stored = try await secrets.loadSecret(LicenseKeychainAccounts.licenseKey)
        #expect(stored == nil)
    }
}
```

(If `SecretsService.inMemory()`'s closure labels differ from `loadSecret(_:)` positional calls, match the call sites to the generated closure-call syntax — `@DependencyClient` structs are called as `secrets.loadSecret(account)`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter LicenseManagerTests`
Expected: FAIL — `cannot find 'LicenseManager' in scope`.

- [ ] **Step 3: Implement**

`Settings.swift` — the four-touch persisted property (mirroring `externalServerURL`):

```swift
    /// Trial-expiry notifications already fired, as "\(unix-expiry)-\(hours)"
    /// tokens (e.g. "1800000000-48") so a new trial re-arms both thresholds.
    public var trialAlertsFired: [String] = Defaults.trialAlertsFired {
        didSet {
            if let data = try? JSONEncoder().encode(trialAlertsFired) {
                preferences.setData(data, Keys.trialAlertsFired)
            }
        }
    }
```

`Keys`: `case trialAlertsFired`. `Defaults`: `static let trialAlertsFired: [String] = []`. `init()`:

```swift
        if let data = preferences.data(Keys.trialAlertsFired),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            self.trialAlertsFired = decoded
        }
```

`LicenseManager.swift`:

```swift
// ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/LicenseManager.swift
#if os(macOS)
    import ClaudeSpyEncryption
    import ClaudeSpyNetworking
    import Dependencies
    import Foundation
    import Observation

    /// Keychain accounts used for licensing secrets.
    public enum LicenseKeychainAccounts {
        public static let licenseKey = "lemonsqueezy-license-key"
    }

    /// Owns the Mac app's view of the hosted-relay license: current status,
    /// activation/deactivation actions, and the stored key. Trial-expiry
    /// alerting hangs off this class (Task 14).
    @Observable
    @MainActor
    public final class LicenseManager {
        public enum ActionState: Equatable {
            case idle
            case working
            case error(String)
        }

        public private(set) var status: LicenseStatus?
        public private(set) var actionState: ActionState = .idle
        public var licenseKeyField: String = ""

        @ObservationIgnored
        @Dependency(LicensingClient.self) private var client
        @ObservationIgnored
        @Dependency(SecretsService.self) private var secrets

        private weak var settings: AppSettings?

        public init(settings: AppSettings) {
            self.settings = settings
        }

        /// Ceil of remaining trial days; nil unless status is an unexpired trial.
        public var trialDaysLeft: Int? {
            guard let status, status.state == .trial, let expiresAt = status.expiresAt else {
                return nil
            }
            let remaining = expiresAt.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            return Int((remaining / 86_400).rounded(.up))
        }

        public func loadStoredKey() async {
            guard licenseKeyField.isEmpty else { return }
            licenseKeyField = (try? await secrets.loadSecret(LicenseKeychainAccounts.licenseKey)) ?? ""
        }

        public func refreshStatus() async {
            guard let settings else { return }
            do {
                status = try await client.status(settings.externalServerURL, settings.deviceId)
            } catch {
                // Status refresh is best-effort background work; existing
                // status (possibly nil) stays and connection errors surface
                // through the relay client's own state.
            }
        }

        public func activate() async {
            guard let settings else { return }
            let key = licenseKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                actionState = .error("Enter a license key first")
                return
            }
            actionState = .working
            do {
                status = try await client.activate(
                    settings.externalServerURL, key, settings.deviceId, settings.deviceName
                )
                try? await secrets.storeSecret(key, LicenseKeychainAccounts.licenseKey)
                licenseKeyField = key
                actionState = .idle
            } catch {
                actionState = .error(error.localizedDescription)
            }
        }

        public func deactivate() async {
            guard let settings else { return }
            actionState = .working
            do {
                try await client.deactivate(settings.externalServerURL, settings.deviceId)
                try? await secrets.deleteSecret(LicenseKeychainAccounts.licenseKey)
                licenseKeyField = ""
                actionState = .idle
                await refreshStatus()
            } catch {
                actionState = .error(error.localizedDescription)
            }
        }
    }
#endif
```

Note: `settings.deviceName` — verify the exact `AppSettings` property for the host's display name (the one `PairingManager` sends as `deviceName` in `PairingRegistration`, see PairingManager.swift:98); use the same expression here.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ClaudeSpyPackage --filter LicenseManagerTests`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/LicenseManager.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Models/Settings.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/LicenseManagerTests.swift
git commit -m "Add LicenseManager observable for Mac license state (#392)"
```

---

### Task 14: Mac — 48h/24h trial-expiry alerts

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/TrialAlertPlanner.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/LicenseNotificationService.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/LicenseManager.swift` (`checkTrialAlerts()`)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/TerminalNotificationService.swift:170-202` (`ForegroundNotificationDelegate` license-tap routing)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift` (own `LicenseManager`, start monitoring, route taps — near `setupNotificationTapHandler()` at :3169)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/LicenseManagerTests.swift` (extend)

**Interfaces:**
- Consumes: `LicenseManager`/`AppSettings.trialAlertsFired` (Task 13), `UNUserNotificationCenter` patterns from `TerminalNotificationService`.
- Produces:
  - `enum TrialAlertThreshold: Int, CaseIterable, Sendable { case hours48 = 48, hours24 = 24 }`
  - `enum TrialAlertPlanner { static func thresholdsToFire(now: Date, expiresAt: Date, alreadyFired: Set<Int>) -> [TrialAlertThreshold] }` — all crossed, unfired thresholds, most-urgent first.
  - `@DependencyClient LicenseNotificationService { var showTrialExpiryNotification: @Sendable (_ hoursRemaining: Int) -> Void }`
  - `LicenseManager.checkTrialAlerts()` — fires ONE notification (the most urgent applicable) and marks ALL applicable thresholds fired.
  - `ForegroundNotificationDelegate.onLicenseAlertTapped: (@MainActor () -> Void)?` — invoked when a tapped notification's `userInfo["licenseAlert"] as? Bool == true`.
  - `AppCoordinator.licenseManager: LicenseManager` + a 30-minute monitoring loop.

- [ ] **Step 1: Write the failing tests** (append to `LicenseManagerTests.swift`)

```swift
@Suite("TrialAlertPlanner")
struct TrialAlertPlannerTests {
    private let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Nothing fires above 48h remaining")
    func nothingEarly() {
        let now = expiry.addingTimeInterval(-49 * 3_600)
        #expect(TrialAlertPlanner.thresholdsToFire(now: now, expiresAt: expiry, alreadyFired: []).isEmpty)
    }

    @Test("48h threshold fires inside the window, once")
    func fires48() {
        let now = expiry.addingTimeInterval(-47 * 3_600)
        #expect(TrialAlertPlanner.thresholdsToFire(now: now, expiresAt: expiry, alreadyFired: [])
            == [.hours48])
        #expect(TrialAlertPlanner.thresholdsToFire(now: now, expiresAt: expiry, alreadyFired: [48])
            .isEmpty)
    }

    @Test("Inside 24h, both unfired thresholds apply, most urgent first")
    func fires24AndCatchUp() {
        let now = expiry.addingTimeInterval(-20 * 3_600)
        #expect(TrialAlertPlanner.thresholdsToFire(now: now, expiresAt: expiry, alreadyFired: [])
            == [.hours24, .hours48])
        #expect(TrialAlertPlanner.thresholdsToFire(now: now, expiresAt: expiry, alreadyFired: [48])
            == [.hours24])
    }

    @Test("Nothing fires after expiry")
    func nothingAfterExpiry() {
        let now = expiry.addingTimeInterval(60)
        #expect(TrialAlertPlanner.thresholdsToFire(now: now, expiresAt: expiry, alreadyFired: []).isEmpty)
    }
}
```

And a `LicenseManager` integration test in the existing suite:

```swift
    @Test("checkTrialAlerts fires once and persists flags")
    func trialAlertsFireOnce() async {
        let expiry = Date().addingTimeInterval(20 * 3_600) // inside 24h window
        let fired = LockIsolated<[Int]>([])
        let (manager, settings) = withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[LicensingClient.self] = LicensingClient(
                activate: { _, _, _, _ in LicenseStatus(state: .active) },
                deactivate: { _, _ in },
                status: { _, _ in LicenseStatus(state: .trial, expiresAt: expiry) }
            )
            $0[SecretsService.self] = .inMemory()
            $0[LicenseNotificationService.self] = LicenseNotificationService(
                showTrialExpiryNotification: { hours in fired.withValue { $0.append(hours) } }
            )
        } operation: {
            let settings = AppSettings()
            settings.deviceId = "device-1"
            return (LicenseManager(settings: settings), settings)
        }

        await manager.refreshStatus()
        manager.checkTrialAlerts()
        #expect(fired.value == [24]) // one notification: the most urgent
        #expect(settings.trialAlertsFired.count == 2) // both thresholds marked

        manager.checkTrialAlerts()
        #expect(fired.value == [24]) // idempotent
    }
```

(`LockIsolated` comes from the Dependencies package's `ConcurrencyExtras`, already a transitive dependency — `import ConcurrencyExtras` if needed.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter "TrialAlertPlanner|LicenseManagerTests"`
Expected: FAIL — `cannot find 'TrialAlertPlanner' in scope`.

- [ ] **Step 3: Implement**

```swift
// ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/TrialAlertPlanner.swift
#if os(macOS)
    import Foundation

    /// Trial-expiry alert thresholds, in hours before expiry.
    public enum TrialAlertThreshold: Int, CaseIterable, Sendable {
        case hours48 = 48
        case hours24 = 24
    }

    /// Pure planning logic for trial-expiry alerts, kept free of I/O so the
    /// 48h/24h windows are unit-testable.
    public enum TrialAlertPlanner {
        /// All crossed-but-unfired thresholds while the trial is still live,
        /// most urgent (smallest) first. Caller fires ONE notification (the
        /// first) and marks every returned threshold as fired, so a Mac that
        /// slept through 48h doesn't get two back-to-back alerts.
        public static func thresholdsToFire(
            now: Date, expiresAt: Date, alreadyFired: Set<Int>
        ) -> [TrialAlertThreshold] {
            let remaining = expiresAt.timeIntervalSince(now)
            guard remaining > 0 else { return [] }
            return TrialAlertThreshold.allCases
                .filter { threshold in
                    remaining <= TimeInterval(threshold.rawValue) * 3_600
                        && !alreadyFired.contains(threshold.rawValue)
                }
                .sorted { $0.rawValue < $1.rawValue }
        }
    }
#endif
```

```swift
// ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/LicenseNotificationService.swift
#if os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation
    import UserNotifications

    /// Posts trial-expiry desktop notifications. Mirrors
    /// TerminalNotificationService's live handler (permission request +
    /// UNUserNotificationCenter add); taps are routed by
    /// ForegroundNotificationDelegate via userInfo["licenseAlert"].
    @DependencyClient
    public struct LicenseNotificationService: Sendable {
        public var showTrialExpiryNotification: @Sendable (_ hoursRemaining: Int) -> Void
    }

    extension LicenseNotificationService: DependencyKey {
        public static var previewValue: LicenseNotificationService {
            LicenseNotificationService(showTrialExpiryNotification: { _ in })
        }

        public static var liveValue: LicenseNotificationService {
            LicenseNotificationService(showTrialExpiryNotification: { hoursRemaining in
                Task {
                    // Reuse the permission flow pattern from
                    // TerminalNotificationService.ensurePermission() (lines
                    // 120-158) — transplant the same authorization check.
                    let content = UNMutableNotificationContent()
                    content.title = "Gallager trial ending"
                    content.body = "Your hosted-relay trial ends in less than \(hoursRemaining) hours. "
                        + "Subscribe to keep remote access."
                    content.sound = .default
                    content.userInfo = ["licenseAlert": true]
                    let request = UNNotificationRequest(
                        identifier: "license-trial-\(hoursRemaining)h",
                        content: content,
                        trigger: nil
                    )
                    try? await UNUserNotificationCenter.current().add(request)
                }
            })
        }
    }
#endif
```

`LicenseManager` additions:

```swift
        @ObservationIgnored
        @Dependency(LicenseNotificationService.self) private var notifications

        /// Fires pending 48h/24h trial-expiry alerts. Idempotent: flags are
        /// persisted per trial expiry in AppSettings.trialAlertsFired.
        public func checkTrialAlerts() {
            guard let settings,
                  let status, status.state == .trial,
                  let expiresAt = status.expiresAt else { return }

            let expiryKey = "\(Int(expiresAt.timeIntervalSince1970))"
            let alreadyFired = Set(settings.trialAlertsFired.compactMap { token -> Int? in
                let parts = token.split(separator: "-")
                guard parts.count == 2, parts[0] == expiryKey else { return nil }
                return Int(parts[1])
            })

            let pending = TrialAlertPlanner.thresholdsToFire(
                now: Date(), expiresAt: expiresAt, alreadyFired: alreadyFired
            )
            guard let mostUrgent = pending.first else { return }

            notifications.showTrialExpiryNotification(mostUrgent.rawValue)
            settings.trialAlertsFired.append(
                contentsOf: pending.map { "\(expiryKey)-\($0.rawValue)" }
            )
        }
```

`ForegroundNotificationDelegate` (TerminalNotificationService.swift): add next to `onTapped`:

```swift
    @MainActor var onLicenseAlertTapped: (() -> Void)?
```

and in `didReceive`, before the paneId handling:

```swift
        if response.notification.request.content.userInfo["licenseAlert"] as? Bool == true {
            Task { @MainActor in
                self.onLicenseAlertTapped?()
            }
            completionHandler()
            return
        }
```

(match the method's existing style for hopping to the main actor and calling `completionHandler` — mirror how `onTapped` is invoked at lines 185-201.)

`AppCoordinator`: add near the other service properties:

```swift
    public private(set) lazy var licenseManager = LicenseManager(settings: settings)
    private var licenseMonitorTask: Task<Void, Never>?
```

In `setupNotificationTapHandler()` (line 3169), add:

```swift
        ForegroundNotificationDelegate.shared.onLicenseAlertTapped = { [weak self] in
            guard let self else { return }
            settings.selectedSettingsTab = .remoteAccess
            // Open the Settings window the same way MenuBarExtraView does
            // (MenuBarExtraView.swift:80-115) — reuse its open-settings helper.
        }
```

and start monitoring wherever the coordinator's other launch-time tasks begin (find the call site of `setupNotificationTapHandler()` and start it there too):

```swift
    private func startLicenseMonitoring() {
        licenseMonitorTask?.cancel()
        licenseMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.licenseManager.refreshStatus()
                self?.licenseManager.checkTrialAlerts()
                try? await Task.sleep(for: .seconds(1_800))
            }
        }
    }
```

Note the open-settings step: `openSettings` is a SwiftUI environment action, unavailable in the coordinator. MenuBarExtraView (lines 80-115) already solves opening Settings from non-view context on this codebase — reuse whatever it does (it may post a notification or use a stored action). If it turns out to be view-bound, store an `openSettingsAction: (() -> Void)?` on the coordinator, set from a view's `@Environment(\.openSettings)` in `onAppear`, and call it here.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ClaudeSpyPackage --filter "TrialAlertPlanner|LicenseManagerTests"`
Expected: all PASS (planner 4, manager 5).

- [ ] **Step 5: Build the Mac app**

Use the XcodeBuildTools `xcodebuild` skill, scheme `ClaudeSpyServer`.
Expected: builds with the AppCoordinator changes.

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/TrialAlertPlanner.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/LicenseNotificationService.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/LicenseManager.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/TerminalNotificationService.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/LicenseManagerTests.swift
git commit -m "Alert host Macs 48h and 24h before trial expiry (#392)"
```

---

### Task 15: Mac — License section in Remote Access settings + typed-error surfacing

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/RemoteAccessSettingsView.swift` (new Section after "Server", lines 37-48)
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Models/LicensingLinks.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/PairingManager.swift` (map `SUBSCRIPTION_REQUIRED` on `.error` responses)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/ExternalServerClient.swift:563-568` (recognize the code, notify)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/SettingsView.swift:295-297` (inject `coordinator.licenseManager` into the environment)

**Interfaces:**
- Consumes: `LicenseManager` (Tasks 13–14), `URLOpener` (`ClaudeSpyCommon/Services/URLOpener.swift`), `Symbols` (`.exclamationmarkTriangle` exists at Symbols.swift:47), `ErrorMessage.subscriptionRequiredCode` (Task 2).
- Produces: user-visible licensing UI; `ExternalServerClient.onSubscriptionRequired: (@MainActor () -> Void)?` callback (set in AppCoordinator next to its other client callbacks → triggers `licenseManager.refreshStatus()`).

- [ ] **Step 1: LicensingLinks** (URLs from Task 0 — if Task 0 isn't done yet, use the store name placeholder and revisit before release; the file is the single place they live)

```swift
// ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Models/LicensingLinks.swift
#if os(macOS)
    import Foundation

    /// Lemon Squeezy storefront links. Constants by design: they change
    /// rarely, and an app update is an acceptable cost to change them
    /// (spec §Mac app changes). Values come from the LS dashboard (Task 0).
    enum LicensingLinks {
        static let checkout = URL(string: "https://gallager.lemonsqueezy.com/buy/CHECKOUT-VARIANT-UUID")!
        static let billingPortal = URL(string: "https://gallager.lemonsqueezy.com/billing")!
    }
#endif
```

- [ ] **Step 2: License section** — in `RemoteAccessSettingsView`, add `@Environment(LicenseManager.self)` and, after the Server section:

```swift
            // License
            Section {
                licenseSection
            } header: {
                Text("License")
            } footer: {
                Text("The hosted relay requires a subscription after a 7-day free trial. Self-hosted relays never need one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

with (as a `@ViewBuilder private var` on the struct, using `@Bindable var licenseManager = licenseManager` inside `body` like the existing `@Bindable var settings` at line 19):

```swift
    @ViewBuilder
    private var licenseSection: some View {
        @Bindable var licenseManager = licenseManager

        switch licenseManager.status?.state {
        case .notRequired:
            Label("Not required on this relay", symbol: .checkmarkCircleFill)
                .foregroundStyle(.secondary)
        case .active:
            LabeledContent("Status") {
                Text("Active")
                    .foregroundStyle(.green)
            }
            if let limit = licenseManager.status?.activationLimit,
               let usage = licenseManager.status?.activationUsage {
                LabeledContent("Activations", value: "\(usage) of \(limit) Macs")
            }
            Button("Manage Subscription") {
                urlOpener.openInDefaultBrowser(LicensingLinks.billingPortal)
            }
            .buttonStyle(.borderless)
            Button("Deactivate This Mac", role: .destructive) {
                Task { await licenseManager.deactivate() }
            }
            .buttonStyle(.borderless)
        default:
            if let daysLeft = licenseManager.trialDaysLeft {
                LabeledContent("Status") {
                    Text("Trial — \(daysLeft) day\(daysLeft == 1 ? "" : "s") left")
                        .foregroundStyle(daysLeft <= 2 ? .orange : .secondary)
                }
            } else if licenseManager.status?.state == .expired {
                Label("Subscription required", symbol: .exclamationmarkTriangle)
                    .foregroundStyle(.orange)
            }
            TextField("License Key", text: $licenseManager.licenseKeyField)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Activate") {
                    Task { await licenseManager.activate() }
                }
                .disabled(licenseManager.actionState == .working)
                Button("Buy a License…") {
                    urlOpener.openInDefaultBrowser(LicensingLinks.checkout)
                }
            }
            if case let .error(message) = licenseManager.actionState {
                Label(message, symbol: .exclamationmarkTriangle)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
```

plus the dependency (next to the view's existing properties): `@Dependency(URLOpener.self) private var urlOpener` (with `@ObservationIgnored` not needed in a View — use a plain `let urlOpener = Dependency(URLOpener.self).wrappedValue` or match how other views consume `URLOpener`/`ClipboardClient`; `RemoteAccessSettingsView` already uses `@Dependency(ClipboardClient.self)`-style access — mirror it). Add `.task { await licenseManager.loadStoredKey(); await licenseManager.refreshStatus() }` on the Form. If `checkmarkCircleFill` is missing from `Symbols`, add it (`"checkmark.circle.fill"`).

- [ ] **Step 3: Typed error surfacing.**

`PairingManager.generatePairingCode` — where `.error(errorInfo)` sets `state = .error(errorInfo.message)` (lines 102-122), keep the message but prefer a friendly one for the typed code:

```swift
            case let .error(errorInfo):
                if errorInfo.code == ErrorMessage.subscriptionRequiredCode {
                    state = .error("Subscription required — see the License section below")
                } else {
                    state = .error(errorInfo.message)
                }
```

`ExternalServerClient.handleWebSocketMessage` `.error` case (lines 563-568):

```swift
            case let .error(errorMessage):
                logger.error("Server error: \(errorMessage.message)")
                if errorMessage.code == ErrorMessage.subscriptionRequiredCode {
                    onSubscriptionRequired?()
                }
                if !errorMessage.recoverable {
                    await updateState(.error(errorMessage.message))
                    await disconnect()
                }
```

with a callback property + setter mirroring `setConnectionStateHandler` (lines 149-153):

```swift
    private var onSubscriptionRequired: (@MainActor () -> Void)?

    public func setSubscriptionRequiredHandler(_ handler: @escaping @MainActor () -> Void) {
        onSubscriptionRequired = handler
    }
```

In `AppCoordinator`, where the external server client's other handlers are wired (search `setConnectionStateHandler` call site), add:

```swift
        externalServerClient.setSubscriptionRequiredHandler { [weak self] in
            guard let self else { return }
            Task { await self.licenseManager.refreshStatus() }
        }
```

`SettingsView.swift:295-297` — add `.environment(coordinator.licenseManager)` next to the existing `.environment(...)` injections (the coordinator is already available there; if only `settings`/`e2eeService` are in scope, thread the manager the same way `PairingManager` is created — but prefer the coordinator-owned instance so alerts and UI share state).

- [ ] **Step 4: Build + run the Mac app and eyeball the section**

Build via XcodeBuildTools `xcodebuild` skill (scheme `ClaudeSpyServer`), launch via `macos-app` skill, open Settings → Remote Access. Expected: License section renders in all three shapes (none/trial with the countdown, active, notRequired against a licensing-disabled relay).

- [ ] **Step 5: Run the full ServerFeature test suite**

Run: `swift test --package-path ClaudeSpyPackage --filter ClaudeSpyServerFeatureTests`
Expected: PASS (no regressions from the PairingManager/ExternalServerClient edits).

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/RemoteAccessSettingsView.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Models/LicensingLinks.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/PairingManager.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/ExternalServerClient.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/SettingsView.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyCommon/UI/Symbols.swift
git commit -m "Add License section to Remote Access settings (#392)"
```

---

### Task 16: Viewers — "Host's subscription expired" state (iOS + Mac viewer)

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/ViewerRelayClient.swift` (new observable flag + message handling near lines 800-843)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/ViewerConnection.swift` (expose the flag, near lines 31-50)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Views/SessionListView.swift` (row in `HostSessionsSection.body`, lines 283-292)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/RemoteHostsSettingsView.swift` (`HostRow`, line 223 — status text)

**Interfaces:**
- Consumes: `WebSocketMessage.hostSubscriptionInactive` (Task 2), existing `ViewerRelayClient` observables (`isHostConnected` etc.).
- Produces: `ViewerRelayClient.hostSubscriptionInactive: Bool` (published), mirrored as `ViewerConnection.hostSubscriptionInactive: Bool`; viewer UIs render "Host's subscription expired".

- [ ] **Step 1: ViewerRelayClient.** Add near the other published properties (lines 61-73):

```swift
    /// True when the relay reported this host is blocked for lack of an
    /// active subscription. Cleared when the host connects again.
    public private(set) var hostSubscriptionInactive = false
```

In `handleMessage`'s switch, add a case (near `.hostDisconnected` at line 800):

```swift
        case .hostSubscriptionInactive:
            logger.info("Host blocked: subscription inactive")
            hostSubscriptionInactive = true
            isHostConnected = false
```

Clear it wherever the host comes back or the connection resets: in the `.hostConnected` handling and in `cleanupConnection()` (find both; set `hostSubscriptionInactive = false`).

- [ ] **Step 2: ViewerConnection.** Next to `versionMismatch` (lines 31-50):

```swift
    /// Relay reported the host's hosted-relay subscription lapsed.
    public var hostSubscriptionInactive: Bool {
        relayClient.hostSubscriptionInactive
    }
```

(Match the exact computed-property style of the neighbors — if they read a stored `relayClient` property under a different name, mirror it.)

- [ ] **Step 3: iOS row.** In `HostSessionsSection.body`'s else-branch (SessionListView.swift:283-292):

```swift
            } else {
                if connection?.hostSubscriptionInactive == true {
                    Label("Host's subscription expired", symbol: .exclamationmarkTriangle)
                        .foregroundStyle(.orange)
                } else if connection?.isHostConnected == true {
                    Text("No active sessions").foregroundStyle(.secondary)
                } else {
                    Text("Host offline").foregroundStyle(.secondary)
                }
            }
```

- [ ] **Step 4: Mac viewer row.** In `RemoteHostsSettingsView`'s `HostRow` (line 223), find where the connection status text/dot is derived and add the same precedence: `hostSubscriptionInactive` → orange "Host's subscription expired", before the generic offline text.

- [ ] **Step 5: Build both apps**

Build via XcodeBuildTools `xcodebuild` skill: scheme `ClaudeSpyServer` (macOS) and scheme `ClaudeSpy` (iOS simulator).
Expected: both build. (State-machine coverage for this flag rides the E2E scenario; `ViewerRelayClient`'s message pump has no existing unit harness to extend.)

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/ViewerRelayClient.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/ViewerConnection.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyFeature/Views/SessionListView.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/RemoteHostsSettingsView.swift
git commit -m "Show host subscription-expired state on viewers (#392)"
```

---

### Task 17: E2E scenario — licensing flow against a stub Lemon Squeezy

**Files:**
- Create: a stub LS server in `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/` (small Vapor app serving `/v1/licenses/activate|validate|deactivate` with canned `LSLicenseResponse` JSON)
- Create: one scenario in the E2E scenario registry
- Possibly modify: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Drivers/Server/ServerDriver.swift:18-60` (env injection before `configure`, mirroring the existing `setenv("APNS_E2E_LOG_PATH", …)`)

**Interfaces:**
- Consumes: everything above; `Application.resetLicensingState()` (Task 7); `LEMONSQUEEZY_API_BASE` env override (Task 3).
- Produces: an automated proof that the full loop works: trial visible → trial expired blocks pairing with the right UI → activate against the stub → connected.

**IMPORTANT:** Write this scenario by invoking the repo's `e2e-for-feature` skill — it owns the ScenarioBuilder DSL, baseline rules (CI-generated, never commit local baselines), and the run/verify protocol. Feed it this outline:

- [ ] **Step 1: Invoke the `e2e-for-feature` skill** with this scenario outline:
  1. Boot the stub LS server on a fixed local port; `setenv` `LEMONSQUEEZY_STORE_ID=123`, `LEMONSQUEEZY_PRODUCT_ID=456`, `LEMONSQUEEZY_API_BASE=http://127.0.0.1:<stub-port>` before `ServerDriver.start()` (and clean env + `licensing.json` in teardown, mirroring the `pairs.json` cleanup).
  2. **Trial visible:** launch the Mac host, open Settings → Remote Access, screenshot the License section showing "Trial — 7 days left".
  3. **Blocked:** restart the relay with `TRIAL_DAYS=0`, attempt Add Viewer, screenshot the "Subscription required" error state.
  4. **Activate:** type the stub-accepted key into the License field, click Activate, screenshot the Active status; verify pairing then succeeds.
- [ ] **Step 2: Run the suite** per that skill's protocol (locally 2–3×, verify every screenshot visually before pushing — see the repo's E2E feedback rules).
- [ ] **Step 3: Also re-run one existing remote-access scenario** to prove licensing-disabled runs are untouched.
- [ ] **Step 4: Commit** per the skill's conventions.

---

### Task 18: Rollout prep — version gate + release checklist (DO NOT merge the bump with the feature PR)

**Files:**
- Modify (enablement release only): `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/VersionCompatibility.swift:14,20`

**Context:** `VersionCompatibility` is peer-to-peer (host↔viewer, exchanged via `peerHello`), not relay-enforced. Bumping the minimums makes updated viewers refuse pre-licensing hosts, surfacing the existing "please update" UI instead of opaque failures once enforcement is live. Per the spec's rollout §3, this ships in the release that coincides with enabling licensing on the hosted relay — NOT with the feature PR (old hosts remain fine until the env vars are set).

- [ ] **Step 1 (at enablement time):** bump both defaults to the enablement release's marketing version (e.g. `"2.5"` — use the actual version being cut):

```swift
    public static let defaultMinRequiredViewerVersion = "2.5"
    public static let defaultMinRequiredHostVersion = "2.5"
```

with the doc comment noting the licensing flag-day, mirroring the existing plugin-system note.

- [ ] **Step 2: Release checklist** (record in the release PR/issue #392):
  1. Task 0 complete; real checkout/portal URLs in `LicensingLinks.swift` (replace the `CHECKOUT-VARIANT-UUID` placeholder — grep for it).
  2. Deploy relay WITHOUT the LS env vars → verify `/health`, existing pairs reconnect, `./deploy.sh test` green.
  3. Ship the Mac/iOS app release containing this feature + the version bump.
  4. Set `LEMONSQUEEZY_STORE_ID`/`LEMONSQUEEZY_PRODUCT_ID` in the relay's `.env`, `docker compose up -d` → licensing live; watch `claudespy_trial_starts_total` climb and `logs` for "Licensing ENABLED".
  5. One real production purchase + refund end-to-end.
  6. Hand out tester discount codes.

---

## Verification & docs wrap-up (fold into the final PR)

- Full suite: `swift test --package-path ClaudeSpyPackage` green; both app schemes build; E2E suite green.
- `CLAUDE.md`: add a one-line reference entry for the licensing feature (the PR-checklist hook will prompt for this and the other post-PR chores on `gh pr create`).
- The feature PR should reference issue #392 and note that enforcement stays dormant until the env vars are set in production.

## Task dependency graph

- Tasks 1–2 (networking) → everything else.
- Tasks 3–4 → 5 → 6 → 7 → 8 → 9 (relay chain, strictly ordered).
- Task 10 (ops/docs) after 9.
- Task 11 (keychain) independent after 2; 12 → 13 → 14 → 15 (Mac chain; 13 needs 11).
- Task 16 (viewers) after 2 (buildable anytime; meaningful after 8).
- Task 17 (E2E) last, after 15 + 16.
- Task 18 at enablement time, not with the feature PR.
- Task 0 (manual LS setup) anytime before 15's URL fill-in and production enablement.





