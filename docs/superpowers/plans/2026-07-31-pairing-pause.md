# Pairing Pause (relay maintenance switch) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An env-var-driven relay switch (`PAIRING_PAUSED_MESSAGE`) that refuses new pairing registrations with an operator-supplied message, requiring zero macOS/iOS client changes.

**Architecture:** The relay reads `PAIRING_PAUSED_MESSAGE` once at boot in `configure(_:env:)` and stores the trimmed value in `app.storage` (same pattern as `METRICS_TOKEN`/`MIN_CLIENT_VERSION`). `PairingController.registerPairingCode` returns a normal 200 `PairingResponse.error(ErrorInfo(message:code:))` when paused — both shipped clients already render `errorInfo.message` verbatim for unrecognized codes, so no client work is needed. A metrics counter records blocked attempts.

**Tech Stack:** Swift 6.3, Vapor, Swift Testing + VaporTesting.

**Spec:** `docs/superpowers/specs/2026-07-31-pairing-pause-design.md`

## Global Constraints

- Env var name: `PAIRING_PAUSED_MESSAGE`. Absent, empty, or whitespace-only (after `.whitespacesAndNewlines` trim) → feature fully OFF, zero behavior change. Set → the trimmed value is the exact user-facing message.
- Error code constant: `PAIRING_PAUSED` (as `ErrorMessage.pairingPausedCode`).
- Gate scope: `POST /api/pairing/register` ONLY. `complete`, `status`, `delete`, and all WebSocket traffic must be untouched.
- Prometheus counter name: `claudespy_paused_pairing_attempts_total`.
- NEVER `setenv` in tests — inject config via `configure(app, env: [...])` (see `EnvSerializedSuites.swift` doc comment for why).
- All server test suites that boot a full Vapor app must be nested under `EnvSerializedSuites` (via `extension EnvSerializedSuites { @Suite(..., .serialized) ... }`).
- Build/test via the XcodeBuildTools `swift-package` skill, never raw `swift test` typed without it. The commands below show the exact invocation the skill should run, from the repo root.
- A repo-scoped hook auto-runs swiftformat on edited Swift files — no manual formatting steps needed.

---

### Task 1: `pausedPairingAttemptsTotal` counter in MetricsService

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/MetricsService.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsServiceTests.swift`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `MetricsService.incrementPausedPairingAttempts()` (actor method, no args, no return) and `MetricsService.pausedPairingAttemptsTotal: Int` (`private(set)` actor property). Task 3's controller gate calls the increment; Task 3's tests read the property.

- [ ] **Step 1: Write the failing test**

Append inside `struct MetricsServiceTests` in `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsServiceTests.swift` (after the `licensingCounters` test):

```swift
    @Test("incrementPausedPairingAttempts increments by one and renders")
    func pausedPairingAttempts() async {
        let service = MetricsService()
        await service.incrementPausedPairingAttempts()
        await service.incrementPausedPairingAttempts()
        #expect(await service.pausedPairingAttemptsTotal == 2)

        let snapshot = MetricsSnapshot(
            activePairs: 0,
            hostsConnected: 0,
            viewersConnected: 0,
            uptimeSeconds: 0
        )
        let output = await service.render(snapshot: snapshot, buildVersion: "1.0-test")
        #expect(output.contains("claudespy_paused_pairing_attempts_total 2"))
        #expect(output.contains("# TYPE claudespy_paused_pairing_attempts_total counter"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path ClaudeSpyPackage --filter MetricsServiceTests`
Expected: compile FAILURE — `value of type 'MetricsService' has no member 'incrementPausedPairingAttempts'` (a compile error is this step's "failing test").

- [ ] **Step 3: Write minimal implementation**

In `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/MetricsService.swift`:

Add the property after `private(set) var blockedHostAttemptsTotal = 0` (line 21):

```swift
    private(set) var pausedPairingAttemptsTotal = 0
```

Add the method after `incrementBlockedHostAttempts()` (lines 47–49):

```swift
    func incrementPausedPairingAttempts() {
        pausedPairingAttemptsTotal &+= 1
    }
```

In `render(snapshot:buildVersion:)`, add after the `claudespy_blocked_host_attempts_total` lines (lines 79–81):

```swift
        lines.append("# HELP claudespy_paused_pairing_attempts_total Pairing registrations refused by the pairing-pause switch.")
        lines.append("# TYPE claudespy_paused_pairing_attempts_total counter")
        lines.append("claudespy_paused_pairing_attempts_total \(pausedPairingAttemptsTotal)")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path ClaudeSpyPackage --filter MetricsServiceTests`
Expected: PASS (all MetricsServiceTests, including the new one).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/MetricsService.swift ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/MetricsServiceTests.swift
git commit -m "Add paused-pairing-attempts counter to relay metrics"
```

---

### Task 2: Read `PAIRING_PAUSED_MESSAGE` into app storage at boot

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/configure.swift`
- Create: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/PairingPauseTests.swift`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `Application.pairingPausedMessage: String?` (internal computed accessor; `nil` = not paused, non-nil = the trimmed user-facing message). Task 3's controller gate reads this.

- [ ] **Step 1: Write the failing tests**

Create `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/PairingPauseTests.swift`. The suite is nested under `EnvSerializedSuites` (defined in `EnvSerializedSuites.swift` in the same directory) because it boots full Vapor apps. `withApp` comes from `VaporTesting`. The helper injects a temp `DATA_DIRECTORY` so no state files land in a shared location (mirrors `LicenseEndpointTests.withDisabledLicensingApp`).

```swift
import ClaudeSpyNetworking
import Foundation
import Testing
import VaporTesting
@testable import ClaudeSpyExternalServerLib

/// Tests for the PAIRING_PAUSED_MESSAGE maintenance switch (spec:
/// docs/superpowers/specs/2026-07-31-pairing-pause-design.md).
///
/// Nested under `EnvSerializedSuites` to bound how many full Vapor apps boot
/// concurrently. Config is injected via `configure(_:env:)` — never `setenv`
/// (see that container's doc comment).
extension EnvSerializedSuites {
    @Suite("Pairing pause", .serialized)
    struct PairingPauseTests {
        /// Boots the relay with the given extra env on top of a hermetic
        /// temp DATA_DIRECTORY (licensing stays disabled: no LS ids injected).
        private func withPauseApp(
            env extraEnv: [String: String],
            _ test: (Application) async throws -> Void
        ) async throws {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("claudespy-pairing-pause-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            var env = extraEnv
            env["DATA_DIRECTORY"] = tempDir.path
            try await withApp(configure: { app in
                try await configure(app, env: env)
            }, test)
        }

        @Test("PAIRING_PAUSED_MESSAGE is trimmed into app storage")
        func messageStored() async throws {
            try await withPauseApp(env: ["PAIRING_PAUSED_MESSAGE": "  Paused for maintenance.\n"]) { app in
                #expect(app.pairingPausedMessage == "Paused for maintenance.")
            }
        }

        @Test("Absent PAIRING_PAUSED_MESSAGE leaves the relay unpaused")
        func messageAbsent() async throws {
            try await withPauseApp(env: [:]) { app in
                #expect(app.pairingPausedMessage == nil)
            }
        }

        @Test("Whitespace-only PAIRING_PAUSED_MESSAGE leaves the relay unpaused")
        func messageBlank() async throws {
            try await withPauseApp(env: ["PAIRING_PAUSED_MESSAGE": "   \n"]) { app in
                #expect(app.pairingPausedMessage == nil)
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter PairingPauseTests`
Expected: compile FAILURE — `value of type 'Application' has no member 'pairingPausedMessage'`.

- [ ] **Step 3: Write minimal implementation**

In `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/configure.swift`:

Insert after the `minClientVersionGate` block (after line 68, before the `APNS_ENVIRONMENT` comment):

```swift
    // Optional pairing-pause maintenance switch: when PAIRING_PAUSED_MESSAGE is
    // set (non-empty after trimming), new pairing registrations are refused and
    // the value is shown verbatim in the clients' pairing UI. Existing pairings
    // and all relay traffic are untouched. Absent/empty → off (the default).
    let pairingPausedMessage = (env["PAIRING_PAUSED_MESSAGE"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    app.storage[PairingPausedMessageKey.self] = pairingPausedMessage.isEmpty ? nil : pairingPausedMessage
    if !pairingPausedMessage.isEmpty {
        app.logger.info("Pairing PAUSED — new pairing registrations will be refused")
    }
```

Add the storage key in the `// MARK: - Storage Keys` section, after `MinClientVersionGateKey` (line 198–202):

```swift
struct PairingPausedMessageKey: StorageKey {
    /// `nil` means pairing registration is not paused (no `PAIRING_PAUSED_MESSAGE`
    /// in env); otherwise the operator's user-facing message.
    typealias Value = String?
}
```

Add the accessor in the internal `extension Application` block, after the `minClientVersionGate` accessor (lines 251–255):

```swift
    /// Non-nil when the relay is paused for new pairings (`PAIRING_PAUSED_MESSAGE`
    /// set in env); the value is the user-facing message returned to hosts.
    var pairingPausedMessage: String? {
        storage[PairingPausedMessageKey.self] ?? nil
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ClaudeSpyPackage --filter PairingPauseTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/configure.swift ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/PairingPauseTests.swift
git commit -m "Read PAIRING_PAUSED_MESSAGE into relay app storage at boot"
```

---

### Task 3: Pause gate in `registerPairingCode` + shared error code

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/WebSocketMessage.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/PairingController.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/PairingPauseTests.swift`

**Interfaces:**
- Consumes: `Application.pairingPausedMessage: String?` (Task 2), `MetricsService.incrementPausedPairingAttempts()` / `pausedPairingAttemptsTotal` (Task 1).
- Produces: `ErrorMessage.pairingPausedCode` (`public static let`, value `"PAIRING_PAUSED"`) in `ClaudeSpyNetworking` — a shared wire constant; clients never branch on it (they render unknown codes' messages verbatim, which is the whole point).

- [ ] **Step 1: Write the failing tests**

Append inside `struct PairingPauseTests` in `ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/PairingPauseTests.swift` (after the `messageBlank` test). The `testPublicKey` constant and the `PairingRegistration`/`PairingCompletion` initializer shapes mirror `LicenseEndpointTests.swift` in the same directory.

```swift
        private static let testPublicKey = "dGVzdC1tYWMtcHVibGljLWtleS0wMTIzNDU2Nzg5MDEyMw=="

        @Test("Paused relay refuses register with the operator's message and PAIRING_PAUSED code")
        func registerRefusedWhenPaused() async throws {
            try await withPauseApp(env: ["PAIRING_PAUSED_MESSAGE": "Paused for maintenance."]) { app in
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
                    #expect(info.message == "Paused for maintenance.")
                    #expect(info.code == ErrorMessage.pairingPausedCode)
                }
                #expect(await app.metricsService.pausedPairingAttemptsTotal == 1)
                // The refused registration must not have created a redeemable
                // code: completing it fails.
                try await app.testing().test(.POST, "api/pairing/complete", beforeRequest: { req in
                    try req.content.encode(PairingCompletion(
                        pairingCode: "ABC123", deviceId: "viewer-1", deviceName: "iPhone",
                        publicKey: Self.testPublicKey, publicKeyId: "vkey-1"
                    ))
                }) { res in
                    let response = try res.content.decode(PairingResponse.self)
                    guard case .error = response else {
                        Issue.record("Expected .error for a never-registered code, got \(response)")
                        return
                    }
                }
            }
        }

        @Test("Register works normally when the relay is not paused")
        func registerNormalWhenNotPaused() async throws {
            try await withPauseApp(env: [:]) { app in
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
                #expect(await app.metricsService.pausedPairingAttemptsTotal == 0)
            }
        }

        @Test("Complete still succeeds while paused (register-only scope)")
        func completeUnaffectedByPause() async throws {
            try await withPauseApp(env: ["PAIRING_PAUSED_MESSAGE": "Paused for maintenance."]) { app in
                // Seed a pending code directly on the service, modeling a code
                // registered just before the pause took effect.
                _ = await app.pairingService.registerCode(
                    code: "ABC123",
                    deviceId: "host-1",
                    deviceName: "My Mac",
                    username: "tester",
                    publicKey: Self.testPublicKey,
                    publicKeyId: "key-1"
                )
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
            }
        }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ClaudeSpyPackage --filter PairingPauseTests`
Expected: compile FAILURE — `type 'ErrorMessage' has no member 'pairingPausedCode'`.

- [ ] **Step 3: Write minimal implementation**

In `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/WebSocketMessage.swift`, add after the `clientTooOld(minVersion:)` factory method's closing brace (the method starting at line 175):

```swift
    /// Error code returned by the relay's pairing-pause maintenance switch
    /// (operator-set `PAIRING_PAUSED_MESSAGE`) when new pairing registrations
    /// are refused. The accompanying message is the operator's own text;
    /// clients show it verbatim.
    public static let pairingPausedCode = "PAIRING_PAUSED"
```

In `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/PairingController.swift`, add at the very top of `registerPairingCode(req:)`, before the `req.content.decode` line (line 19) — the gate needs nothing from the body, so it runs first:

```swift
        // Operator maintenance switch (PAIRING_PAUSED_MESSAGE): refuse new
        // pairing registrations with the operator's message. Delivered as a
        // normal `.error` response body — both clients render an unrecognized
        // code's message verbatim, so this needs no client-side support.
        if let pausedMessage = req.application.pairingPausedMessage {
            await req.application.metricsService.incrementPausedPairingAttempts()
            return .error(ErrorInfo(
                message: pausedMessage,
                code: ErrorMessage.pairingPausedCode
            ))
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ClaudeSpyPackage --filter PairingPauseTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Run the networking tests too (shared model touched)**

Run: `swift test --package-path ClaudeSpyPackage --filter ClaudeSpyNetworkingTests`
Expected: PASS (the new constant is additive; nothing should break).

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/WebSocketMessage.swift ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Routes/PairingController.swift ClaudeSpyPackage/Tests/ClaudeSpyExternalServerTests/PairingPauseTests.swift
git commit -m "Refuse new pairing registrations when PAIRING_PAUSED_MESSAGE is set"
```

---

### Task 4: Operator docs, env examples, full-suite verification

**Files:**
- Modify: `ClaudeSpyPackage/.env.example`
- Modify: `ClaudeSpyPackage/.env.staging.example`
- Modify: `docs/self-hosting.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the behavior shipped in Tasks 1–3 (documentation only — exact names `PAIRING_PAUSED_MESSAGE`, `PAIRING_PAUSED`, `claudespy_paused_pairing_attempts_total`).
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Add the `.env.example` block**

In `ClaudeSpyPackage/.env.example`, insert a new section between the `MIN_CLIENT_VERSION_REJECT_UNKNOWN` block and the `MONITORING (OPTIONAL)` header (i.e. after the commented `# MIN_CLIENT_VERSION_REJECT_UNKNOWN=false` line):

```bash
# ============================================================================
# PAIRING PAUSE (OPTIONAL)
# ============================================================================
# Maintenance switch: when set (non-empty), the relay refuses NEW pairing
# registrations and this exact text is shown in the Mac's pairing UI. Existing
# pairings, WebSocket relay traffic, status polling, and unpairing are all
# untouched. Leave unset (the default) to accept pairings normally.
# Applying a change requires a container recreate: docker compose up -d
# PAIRING_PAUSED_MESSAGE="Pairing is temporarily paused while we migrate servers. Existing pairings are unaffected — please try again in a few hours."
```

- [ ] **Step 2: Add the `.env.staging.example` entry**

In `ClaudeSpyPackage/.env.staging.example`, insert after the commented `# MIN_CLIENT_VERSION_REJECT_UNKNOWN=false` line (staging file keeps entries terse, matching its MIN_CLIENT_VERSION style):

```bash
# Pairing pause (optional). Set to refuse NEW pairing registrations with this
# message (shown verbatim in the Mac's pairing UI); existing pairings unaffected.
# PAIRING_PAUSED_MESSAGE=
```

- [ ] **Step 3: Update `docs/self-hosting.md`**

Two edits:

(a) In the `### Environment Variables` code block, insert after the `MIN_CLIENT_VERSION_REJECT_UNKNOWN=false  # also refuse clients that report no version` line:

```bash

# Pairing pause (optional — leave unset to accept new pairings)
PAIRING_PAUSED_MESSAGE=        # when set, refuse NEW pairing registrations and show this message
```

(b) Add a new subsection after the `### Minimum Client Version Gate (Optional)` section (immediately before the `## Reverse Proxy Setup` heading):

```markdown
### Pairing Pause (Optional)

A maintenance switch for server migrations or overload: set `PAIRING_PAUSED_MESSAGE` to any non-empty text and the relay refuses **new** pairing registrations, returning that exact text as the error message — it appears verbatim in the Mac's pairing UI (red error state with a "Try Again" button). Existing pairings are completely unaffected: WebSocket relay traffic, status polling, and unpairing all keep working, and a viewer holding an already-registered code can still complete it.

- Leave it unset (the default) and pairing works normally — self-hosting needs no configuration here.
- The value is read at boot, so applying a change requires a container recreate (`docker compose up -d`).
- Refused attempts are counted in the `claudespy_paused_pairing_attempts_total` metric.
- On the wire this is a normal pairing `error` response with code `PAIRING_PAUSED`; no minimum client version is required.
```

- [ ] **Step 4: Update `CLAUDE.md`**

In the `**Self-hosting:**` bullet of the Reference Docs list, after the sentence ending "(separate from the peer-to-peer `peerHello` version handshake, which the relay can't read). Enforced in `WebSocketController` for host+viewer connects; unknown-version (pre-reporting) clients allowed unless `rejectUnknown`." append:

```markdown
 Also documents the **pairing-pause maintenance switch**: `PAIRING_PAUSED_MESSAGE` env var (default-off) makes `PairingController.registerPairingCode` refuse NEW pairings with the operator's text as a normal `.error(ErrorInfo)` (code `PAIRING_PAUSED`) — zero client changes because both apps render unrecognized codes' messages verbatim; register-only (complete/status/WS untouched), counted in `claudespy_paused_pairing_attempts_total`.
```

- [ ] **Step 5: Run the full external-server test suite**

Run: `swift test --package-path ClaudeSpyPackage --filter ClaudeSpyExternalServerTests`
Expected: PASS — all suites, including the new PairingPauseTests and MetricsServiceTests additions.

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/.env.example ClaudeSpyPackage/.env.staging.example docs/self-hosting.md CLAUDE.md
git commit -m "Document the PAIRING_PAUSED_MESSAGE pairing-pause switch"
```
