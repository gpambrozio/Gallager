# Trial-status badge + trial-starts-on-pairing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start a host's free-trial clock only when a viewer completes pairing, and surface the trial/expired state as a toolbar badge (left of Disconnect) whose popover lets the user buy or activate a license.

**Architecture:** Two coordinated changes. (A) Relay: `LicensingService.checkEntitlement` becomes side-effect-free (new `.preTrial` allowed state); a new `startTrialIfNeeded` is called from `PairingController.completePairing`. (B) Mac: a new `TrialStatusToolbarItem` view renders a pill + buy/activate popover over the existing `LicenseManager`, gated on `settings.isPaired`, wired into `MainView`'s toolbar.

**Tech Stack:** Swift 6.3, Vapor (relay), SwiftUI + Point-Free Dependencies (Mac), Swift Testing + VaporTesting, ClaudeSpyE2ELib (E2E).

## Global Constraints

- SF Symbols only via `Symbols` enum (`ClaudeSpyCommon/UI/Symbols.swift`) — never string literals. (project rule)
- No ViewModels; use `@State`/`@Observable`/`@Environment`/`@Dependency`. (project rule)
- All licensing *logic* stays in `LicensingService` (relay) and `LicenseManager` (Mac) — views/controllers add no new licensing logic. (design)
- Trial "urgent" threshold = **`daysLeft <= 2`** → orange (matches the existing Settings License section). (design)
- No wire-format change → **no `VersionCompatibility` bump.** (design)
- Relay tests run under `EnvSerializedSuites` and must stay hermetic against a local `.env` (licensing-disabled tests force `LEMONSQUEEZY_*` to empty). (existing convention)
- Run relay tests with: `swift test --package-path ClaudeSpyPackage --filter ClaudeSpyExternalServerTests` (use the `XcodeBuildTools:swift-package` skill; pipe through `xcsift`).

---

### Task 1: Relay — trial starts on viewer pairing

Move trial-start from first-touch `checkEntitlement` (fires at register + WS connect) to the `complete` endpoint. `checkEntitlement` becomes a pure gate returning a new `.preTrial` (allowed) state for a device with no trial and no activation.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LicensingService.swift:40-50` (Entitlement enum), `:143-185` (checkEntitlement + trialEntitlement)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/PairingController.swift:45-56` (completePairing)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicensingServiceTests.swift` (actor-level)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicenseEndpointTests.swift` (endpoint-level)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicenseEnforcementWebSocketTests.swift:232-256` (`makePair` helper)

**Interfaces:**
- Produces: `LicensingService.Entitlement.preTrial` (case, `isAllowed == true`); `func startTrialIfNeeded(hostDeviceId: String)` (actor method, sync, idempotent, no-op when licensing disabled / activation exists / trial exists).
- Consumes (unchanged): `PairingService.getPair(pairId:) -> Pair?` with `Pair.hostDeviceId: String`; `PairingResponse.paired(PairedViewerInfo)` with `PairedViewerInfo.pairId: String`.

- [ ] **Step 1: Add `.preTrial` and split check/start in `LicensingService`**

In `LicensingService.swift`, add the case to the `Entitlement` enum (`:40`):

```swift
enum Entitlement: Equatable {
    case unrestricted
    /// Licensing enabled, but this host has no trial yet and no activation.
    /// Allowed — the trial clock has not started (it starts at viewer pairing).
    case preTrial
    case trial(expiresAt: Date)
    case licensed
    case blocked(reason: BlockReason)

    var isAllowed: Bool {
        if case .blocked = self { return false }
        return true
    }
}
```

Replace both `trialEntitlement(deviceId:config:)` call sites in `checkEntitlement` (`:153` and `:169`) with `evaluateTrial(deviceId:config:)`, and replace the `trialEntitlement` method (`:172-185`) with a pure `evaluateTrial` plus a new `startTrialIfNeeded`:

```swift
/// Pure: evaluate an EXISTING trial. Never creates one. A device with no
/// trial (and no activation) is `.preTrial` — allowed, clock not started.
private func evaluateTrial(deviceId: String, config: LicensingConfiguration) -> Entitlement {
    guard let trial = state.trials[deviceId] else { return .preTrial }
    let expiresAt = trial.startedAt.addingTimeInterval(TimeInterval(config.trialDays) * 86_400)
    return now() < expiresAt ? .trial(expiresAt: expiresAt) : .blocked(reason: .trialExpired)
}

/// Start the host's free trial the first time a viewer pairs. Idempotent:
/// no-op when licensing is disabled, an activation exists, or a trial already
/// exists. This is the ONLY place a trial is created.
func startTrialIfNeeded(hostDeviceId: String) {
    guard config != nil else { return }
    guard state.activations[hostDeviceId] == nil else { return }
    guard state.trials[hostDeviceId] == nil else { return }
    state.trials[hostDeviceId] = TrialRecord(startedAt: now())
    saveState()
    logger.info("Started trial", metadata: ["deviceId": "\(hostDeviceId)"])
    Task { await metricsService?.incrementTrialStarts() }
}
```

- [ ] **Step 2: Start the trial from `completePairing`**

In `PairingController.swift`, replace `completePairing` (`:45-56`) with:

```swift
/// Viewer completes pairing with a code
/// POST /api/pairing/complete
@Sendable
func completePairing(req: Request) async throws -> PairingResponse {
    let completion = try req.content.decode(PairingCompletion.self)

    let response = await req.application.pairingService.completePairing(
        code: completion.pairingCode,
        deviceId: completion.deviceId,
        deviceName: completion.deviceName,
        publicKey: completion.publicKey,
        publicKeyId: completion.publicKeyId
    )

    // Start the host's free-trial clock the moment a viewer actually pairs —
    // not at register/first-touch. Idempotent; a no-op when licensing is off.
    if case let .paired(info) = response,
       let hostDeviceId = await req.application.pairingService.getPair(pairId: info.pairId)?.hostDeviceId {
        await req.application.licensingService.startTrialIfNeeded(hostDeviceId: hostDeviceId)
    }

    return response
}
```

- [ ] **Step 3: Update actor-level tests (`LicensingServiceTests.swift`)**

Replace `trialAutoStart` (`:120-138`) with two tests — `checkEntitlement` no longer starts a trial, and `startTrialIfNeeded` does:

```swift
@Test("checkEntitlement returns .preTrial for a fresh device and starts no trial")
func freshDeviceIsPreTrial() async throws {
    let dir = try LicensingTestSupport.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let service = LicensingService(
        config: LicensingTestSupport.config, apiClient: StubLicenseAPIClient(),
        dataDirectory: dir
    )
    #expect(await service.checkEntitlement(hostDeviceId: "host-1") == .preTrial)
    // No trial recorded by asking.
    #expect(await service.status(deviceId: "host-1") == LicenseStatus(state: .none))
}

@Test("startTrialIfNeeded starts a 7-day trial once; idempotent thereafter")
func startTrialIfNeededStartsOnce() async throws {
    let dir = try LicensingTestSupport.tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clock = TestNow()
    let service = LicensingService(
        config: LicensingTestSupport.config, apiClient: StubLicenseAPIClient(),
        dataDirectory: dir, now: { clock.value }
    )
    await service.startTrialIfNeeded(hostDeviceId: "host-1")
    let expectedExpiry = clock.value.addingTimeInterval(7 * 86_400)
    #expect(await service.checkEntitlement(hostDeviceId: "host-1") == .trial(expiresAt: expectedExpiry))

    // Second call does not restart the clock.
    clock.advance(bySeconds: 3 * 86_400)
    await service.startTrialIfNeeded(hostDeviceId: "host-1")
    #expect(await service.checkEntitlement(hostDeviceId: "host-1") == .trial(expiresAt: expectedExpiry))
}
```

In `trialExpires` (`:140-163`), replace the trial-arming line `_ = await service.checkEntitlement(hostDeviceId: "host-1")` (`:150`) with `await service.startTrialIfNeeded(hostDeviceId: "host-1")`.

In `trialPersistence` (`:178-196`), replace `let original = await first.checkEntitlement(hostDeviceId: "host-1")` (`:188`) with:

```swift
await first.startTrialIfNeeded(hostDeviceId: "host-1")
let original = await first.checkEntitlement(hostDeviceId: "host-1")
```

In `sweepFindsBlockedHosts` (`:423-456`), replace `_ = await service.checkEntitlement(hostDeviceId: "host-1")` (`:450`) with `await service.startTrialIfNeeded(hostDeviceId: "host-1")`.

- [ ] **Step 4: Update endpoint tests (`LicenseEndpointTests.swift`)**

Replace `registerStartsTrial` (`:92-114`) with a "register does not start" test plus a "complete starts" test:

```swift
@Test("Pairing register succeeds but does NOT start a trial")
func registerDoesNotStartTrial() async throws {
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
        // Registering a code alone must not start the trial clock.
        try await app.testing().test(.GET, "api/license/status?deviceId=host-1") { res in
            let status = try res.content.decode(LicenseStatus.self)
            #expect(status.state == .none)
        }
    }
}

@Test("Completing a pairing starts the host's trial")
func completeStartsTrial() async throws {
    try await withLicensingApp { app in
        try await app.testing().test(.POST, "api/pairing/register", beforeRequest: { req in
            try req.content.encode(PairingRegistration(
                deviceId: "host-1", deviceName: "My Mac", pairingCode: "ABC123",
                publicKey: Self.testPublicKey, publicKeyId: "key-1", username: "tester"
            ))
        }) { res in #expect(res.status == .ok) }

        try await app.testing().test(.POST, "api/pairing/complete", beforeRequest: { req in
            try req.content.encode(PairingCompletion(
                pairingCode: "ABC123", deviceId: "viewer-1", deviceName: "iPhone",
                publicKey: Self.testPublicKey, publicKeyId: "vkey-1"
            ))
        }) { res in
            #expect(res.status == .ok)
            let response = try res.content.decode(PairingResponse.self)
            guard case .paired = response else {
                Issue.record("Expected .paired, got \(response)")
                return
            }
        }
        // The viewer pairing started the host's trial.
        try await app.testing().test(.GET, "api/license/status?deviceId=host-1") { res in
            let status = try res.content.decode(LicenseStatus.self)
            #expect(status.state == .trial)
        }
    }
}
```

Replace `registerBlockedAfterTrial` (`:116-135`) so the trial is armed via `complete` first (TRIAL_DAYS=0 → immediately expired), then a subsequent register is blocked:

```swift
@Test("Register is blocked with SUBSCRIPTION_REQUIRED once the trial has expired")
func registerBlockedAfterTrial() async throws {
    // TRIAL_DAYS=0 → the trial started by completing a pairing is already expired.
    try await withLicensingApp(trialDays: "0") { app in
        // Register + complete once: allowed (pre-trial), and complete starts the
        // (already-expired) trial for host-1.
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
        try await app.testing().test(.POST, "api/pairing/complete", beforeRequest: { req in
            try req.content.encode(PairingCompletion(
                pairingCode: "ABC123", deviceId: "viewer-1", deviceName: "iPhone",
                publicKey: Self.testPublicKey, publicKeyId: "vkey-1"
            ))
        }) { res in #expect(res.status == .ok) }

        // A NEW register for the same host is now blocked — its trial expired.
        try await app.testing().test(.POST, "api/pairing/register", beforeRequest: { req in
            try req.content.encode(PairingRegistration(
                deviceId: "host-1", deviceName: "My Mac", pairingCode: "XYZ789",
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
```

- [ ] **Step 5: Arm the trial in the WebSocket test helper (`LicenseEnforcementWebSocketTests.swift`)**

`makePair` (`:232-256`) calls `pairingService.completePairing` directly (bypassing the controller), so it must start the trial itself to mirror real behavior. After the `guard case .paired = complete` block (`:252-254`) and before `return info.pairId` (`:255`), add:

```swift
// Mirror PairingController.completePairing: a completed pairing starts the
// host's trial (no-op when licensing is disabled, i.e. licensingTrialDays == nil).
await app.licensingService.startTrialIfNeeded(hostDeviceId: "host-device")
```

- [ ] **Step 6: Run the full relay suite**

Run: `swift test --package-path ClaudeSpyPackage --filter ClaudeSpyExternalServerTests`
Expected: PASS, 0 failures (the previously-green count plus the one net-new endpoint test).

- [ ] **Step 7: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/LicensingService.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/PairingController.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicensingServiceTests.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicenseEndpointTests.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/LicenseEnforcementWebSocketTests.swift
git commit -m "relay: start the free trial on viewer pairing, not on register/first-touch"
```

---

### Task 2: Mac — trial-badge appearance helper + `hourglass` symbol

A pure, unit-testable mapping from license state to badge appearance, plus the SF Symbol the badge uses.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyCommon/UI/Symbols.swift:47` (add `hourglass`)
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/TrialStatusToolbarItem.swift` (helper only in this task)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/TrialBadgeAppearanceTests.swift`

**Interfaces:**
- Produces: `enum TrialBadgeAppearance: Equatable { case trial(daysLeft: Int, urgent: Bool); case expired }` and `func trialBadgeAppearance(state: LicenseStatus.State?, trialDaysLeft: Int?) -> TrialBadgeAppearance?` (returns `nil` when the badge should be hidden). Both `internal`, in `ClaudeSpyServerFeature`, macOS-only.

- [ ] **Step 1: Write the failing test**

Create `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/TrialBadgeAppearanceTests.swift`:

```swift
#if os(macOS)
    import ClaudeSpyNetworking
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("trialBadgeAppearance")
    struct TrialBadgeAppearanceTests {
        @Test("Trial with more than 2 days is a non-urgent trial badge")
        func trialRelaxed() {
            #expect(trialBadgeAppearance(state: .trial, trialDaysLeft: 5) == .trial(daysLeft: 5, urgent: false))
        }

        @Test("Trial with 2 or fewer days is urgent")
        func trialUrgent() {
            #expect(trialBadgeAppearance(state: .trial, trialDaysLeft: 2) == .trial(daysLeft: 2, urgent: true))
            #expect(trialBadgeAppearance(state: .trial, trialDaysLeft: 1) == .trial(daysLeft: 1, urgent: true))
        }

        @Test("Expired maps to the expired badge")
        func expired() {
            #expect(trialBadgeAppearance(state: .expired, trialDaysLeft: nil) == .expired)
        }

        @Test("Hidden for non-trial/expired states and for a trial with no day count")
        func hidden() {
            #expect(trialBadgeAppearance(state: .active, trialDaysLeft: nil) == nil)
            #expect(trialBadgeAppearance(state: .none, trialDaysLeft: nil) == nil)
            #expect(trialBadgeAppearance(state: .notRequired, trialDaysLeft: nil) == nil)
            #expect(trialBadgeAppearance(state: nil, trialDaysLeft: nil) == nil)
            #expect(trialBadgeAppearance(state: .trial, trialDaysLeft: nil) == nil)
        }
    }
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path ClaudeSpyPackage --filter TrialBadgeAppearanceTests`
Expected: FAIL to build — `trialBadgeAppearance` / `TrialBadgeAppearance` are undefined.

- [ ] **Step 3: Add the `hourglass` symbol**

In `ClaudeSpyPackage/Sources/ClaudeSpyCommon/UI/Symbols.swift`, add next to `exclamationmarkTriangle` (`:47`):

```swift
    case hourglass = "hourglass"
```

- [ ] **Step 4: Create the helper**

Create `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/TrialStatusToolbarItem.swift`:

```swift
#if os(macOS)
    import ClaudeSpyNetworking
    import SwiftUI

    /// Pure mapping from license state to toolbar-badge appearance. Kept free of
    /// view state so the trial/expired/urgent rules are unit-testable. `nil` means
    /// render nothing. The `isPaired` gate lives in the view (it's app state).
    enum TrialBadgeAppearance: Equatable {
        /// `urgent` → orange (≤ 2 days left), else secondary grey.
        case trial(daysLeft: Int, urgent: Bool)
        case expired
    }

    func trialBadgeAppearance(
        state: LicenseStatus.State?,
        trialDaysLeft: Int?
    ) -> TrialBadgeAppearance? {
        switch state {
        case .trial:
            guard let days = trialDaysLeft else { return nil }
            return .trial(daysLeft: days, urgent: days <= 2)
        case .expired:
            return .expired
        default:
            return nil
        }
    }
#endif
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path ClaudeSpyPackage --filter TrialBadgeAppearanceTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyCommon/UI/Symbols.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/TrialStatusToolbarItem.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/TrialBadgeAppearanceTests.swift
git commit -m "mac: trial-badge appearance helper + hourglass symbol"
```

---

### Task 3: Mac — `TrialStatusToolbarItem` view (badge + popover)

Add the badge button and its buy/activate popover to the file created in Task 2. Uses the existing `LicenseManager` for all logic; adds no licensing logic.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/TrialStatusToolbarItem.swift`

**Interfaces:**
- Consumes: `trialBadgeAppearance(state:trialDaysLeft:)`, `TrialBadgeAppearance` (Task 2); `LicenseManager` (`status`, `trialDaysLeft`, `licenseKeyField`, `actionState`, `activate()`); `AppSettings.isPaired`; `URLOpener.openInDefaultBrowser(_:)`; `LicensingLinks.checkout`; `Symbols.hourglass`, `Symbols.exclamationmarkTriangle`.
- Produces: `struct TrialStatusToolbarItem: View`.

- [ ] **Step 1: Add the view to `TrialStatusToolbarItem.swift`**

Insert above the `#endif` in `TrialStatusToolbarItem.swift`, adding the imports `ClaudeSpyCommon` and `Dependencies` at the top of the file (keep the existing `ClaudeSpyNetworking` and `SwiftUI` imports):

```swift
    struct TrialStatusToolbarItem: View {
        @Environment(LicenseManager.self) private var licenseManager
        @Environment(AppSettings.self) private var settings
        @Dependency(URLOpener.self) private var urlOpener
        @State private var showingPopover = false

        var body: some View {
            if settings.isPaired,
               let appearance = trialBadgeAppearance(
                   state: licenseManager.status?.state,
                   trialDaysLeft: licenseManager.trialDaysLeft
               ) {
                Button {
                    showingPopover = true
                } label: {
                    Label(labelText(appearance), symbol: symbol(appearance))
                }
                .controlSize(.small)
                .tint(tint(appearance))
                .help(labelText(appearance))
                .accessibilityIdentifier("trial-status-badge")
                .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                    popoverContent(appearance)
                }
            }
        }

        private func labelText(_ appearance: TrialBadgeAppearance) -> String {
            switch appearance {
            case let .trial(daysLeft, _):
                "\(daysLeft) day\(daysLeft == 1 ? "" : "s") left"
            case .expired:
                "Subscription required"
            }
        }

        private func symbol(_ appearance: TrialBadgeAppearance) -> Symbols {
            switch appearance {
            case .trial: .hourglass
            case .expired: .exclamationmarkTriangle
            }
        }

        private func tint(_ appearance: TrialBadgeAppearance) -> Color {
            // `tint(_:)` needs a `Color` (not the `.secondary` ShapeStyle the
            // Settings Text uses); `.gray` is the Color equivalent for the
            // non-urgent pill.
            switch appearance {
            case let .trial(_, urgent): urgent ? .orange : .gray
            case .expired: .red
            }
        }

        @ViewBuilder
        private func popoverContent(_ appearance: TrialBadgeAppearance) -> some View {
            @Bindable var licenseManager = licenseManager
            VStack(alignment: .leading, spacing: 12) {
                Text(popoverHeadline(appearance))
                    .font(.headline)
                Text(popoverBody(appearance))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Buy a License…") {
                    urlOpener.openInDefaultBrowser(LicensingLinks.checkout)
                }
                .accessibilityIdentifier("trial-popover-buy")

                Divider()
                Text("or enter a license key")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("License Key", text: $licenseManager.licenseKeyField)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("trial-popover-license-key")

                if case let .error(message) = licenseManager.actionState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Activate") {
                        Task {
                            await licenseManager.activate()
                            if licenseManager.actionState == .idle { showingPopover = false }
                        }
                    }
                    .disabled(licenseManager.actionState == .working)
                    .accessibilityIdentifier("trial-popover-activate")
                }
            }
            .padding(16)
            .frame(width: 320)
        }

        private func popoverHeadline(_ appearance: TrialBadgeAppearance) -> String {
            switch appearance {
            case let .trial(daysLeft, _):
                "Free trial — \(daysLeft) day\(daysLeft == 1 ? "" : "s") left"
            case .expired:
                "Your trial has ended"
            }
        }

        private func popoverBody(_ appearance: TrialBadgeAppearance) -> String {
            switch appearance {
            case .trial:
                "The hosted relay needs a subscription after the 7-day free trial. "
                    + "Buy a license or enter a key to keep remote access after the trial."
            case .expired:
                "Remote access is paused until you subscribe. Buy a license or enter a "
                    + "license key to restore it."
            }
        }
    }
```

- [ ] **Step 2: Build the package to verify it compiles**

Run: `swift build --package-path ClaudeSpyPackage`
Expected: Build succeeds, 0 errors.

- [ ] **Step 3: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/TrialStatusToolbarItem.swift
git commit -m "mac: TrialStatusToolbarItem badge + buy/activate popover"
```

---

### Task 4: Mac — wire the badge into the toolbar, environment, and refresh-on-pair

Make the badge appear: place it left of the Disconnect capsule, inject `LicenseManager` into the panes window, and refresh license status when a viewer pairs so the badge shows promptly.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/MainView.swift:1765-1769` (toolbar), `:11-18` (environment/dependency)
- Modify: `ClaudeSpyServer/ClaudeSpyServerApp.swift:379-390` (panes window environment)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift` (`connectToNewlyPairedViewer`)

**Interfaces:**
- Consumes: `TrialStatusToolbarItem` (Task 3); `AppCoordinator.licenseManager` (`:36`); `LicenseManager.refreshStatus()`.

- [ ] **Step 1: Add the toolbar item left of the connection status**

In `MainView.swift`, in `toolbarContent` (`:1766`), add a new item BEFORE the existing `connectionStatusView` item (`:1767-1769`) so it renders to its left:

```swift
        ToolbarItem(placement: .automatic) {
            TrialStatusToolbarItem()
        }

        ToolbarItem(placement: .automatic) {
            connectionStatusView
        }
```

`MainView` already has `@Environment(AppSettings.self) private var settings` (`:13`). `TrialStatusToolbarItem` resolves `LicenseManager`, `AppSettings`, and `URLOpener` from the environment/dependencies itself, so no new properties are needed on `MainView`.

- [ ] **Step 2: Inject `LicenseManager` into the panes window**

In `ClaudeSpyServer/ClaudeSpyServerApp.swift`, add to the `Window("Panes", id: "panes")` modifier chain (after `:389`, alongside the other `.environment(...)` calls):

```swift
                .environment(coordinator.licenseManager)
```

- [ ] **Step 3: Refresh license status when a viewer pairs**

In `AppCoordinator.swift`, find `connectToNewlyPairedViewer(_:)` (the single method both `onViewerPaired` callbacks route through, `:2675` / `:2701`). At the end of that method's body, add:

```swift
            // A viewer just paired → the relay started this host's trial. Refresh
            // so the toolbar trial badge appears now rather than at the next poll.
            await licenseManager.refreshStatus()
```

(`connectToNewlyPairedViewer(_:)` is already `async` and runs on the `@MainActor` coordinator — both callback sites call it with `await` — so `await licenseManager.refreshStatus()` can be called directly.)

- [ ] **Step 4: Build the macOS app**

Build the `ClaudeSpyServer` scheme for macOS (use the `XcodeBuildTools:xcodebuild` skill).
Expected: Build succeeds, 0 errors.

- [ ] **Step 5: Manual verification**

Launch the app paired to the hosted (or staging) relay on a trial. Confirm: a pill "N days left" appears immediately left of the Disconnect button; it is grey with >2 days and orange at ≤2; clicking opens the popover with "Buy a License…", a license-key field, and "Activate". Confirm the badge is absent when not paired and when licensing is `.notRequired` (self-hosted).

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/MainView.swift \
        ClaudeSpyServer/ClaudeSpyServerApp.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift
git commit -m "mac: show trial-status badge in the panes toolbar + refresh on pairing"
```

---

### Task 5: E2E — prove the badge with a scenario

Add a deterministic license-state override for E2E and a scenario that exercises the badge + popover. Scenario authoring uses the repo's E2E skill.

**Files:**
- Modify: `ClaudeSpyServer/ClaudeSpyServerApp.swift` (E2E `prepareDependencies` block near `:173`, inside the `--e2e-test` branch)
- Create: an E2E scenario file under `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/` and register it in `allScenarios` (`ClaudeSpyE2ELib/Scenarios/ScenarioShortcuts.swift`)

**Interfaces:**
- Consumes: launch arg `--e2e-license-state <trial|expired|none>`; AX identifiers from Task 3 (`trial-status-badge`, `trial-popover-buy`, `trial-popover-license-key`, `trial-popover-activate`).

- [ ] **Step 1: Add the E2E license-state override**

In `ClaudeSpyServerApp.swift`, inside the `prepareDependencies { … }` block used for `--e2e-test` (near `:173`), add a `LicensingClient` override driven by a launch arg:

```swift
                // E2E: deterministic license status for the toolbar trial badge.
                let e2eLicenseState: LicenseStatus.State? = {
                    guard let idx = CommandLine.arguments.firstIndex(of: "--e2e-license-state"),
                          idx + 1 < CommandLine.arguments.count
                    else { return nil }
                    return LicenseStatus.State(rawValue: CommandLine.arguments[idx + 1])
                }()
                if let e2eLicenseState {
                    $0[LicensingClient.self] = LicensingClient(
                        activate: { _, _, _, _ in LicenseStatus(state: .active) },
                        deactivate: { _, _ in },
                        status: { _, _ in
                            LicenseStatus(
                                state: e2eLicenseState,
                                // Trial badge shows "5 days left" deterministically.
                                expiresAt: e2eLicenseState == .trial
                                    ? Date().addingTimeInterval(5 * 86_400) : nil
                            )
                        }
                    )
                }
```

Ensure `ClaudeSpyNetworking` and the `LicensingClient` type are in scope in this file (add imports if the build reports them missing).

- [ ] **Step 2: Author the scenario with the E2E skill**

Invoke the `e2e-for-feature` skill to generate a scenario that:
- launches the host app with `--e2e-test --e2e-license-state trial` and a **paired** state (reuse the existing Remote Access / pairing E2E seed used by other remote scenarios);
- waits for `trial-status-badge` (macWaitForElement) and screenshots the toolbar showing "5 days left";
- clicks `trial-status-badge`, waits for `trial-popover-buy` / `trial-popover-license-key` / `trial-popover-activate`, and screenshots the popover;
- adds a second run (or step) with **no pairing** asserting `trial-status-badge` is absent.

Register the scenario in `allScenarios` (`ScenarioShortcuts.swift`). Follow `docs/e2e-testing.md` and the `feedback_e2e-test-patterns` / `project_e2e-runs-from-agent-sessions` memories (no `compare:false`; verify baselines visually; run 2–3× locally before pushing; let CI generate baselines).

- [ ] **Step 3: Run the scenario locally**

Run: `./scripts/e2e-test.sh <scenario-name>` (per `docs/e2e-testing.md`).
Expected: PASS; screenshots show the badge with the countdown and the populated popover, and the badge absent when unpaired. Verify every screenshot visually.

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyServer/ClaudeSpyServerApp.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/
git commit -m "e2e: trial-status toolbar badge + popover scenario"
```

---

## Post-implementation chores

After the feature lands (the `gh pr create` hook will also remind you — see `docs/repo-hooks.md`):

- **Docs:** update `docs/superpowers/specs/2026-07-13-hosted-relay-monetization-design.md` (and CLAUDE.md's #392 line) to note that the trial now starts at viewer pairing (`complete`), not register/first-touch, and that the panes toolbar shows a trial/expired badge.
- **Task 18 gate:** unrelated to this change, but the monetization enablement gates (real `LicensingLinks` URLs, LS dashboard) still live in the plan's Task 18 checklist — no change here (`LicensingLinks.checkout` is already a real URL).
- **Staging:** exercise end-to-end against `staging.gallager.app` (licensing enabled, test mode) via `scripts/deploy.sh staging`.
