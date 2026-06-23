# Task 18 Report: Sidecar E2E Scenarios + Orchestrator Fixture Staging

## Status: DONE_WITH_CONCERNS

## What Was Delivered

### Priority 1 — Orchestrator Fixture Staging (MUST) ✅

Added `TestStep.macStageSidecarFixture(id:instance:)` step that:

1. Derives `gallagerRoot = parent of gallagerStateRootPath(for: instance)` (mirrors `GallagerPaths(stateRootOverride:)` logic).
2. Creates `<gallagerRoot>/plugins/<id>/bin/` and copies the built `EchoPluginSidecar` binary to `bin/sidecar` (chmod 0o755).
3. Writes a minimal `plugin.json` with `"runtime": "sidecar"` and `"sidecar": { "executable": "bin/sidecar" }`.
4. Binary locator walks up from `#file` to find `Package.swift`, then probes `.build/debug/EchoPluginSidecar` then `.build/release/EchoPluginSidecar` — identical strategy to `EchoSidecarTestSupport.locateEchoSidecarBinary`.

### Priority 2 — `PluginSidecarIngressScenario` (MUST) ✅

`PluginSidecarIngressScenario.swift` — the headline proof:
- Stages `echo-sidecar` before any `launchMacApp` step (inside `ClaudeSessionsShowScenario`).
- Sends a `doneWorking` `EchoDirective` with `projectPath "/Users/test/SidecarLab"` via `macSendHookEvent(pluginID: "echo-sidecar", ...)`.
- Asserts iOS shows "SidecarLab", then screenshots.
- Registered in `allScenarios` as `PluginSidecarIngressScenario.scenario`.

### Priority 3 — `PluginSidecarResponseRoundTripScenario` (best-effort) ✅

`PluginSidecarResponseRoundTripScenario.swift` — mirrors `EchoResponseRoundTripScenario`:
- Stages `echo-sidecar`, pairs, drives an `awaitingPermission` form through the sidecar.
- iOS taps the deny-with-feedback field, types "sidecar-roundtrip-marker", taps Send.
- Asserts the marker lands in the tmux pane via `tmuxCapturePaneContent` + `assertStoredContains`.
- Registered in `allScenarios`.

### Priority 4 — Crash Scenarios (partial best-effort) ✅/⚠️

`PluginCrashRestartScenario.swift` — sends `abort: true` directive, waits 4 s for the supervisor's 1 s backoff restart, then sends a normal frame and asserts "SidecarRestart" appears on iOS. Registered in `allScenarios`.

**`PluginCrashLoopDisableScenario` — NOT delivered (as permitted by task):** The `onAutoDisabled` callback in `SidecarSupervisor` is defined (`setOnAutoDisabled`) but wired to no UI anywhere in `AppCoordinator` or any Settings view. Without a Settings banner / "Re-enable" button in the macOS app, the scenario would have no observable UI to assert against. Adding that UI wiring is a follow-up task.

## Compile Result

`swift build --target ClaudeSpyE2E`: **0 errors, 0 warnings** ✅

`swift test` (full unit suite): **1094 tests passed** ✅

## E2E Run Outcome — Harness Blocked

**Command run:** `./scripts/e2e-test.sh --scenario "Plugin Sidecar Ingress Round Trip"`

**Blocker:** The Xcode build step (`xcodebuild` for ClaudeSpyServer) fails with **9 pre-existing SwiftLint violations** in files that were already on the `plugin-system-v2-sidecar` branch before my changes:

- `SidecarTransport.swift:125` — `statement_position` (else/catch not on same line)
- `SidecarStderrLog.swift:30` — `optional_data_string_conversion`
- `SidecarWireTests.swift` (5 violations) — `optional_data_string_conversion`
- `SidecarPluginCoreTests.swift:232` — `force_try`
- `SidecarCapabilitiesTests.swift:22` — `force_try`

Verified by running `./scripts/e2e-test.sh --scenario "Plugin Sidecar Ingress Round Trip"` with my stash removed — identical 9 failures. These are pre-existing violations from tasks 5–17 of this branch, not introduced by Task 18.

## Crash-Loop-Disable Banner — Deferred

`PluginCrashLoopDisableScenario` requires a Settings banner with stderr log + "Re-enable" button. The `SidecarSupervisor.setOnAutoDisabled(_:)` callback exists but is **not wired to any AppCoordinator state or Settings view**. Adding that wiring (AppCoordinator stores `[String: [String]]` disabled-plugin-stderr, SettingsView shows a banner per disabled plugin) is a follow-up task for whoever unblocks the SwiftLint violations.

## Files Changed

**Modified:**
- `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/DSL/TestScenario.swift` — added `macStageSidecarFixture(id:instance:)` step case
- `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/DSL/TestStep+Scope.swift` — added scope for new step
- `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/TestOrchestrator.swift` — added `stageSidecarFixture` + `locateEchoSidecarBinary` helpers; wired `macStageSidecarFixture` in `executeStep`
- `ClaudeSpyPackage/Sources/ClaudeSpyE2E/ClaudeSpyE2ECommand.swift` — registered 3 new scenarios in `allScenarios`

**Created:**
- `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/PluginSidecarIngressScenario.swift`
- `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/PluginSidecarResponseRoundTripScenario.swift`
- `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/PluginCrashRestartScenario.swift`

## Concerns

1. **Pre-existing SwiftLint violations on the branch** block `e2e-test.sh` (the Xcode build step). The scenarios compile and unit tests pass; the harness just cannot reach the E2E run stage. These need to be fixed before any E2E scenario on this branch can be run.
2. **Crash-loop-disable scenario** (`PluginCrashLoopDisableScenario`) requires UI wiring for the disabled-plugin banner in Settings — deferred as a follow-up.
3. **`PluginCrashRestartScenario` uses a fixed 4 s wait** (no observable signal for supervisor restart completion). This is intentional and documented in the scenario.

---

## UPDATE — E2E Run Re-attempt (after SwiftLint unblock, commit 208187ba)

### Status: DONE — all three delivered scenarios PASS

The coordinator's SwiftLint unblock (208187ba) let the Xcode build complete, so
the harness reached the E2E run stage. Two real defects surfaced and were fixed:

**Fix 1 — robust EchoPluginSidecar locator (TestOrchestrator).**
The original `#file`-walk locator returned `Searched: []` under the Xcode-built
coordinator (remapped source paths → never found `Package.swift`), so
`macStageSidecarFixture` failed at step 1. Rewrote `locateEchoSidecarBinary` to
assemble candidate `ClaudeSpyPackage` roots from `CLAUDESPY_PACKAGE_ROOT`, the
`#file` walk, AND the current working directory (the repo root `e2e-test.sh`
launches the coordinator from), probing `.build/{debug,release}/EchoPluginSidecar`
in each. NOTE: `EchoPluginSidecar` is built by `swift build` (not the Xcode
workspace), so it must exist under `ClaudeSpyPackage/.build/` — the harness/CI
must run `swift build` (or the package build) before the sidecar scenarios.

**Fix 2 — SidecarPluginCore transport refresh on crash-restart.**
The crash-restart scenario initially failed at step 49: after the abort the
supervisor *did* restart the child, but `SidecarPluginCore` kept its cached
`transport` pointing at the dead pipe, so post-restart `translate_event`
silently returned nil. Added a `SidecarSupervisor.setOnRestart` callback
(symmetric with the existing `onAutoDisabled`) that hands the fresh transport to
the core; the core's `adoptTransport` swaps it in and replays the `initialize`
handshake. This is a genuine product-code fix in the supervisor↔core seam, not a
test-only workaround.

### E2E commands run + results

- `./scripts/e2e-test.sh --scenario "Plugin Sidecar Ingress Round Trip"`
  → **PASS** (45 steps, 38 s). Baselines generated (7 screenshots).
- `./scripts/e2e-test.sh --skip-build --scenario "Plugin Sidecar Response Round Trip"`
  → **PASS** (58 steps, 49 s). deny-with-feedback marker landed in the pane.
- `./scripts/e2e-test.sh --scenario "Plugin Sidecar Crash Restart"`
  → **PASS** (50 steps, 48 s) after Fix 2. Post-restart frame surfaces on iOS.

Full unit suite re-run after Fix 2: **1094 passed**. Sidecar
supervisor/core/integration filter: **8 passed**.

### Baselines

First runs generated baselines under `E2ETests/plugin-sidecar-*/`. Per the
e2e-testing skill these are left UNTRACKED and NOT committed (CI regenerates
them).

### Commits

- `29bcf12f` — sidecar E2E scenarios + orchestrator fixture staging
- `13ae1063` — robust sidecar locator + refresh core transport on restart

### PluginCrashLoopDisableScenario — still deferred

Unchanged from above: requires a Settings disabled-plugin banner UI wired to
`SidecarSupervisor.onAutoDisabled`, which does not exist. Follow-up.

---

## Fix wave 1 — Harden sidecar restart re-initialize

### Changes

**Fix 1 — `adoptTransport` silent encode drop (`SidecarPluginCore.swift`)**

Rewrote `adoptTransport(_:)` to encode the env via a guarded `let` chain instead
of a nested `try? JSONValue(encoding: try? PluginEnvWire(env))` argument. The old
code passed `nil` as the RPC param on any encode failure with no diagnostic. The
new code:
- Sets `transport = t` unconditionally as the first line (transport swap is
  always safe regardless of env availability).
- Uses a `guard let env = lastEnv, let wire = try? PluginEnvWire(env), let payload
  = try? JSONValue(encoding: wire)` chain; on any failure emits
  `logger.warning("adoptTransport: could not encode env …")` and returns.
- Wraps the RPC call in `do/catch`, emitting a warning if the `initialize` RPC
  itself throws — no silent swallow.

**Fix 2 — Structured transport adoption (`SidecarSupervisor.swift` +
`SidecarPluginCore.swift`)**

Changed `onRestartCallback` from `(@Sendable (SidecarTransport) -> Void)?` to
`(@Sendable (SidecarTransport) async -> Void)?`. Consequences:
- `setOnRestart` now accepts an `async` closure.
- `fireOnRestart` is now `async` and `await`s the callback, so the backoff task
  cannot proceed past `fireOnRestart(newTransport)` until `adoptTransport` has
  completed and the core's `transport` field already points at the new pipe.
- In `SidecarPluginCore.initialize`, the `setOnRestart` closure no longer wraps
  in an unstructured `Task { await self?.adoptTransport(t) }` — it `await`s
  directly: `await self?.adoptTransport(newTransport)`.

### Crash policy unchanged

- The `n >= 4` auto-disable path, the 60 s sliding window, the backoff schedule,
  the `.crashed` / `.disabled` state guards, and the `stopping` guard are all
  untouched.
- `onRestart` still fires only on the crash-restart path (after a successful
  `startTransport`), never from `stop()` or `reEnable`.

### Verification

- `swift test` (full unit suite): **1094 passed, 0 failed, 0 errors, 0 warnings**.
- SwiftLint (`--quiet`) on both changed files: **0 violations**.
