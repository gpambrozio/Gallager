# Coding-Agent Plugin System — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Gallager's built-in support for specific coding agents (Claude Code, Codex) with a generic plugin system, by extracting today's agent code paths into bundled sidecar plugins driven by a JSON-RPC protocol.

**Architecture:** New SPM packages under `ClaudeSpyPackage/Sources/` provide a shared protocol (`GallagerPluginProtocol`), a Mac-only runtime that supervises sidecar processes (`ClaudeSpyPluginRuntime`), and two reference plugins (`ClaudeCodePluginCore` + `ClaudeCodePluginSidecar`, `CodexPluginCore` + `CodexPluginSidecar`). Each sidecar listens on a Unix socket for hook payloads, translates them into a tiny agent-blind `PluginEvent` envelope, and drives all per-agent UI and key handling. The Mac app loses every `CodingAgent` switch; iOS loses every `HookAction`-shaped view and instead consumes `agent_session_status`, `agent_response_request`, and `plugin_presentations` messages forwarded by the Mac.

**Tech Stack:** Swift 6.1+ Concurrency, swift-testing, Point-Free Dependencies, JSON-RPC LSP framing, FSEvents, Unix domain sockets, Vapor (relay only).

**Scope reference:** This plan implements `docs/superpowers/specs/2026-05-24-coding-agent-plugin-system-design.md` as a single flag-day release (Section 11 of the spec). Section numbers below (e.g. "Spec §6.1") refer to that spec — every task should keep that file open as the source of truth for type shapes, contracts, and field semantics. Where the spec already pins exact code (enums, schemas), this plan does not repeat it; tasks transcribe directly from the spec.

---

## File Structure

New packages (under `ClaudeSpyPackage/Sources/`):

```
GallagerPluginProtocol/        Cross-platform Codable types: JSON-RPC envelope, PluginEvent,
                               PluginManifest, AppAction, RPC method names. Used by sidecars
                               AND the Mac runtime. No iOS dep; lives under macOnlyDependencies
                               so the Linux relay build skips it.
ClaudeSpyPluginRuntime/        Mac-only. PluginRegistry, SidecarSupervisor, JSONRPCConnection,
                               PluginEventDispatcher, PluginRouter, IngressBroker, AssetCache,
                               SettingsFormRenderer.
ClaudeCodePluginCore/          Mac-only library. ClaudeProjectScanner, ClaudeBinaryLocator,
                               ClaudeCodeEventTranslator, ClaudeCodeInstaller,
                               ClaudeCodeKeystrokeBuilder, ClaudeCodeTools.
ClaudeCodePluginSidecar/       Mac-only executable target. JSON-RPC server, ingress socket
                               listener, FSEvents watcher.
CodexPluginCore/               Mac-only library. CodexProjectScanner, CodexPluginInstaller,
                               CodexEventTranslator, CodexKeystrokeBuilder.
CodexPluginSidecar/            Mac-only executable target.
```

Existing packages that get touched:

```
ClaudeSpyNetworking/   + AgentSession (renamed from ClaudeSession), AgentProject (renamed from ClaudeProjectInfo),
                         AgentResponseRequest, AgentResponse, AgentSessionStatusUpdate, PluginPresentation,
                         AppAction. Wire-version bump.
                       − CodingAgent, HookEvent, HookAction, every *Body struct, ClaudeCodeTools, HookModels.
ClaudeSpyCommon/       − HookActionUI.swift (string table moves into ClaudeCodePluginCore).
ClaudeSpyServerFeature/   PluginManager, PluginIngressSocketServer (in IngressBroker form). Migrations.
                       − HookServerService, HookModels.swift (Hooks/), CodexPluginInstaller,
                         CodexProjectScanner, ClaudeProjectScanner, ClaudeBinaryLocator,
                         CodexPluginInstallerRow, agent-specific PluginSetupView fragments.
ClaudeSpyFeature/      − EventRowView, AskUserQuestionKeystrokes, all HookAction decoding.
                       + Routing for AgentResponseRequest, agent_session_status,
                         plugin_presentations; presentation cache.
ClaudeSpyE2ELib/       + MacAppPluginIngressClient, --gallager-state-root support,
                         EchoPlugin fixture, new DSL steps. Migrated scenarios.
plugin/                Repo-root folder is deleted. Bundled plugin trees move into
                       ClaudeSpyPackage/PluginBundles/<id>/ and Xcode build phase copies them
                       into Gallager.app/Contents/Resources/plugins/<id>/.
GallagerCLI/           + Plugin verbs (list/info/install/remove/enable/disable/update/call/logs).
```

The Linux relay (`ClaudeSpyExternalServer` / `ClaudeSpyExternalServerLib`) only needs to compile against `ClaudeSpyNetworking`. Plugin-runtime packages are guarded with `#if os(macOS)` in `Package.swift` so the Docker build skips them.

---

## Phased Order of Work

Each phase produces a buildable Mac app and runnable test suite when it lands; intermediate compilation breaks are allowed only within a single task. Phases roughly correspond to Section 11 of the spec.

| Phase | Tasks | Outcome |
|---|---|---|
| 1. Foundation types | 1–3 | New `ClaudeSpyNetworking` types + `GallagerPluginProtocol` package compile; legacy types still present. |
| 2. Plugin runtime scaffolding | 4–7 | `ClaudeSpyPluginRuntime` package compiles in isolation; unit tests cover registry, supervisor, JSON-RPC, dispatcher. |
| 3. Sidecar cores | 8–11 | Both `*PluginCore` packages compile; unit tests for scanners, installers, event translators, keystroke builders. |
| 4. Sidecar executables | 12–13 | `ClaudeCodePluginSidecar` + `CodexPluginSidecar` build as executables; build phase copies into Gallager.app/Contents/Resources/plugins/. |
| 5. App integration | 14–17 | `AppCoordinator` runs the runtime; old `CodingAgent` switches replaced; settings migrated; gallager CLI verbs ship. |
| 6. iOS migration | 18–20 | iOS consumes new wire types; `EventRowView` deleted; `ResponseViews` driven by `AgentResponseRequest`. |
| 7. Cleanup | 21 | All legacy types/files deleted; project still builds. |
| 8. E2E migration | 22–25 | EchoPlugin fixture; DSL updated; existing scenarios migrated; new scenarios pass. |
| 9. Validation | 26 | Full unit + E2E suite green; baselines updated; PR-ready. |

---

## Conventions for every task

- **TDD:** write failing tests first when the unit is logic (scanners, translators, dispatchers, builders). For pure scaffolding (target stub, file move) tests come after. The `superpowers:test-driven-development` skill is implicit in every task.
- **Commit cadence:** at minimum one commit per task. Many tasks list several commits.
- **Build:** before claiming a task done, ensure `swift build` (or `xcodebuild` for the Mac/iOS app) is green for every affected target. Use the `XcodeBuildTools:xcodebuild` and `XcodeBuildTools:swift-package` skills.
- **Spec references:** when a step says "implement per Spec §X.Y", consult that exact section. Do not invent shape; transcribe.
- **No backward compat:** legacy types are deleted outright. Do not dual-emit. Per `feedback_force-upgrade-over-deprecation`, version bumps gate the wire break.
- **Relay decode tolerance still applies:** `RelayMessages` types still use `decodeIfPresent` for incidental fields (per `feedback_no-backward-compat`), but the wire-format break itself uses `VersionCompatibility`.

---

# Phase 1 — Foundation types

## Task 1: Add new shared types to `ClaudeSpyNetworking`

**Goal:** Land the iOS-visible wire types before anything else. Pure additions — nothing legacy is removed yet.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentResponseRequest.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentResponse.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentSessionStatusUpdate.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/PluginPresentation.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AppAction.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/AgentResponseRequestTests.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/PluginPresentationTests.swift`

- [ ] **Step 1: Write failing Codable round-trip tests.** For each of the new types, write a swift-testing test that constructs a value, encodes via `JSONEncoder`, decodes via `JSONDecoder`, and asserts equality using `expectNoDifference` (from `pfw-custom-dump`). Include one test per `AgentResponseRequest` and `AgentResponse` case to lock the discriminator wire format. Use `keyEncodingStrategy = .convertToSnakeCase` (and matching decode strategy) — this is the conventional choice across `ClaudeSpyNetworking` for inter-platform JSON.

- [ ] **Step 2: Run tests, confirm they fail (types don't exist yet).** `swift test --filter AgentResponseRequestTests` should fail to compile.

- [ ] **Step 3: Implement the types verbatim from Spec §7.2, §7.2.1, §7.3, §7.4, §17.1.**

  Specifically:
  - `AgentResponseRequest`, `PromptRequest`, `ReplyAfterStopRequest`, `PermissionRequest`, `PermissionSuggestion`, `AskUserQuestionRequest`, `ApprovePlanRequest` — Spec §7.2.
  - `AgentResponse`, `PromptResponse`, `ReplyAfterStopResponse`, `PermissionResponse`, `AskUserQuestionResponse`, `ApprovePlanResponse` — Spec §7.2.1.
  - `AgentSessionStatusUpdate` (struct with `sessionId`, `pluginID`, `working: Bool`, `attention: Bool`, `timestamp: Date`) — Spec §7.4.
  - `PluginPresentation` (id, version, displayName, shortName, color: String, iconPNGData: Data) and the wrapping `PluginPresentationsMessage` — Spec §7.3. Decoder accepts `icon_b64` as base64 and exposes `iconPNGData: Data`.
  - `AppAction` enum — Spec §17.1 verbatim.

  All types are `public`, `Codable`, `Sendable`, `Equatable` where it makes sense for tests. Add `CodingKeys` if needed to match snake_case fields (e.g. `plugin_id`, `request_id`).

- [ ] **Step 4: Run tests, confirm they pass.** `swift test --filter ClaudeSpyNetworkingTests`.

- [ ] **Step 5: Commit.** Message: `feat(networking): add AgentResponseRequest/Response, status update, presentation, AppAction types`.

## Task 2: Bump `VersionCompatibility` minimum

**Goal:** Lock in the wire-format break for the plugin migration.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/VersionCompatibility.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/VersionCompatibilityTests.swift` (existing tests stay green)

- [ ] **Step 1: Decide the new minimum.** Current is `1.23`. The shipping version (per `Recent commits`) is `1.32`. Bump both `defaultMinRequiredViewerVersion` and `defaultMinRequiredHostVersion` to the next unreleased version — `1.33` — to force the upgrade prompt for any peer still on 1.32 or older.

- [ ] **Step 2: Update the constants.** Replace `"1.23"` with `"1.33"` in both lines of `VersionCompatibility.swift`. Add a doc comment paragraph noting "Bumped 2026-05-24 for the plugin-system flag-day release; v1.33+ peers refuse to pair with v1.32 or older."

- [ ] **Step 3: Run existing tests to confirm no regression.** `swift test --filter VersionCompatibility`.

- [ ] **Step 4: Commit.** Message: `feat(networking): bump min-required versions to 1.33 for plugin flag-day`.

## Task 3: Create `GallagerPluginProtocol` package

**Goal:** New SPM target containing the JSON-RPC envelope, `PluginEvent`, `PluginManifest`, RPC method-name constants, and ingress frame Codable. Reusable by sidecars and the Mac runtime alike.

**Files:**
- Modify: `ClaudeSpyPackage/Package.swift` — add target + product + Apple-only gate.
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/JSONRPCEnvelope.swift`
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/JSONRPCFraming.swift`
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginManifest.swift`
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginEvent.swift`
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginRPCMethod.swift`
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/IngressFrame.swift`
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginRegistryEntry.swift`
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginSettingsSchema.swift`
- Test: `ClaudeSpyPackage/Tests/GallagerPluginProtocolTests/JSONRPCFramingTests.swift`
- Test: `ClaudeSpyPackage/Tests/GallagerPluginProtocolTests/PluginManifestTests.swift`
- Test: `ClaudeSpyPackage/Tests/GallagerPluginProtocolTests/IngressFrameTests.swift`

- [ ] **Step 1: Add the SPM target.** In `Package.swift`:
  - Append `.library(name: "GallagerPluginProtocol", targets: ["GallagerPluginProtocol"])` to `products`.
  - Append a `.target(name: "GallagerPluginProtocol", dependencies: [.claudeSpyNetworking])` to `targets`, with no resources.
  - Append `.testTarget(name: "GallagerPluginProtocolTests", dependencies: ["GallagerPluginProtocol", .dependenciesTestSupport])`.
  - Add a `static var gallagerPluginProtocol: Self { "GallagerPluginProtocol" }` to `extension Target.Dependency`.
  - Gate behind `macOnlyDependencies` flow is unnecessary because the target has no macOS-specific deps — but the executables in Phase 4 will be macOS-only.

- [ ] **Step 2: Write failing tests.**
  - `JSONRPCFramingTests`: writing a 100-byte payload through `JSONRPCFramer.encodeFrame(_:)` produces `"Content-Length: 100\r\n\r\n" + payload`. Reading it back via `JSONRPCFramer.readFrame(from:)` (which consumes an `AsyncSequence<UInt8>`) yields the same payload bytes. Cover: bad header, missing blank line, truncated body — each should throw a specific error case.
  - `PluginManifestTests`: parses the bundled Claude Code manifest JSON from Spec §5 and asserts every field. Also asserts that `bundle_sha256: null` is valid for a `bundle://` URL and required for `https://`.
  - `IngressFrameTests`: a `{ context: { "FOO": "bar" }, payload: { "tool": "Read" } }` round-trips through length-prefixed encoding.

- [ ] **Step 3: Run failing tests** — confirm compile errors from missing types.

- [ ] **Step 4: Implement the types.**

  - `JSONRPCFramer` — static `encodeFrame(_:to:) async throws` writing `Content-Length: N\r\n\r\n` + body to a `FileHandle` or `AsyncByteWriter`. `readFrame(from:) async throws -> Data` reading bytes off any `AsyncSequence<UInt8>`. Errors: `JSONRPCFramingError.malformedHeader`, `.contentLengthMissing`, `.truncated`. The framer is async-aware because both sides will pipe through `FileHandle` async byte streams.
  - `JSONRPCEnvelope`:
    ```swift
    public enum JSONRPCMessage: Codable, Sendable {
        case request(JSONRPCRequest)
        case response(JSONRPCResponse)
        case notification(JSONRPCNotification)
    }
    public struct JSONRPCRequest: Codable, Sendable, Equatable {
        public let jsonrpc: String     // "2.0"
        public let id: JSONRPCID       // .number or .string
        public let method: String
        public let params: JSONValue?  // arbitrary blob; sidecar-or-app decodes downstream
    }
    public struct JSONRPCNotification: Codable, Sendable, Equatable {
        public let jsonrpc: String
        public let method: String
        public let params: JSONValue?
    }
    public struct JSONRPCResponse: Codable, Sendable, Equatable {
        public let jsonrpc: String
        public let id: JSONRPCID
        public let result: JSONValue?
        public let error: JSONRPCError?
    }
    public struct JSONRPCError: Codable, Sendable, Equatable {
        public let code: Int
        public let message: String
        public let data: JSONValue?
    }
    public enum JSONRPCID: Codable, Sendable, Hashable {
        case number(Int)
        case string(String)
    }
    ```
    Use the existing `JSONValue` type from `ClaudeSpyNetworking/Models/JSONRPC.swift` (`ClaudeSpyNetworking` already exposes a typed `JSONValue`; add it as a dep and re-export if needed).
  - `PluginManifest` — Spec §5 verbatim. `runtime` is an enum `case sidecar`. `capabilities` is a nested struct. `bundleSHA256: String?` validated as required when `manifestURL.scheme == "https"`.
  - `PluginEvent` — Spec §6.3 envelope.
  - `PluginRPCMethod` — string-raw-value enum of every method name in Spec §6.1 + §6.2:
    ```swift
    public enum PluginRPCMethod {
        public enum AppToSidecar: String, CaseIterable {
            case initialize, shutdown, refreshProjects = "refresh_projects",
                 detectPane = "detect_pane", install, uninstall,
                 isInstalled = "is_installed", translateEvent = "translate_event",
                 deliverResponse = "deliver_response",
                 getSettingsSchema = "get_settings_schema",
                 applySettings = "apply_settings",
                 commandForLaunch = "command_for_launch", health
        }
        public enum SidecarToApp: String, CaseIterable {
            case setProjects = "set_projects", emitEvent = "emit_event",
                 sendText = "send_text", sendKeys = "send_keys",
                 dismissResponseRequest = "dismiss_response_request",
                 requestNotification = "request_notification",
                 updateSessionStatus = "update_session_status",
                 log, promptUser = "prompt_user"
        }
    }
    ```
  - `IngressFrame`:
    ```swift
    public struct IngressFrame: Codable, Sendable, Equatable {
        public let context: [String: String]
        public let payload: JSONValue
    }
    ```
    Encoding: `UInt32` big-endian length prefix + JSON body. Add a static `encode(_:) throws -> Data` and `decode(from:) throws -> IngressFrame`.
  - `PluginRegistryEntry` — Spec §9.1 + §9.2: id, version, source (`bundled` / `url`), manifestURL, enabled, installedAt, bundleSHA256 (nullable for bundled).
  - `PluginSettingsSchema` — closed enum for field types per Spec §17.3 table. Fields: `id`, `type`, `label`, `default`, optional `placeholder`, `help`, `min`, `max`, `step`, `options`, `mustExist`, `directoriesOnly`. Decoded from JSON; encoder is unused (schemas are read-only).

- [ ] **Step 5: Run tests** — `swift test --filter GallagerPluginProtocolTests` until green.

- [ ] **Step 6: Commit.** Message: `feat: add GallagerPluginProtocol package (JSON-RPC framing, manifest, events)`.

---

# Phase 2 — Plugin runtime scaffolding

## Task 4: Create `ClaudeSpyPluginRuntime` package + `PluginRegistry`

**Goal:** Bring up the Mac-only runtime package with its first piece: an actor that loads + persists the on-disk plugin registry.

**Files:**
- Modify: `ClaudeSpyPackage/Package.swift` — add target + product + macOS gate.
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/PluginRegistry.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/PluginRootLayout.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/PluginRegistryTests.swift`

- [ ] **Step 1: Add the SPM target.** Apple-only via the same pattern as `ClaudeSpyServerFeature`:
  ```swift
  .target(
      name: "ClaudeSpyPluginRuntime",
      dependencies: [
          "GallagerPluginProtocol",
          .claudeSpyNetworking,
          .claudeSpyCommon,
          .dependencies,
          .dependenciesMacros,
          .logging,
      ]
  )
  ```
  And a matching test target. Also expose `static var claudeSpyPluginRuntime: Self { "ClaudeSpyPluginRuntime" }` on `Target.Dependency`. `ClaudeSpyServerFeature` will later depend on this.

- [ ] **Step 2: Define `PluginRootLayout`.** A `@DependencyClient` struct (so tests can redirect paths) exposing:
  ```swift
  @DependencyClient
  public struct PluginRootLayout: Sendable {
      public var registryURL: @Sendable () -> URL = { unimplemented(...) }
      public var bundledPluginsDir: @Sendable () -> URL = { unimplemented(...) }
      public var userPluginsDir: @Sendable () -> URL = { unimplemented(...) }
      public var stateDir: @Sendable (_ pluginID: String) -> URL = { _ in unimplemented(...) }
      public var ingressSocketURL: @Sendable (_ pluginID: String) -> URL = { _ in unimplemented(...) }
      public var settingsURL: @Sendable (_ pluginID: String) -> URL = { _ in unimplemented(...) }
      public var logsDir: @Sendable (_ pluginID: String) -> URL = { _ in unimplemented(...) }
  }
  extension PluginRootLayout: DependencyKey {
      public static let liveValue: Self = .live(rootOverride: nil)
      public static func live(rootOverride: URL?) -> Self {
          let root = rootOverride ?? URL(fileURLWithPath:
              NSString(string: "~/.gallager").expandingTildeInPath, isDirectory: true)
          let bundledDir = Bundle.main.resourceURL!.appendingPathComponent("plugins", isDirectory: true)
          return PluginRootLayout(
              registryURL: { root.appendingPathComponent("registry.json") },
              bundledPluginsDir: { bundledDir },
              userPluginsDir: { root.appendingPathComponent("plugins", isDirectory: true) },
              stateDir: { id in root.appendingPathComponent("state/plugins/\(id)", isDirectory: true) },
              ingressSocketURL: { id in root.appendingPathComponent("state/plugins/\(id)/ingress.sock") },
              settingsURL: { id in root.appendingPathComponent("state/plugins/\(id)/settings.json") },
              logsDir: { id in root.appendingPathComponent("state/plugins/\(id)/logs", isDirectory: true) }
          )
      }
  }
  ```
  The `rootOverride` is fed by the new `--gallager-state-root` launch arg added in Task 23.

- [ ] **Step 3: Write failing tests for `PluginRegistry`.**
  - Empty registry: loads cleanly from a missing file, returns `[]`.
  - Read + write: write a 3-entry registry, re-read, expect the same entries.
  - Atomic replace: writing a new registry uses temp+rename (no partial file on disk if write errors). Validate by writing to a directory you make read-only mid-write.
  - Bundled refresh: passing in a list of bundled entries and a list of user entries returns a merged list with bundled first.
  - Update entry: changing the enabled bit for one id mutates only that entry.

- [ ] **Step 4: Implement `PluginRegistry` as an `actor`.** It owns a `[PluginRegistryEntry]` array, lazily loaded from `layout.registryURL()`. Public surface: `load()`, `entries()`, `mergeBundled(_:)`, `addUserInstall(_:)`, `remove(id:)`, `setEnabled(id:enabled:)`. Persistence: each mutator writes to a temp file in the registry's directory and atomically renames. Errors propagate as `PluginRegistryError`.

- [ ] **Step 5: Run tests; iterate to green.** `swift test --filter PluginRegistryTests`.

- [ ] **Step 6: Commit.** Message: `feat(runtime): add PluginRootLayout dependency + PluginRegistry actor`.

## Task 5: `SidecarSupervisor`

**Goal:** Spawn one sidecar process per enabled plugin; capture stdin/stdout for JSON-RPC; stderr to a per-plugin log file; handle init, shutdown, crash/restart per Spec §12.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/SidecarSupervisor.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/JSONRPCConnection.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/SidecarLogFile.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/JSONRPCConnectionTests.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/SidecarSupervisorTests.swift`

- [ ] **Step 1: Write failing tests for `JSONRPCConnection`.** A pair of `Pipe` instances simulates a sidecar. Tests:
  - `send(method:params:)` writes a framed `JSONRPCRequest` to stdin; the read side decodes it intact.
  - Inbound response with matching `id` resolves the awaiting continuation; response with unknown `id` is logged and dropped.
  - Inbound notification routes to a delegate's `received(method:params:)`.
  - Outbound timeout: a request with a 100ms deadline that never gets a reply throws `JSONRPCError.timeout` and removes its continuation.
  - Closing the connection cancels all outstanding requests.

- [ ] **Step 2: Implement `JSONRPCConnection` as an `actor`.**
  ```swift
  public actor JSONRPCConnection {
      public protocol Delegate: AnyObject, Sendable {
          func received(notification: JSONRPCNotification) async
          func received(request: JSONRPCRequest) async -> JSONRPCResponse
      }
      public init(input: FileHandle, output: FileHandle, delegate: Delegate)
      public func start() async
      public func stop() async
      public func send<P: Encodable & Sendable, R: Decodable & Sendable>(
          method: String, params: P, timeout: Duration = .seconds(30)
      ) async throws -> R
      public func notify<P: Encodable & Sendable>(method: String, params: P) async throws
  }
  ```
  Internal state: `nextID: Int`, `[JSONRPCID: CheckedContinuation<JSONValue, Error>]`, a `Task` reading frames from `output.bytes`. JSON encoding/decoding uses snake_case strategy.

- [ ] **Step 3: Write failing tests for `SidecarSupervisor`.** Build a small "echo" test sidecar as an inline `Foundation.Process` running `/usr/bin/cat` is not enough — write a Swift command tool in `Tests/ClaudeSpyPluginRuntimeTests/Fixtures/EchoSidecar/main.swift` that reads RPC frames and replies with `{"echo": params}`. Tests:
  - Spawning the supervisor with the echo binary path completes `initialize` within timeout.
  - Killing the echo process triggers restart with 1s backoff (use a `TestClock` from `swift-clocks` + `withMainSerialExecutor` per `feedback_testclock-needs-serial-executor`).
  - 4 crashes in 60s flips the plugin into the `disabled` state and surfaces the last 50 stderr lines.
  - `shutdown()` sends the RPC, waits 3s for graceful exit, then SIGTERM, then SIGKILL after 5s.

- [ ] **Step 4: Implement `SidecarSupervisor` as an `actor`.**
  - Public surface: `init(pluginID:executableURL:env:layout:clock:)`. `start()`, `stop()`, `restart()`, `state: SidecarState` (enum: notStarted, starting, running, failed(reason), disabled(stderr)).
  - Spawns via `Foundation.Process` with `stdin`/`stdout` as the connection pipes; `stderr` redirected to `layout.logsDir(pluginID).appendingPathComponent("sidecar.log")` via `SidecarLogFile` (which size-rotates at 5 MB per Spec §12).
  - Crash counter in 60-second sliding window, backoffs 1/2/4 seconds, 4th crash → disabled.
  - Health: a `Task` calling `connection.send(method: "health", ...)` every 30 s. Three misses → forcibly restart.
  - `SidecarSupervisorDelegate` protocol exposes `received(notification:)` so `PluginManager` (Task 7) can route sidecar→app notifications.

- [ ] **Step 5: Implement `SidecarLogFile`.** `actor` opening a file handle, writing newline-terminated lines, size-checking and rotating (`sidecar.log` → `sidecar.log.1`, drop `.2`). Stderr handling: `Pipe` whose read-end is fed line-by-line to `SidecarLogFile.append`.

- [ ] **Step 6: Run tests; iterate to green.** `swift test --filter SidecarSupervisorTests JSONRPCConnectionTests`.

- [ ] **Step 7: Commit.** Message: `feat(runtime): add JSONRPCConnection + SidecarSupervisor with crash policy`.

## Task 6: `IngressBroker` (Unix-socket listener per plugin)

**Goal:** Each enabled plugin's ingress socket runs inside the Mac app process — wait, re-read Spec §8: the spec says the sidecar listens on `ingress.sock`. So `IngressBroker` actually lives inside each sidecar. The app does NOT listen on these sockets.

Re-scope this task: provide the **listener helper** in `GallagerPluginProtocol` so sidecars can drop it into their main loop, then the Mac runtime never opens the socket itself.

**Files:**
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/IngressSocketServer.swift`
- Test: `ClaudeSpyPackage/Tests/GallagerPluginProtocolTests/IngressSocketServerTests.swift`

- [ ] **Step 1: Failing test.** `IngressSocketServerTests.testAcceptAndDecodeFrame`: spin up the server on a temp `.sock` path, dial it from `Network.framework` with `NWConnection`, write a `UInt32` BE length-prefixed JSON body, expect the server to surface the decoded `IngressFrame` via its async stream.

- [ ] **Step 2: Implement `IngressSocketServer`.** Built on `Network` framework `NWListener` over Unix domain sockets (set `listener.parameters = .tcp` doesn't apply; use `NWParameters.tcp` with `.unix(path:)` endpoint — refer to Spec §8 + Apple docs via `sosumi`). Public surface:
  ```swift
  public actor IngressSocketServer {
      public init(socketURL: URL, parseErrors: AsyncStream<Error>.Continuation? = nil)
      public func start() async throws -> AsyncStream<IngressFrame>
      public func stop() async
  }
  ```
  Each connection: read 4-byte length, read body bytes, decode, yield to the stream. Parse errors are logged via the optional `parseErrors` continuation (Spec §8 backpressure handling).

- [ ] **Step 3: Run tests.** Iterate.

- [ ] **Step 4: Commit.** Message: `feat(protocol): add IngressSocketServer helper for sidecars`.

## Task 7: `PluginManager`, `PluginEventDispatcher`, `PluginRouter`, `AssetCache`

**Goal:** The Mac-side controller that brings everything together — supervisors, registry, manifest discovery, asset loading, and routing of inbound sidecar messages onto the existing Mac feature surfaces (notifications, status, file-suggestion, etc.).

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/PluginManager.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/PluginEventDispatcher.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/PluginRouter.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/AssetCache.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/BundledPluginDiscovery.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/PluginEventDispatcherTests.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/PluginManagerTests.swift`

- [ ] **Step 1: Define the dispatcher's collaborator protocols.** `PluginEventDispatcher` doesn't own UI state — it forwards into protocols implemented later by `MirrorWindowManager`, `MarkdownOpenSuggestionStore`, `MacNotificationDeliveryService`, etc. Define:
  ```swift
  public protocol PluginSessionStatusSink: AnyObject, Sendable {
      func updateStatus(pluginID: String, sessionID: String, working: Bool?, attention: Bool) async
  }
  public protocol PluginNotificationSink: AnyObject, Sendable {
      func deliverNotification(pluginID: String, sessionID: String?, title: String, body: String) async
  }
  public protocol PluginResponseRequestSink: AnyObject, Sendable {
      func deliverRequest(pluginID: String, sessionID: String, requestID: String,
                          request: AgentResponseRequest, isAutoApprovable: Bool) async
      func dismissRequest(pluginID: String, sessionID: String, requestID: String) async
  }
  public protocol PluginAppActionSink: AnyObject, Sendable {
      func handle(pluginID: String, action: AppAction) async
  }
  public protocol PluginAgentDriverSink: AnyObject, Sendable {
      func sendText(pluginID: String, sessionID: String, text: String) async
      func sendKeys(pluginID: String, sessionID: String, keys: [TmuxKey]) async
  }
  ```
  These will be wired to existing app services in Phase 5.

- [ ] **Step 2: Write failing tests for `PluginEventDispatcher`.**
  - A `PluginEvent` with `working: true, attention: false` and no other fields invokes only the status sink.
  - A `PluginEvent` with a notification AND a response_request invokes both sinks.
  - An `app_actions` entry of `.openFileSuggestion(...)` invokes the app action sink with the right args.
  - A response_request marked `isAutoApprovable: true` AND yolo mode on (encoded via a `YoloModeProvider` collaborator) results in an immediate `deliverResponse` call back to the sidecar (mocked) AND no `deliverRequest` call to the iOS-facing sink.

- [ ] **Step 3: Implement `PluginEventDispatcher` as an `actor`.** Takes references to all sinks + a `PluginAgentDriverSink` (for the yolo auto-approve flow needs to send `deliver_response` to the sidecar — but actually the yolo auto-approve goes back through `PluginManager.deliverResponse(...)` since the sidecar is the destination, not the agent driver). Wire it so that on a `PluginEvent`:
  1. If `working` non-nil OR `attention` non-default → `statusSink.updateStatus(...)`.
  2. If `notification` non-nil → `notificationSink.deliverNotification(...)`.
  3. If `response_request` non-nil:
     - If `request` is `.permission(let req)` AND `req.isAutoApprovable` AND `yoloProvider.isYolo(sessionID:)` → bypass UI: tell `PluginManager` to call `deliverResponse(.permission(.init(decision: .allow, appliedSuggestionId: nil)))`.
     - Else: `responseRequestSink.deliverRequest(...)`.
  4. For each `app_actions` entry → `appActionSink.handle(...)`.

- [ ] **Step 4: Write failing tests for `PluginManager`.** Use the same echo-sidecar fixture from Task 5.
  - On `start()`, the manager loads bundled-plugins from `layout.bundledPluginsDir()`, merges into the registry, and spawns supervisors for every enabled entry.
  - `setProjects` notification from a sidecar updates `manager.projects(for: pluginID)`.
  - `refreshProjects()` fanout sends the RPC to every running supervisor.
  - `deliverResponse(sessionID:requestID:response:)` calls the right sidecar's RPC and times out gracefully if the sidecar is dead.
  - Disabling a plugin stops its supervisor cleanly.

- [ ] **Step 5: Implement `PluginManager`.**
  ```swift
  @MainActor
  public final class PluginManager: Sendable {
      public init(layout: PluginRootLayout,
                  statusSink: PluginSessionStatusSink,
                  notificationSink: PluginNotificationSink,
                  responseRequestSink: PluginResponseRequestSink,
                  appActionSink: PluginAppActionSink,
                  agentDriverSink: PluginAgentDriverSink,
                  yoloProvider: YoloModeProvider)
      public func start() async throws
      public func stop() async
      public func enable(pluginID: String) async throws
      public func disable(pluginID: String) async throws
      public func refreshProjects() async
      public func deliverResponse(pluginID: String, sessionID: String, requestID: String, response: AgentResponse) async
      public func install(manifestURL: URL) async throws
      public func uninstall(pluginID: String) async throws
      public func projects(for pluginID: String) -> [AgentProject]
      public var allProjects: [AgentProject] { get }
      public var presentations: [PluginPresentation] { get }
      public func commandForLaunch(pluginID: String) async throws -> CommandSpec
      public func detectPane(pluginID: String, paneInfo: [String: String]) async -> Bool
      public func openSettingsSchema(pluginID: String) async throws -> PluginSettingsSchema
      public func applySettings(pluginID: String, settings: [String: JSONValue]) async throws
      public func installSidecarHooks(pluginID: String) async throws
      public func isHookInstalled(pluginID: String) async throws -> Bool
  }
  ```
  Internal: `[String: SidecarSupervisor]`, `[String: [AgentProject]]`, `[String: PluginPresentation]`. Each supervisor's delegate forwards sidecar→app calls through to the dispatcher.

- [ ] **Step 6: Implement `AssetCache`.** Given a manifest, loads the icon PNG from disk into a `Data`, base64-encodes it for the iOS push, and returns a `PluginPresentation`. Caches in memory keyed by `(pluginID, version)`. Trivial enough that one test covers it.

- [ ] **Step 7: Implement `BundledPluginDiscovery`.** Scans `Bundle.main.resourceURL/plugins/*/plugin.json`, parses, returns `[PluginRegistryEntry]`. Tests: parse the Claude Code manifest from a fixture directory; reject manifests with the wrong `schema_version`.

- [ ] **Step 8: Run all runtime tests until green.**

- [ ] **Step 9: Commit.** Message: `feat(runtime): wire PluginManager + dispatcher + asset cache`.

---

# Phase 3 — Sidecar cores

## Task 8: `ClaudeCodePluginCore` package — scanner, command resolver, tools

**Goal:** Move the agent-specific Mac code into a new library. No behavioral changes; just relocation + lifted from the `@Observable` and other Mac patterns into a plain library suitable to run inside a command-line sidecar.

**Files:**
- Modify: `ClaudeSpyPackage/Package.swift` — add the new target + product.
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginCore/Claude/`(empty for now — will receive moves)
- Move (don't copy, use `git mv`):
  - `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/ClaudeProjectScanner.swift` → `Sources/ClaudeCodePluginCore/ClaudeProjectScanner.swift`
  - `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/ClaudeBinaryLocator.swift` → `Sources/ClaudeCodePluginCore/ClaudeBinaryLocator.swift`
  - `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/ClaudeCodeTools.swift` → `Sources/ClaudeCodePluginCore/ClaudeCodeTools.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeInstaller.swift` (extracted from the inline logic in `AppCoordinator`)
- Create: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeNotificationCopy.swift` (extracted from `HookActionUI.swift` + `HookNotificationExtensions.swift`, scoped to Claude-specific strings)
- Tests: `ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/` — move existing tests from `ClaudeSpyServerFeatureTests` for `ClaudeProjectScanner`, `ClaudeBinaryLocator`. Add new tests for `ClaudeCodeInstaller` and copy.

- [ ] **Step 1: Add SPM target.** Apple-only via the same pattern. Dependencies: `GallagerPluginProtocol`, `ClaudeSpyNetworking` (for `AgentProject`, `AgentResponseRequest`), `Dependencies`/`DependenciesMacros`, `Logging`.

- [ ] **Step 2: Move scanner + locator + tools.** `git mv` the three files into the new package; fix imports (drop `ClaudeSpyServerFeature` deps, swap to `ClaudeCodePluginCore`-internal types). The scanner's output type changes from "raw struct" to `[AgentProject]` (use the rename from Task 14 if it lands first — but since this task runs before Task 14, temporarily expose a `ClaudeCodeRawProject` and add a transformer; Task 14 will collapse it). The simpler path: rename `ClaudeProjectInfo` to `AgentProject` as a precondition by doing it as Step 0 of this task. Decision: include the rename of `ClaudeProjectInfo` → `AgentProject` in this task, defer the `ClaudeSession` rename to Task 14.

- [ ] **Step 3: Rename `ClaudeProjectInfo` → `AgentProject` everywhere.** This is a global replace across the codebase: `ClaudeSpyNetworking/Models/RelayMessages.swift` (its definition), all references in `ClaudeSpyServerFeature`, `ClaudeSpyFeature`, `ClaudeSpyE2ELib`. Also rename the `agent: CodingAgent` field to `pluginID: String`. For now, populate `pluginID` from `agent.rawValue` to keep behavior. Run tests; the codebase should still build.

- [ ] **Step 4: Move tests.** `git mv` the corresponding test files. Adjust imports.

- [ ] **Step 5: Extract `ClaudeCodeInstaller`.** Read `AppCoordinator.swift` to find the inline Claude install logic (the bit that registers the bundled marketplace with the `claude` CLI). Encapsulate as:
  ```swift
  @DependencyClient
  public struct ClaudeCodeInstaller: Sendable {
      public var install: @Sendable (_ pluginRoot: URL, _ claudeBin: URL) async throws -> InstallStatus
      public var uninstall: @Sendable (_ claudeBin: URL) async throws -> InstallStatus
      public var isInstalled: @Sendable (_ claudeBin: URL) async throws -> Bool
  }
  ```
  with a `liveValue` that drives the `claude` CLI just like the original code. Move the `marketplace.json` JSON template, hook.json, and hook.py into `ClaudeSpyPackage/PluginBundles/claude-code/agent-bundle/...` (the new bundled-plugin tree; see Task 13).

- [ ] **Step 6: Move + rewrite notification + display copy.** `HookActionUI.swift` contains the per-`HookAction` `title`/`subtitle` table — split it: Claude-Code-specific strings into `ClaudeCodeNotificationCopy.swift` (with constants like `static let workingTitle = "Claude is working"`), and any cross-agent infrastructure stays in `ClaudeSpyCommon` as an empty placeholder until Task 21. `HookNotificationExtensions.swift` `buildNotification()` similarly moves; sidecar now bakes the title/body and emits a `notification` field on `PluginEvent`.

- [ ] **Step 7: Run tests.** `swift test --filter ClaudeCodePluginCoreTests`.

- [ ] **Step 8: Commit.** Message: `feat: extract ClaudeCodePluginCore (scanner, locator, installer, copy); rename ClaudeProjectInfo→AgentProject`.

## Task 9: `ClaudeCodePluginCore` — event translator + keystroke builder

**Goal:** Implement the `HookAction → PluginEvent` translation table (Spec §17.2) and the keystroke logic for delivering responses back to the Claude TUI.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeEventTranslator.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeKeystrokeBuilder.swift`
- Move: `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Views/ResponseViews/AskUserQuestionKeystrokes.swift` → `Sources/ClaudeCodePluginCore/ClaudeCodeKeystrokeBuilder.swift` (rename and rework signatures to take an `AskUserQuestionResponse` and return `[TmuxKey] + freeText`)
- Test: `ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/ClaudeCodeEventTranslatorTests.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/ClaudeCodeKeystrokeBuilderTests.swift`

- [ ] **Step 1: Define the translator API.**
  ```swift
  public struct ClaudeCodeEventTranslator: Sendable {
      public init()
      /// Translate one inbound Claude-Code hook payload (raw JSON from stdin)
      /// into a PluginEvent (or nil if the event should be log-and-drop).
      public func translate(rawPayload: JSONValue,
                            context: IngressContext) throws -> PluginEvent?
  }
  public struct IngressContext: Sendable {
      public let projectPath: String?
      public let tmuxPane: String?
      public let sessionID: String?
      public let envOverrides: [String: String]
      public static func from(_ envMap: [String: String]) -> IngressContext { ... }
  }
  ```

- [ ] **Step 2: Write the spec table as a parameterised test.** One row per `HookAction` case from Spec §17.2. Each row asserts the produced `PluginEvent` exactly. Where the spec says "log-and-drop", assert `translate(...)` returns `nil`. Tests should use `expectNoDifference` for full-envelope equality.

- [ ] **Step 3: Implement the translator.** Internally still parses the old `HookEvent` / `HookAction` Codable types — but those types live INSIDE this package now, moved from `ClaudeSpyNetworking/Models/HookModels.swift`. Move the existing `HookModels.swift` and its `*Body` structs into `ClaudeCodePluginCore` (rename file to `ClaudeCodeHookPayloads.swift`, internalize so only the translator uses them). The legacy public type is gone; the file's contents survive as private decoding helpers.

- [ ] **Step 4: Tests pass.**

- [ ] **Step 5: Define the keystroke builder API.**
  ```swift
  public struct ClaudeCodeKeystrokeBuilder: Sendable {
      public init()
      /// Build the sequence of keys + free-text needed to drive Claude's
      /// AskUserQuestion menu given the user's structured answers and the
      /// original question.
      public func keystrokes(for response: AskUserQuestionResponse,
                             matching request: AskUserQuestionRequest)
          -> [KeystrokeStep]
      /// Build keys for a PermissionResponse / ApprovePlanResponse / etc.
      public func keystrokes(for response: PermissionResponse,
                             matching request: PermissionRequest)
          -> [KeystrokeStep]
      public func keystrokes(for response: ApprovePlanResponse,
                             matching request: ApprovePlanRequest)
          -> [KeystrokeStep]
  }
  public enum KeystrokeStep: Sendable, Equatable {
      case keys([TmuxKey])
      case text(String)
      case wait(Duration)
  }
  ```
  Move logic from `AskUserQuestionKeystrokes.swift`; for the other response types, port the logic that today lives in iOS `ResponseViews/*` (e.g. `PermissionRequestResponseView` sending `Tmux.Key.enter` for allow). Add small `wait`s where Claude's TUI needs settle time.

- [ ] **Step 6: Tests for the builder.** Cover at least: single-select question, multi-select question, free-text "Other" answer, permission allow (default suggestion), permission deny, approve plan, edit-then-approve plan.

- [ ] **Step 7: Commit.** Message: `feat(claude-core): event translator + keystroke builder`.

## Task 10: `CodexPluginCore` package — scanner, installer, translator, builder

**Goal:** Same pattern as Task 8 + Task 9 but for Codex.

**Files:**
- Modify: `ClaudeSpyPackage/Package.swift` — add `CodexPluginCore` target.
- Move:
  - `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/CodexProjectScanner.swift` → `Sources/CodexPluginCore/CodexProjectScanner.swift`
  - `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/CodexPluginInstaller.swift` → `Sources/CodexPluginCore/CodexInstaller.swift`
- Create: `ClaudeSpyPackage/Sources/CodexPluginCore/CodexEventTranslator.swift`
- Create: `ClaudeSpyPackage/Sources/CodexPluginCore/CodexKeystrokeBuilder.swift`
- Create: `ClaudeSpyPackage/Sources/CodexPluginCore/CodexHookPayloads.swift` (internal copies of any Codex-only Codable shapes that today live in `HookModels.swift`)
- Tests: `ClaudeSpyPackage/Tests/CodexPluginCoreTests/...` (move the corresponding tests from `ClaudeSpyServerFeatureTests`)

- [ ] **Step 1: Add the target.** Apple-only. Dependencies parallel to Task 8.

- [ ] **Step 2: Move scanner + installer.** `git mv`; fix imports. Both keep their existing behavior; just relocate.

- [ ] **Step 3: Carry forward the Codex correlation file.** Per Spec §17.2 Codex audit footnote: on `SessionStart` the sidecar writes `~/.claudespy/codex-sessions/<tmux_pane>.json`. This lives in `CodexEventTranslator` now. Add a test.

- [ ] **Step 4: Translator + keystroke builder.** Codex's `HookAction` set is a subset of Claude's + `PostCompact` and `SubagentStart`. Reuse most of the translator logic from Task 9 but parameterize by agent. Practical approach: factor a `HookActionMapper` protocol in `ClaudeCodePluginCore` and let `CodexEventTranslator` plug in the Codex-specific deltas — or just copy and adapt (simpler, fewer shared abstractions to maintain). Spec says agents differ in small ways; copy is the right call.

- [ ] **Step 5: Tests pass.**

- [ ] **Step 6: Commit.** Message: `feat: extract CodexPluginCore + scanner/installer/translator/builder`.

## Task 11: `*PluginCore` settings + `command_for_launch`

**Goal:** Each core knows how to read/apply per-plugin settings from disk and how to assemble the launch command for auto-spawning the agent in a tmux pane.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeSettings.swift`
- Create: `ClaudeSpyPackage/Sources/CodexPluginCore/CodexSettings.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeLaunchCommand.swift`
- Create: `ClaudeSpyPackage/Sources/CodexPluginCore/CodexLaunchCommand.swift`
- Create JSON: `ClaudeSpyPackage/PluginBundles/claude-code/ui/settings.json` (per Spec §17.3 — `command_path`, `auto_run`, `log_level`)
- Create JSON: `ClaudeSpyPackage/PluginBundles/codex/ui/settings.json`
- Test: `ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/ClaudeCodeSettingsTests.swift`
- Test: `ClaudeSpyPackage/Tests/CodexPluginCoreTests/CodexSettingsTests.swift`

- [ ] **Step 1: Per-plugin settings struct.** For Claude:
  ```swift
  public struct ClaudeCodeSettings: Codable, Sendable, Equatable {
      public var commandPath: String = "claude"
      public var autoRun: Bool = true
      public var logLevel: LogLevel = .info
      public enum LogLevel: String, Codable, Sendable { case debug, info, warn, error }
  }
  ```
  Same shape for Codex. Decoded from `[String: JSONValue]` via a small bridge.

- [ ] **Step 2: Launch-command resolver.** Look up the binary via `ClaudeBinaryLocator` (Claude) / a Codex equivalent; return `{ command: String, args: [String], env: [String: String] }`. Today's `AppCoordinator` has the logic — relocate.

- [ ] **Step 3: Tests.** Cover: settings round-trip, missing-key defaults, validation rejecting unknown values. Launch command tests cover bin found in `/usr/local/bin`, missing bin returns an error.

- [ ] **Step 4: Bundled settings.json files.** Transcribe Spec §17.3 verbatim into `PluginBundles/claude-code/ui/settings.json` and `PluginBundles/codex/ui/settings.json`.

- [ ] **Step 5: Commit.** Message: `feat: per-plugin settings + launch command resolvers`.

---

# Phase 4 — Sidecar executables and bundling

## Task 12: `ClaudeCodePluginSidecar` executable

**Goal:** The actual binary that runs as a child process under the Mac app. Implements the JSON-RPC server that the supervisor talks to, drives the ingress socket, and wires the core into the protocol.

**Files:**
- Modify: `ClaudeSpyPackage/Package.swift` — add an `.executableTarget(name: "ClaudeCodePluginSidecar", ...)`.
- Create: `ClaudeSpyPackage/Sources/ClaudeCodePluginSidecar/main.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeCodePluginSidecar/ClaudeCodeSidecar.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeCodePluginSidecar/FSEventsProjectWatcher.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeCodePluginSidecar/RPCHandler.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeCodePluginSidecarTests/ClaudeCodeSidecarTests.swift` (integration: spawn the binary, talk to it)

- [ ] **Step 1: Add executable target.** Apple-only:
  ```swift
  .executableTarget(
      name: "ClaudeCodePluginSidecar",
      dependencies: [
          "GallagerPluginProtocol",
          "ClaudeCodePluginCore",
          .claudeSpyNetworking,
          .logging,
      ]
  )
  ```
  Add it to `products` as `.executable(...)`.

- [ ] **Step 2: Implement `ClaudeCodeSidecar`.** The class that owns the JSON-RPC server loop:
  - Reads framed messages from stdin (`FileHandle.standardInput.bytes`), writes framed messages to stdout via `FileHandle.standardOutput`.
  - Maintains a `[Method: AsyncCall]` dispatch table.
  - On `initialize`: takes `{ plugin_root, state_dir, app_version }`, mounts settings, starts `IngressSocketServer` on `state_dir/ingress.sock`, kicks off `FSEventsProjectWatcher`. Returns `{ capabilities, schemas }` per Spec §6.1.
  - On `shutdown`: stops watcher, server, sends a final stderr line.
  - On `refresh_projects`: triggers a fresh scan + `set_projects` callback.
  - On `detect_pane`: not implemented (returns method-not-found — manifest declares `requires_rich_detection: false`).
  - On `install`/`uninstall`/`is_installed`: defers to `ClaudeCodeInstaller`.
  - On `translate_event`: takes the raw payload, runs `ClaudeCodeEventTranslator.translate`, returns the `PluginEvent`.
  - On `deliver_response`: looks up cached request context (stored when the originating `permissionRequest` / `stop` / etc. event was translated); runs the keystroke builder; emits `send_text`/`send_keys` notifications.
  - On `get_settings_schema`: returns the JSON schema from `plugin_root/ui/settings.json`.
  - On `apply_settings`: validates + writes to `state_dir/settings.json`; reacts (e.g. resets log level).
  - On `command_for_launch`: returns the launch command via `ClaudeCodeLaunchCommand`.
  - On `health`: returns `{ ok: true }`.
  - On ingress frame: parses, runs translator with the embedded context, calls `emit_event` notification back to the app.

- [ ] **Step 3: Implement `FSEventsProjectWatcher`.** Use the Apple `FSEvents` C API (or wrap in `DispatchSource.makeFileSystemObjectSource` for simpler dir watching — but `~/.claude/projects/` has many files, FSEvents is the right tool). When something under `~/.claude/projects/` changes, debounce 250 ms then re-scan via `ClaudeProjectScanner.scan()` and emit `set_projects`.

- [ ] **Step 4: Implement `main.swift` as the entry point.** Wires `ClaudeCodeSidecar` and `await sidecar.run()`. Logs uncaught errors to stderr.

- [ ] **Step 5: Integration test.** Spawn the binary as a `Foundation.Process`, drive it over pipes with a hand-built `JSONRPCConnection`, send `initialize`, expect `capabilities` back; then write a fake hook frame to its ingress socket and expect a `set_projects` + an `emit_event` notification.

- [ ] **Step 6: Commit.** Message: `feat: ClaudeCodePluginSidecar executable target`.

## Task 13: `CodexPluginSidecar` executable + plugin bundle resources + Xcode build phase

**Goal:** Symmetric to Task 12 for Codex, plus the build-phase plumbing that copies both sidecars + their bundle trees into `Gallager.app/Contents/Resources/plugins/`.

**Files:**
- Modify: `ClaudeSpyPackage/Package.swift` — add `CodexPluginSidecar` executable target.
- Create: `ClaudeSpyPackage/Sources/CodexPluginSidecar/main.swift`
- Create: `ClaudeSpyPackage/Sources/CodexPluginSidecar/CodexSidecar.swift`
- Create: `ClaudeSpyPackage/Sources/CodexPluginSidecar/FSEventsProjectWatcher.swift`
- Move: existing repo-root `plugin/gallager/` → `ClaudeSpyPackage/PluginBundles/claude-code/agent-bundle/.claude-plugin/...` (preserve `.claude-plugin/marketplace.json`, `gallager/hooks/hooks.json`, `gallager/scripts/hook.py`)
- Move: existing repo-root `plugin/codex/` → `ClaudeSpyPackage/PluginBundles/codex/agent-bundle/.agents/...`
- Create: `ClaudeSpyPackage/PluginBundles/claude-code/plugin.json` (Spec §5 verbatim)
- Create: `ClaudeSpyPackage/PluginBundles/codex/plugin.json` (Spec §5, with `id: "codex"`, `process_names: ["codex"]`)
- Create: `ClaudeSpyPackage/PluginBundles/claude-code/assets/icon.png` (extract today's Claude icon)
- Create: `ClaudeSpyPackage/PluginBundles/codex/assets/icon.png`
- Create: `Gallager.xcodeproj` build phase script to copy `PluginBundles/<id>/...` + the two built executables into `$BUILT_PRODUCTS_DIR/Gallager.app/Contents/Resources/plugins/<id>/`. Edit the Mac app target via `xcodebuild -resolvePackageDependencies` + a `Run Script` build phase.

- [ ] **Step 1: `CodexPluginSidecar`.** Mirror Task 12 substituting Codex types. `requires_rich_detection: false` (process name matching is fine for Codex too).

- [ ] **Step 2: Move plugin trees.** `git mv` `plugin/gallager/scripts/hook.py` to `ClaudeSpyPackage/PluginBundles/claude-code/agent-bundle/gallager/scripts/hook.py` etc. Update the script to connect to `${state_dir}/ingress.sock` (read from `GALLAGER_INGRESS_SOCK` env var which `ClaudeCodeInstaller` injects into the host-agent hook environment) instead of POSTing to localhost. The bridge script becomes ~30 lines of Python:
  ```python
  import os, sys, struct, json, socket
  sock_path = os.environ.get("GALLAGER_INGRESS_SOCK")
  if not sock_path or not os.path.exists(sock_path):
      sys.exit(0)
  payload = sys.stdin.read()
  context = {k: v for k, v in os.environ.items()
             if k.startswith(("CLAUDE_", "TMUX_", "CODEX_"))}
  frame = json.dumps({"context": context, "payload": json.loads(payload)}).encode()
  with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
      try:
          s.connect(sock_path)
          s.sendall(struct.pack(">I", len(frame)) + frame)
      except OSError:
          sys.exit(0)
  ```
  Same script for Codex.

- [ ] **Step 3: Plugin manifests + icons.** Transcribe Spec §5 (claude-code) verbatim into `plugin.json`; do the same for codex with `id: "codex"`, `display_name: "Codex"`, `short_name: "Codex"`, `process_names: ["codex"]`. Icons: there are existing assets shipped in the app already — find them (`grep -r "icon" PluginBundles` or look in `Gallager/Assets.xcassets`) and extract appropriate PNG files into `PluginBundles/<id>/assets/icon.png`.

- [ ] **Step 4: Xcode build phase.** In `Gallager.xcodeproj`, add a "Copy Plugin Bundles" Run Script phase on the `ClaudeSpyServer` target (macOS) after Swift compilation:
  ```bash
  set -e
  PLUGIN_SRC="$SRCROOT/ClaudeSpyPackage/PluginBundles"
  PLUGIN_DST="$BUILT_PRODUCTS_DIR/Gallager.app/Contents/Resources/plugins"
  rm -rf "$PLUGIN_DST"
  mkdir -p "$PLUGIN_DST"
  for id in claude-code codex; do
      mkdir -p "$PLUGIN_DST/$id"
      ditto "$PLUGIN_SRC/$id/" "$PLUGIN_DST/$id/"
      mkdir -p "$PLUGIN_DST/$id/bin"
      cp "$BUILT_PRODUCTS_DIR/${id//-/}PluginSidecar" "$PLUGIN_DST/$id/bin/sidecar"
      chmod +x "$PLUGIN_DST/$id/bin/sidecar"
  done
  ```
  (Adjust executable names to match the SPM output names: `ClaudeCodePluginSidecar`, `CodexPluginSidecar`.)
  Mark the executables as build target dependencies in the project so SPM builds them before this script runs.

- [ ] **Step 5: Verify the .app build.** `xcodebuild build -workspace ... -scheme ClaudeSpyServer` and then inspect `Gallager.app/Contents/Resources/plugins/`. Use the `XcodeBuildTools:xcodebuild` skill.

- [ ] **Step 6: Commit.** Message: `feat: Codex sidecar + plugin bundle tree + Xcode copy phase`.

---

# Phase 5 — App integration

## Task 14: Rename `ClaudeSession` → `AgentSession` and pane-state ripple

**Goal:** Per Spec §10.4, rename the central session type and all pane-state fields. Drop the trailing-5 `events: [HookEvent]` buffer.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/HookModels.swift` — move `ClaudeSession` definition; rename + adjust fields.
- Modify (rename + field changes): every file that referenced the symbol — `ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift`, `Coordinators/AppCoordinator.swift`, `Services/TmuxService.swift`, `Services/APIRequestRouter.swift`, `Views/MainView.swift`, `Views/MainViewComponents/*`, etc., plus E2E scenarios.

- [ ] **Step 1: Define the new type.** In `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentSession.swift`:
  ```swift
  public struct AgentSession: Codable, Sendable, Equatable, Identifiable {
      public let id: String           // session ID from the agent
      public let pluginID: String     // replaces `agent: CodingAgent`
      public var tmuxPane: String?
      public var projectPath: String?
      public var working: Bool        // was isWorking
      public var attention: Bool      // was needsAttention
      public var lastEventTimestamp: Date?
      // 'events: [HookEvent]' field is gone
      public init(...)
  }
  ```
  Move into its own file; keep `HookModels.swift` only for what's not yet deleted (Task 21 cleans the rest).

- [ ] **Step 2: Rename ripple.** Use Xcode global rename or `sed -i`:
  - `ClaudeSession` → `AgentSession`
  - `claudeSession` → `agentSession`
  - `hasClaudeSession` → `hasAgentSession`
  - `claudePanes` → `agentPanes`
  - `markDetectedClaudeSessions` → `markDetectedAgentSessions`
  - `detectClaudePanes` → `detectAgentPanes`
  - `agent: CodingAgent` field → `pluginID: String` (where it lives on `AgentSession`, `AgentProject`)
  - `session.agent.shortName` etc. → look up via `pluginManager.presentation(for: session.pluginID)?.shortName`
  Use `Bash` + `rg --files-with-matches` to find all hits, then bulk replace.

- [ ] **Step 3: Drop the events buffer.** Anywhere code reads `session.events`, rip it out. The places that consumed it:
  - The trailing-5 list was used to derive status. Status now comes from `update_session_status` callbacks routed via `PluginEventDispatcher` → `MirrorWindowManager` (Task 15 wires this).
  - Any UI showing recent events is gone (`EventRowView` deletion in Task 19).

- [ ] **Step 4: Update relay messages.** `RelayMessages.swift` has cross-host `decodeIfPresent` fallbacks per `feedback_no-backward-compat`. The `agent: CodingAgent?` → `pluginID: String?` field migration must keep `decodeIfPresent` so an older paired Mac sending the same field doesn't crash this build. Per Spec §11, the v1.33 bump means older peers can't pair anyway — but the safety net stays. Also add `agent_session_status` and `plugin_presentations` and `agent_response_request` / `agent_response_submission` cases to the `RelayMessage` enum so the Mac → iOS pipe can carry them.

- [ ] **Step 5: Run unit tests.** `swift test`. Fix compilation errors.

- [ ] **Step 6: Commit.** Message: `refactor: rename ClaudeSession→AgentSession + drop events buffer + pluginID field`.

## Task 15: Wire `PluginManager` into `AppCoordinator`

**Goal:** Replace every `CodingAgent` switch with a call into the plugin manager. This is the integration tipping point — after this task the app no longer reaches into Claude- or Codex-specific code directly.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift` — adopt the new sink protocols.
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Managers/MarkdownOpenSuggestionStore.swift` — implement `PluginAppActionSink`.
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/TmuxService.swift` — `detectAgentPanes` fans out across plugin manifests' `process_names` and falls back to `detectPane` RPC for manifests declaring `requires_rich_detection`.
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/PluginService.swift` — fold into / replace by `PluginManager`. Delete the old class once everything is migrated.
- Delete: every `switch agent { case .claudeCode: ... case .codex: ... }` block.

- [ ] **Step 1: Stand up the `PluginManager` instance.** In `AppCoordinator.init`, instantiate the manager:
  ```swift
  let layout = PluginRootLayout.live(rootOverride: LaunchArgs.gallagerStateRoot)
  let manager = PluginManager(
      layout: layout,
      statusSink: mirrorWindowManager, // adopts PluginSessionStatusSink
      notificationSink: macNotificationService,
      responseRequestSink: connectedViewerManager, // forwards to iOS
      appActionSink: appActionRouter,
      agentDriverSink: tmuxAgentDriver,
      yoloProvider: yoloModeProvider
  )
  await manager.start()
  ```
  `MainActor` isolation is appropriate since this is app-bootstrap code.

- [ ] **Step 2: Make `MirrorWindowManager` conform to `PluginSessionStatusSink`.** Its `updateStatus(...)` finds the right `PaneState` by `tmuxPane`/`sessionID`, updates `working`/`attention`, propagates to UI as before. Auto-approve logic in Spec §17.1 / §17.2 now happens up in `PluginEventDispatcher` (yolo applies before the request reaches the sink).

- [ ] **Step 3: Implement `PluginAppActionSink`.** A new `AppActionRouter` (or extend `AppCoordinator`) that switches on `AppAction`:
  - `.openFileSuggestion(sessionID, path, displayName, isPlan)` → call existing `MarkdownOpenSuggestionStore.addSuggestion(...)`.
  - `.dismissFileSuggestions(sessionID)` → `MarkdownOpenSuggestionStore.dismissSuggestions(forSession:)`.
  - `.closePaneIfPreferenceAllows(sessionID)` → read `settings.closePaneOnSessionEnd`, if set → kill the pane via `tmuxService`. (The "reason was `promptInputExit`" check is gone — the sidecar already filtered.)

- [ ] **Step 4: Replace `TmuxService.detectClaudePanes()`.** New `detectAgentPanes()` collects `process_names` from `pluginManager.presentations + manifests` (the manager needs to expose the per-plugin process-name list). Scan tmux pane process trees once and bucket panes by matching process name → plugin id. For any pane that doesn't match and any plugin whose manifest declares `requires_rich_detection: true`, fall through to `pluginManager.detectPane(pluginID:paneInfo:)`. Today's `pluginID` field on `AgentSession` is set from this result.

- [ ] **Step 5: Route iOS response submissions back into the plugin manager.** The relay path receives `agent_response_submission` from iOS; the `ConnectedViewerManager` / `APIRequestRouter` decodes it; the Mac calls `pluginManager.deliverResponse(pluginID:, sessionID:, requestID:, response:)`.

- [ ] **Step 6: Verify the Mac app launches.** Use `XcodeBuildTools:macos-app` skill to start Gallager. Confirm the menu bar item appears and projects are listed in the sidebar (both plugins should report projects). Confirm Settings → Plugins page shows the two bundled plugins.

- [ ] **Step 7: Commit.** Message: `feat: wire PluginManager into AppCoordinator; replace CodingAgent switches`.

## Task 16: Settings migration + per-plugin settings UI

**Goal:** One-shot migrate `Settings.claudeCommandPath` and `Settings.codexCommandPath` into per-plugin `settings.json`; render the per-plugin settings form from the schema.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Models/Settings.swift` — remove `claudeCommandPath` and `codexCommandPath` (after migration).
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/SettingsMigration.swift` — runs once at app startup; idempotent.
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/PluginSettingsView.swift` — schema-driven form (per Spec §17.3 field-type table).
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/SchemaFormBuilder.swift` — turns a `PluginSettingsSchema` into a SwiftUI form.
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/SettingsView.swift` — replace the per-agent rows (`CodexPluginInstallerRow`, inline Claude rows) with a per-plugin generic row that links into a Settings → Plugins → `<id>` detail screen.
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/SettingsMigrationTests.swift`

- [ ] **Step 1: Write failing migration tests.** Pre-state has `claudeCommandPath = "/opt/claude/bin/claude"` and `codexCommandPath = nil` in mocked `UserDefaults`. Run migration; assert `state_dir/claude-code/settings.json` now exists with `{ "command_path": "/opt/claude/bin/claude", ... }` and `state_dir/codex/settings.json` was not created (no value to migrate). Re-running the migration is a no-op.

- [ ] **Step 2: Implement migration.** Reads `UserDefaults.standard.string(forKey: "claudeCommandPath")`; if present, writes JSON to `layout.settingsURL("claude-code")` and clears the UserDefaults key. Same for Codex. Idempotency: track `migrated_v1` flag in `UserDefaults`.

- [ ] **Step 3: Schema-driven form.** Implement `SchemaFormBuilder.view(for schema: PluginSettingsSchema, values: Binding<[String: JSONValue]>) -> some View` rendering each field per the Spec §17.3 table:
  - `string` → `TextField(label, text: $value.string)`
  - `boolean` → `Toggle(label, isOn: $value.bool)`
  - `int` → `Stepper("\(label): \(value)", value: $value.int, in: min...max)`
  - `picker` → `Picker(label, selection: $value.string) { ForEach(options) { ... } }.pickerStyle(options.count <= 4 ? .segmented : .menu)`
  - `file_path` → button that opens `NSOpenPanel`; show selected path.
  Validation errors surface inline.

- [ ] **Step 4: Per-plugin settings page.** `Settings → Plugins → <id>` shows: enabled toggle, version/source line, install hooks button (calling `pluginManager.installSidecarHooks(pluginID:)`), the schema-driven form, View Logs button (opens log viewer per Spec §17.5), uninstall button (disabled for bundled plugins). The log viewer is a `LogViewerSheet` with `Show in Finder`, `Copy All`, `Clear` buttons; reuse the monospace text patterns from `gallager-cli-api`.

- [ ] **Step 5: Run the app, confirm both plugins appear, settings save correctly, log viewer opens.**

- [ ] **Step 6: Commit.** Three commits: migration + tests, schema form, plugin settings page.

## Task 17: `gallager plugin ...` CLI verbs

**Goal:** Add the eight verbs from Spec §17.4 to the existing `GallagerCLI` target.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/Gallager/GallagerCLI.swift` (or wherever subcommands register) — add `plugin` parent with eight subcommands.
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/APIRequestRouter.swift` — add `plugin.*` RPC routes that call into `PluginManager`.
- Update: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Resources/gallager-cli-api.md` — append the new verbs to the API doc that ships with the app.
- Test: extend the existing `GallagerCLIScenario` E2E to call `gallager plugin list --json` and assert output.

- [ ] **Step 1: For each verb in Spec §17.4 table, add a subcommand.** Use the existing `swift-argument-parser` pattern. Each subcommand:
  - Parses args.
  - Constructs the JSON-RPC request and sends it over the existing socket.
  - Renders the reply (default: tabular; `--json`: raw).
  - Exits 0/1/2 per Spec §17.4.

- [ ] **Step 2: Add the eight `plugin.*` RPC routes** on the app side. Each route maps to a `PluginManager` method.

- [ ] **Step 3: Sanity test.** Build the app, run it, run `gallager plugin list` — expect Claude Code and Codex listed as bundled.

- [ ] **Step 4: Commit.** Message: `feat(cli): gallager plugin {list, info, install, remove, enable, disable, update, call, logs}`.

---

# Phase 6 — iOS migration

## Task 18: Wire-format updates on iOS

**Goal:** iOS recognizes the new message types: `agent_session_status`, `agent_response_request`, `agent_response_submission`, `plugin_presentations`.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/RelayMessages.swift` or wherever the wire enum lives — add the four new cases.
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Services/SessionDetailService.swift` (and surrounding) — route inbound messages.
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Services/PluginPresentationCache.swift` — `(pluginID, version)` keyed cache; persisted to disk.

- [ ] **Step 1: Add cases to the relay enum.** Whatever today's union of `WebSocketMessage` / `RelayMessage` looks like, add:
  - `agentSessionStatus(AgentSessionStatusUpdate)`
  - `agentResponseRequest(AgentResponseRequestMessage)` — struct wrapping `request: AgentResponseRequest`, plus `sessionID`, `pluginID`, `requestID`. Decodes `request: null` as "dismiss this request" per Spec §7.5.
  - `agentResponseSubmission(AgentResponseSubmission)` — iOS→Mac direction.
  - `pluginPresentations(PluginPresentationsMessage)`.
  Round-trip tests in `ClaudeSpyNetworkingTests`.

- [ ] **Step 2: Implement presentation cache.** Stores `[String: PluginPresentation]` keyed by id, with version tracking so the Mac can push updates. Persisted as JSON in the app support dir (so the cache survives reconnects). The iOS `AgentSession.pluginID` looks up its icon/name through this cache.

- [ ] **Step 3: Wire inbound routing.** When the iOS app receives `pluginPresentations`, update the cache. When it receives `agentSessionStatus`, find the session by `sessionID + pluginID` and update its `working`/`attention`. When it receives `agentResponseRequest` with a non-nil `request`, present the corresponding response sheet; with a nil `request`, dismiss any sheet matching `requestID`.

- [ ] **Step 4: Commit.** Message: `feat(ios): wire new message types + plugin presentation cache`.

## Task 19: Re-route iOS `ResponseViews` onto `AgentResponseRequest`

**Goal:** Keep the five existing response views but drive them from the closed-set `AgentResponseRequest` cases instead of `HookAction.permissionRequest(...)` cases.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Views/ResponseViews/PromptView.swift` — accept `PromptRequest`, emit `PromptResponse`.
- Modify: `ResponseViews/StopResponseView.swift` — accept `ReplyAfterStopRequest`, emit `ReplyAfterStopResponse`.
- Modify: `ResponseViews/PermissionRequestResponseView.swift` — accept `PermissionRequest`, emit `PermissionResponse`.
- Modify: `ResponseViews/AskUserQuestionResponseView.swift` — accept `AskUserQuestionRequest`, emit `AskUserQuestionResponse` (no more keystroke building on iOS; just structured answers).
- Modify: `ResponseViews/ExitPlanModeResponseView.swift` — accept `ApprovePlanRequest`, emit `ApprovePlanResponse`.
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Models/ResponseState.swift` — replace the old `HookAction`-shaped state.
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Views/EventResponseView.swift` — switch over `AgentResponseRequest` cases.
- Delete: `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Views/ResponseViews/AskUserQuestionKeystrokes.swift` (moved to Mac sidecar in Task 9; iOS no longer needs it).
- Delete: `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Views/EventRowView.swift` per Spec §7.6.
- Update: any preview / E2E refs.

- [ ] **Step 1: Define the new submission flow.** A new `AgentResponseSubmitter` actor that takes `(sessionID, requestID, response)` and writes via the existing command channel. Each response view receives an `onSubmit: (AgentResponse) -> Void` closure.

- [ ] **Step 2: Wire each view.** PromptView returns `.prompt(.init(text: trimmed))`. PermissionView's two suggestion buttons call `onSubmit(.permission(.init(decision: .allow, appliedSuggestionId: suggestion.id)))`. AskUserQuestionView builds an `AskUserQuestionResponse` by walking the user's per-question selections; no keystrokes are constructed.

- [ ] **Step 3: Delete `EventRowView.swift` + its preview + the routing logic that constructed it.** Anywhere it was instantiated (likely `SessionListView` or `MainView`-iOS), replace with whatever Sidebar UI Spec §7.1 calls for: per-session row with icon (from presentation cache), name, working/attention badge.

- [ ] **Step 4: Build the iOS app.** Use `XcodeBuildTools:xcodebuild` for the `ClaudeSpy` scheme.

- [ ] **Step 5: Commit.** Message: `feat(ios): route response views from AgentResponseRequest; delete EventRowView and keystroke builder`.

## Task 20: iOS — delete all `HookEvent` / `HookAction` decoding

**Goal:** Cut every iOS-side reference to the old hook types so the type deletion in Task 21 can proceed without iOS errors.

**Files:**
- `rg HookEvent\|HookAction\|HookSomething` -l inside `ClaudeSpyFeature/`; for each hit, replace with the relevant `AgentResponseRequest`-driven equivalent or delete.

- [ ] **Step 1: Audit.** Run `rg "HookEvent|HookAction|HookCommonFields|SessionStartBody|PreToolUseBody|PostToolUseBody" ClaudeSpyPackage/Sources/ClaudeSpyFeature/`.

- [ ] **Step 2: Remove.** Every iOS use of these types is either status-derived (now `agent_session_status`) or response-driven (now `agent_response_request`). Delete the imports and the types.

- [ ] **Step 3: Build iOS scheme.** `ClaudeSpy` scheme — `xcodebuild` should succeed.

- [ ] **Step 4: Commit.** Message: `refactor(ios): drop all HookEvent/HookAction decoding`.

---

# Phase 7 — Cleanup

## Task 21: Delete legacy types and files

**Goal:** Remove every file the spec marks for deletion. The build must remain green.

**Files (delete):**
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Hooks/HookServerService.swift`
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Hooks/HookModels.swift`
- `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/HookModels.swift` (after the parts that survive — `AgentSession` — moved in Task 14)
- `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/CodingAgent.swift`
- `ClaudeSpyPackage/Sources/ClaudeSpyCommon/UI/HookActionUI.swift`
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/CodexPluginInstallerRow.swift`
- The repo-root `plugin/` folder (already moved in Task 13; the old paths are now empty).
- `Settings.claudeCommandPath`, `Settings.codexCommandPath` UserDefaults keys (removed from `Settings.swift` after migration in Task 16).
- Any test files left orphaned by the moves.

- [ ] **Step 1: Search-and-confirm.** `rg "import .* HookModels|HookServerService|CodingAgent|HookActionUI" ClaudeSpyPackage/Sources` — should report zero hits before deleting.

- [ ] **Step 2: Delete files via `git rm`.**

- [ ] **Step 3: Build all targets.** Both Mac and iOS schemes via `xcodebuild`; SPM `swift build` for the relay/Linux build.

- [ ] **Step 4: Commit.** Message: `chore: delete legacy hook types and per-agent services`.

---

# Phase 8 — E2E migration

## Task 22: `EchoPlugin` fixture and E2E DSL state-root support

**Goal:** Build the reference plugin used by every new E2E scenario, and teach the test orchestrator how to isolate per-test plugin state roots.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Fixtures/EchoPlugin/plugin.json`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Fixtures/EchoPlugin/assets/icon.png` (tiny solid color)
- Create: `ClaudeSpyPackage/Sources/EchoPluginSidecar/main.swift` (new test executable target)
- Create: `ClaudeSpyPackage/Sources/EchoPluginSidecar/EchoSidecar.swift`
- Modify: `Package.swift` — add `EchoPluginSidecar` executable target referenced only by `ClaudeSpyE2ELib` (so it doesn't ship in the .app).
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Bootstrap/...` — wire `--gallager-state-root` arg.
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift` (and the `LaunchArgs` parser) — accept `--gallager-state-root <path>`.

- [ ] **Step 1: `--gallager-state-root` launch arg.** Parse from `CommandLine.arguments` early in app startup; pass to `PluginRootLayout.live(rootOverride:)`. Document in `docs/e2e-testing.md`.

- [ ] **Step 2: Build the `EchoPluginSidecar` executable target.** Implements the JSON-RPC server and ingress socket using `GallagerPluginProtocol`'s `IngressSocketServer` and a small dispatch table. Behavior per Spec §15.5 — every test control payload (`_test: "set_status"`, `_test: "request_permission"`, etc.) maps to a `PluginEvent`. On `deliver_response`, writes the response to `${state_dir}/responses/<request_id>.json` and runs any embedded `_delivery_script`.

- [ ] **Step 3: Build the fixture tree.** `plugin.json`, `assets/icon.png`. Make the icon a 16×16 red PNG (use a simple deterministic generator in the test target).

- [ ] **Step 4: E2E orchestrator support.** A new `EchoPluginInstaller` in `ClaudeSpyE2ELib` that, given the test instance's state-root dir, copies the fixture tree to `<state_root>/plugins/echo/` and the built echo executable to `<state_root>/plugins/echo/bin/sidecar`, then adds it to the registry. Surfaces as a new DSL step: `macSpawnSidecar(pluginID: "echo", executablePath: ..., instance: ...)`.

- [ ] **Step 5: Unit test.** Spawn the EchoSidecar via the supervisor in a `ClaudeSpyE2ELibTests`-style test (or repurpose part of `ClaudeSpyPluginRuntimeTests`) to assert init + a `_test: "set_status"` round-trip works.

- [ ] **Step 6: Commit.** Message: `feat(e2e): EchoPlugin fixture + --gallager-state-root launch arg`.

## Task 23: E2E DSL updates for ingress + plugins

**Goal:** Replace the HTTP hook-server DSL with the new ingress-socket DSL per Spec §15.1.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Drivers/MacOS/MacAppPluginIngressClient.swift` — opens the Unix socket and writes length-prefixed JSON.
- Delete: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Drivers/MacOS/MacAppHTTPClient.swift` (the `sendHook` HTTP path).
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/DSL/TestScenario.swift` — add `macSendRawHookPayload(pluginID:, json:, env:, instance:)` and `macInstallBundledPlugin(pluginID:, instance:)` and `macSpawnSidecar(pluginID:, executablePath:, instance:)` cases; drop `macSendHookEvent`.
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/DSL/StepExecutor.swift` (or equivalent runner) — implement the new cases.

- [ ] **Step 1: Implement the ingress client.**
  ```swift
  public actor MacAppPluginIngressClient {
      public init(socketURL: URL)
      public func send(payload: JSONValue, env: [String: String]) async throws
  }
  ```
  Uses `NWConnection` over Unix socket, writes `UInt32` BE length + JSON body. The DSL step computes `socketURL` from the test instance's `gallager-state-root`.

- [ ] **Step 2: Add the three new DSL cases.** Each case has a struct payload describing args; the executor dispatches.

- [ ] **Step 3: Adjust the `macSendHookEvent` → `macSendRawHookPayload` global rename.** Run `rg macSendHookEvent` across scenarios; each call site needs migration (one of: passing `pluginID: "claude-code"`, moving `project_path` / `tmux_pane` query params into the env map). Don't actually migrate the scenarios yet — that's Task 24; just verify zero scenarios still reference the deleted case so the type-checker fails until they're updated.

- [ ] **Step 4: Commit.** Message: `feat(e2e): MacAppPluginIngressClient + new DSL ingress steps`.

## Task 24: Migrate existing hook-driven E2E scenarios

**Goal:** Every scenario that today uses `macSendHookEvent` becomes `macSendRawHookPayload` per Spec §15.2.

**Affected scenarios** (from `rg`):
- `ClaudeSessionUpdatesScenario`
- `ClaudeSessionRepliesPersistScenario`
- `ClaudeSessionsShowScenario`
- `AskUserQuestionScenario`
- `BadgeAggregationScenario`
- `MarkHandledScenario`
- `MarkdownWriteOpenSuggestionScenario`
- `ClipboardSyncScenario`
- `GallagerCLIScenario`
- `HostDisconnectClearsSessionsScenario`
- `FileBrowserScenario`
- `StopHookSummaryScenario`
- `YoloModeAutoApproveScenario`
- `YoloModeContextCompactionScenario`
- `YoloModeMacToMacScenario`
- `YoloModeStateSyncScenario`

- [ ] **Step 1: For each scenario, rewrite hook sends.** Pattern: every `macSendHookEvent(json: { ... "tmux_pane": ..., "project_path": ... }, instance: ...)` becomes
  ```swift
  .macSendRawHookPayload(
      pluginID: "claude-code",
      json: stripHookEnvelopeFields(...),
      env: ["TMUX_PANE": ..., "CLAUDE_PROJECT_DIR": ...],
      instance: ...
  )
  ```
  The `stripHookEnvelopeFields` helper just removes the now-context fields from the JSON payload.

- [ ] **Step 2: Replace event-label assertions.** Per Spec §15.2:
  - `.labelContains("Prompt Submitted")` (from `EventRowView`) → `.labelContains("Working")` or per-session sidebar badge state.
  - Other event-label asserts that referenced `EventRowView` → `.labelContains("Claude")` (presentation label), or response-form-visibility checks.
  Keep the rest of each scenario intact — same steps, same screenshot points; only the assertion text changes.

- [ ] **Step 3: Re-run scenarios locally.** Per `feedback_test-before-ci` and `feedback_baselines-ci-generated`: run each migrated scenario 2-3 times locally; visually inspect every changed screenshot; **`git rm` any screenshot baselines whose architecture changed and let CI regenerate them**, do not commit locally-regenerated baselines.

- [ ] **Step 4: Commit.** Likely one commit per logical scenario family (Claude session scenarios, yolo scenarios, etc.).

## Task 25: Add new E2E scenarios

**Goal:** Cover the plugin-runtime contract with the seven new scenarios listed in Spec §15.3.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/PluginRuntimeBasicsScenario.swift`
- Create: `Scenarios/PluginCrashRestartScenario.swift`
- Create: `Scenarios/PluginCrashLoopDisableScenario.swift`
- Create: `Scenarios/PluginResponseRequestScenario.swift`
- Create: `Scenarios/PluginPresentationUpdateScenario.swift`
- Create: `Scenarios/PluginProjectPushScenario.swift`
- Create: `Scenarios/PluginAskUserQuestionRoundTripScenario.swift`
- Modify: `Scenarios/AllScenarios.swift` (or wherever the registry lives) — register the new scenarios.

- [ ] **Step 1: Implement each scenario per Spec §15.3 description.** Each scenario:
  1. Boots the orchestrator with `--gallager-state-root` (default behavior from Task 22).
  2. Calls `macSpawnSidecar(pluginID: "echo", executablePath: <fixture path>, ...)`.
  3. Drives the EchoPlugin via `macSendRawHookPayload(..., json: {"_test": "..."})`.
  4. Asserts on Mac/iOS state per scenario goal.
  Screenshots at key moments per `feedback_e2e-test-patterns` (no `compare: false`; visually verify baselines before commit).

- [ ] **Step 2: Run all new scenarios locally 2-3x.** Verify every screenshot. Save review copies, **do not commit locally-regenerated baselines** — let CI generate them.

- [ ] **Step 3: Commit.** One commit per scenario file.

---

# Phase 9 — Validation

## Task 26: Full-suite validation and cleanup

**Goal:** Get to a green build with zero unit-test failures and zero E2E failures (existing or new). Update any baselines that legitimately changed because of test architecture changes (per the user's instruction).

- [ ] **Step 1: Run all unit tests.** `swift test` at the package root. Address any leftover compile errors / failures from cleanup.

- [ ] **Step 2: Build both Xcode schemes.** `ClaudeSpyServer` (macOS) and `ClaudeSpy` (iOS).

- [ ] **Step 3: Run the full E2E suite locally.** `./scripts/e2e-test.sh` (per `docs/e2e-testing.md`). Confirm every scenario passes 2-3 times.

- [ ] **Step 4: Sweep for orphaned types / files.** `rg "CodingAgent|HookEvent|HookAction|HookServerService|ClaudeSession|ClaudeProjectInfo|claudeCommandPath|codexCommandPath"` should yield zero hits in app/test code. Any survivors in docs that are still accurate stay (with updates explaining the deprecation); inaccurate doc lines get updated.

- [ ] **Step 5: Update docs.** Touch:
  - `docs/architecture.md` — replace per-agent integration sections with a plugin-runtime section pointing at the spec.
  - `docs/codex-cli-integration-plan.md` — add a note at the top saying "Superseded by the plugin system; see Spec §2026-05-24."
  - `docs/distributed-architecture-plan.md` — update the iOS surface section to match Spec §7.
  - `docs/e2e-testing.md` — document `--gallager-state-root` and the new DSL steps.
  - `CLAUDE.md` — refresh the package layout section.

- [ ] **Step 6: Final commit.** Message: `docs: update for plugin-system flag-day` (and any other small fixes).

- [ ] **Step 7: Verify the goal is met.** Re-check Spec §3 decision table and §11 rollout list — every line item should be done.

---

## Self-Review

Spec coverage:
- Spec §1 (Goal) — Tasks 1–25 collectively replace built-in agent support with the plugin system. ✓
- Spec §2 (Background) — Tasks 8, 10, 14, 15, 21 move each "Current implementation" cell out of the app. ✓
- Spec §3 (Decisions) — Mapped: scope (Tasks 4–13), runtime (Tasks 5, 12, 13), distribution (Tasks 7, 17, 22), trust (Task 7), iOS rendering (Tasks 18–20), event ingress (Tasks 6, 13, 22), wire compat (Task 2), rollout (Phase ordering). ✓
- Spec §4 (Layout) — Task 4 (`PluginRootLayout`), Task 13 (Xcode build phase). ✓
- Spec §5 (Manifest) — Task 3 (`PluginManifest` type), Task 13 (real bundled manifests). ✓
- Spec §6 (Sidecar protocol) — Task 3 (RPC method enum), Task 5 (`JSONRPCConnection`), Tasks 12/13 (sidecar implementations of each method). ✓
- Spec §7 (iOS surface) — Tasks 18, 19, 20. ✓
- Spec §8 (Hook ingress) — Task 6 (`IngressSocketServer`), Task 13 (bridge scripts), Task 23 (E2E client). ✓
- Spec §9 (Distribution) — Task 7 (`install`/`update`/`uninstall` in `PluginManager`), Task 17 (CLI), out-of-scope items per Spec §16 noted. ✓
- Spec §10 (Extraction map) — Tasks 8–11, 14, 15, 16, 21. ✓
- Spec §11 (Rollout order) — Phase 1–9 mirrors the spec's numbered list. ✓
- Spec §12 (Supervision) — Task 5. ✓
- Spec §13 (Error handling) — Spread across Tasks 5, 7, 12, 13, 16 as inline policies in the respective implementations. ✓
- Spec §14 (Testing strategy) — Task 9 (translator unit tests), Task 5 (JSON-RPC contract tests with EchoSidecar fixture), Tasks 22–25 (E2E). ✓
- Spec §15 (E2E migration) — Tasks 22, 23, 24, 25. ✓
- Spec §16 (Non-goals) — Honored; sandboxing, signing, in-app discovery, hot-reload not in any task. ✓
- Spec §17.1 (`AppAction` enum) — Task 1 + Task 15 sink wiring. ✓
- Spec §17.2 (`HookAction` → sidecar behavior) — Task 9 (translator) + Task 10 (Codex translator). ✓
- Spec §17.3 (Settings schema) — Task 11 (bundled JSON), Task 16 (schema renderer). ✓
- Spec §17.4 (CLI verbs) — Task 17. ✓
- Spec §17.5 (Log viewer) — Task 16. ✓

Placeholder scan: No "TBD" / "implement later" / "add appropriate error handling" steps. Steps that delegate to spec sections reference exact section numbers. ✓

Type consistency: `AgentResponseRequest`, `AgentResponse`, `PluginEvent`, `AppAction`, `PluginManifest`, `PluginPresentation` are introduced in Tasks 1/3 and used by every subsequent task with the same names. ✓

---

**Plan complete.** Total: 26 tasks across 9 phases, single flag-day PR, expected to produce a working build with all unit tests + all E2E scenarios (old migrated + 7 new) passing.
