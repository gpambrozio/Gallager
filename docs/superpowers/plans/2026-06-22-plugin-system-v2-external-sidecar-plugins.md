# Plugin System v2 (external sidecar plugins) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Date: 2026-06-22
Spec: `docs/superpowers/specs/2026-05-29-plugin-system-v2-external-sidecar-plugins.md`
Builds on: `docs/superpowers/specs/2026-05-29-plugin-system-v1-in-process.md` (shipped)
Suggested branch: `plugin-system-v2-sidecar`

**Goal:** Let third parties ship out-of-process, URL-distributed coding-agent plugins (sidecars) that satisfy the *same* `PluginCore` contract as bundled in-process plugins, supervised and crash-isolated by Gallager, with no change to the dispatcher, iOS, or relay.

**Architecture:** Add exactly one new `PluginCore` conformer — `SidecarPluginCore` — that marshals each `PluginCore` method to a JSON-RPC request over a child process's stdio (LSP `Content-Length` framing) and translates inbound notifications back into `PluginHost` callbacks. A `SidecarSupervisor` owns the child process lifecycle (spawn, stderr logging, crash counter/backoff/auto-disable). `PluginRegistry.makeCore` gains the `.sidecar` construction path it already stubs. Distribution (HTTPS manifest+bundle fetch, SHA-256 integrity pinning, zip-slip-hardened unpack, an on-disk `registry.json`, a trust prompt, and install/update/remove CLI verbs) is layered on top. Everything upstream of `PluginCore` — the dispatcher, the one app-owned ingress socket, the OTLP receiver, `PluginEvent`, `AgentResponseRequest`, the iOS surface — is untouched.

**Tech Stack:** Swift 6.1+, Swift Concurrency (actors for I/O), `Foundation.Process`, SwiftUI (MV pattern, no ViewModels), Point-Free Dependencies, swift-testing, the `ClaudeSpyE2ELib` Swift-DSL E2E framework. SPM package at `ClaudeSpyPackage/`.

---

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the spec and the live code.

- **The v1 contract is frozen.** Do not change `PluginCore`, `PluginHost`, `PluginEvent`, `AgentResponseRequest`/`AgentResponse`, `IngressFrame`, or the iOS wire. v2 is *additive*. The contract already has the v2-ready shape: `PluginCore.install(configRoot:)`/`uninstall(configRoot:)`/`installStatus(configRoot:)`, `PluginHost.agentPanes() async -> [String]`, `PluginEnv.marketplaceSource`/`otlpReceiverEndpoint`, and `Manifest.Runtime { inProcess, sidecar }`.
- **Bundled plugins stay in-process.** Only `runtime: "sidecar"`, `source: "url"`/folder-drop plugins are sidecars. Never convert `claude-code`/`codex`.
- **No `VersionCompatibility` bump.** v2 is a Mac-app capability addition; iOS/relay parse nothing new. `VersionCompatibility` stays at its v1 value on both sides.
- **One hook ingress socket only.** Do **not** add a per-sidecar ingress socket, a `health` heartbeat, or `detect_pane`-by-default. Ingress stays on `~/.gallager/state/ingress.sock`; crash detection is `Process.terminationHandler` + per-RPC timeout; rich pane detection is an opt-in capability.
- **Transport framing = LSP `Content-Length`.** The sidecar stdio transport uses `Content-Length: <n>\r\n\r\n<json>` framing (distinct from the ingress socket's 4-byte big-endian prefix). Hard caps: header ≤ 16 KiB (`malformedHeader` past the cap), body ≤ 32 MiB (reject the `Content-Length` *before* allocating). Use `loadUnaligned(as:)` on any `Data` integer load, never `load(as:)`.
- **No fire-and-forget for ordered sends.** Await inbound-notification delegate calls inline in the read loop to preserve wire order (project rule). Register a pending-request continuation slot *synchronously before* writing the request frame.
- **Per-RPC timeouts are mandatory.** Default 30 s; `initialize` uses 10 s. A timed-out RPC surfaces an error and never hangs the app.
- **stderr log file is `logs/stderr.log`, NOT `logs/sidecar.log`.** `PluginLogSink` already owns `<stateDir>/logs/sidecar.log` for `host.log()`. The spec's "stderr → sidecar.log" would clobber it, so route the child's stderr to a *separate* `<stateDir>/logs/stderr.log`, size-rotated at 5 MB (reuse `PluginLogSink`'s rotation approach). This is the one deliberate deviation from the spec's literal path; everything else matches.
- **Security scope is transport-trust only.** `https://` fetch, SHA-256 bundle→manifest integrity pin, explicit trust prompt, install-time path/zip-slip hardening. No code signing, no publisher identity, no OS sandbox (all v2.x/v3). A sidecar runs as the user with full permissions; the trust prompt must say so verbatim: **"This plugin runs arbitrary code on your Mac."**
- **`manifest.id` sanitization is mandatory before any path use:** regex `^[a-z0-9][a-z0-9._-]*$`, no `..`, ≤128 chars. Applies to URL install *and* folder-drop.
- **Heavy work off the MainActor.** Download, unzip, `waitUntilExit`, SHA-256 hashing run off the MainActor; the UI only awaits results.
- **Build/test go through XcodeBuildTools skills.** Use the `swift-package` skill for `swift build`/`swift test` (the sandbox wrappers inject isolated DerivedData/SPM caches). `Run:` commands below are written as `swift test --filter …` for clarity; execute them via the skill.
- **Concurrency/style:** `@MainActor` for UI; actors for I/O; all cross-boundary types `Sendable`; `guard let`/`if let`, no force-unwrap on parsed/network data (a trap in a sidecar's *host-side* code still crashes Gallager — the isolation only covers the child process); SF Symbols via `Symbols.swift` (alphabetically sorted, `@SFSymbol`); no GCD except the established `DispatchQueue.global()` bridge for blocking POSIX I/O behind a continuation (the `TmuxControlClient`/`IngressSocketServer` pattern).
- **Frequent commits, TDD, DRY, YAGNI.** Each task ends green and committed.

---

## File Structure

### New files

**Shared, pure (`ClaudeSpyPackage/Sources/GallagerPluginProtocol/`)** — usable by both the app and the executable test fixture:
- `SidecarWire.swift` — the JSON-RPC envelope (`RPCMessage`), `StdioFramer` (Content-Length codec), method-name constants (`SidecarRPC`, `HostRPC`), and the Codable wire DTOs that aren't already Codable (`PluginEnvWire`, `IngressFrameWire`).
- `Manifest.swift` (modify) — add the v2 fields + `Sidecar`/`Capabilities` sub-structs.

**App, macOS (`ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/`):**
- `PluginRootLayout.swift` — the on-disk paths a sidecar needs (plugin root, state dir, log dir, ingress socket path).
- `SidecarTransport.swift` — actor: long-lived stdio JSON-RPC, request/response correlation in *both* directions, per-RPC timeout, ordered notification delivery.
- `SidecarSupervisor.swift` — actor: spawn, stderr→`stderr.log`, `terminationHandler`, crash counter/backoff/auto-disable, graceful shutdown (SIGTERM→SIGKILL).
- `SidecarPluginCore.swift` — actor, `PluginCore` conformer; marshals each method ↔ RPC, retains the `PluginHost`, synthesizes callbacks from inbound notifications, services the inbound `agent_panes` request.
- `SidecarStderrLog.swift` — 5 MB-rotated stderr sink (thin reuse of `PluginLogSink`'s rotation).

**App, macOS (`ClaudeSpyServerFeature/Plugins/`):**
- `PluginRegistryStore.swift` — Codable `registry.json` model (`source`, `runtime`, `id`, `version`, `manifestURL?`, `bundleURL?`, `bundleSHA256?`, `enabled`) + atomic load/save.

**App, macOS (`ClaudeSpyServerFeature/Distribution/`):**
- `PluginInstaller.swift` — HTTPS manifest+bundle fetch (size caps), SHA-256 verify, unzip + zip-slip rejection, atomic install/swap, folder-drop discovery.
- `PluginUpdateChecker.swift` — `If-None-Match`/`If-Modified-Since` manifest re-fetch, "newer version" detection, source-changed re-trust.
- `TrustDetails.swift` — the value the trust sheet renders (display name, publisher, version, source URL, bundle size, sha256).

**App, macOS UI (`ClaudeSpyServerFeature/Views/`):**
- `AddPluginSheet.swift` — "Add Plugin from URL…" entry + the trust sheet.

**Executable test fixture (`ClaudeSpyPackage/Sources/EchoPluginSidecar/`):**
- `main.swift` — a real out-of-process sidecar: reads `Content-Length` frames on stdin, answers `initialize`/`translate_event`/`deliver_response`/…, pushes `set_projects`/`emit_event`/`send_text`, supports a control payload that aborts (crash test) and a configurable response-delivery script. Built as an `executableTarget`.

**Tests:**
- `Tests/GallagerPluginProtocolTests/SidecarWireTests.swift`, `ManifestV2Tests.swift`.
- `Tests/ClaudeSpyServerFeatureTests/SidecarPluginCoreTests.swift` (with `MockSidecarProcess`), `SidecarSupervisorTests.swift`, `PluginInstallerTests.swift`, `PluginRegistryStoreTests.swift`, `PluginManifestSanitizeTests.swift`.
- `Sources/ClaudeSpyE2ELib/Scenarios/PluginCrashRestartScenario.swift`, `PluginCrashLoopDisableScenario.swift`, `PluginSidecarResponseRoundTripScenario.swift`.

**Docs:**
- `docs/plugins/sidecar-authoring.md` — the durable external contract a third party builds against.

### Modified files (key)
- `Plugins/PluginRegistry.swift` — `.sidecar` arm in `makeCore`; runtime sidecar registration; `registry.json`-backed `source`; widen `callCore` to a passthrough for sidecar RPCs.
- `Plugins/GallagerPaths.swift` — `pluginsDir` (`~/.gallager/plugins/`), `pluginStderrLogPath(_:)`, staging/replacing dirs.
- `Coordinators/AppCoordinator.swift` — enable url/folder-drop sidecars in `setupPluginRuntime`; pass `GallagerPaths` to the registry; `GALLAGER_INGRESS_SOCK` into the layout; `installPluginFromURL`/`removePlugin`/`checkPluginUpdates` coordinator methods.
- `Services/APIRequestRouter.swift` — `plugin.install`/`plugin.remove`/`plugin.update` methods + widen the `plugin.call` passthrough.
- `Sources/Gallager/Commands/PluginCommands.swift` — `install`/`remove`/`update` subcommands.
- `Views/AgentsSettingsView.swift` (+ `Models/Settings.swift`) — "Add Plugin from URL…" affordance + sidecar lifecycle rows.
- `UI/Symbols.swift` — any new symbols.
- `Package.swift` — `EchoPluginSidecar` executable target; test-target deps.

---

## Milestone A — Manifest + wire foundations (no behavior change)

### Task 1: Extend `PluginManifest` with the v2 fields

**Files:**
- Modify: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/Manifest.swift`
- Test: `ClaudeSpyPackage/Tests/GallagerPluginProtocolTests/ManifestV2Tests.swift`

**Interfaces:**
- Produces: `PluginManifest.sidecar: Sidecar?`, `.capabilities: Capabilities`, `.publisher: String?`, `.manifestURL: URL?`, `.bundleURL: URL?`, `.bundleSHA256: String?`, `.signature: String?`; nested `PluginManifest.Sidecar { executable: String; args: [String] }`, `PluginManifest.Capabilities { richPaneDetection: Bool; modalPrompts: Bool }`. All decode tolerantly (absent ⇒ nil/false). The existing fields and `Runtime` enum are unchanged.

- [ ] **Step 1: Write the failing test**

```swift
// ManifestV2Tests.swift
import Foundation
import Testing
@testable import GallagerPluginProtocol

@Suite("PluginManifest v2 fields")
struct ManifestV2Tests {
    private func decode(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    @Test("decodes a full sidecar manifest")
    func fullSidecar() throws {
        let m = try decode("""
        {
          "schema_version": 1, "id": "opencode", "display_name": "OpenCode",
          "short_name": "OpenCode", "version": "1.2.0", "publisher": "opencode.ai",
          "manifest_url": "https://opencode.ai/plugins/gallager.json",
          "bundle_url": "https://opencode.ai/plugins/opencode-1.2.0.zip",
          "bundle_sha256": "abc123", "runtime": "sidecar",
          "sidecar": { "executable": "bin/sidecar", "args": ["--serve"] },
          "process_names": ["opencode"],
          "capabilities": { "rich_pane_detection": true, "modal_prompts": false },
          "ui": { "icon": "assets/icon.png", "color": "#3a7fcb" }
        }
        """)
        #expect(m.runtime == .sidecar)
        #expect(m.publisher == "opencode.ai")
        #expect(m.bundleURL?.absoluteString == "https://opencode.ai/plugins/opencode-1.2.0.zip")
        #expect(m.bundleSHA256 == "abc123")
        #expect(m.sidecar?.executable == "bin/sidecar")
        #expect(m.sidecar?.args == ["--serve"])
        #expect(m.capabilities.richPaneDetection == true)
        #expect(m.capabilities.modalPrompts == false)
    }

    @Test("a bundled v1 manifest still decodes; v2 fields default empty/false")
    func bundledStillDecodes() throws {
        let m = try decode("""
        { "schema_version": 1, "id": "claude-code", "display_name": "Claude Code",
          "short_name": "Claude", "version": "1.0.0", "process_names": ["claude"],
          "ui": { "icon": "assets/icon.png", "color": "#cb6f3a" } }
        """)
        #expect(m.runtime == .inProcess)
        #expect(m.sidecar == nil)
        #expect(m.bundleURL == nil)
        #expect(m.capabilities.richPaneDetection == false)
        #expect(m.capabilities.modalPrompts == false)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails to compile / fails**

Run: `swift test --filter ManifestV2Tests` (via the `swift-package` skill)
Expected: FAIL — `value of type 'PluginManifest' has no member 'sidecar'` (and similar).

- [ ] **Step 3: Add the fields + sub-structs + decode**

In `Manifest.swift`, add to `PluginManifest` (after the existing stored properties):

```swift
public let publisher: String?
public let manifestURL: URL?
public let bundleURL: URL?
public let bundleSHA256: String?
public let signature: String?
public let sidecar: Sidecar?
public let capabilities: Capabilities

public struct Sidecar: Sendable, Codable, Equatable {
    public let executable: String
    public let args: [String]
    public init(executable: String, args: [String] = []) {
        self.executable = executable
        self.args = args
    }
}

public struct Capabilities: Sendable, Codable, Equatable {
    public let richPaneDetection: Bool
    public let modalPrompts: Bool
    public init(richPaneDetection: Bool = false, modalPrompts: Bool = false) {
        self.richPaneDetection = richPaneDetection
        self.modalPrompts = modalPrompts
    }
    private enum CodingKeys: String, CodingKey {
        case richPaneDetection = "rich_pane_detection"
        case modalPrompts = "modal_prompts"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.richPaneDetection = try c.decodeIfPresent(Bool.self, forKey: .richPaneDetection) ?? false
        self.modalPrompts = try c.decodeIfPresent(Bool.self, forKey: .modalPrompts) ?? false
    }
}
```

Add to `CodingKeys`:

```swift
case publisher
case manifestURL = "manifest_url"
case bundleURL = "bundle_url"
case bundleSHA256 = "bundle_sha256"
case signature
case sidecar
case capabilities
```

Add to `init(from:)` (after the existing decodes):

```swift
self.publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
self.manifestURL = try container.decodeIfPresent(URL.self, forKey: .manifestURL)
self.bundleURL = try container.decodeIfPresent(URL.self, forKey: .bundleURL)
self.bundleSHA256 = try container.decodeIfPresent(String.self, forKey: .bundleSHA256)
self.signature = try container.decodeIfPresent(String.self, forKey: .signature)
self.sidecar = try container.decodeIfPresent(Sidecar.self, forKey: .sidecar)
self.capabilities = try container.decodeIfPresent(Capabilities.self, forKey: .capabilities)
    ?? Capabilities()
```

Update the memberwise `init(...)` to accept and default the new fields (`publisher: String? = nil`, `manifestURL: URL? = nil`, `bundleURL: URL? = nil`, `bundleSHA256: String? = nil`, `signature: String? = nil`, `sidecar: Sidecar? = nil`, `capabilities: Capabilities = Capabilities()`), assigning each. Keep `Equatable`/`Codable` synthesis intact.

- [ ] **Step 4: Run the test, verify pass**

Run: `swift test --filter ManifestV2Tests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/GallagerPluginProtocol/Manifest.swift \
        ClaudeSpyPackage/Tests/GallagerPluginProtocolTests/ManifestV2Tests.swift
git commit -m "feat(plugin-v2): decode v2 sidecar manifest fields"
```

---

### Task 2: The `StdioFramer` (LSP Content-Length codec)

**Files:**
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/SidecarWire.swift`
- Test: `ClaudeSpyPackage/Tests/GallagerPluginProtocolTests/SidecarWireTests.swift`

**Interfaces:**
- Produces:
  - `enum StdioFramer` with `static func encode(_ body: Data) -> Data` (prepends `Content-Length: <n>\r\n\r\n`).
  - `actor`-free incremental decoder `struct FrameDecoder { mutating func push(_ chunk: Data) throws -> [Data] }` that accumulates bytes and returns each complete JSON body; throws `FramingError.malformedHeader` if the header exceeds 16 KiB without `\r\n\r\n`, and `FramingError.bodyTooLarge(Int)` if `Content-Length` > 32 MiB.
  - `enum FramingError: Error, Equatable { case malformedHeader; case bodyTooLarge(Int); case missingContentLength }`.
- Consumed by: Task 4 (`SidecarTransport`) and the `EchoPluginSidecar` fixture (Task 10).

- [ ] **Step 1: Write the failing test**

```swift
// SidecarWireTests.swift
import Foundation
import Testing
@testable import GallagerPluginProtocol

@Suite("StdioFramer")
struct StdioFramerTests {
    @Test("encode prepends a Content-Length header + blank line")
    func encodeShape() {
        let framed = StdioFramer.encode(Data("{}".utf8))
        #expect(String(decoding: framed, as: UTF8.self) == "Content-Length: 2\r\n\r\n{}")
    }

    @Test("decoder reassembles a frame split across chunks")
    func splitChunks() throws {
        var dec = FrameDecoder()
        let framed = StdioFramer.encode(Data(#"{"a":1}"#.utf8))
        #expect(try dec.push(framed.prefix(5)).isEmpty)           // header start only
        let bodies = try dec.push(framed.suffix(from: framed.index(framed.startIndex, offsetBy: 5)))
        #expect(bodies.count == 1)
        #expect(String(decoding: bodies[0], as: UTF8.self) == #"{"a":1}"#)
    }

    @Test("decoder yields two frames from one chunk, in order")
    func twoFrames() throws {
        var dec = FrameDecoder()
        var buf = StdioFramer.encode(Data(#"{"n":1}"#.utf8))
        buf.append(StdioFramer.encode(Data(#"{"n":2}"#.utf8)))
        let bodies = try dec.push(buf)
        #expect(bodies.map { String(decoding: $0, as: UTF8.self) } == [#"{"n":1}"#, #"{"n":2}"#])
    }

    @Test("header past 16 KiB without terminator throws malformedHeader")
    func headerCap() {
        var dec = FrameDecoder()
        let hostile = Data(repeating: UInt8(ascii: "X"), count: 17 * 1024)
        #expect(throws: FramingError.malformedHeader) { _ = try dec.push(hostile) }
    }

    @Test("Content-Length above 32 MiB is rejected before allocation")
    func bodyCap() {
        var dec = FrameDecoder()
        let header = Data("Content-Length: \(33 * 1024 * 1024)\r\n\r\n".utf8)
        #expect(throws: FramingError.bodyTooLarge(33 * 1024 * 1024)) { _ = try dec.push(header) }
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `swift test --filter StdioFramerTests`
Expected: FAIL — `cannot find 'StdioFramer' in scope`.

- [ ] **Step 3: Implement the framer**

Create `SidecarWire.swift` with (this task implements only the framer; the RPC envelope is Task 3):

```swift
import Foundation

public enum FramingError: Error, Equatable {
    case malformedHeader
    case bodyTooLarge(Int)
    case missingContentLength
}

public enum StdioFramer {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 32 * 1024 * 1024

    public static func encode(_ body: Data) -> Data {
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }
}

/// Incremental, allocation-bounded decoder for `Content-Length`-framed JSON.
/// Not thread-safe; the transport actor owns one and feeds it inline.
public struct FrameDecoder {
    private var buffer = Data()
    private var expectedBody: Int?     // set once a header is parsed; nil while reading a header
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    public init() {}

    /// Append `chunk`; return every complete body it completes, in order.
    public mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var bodies: [Data] = []
        while true {
            if let need = expectedBody {
                guard buffer.count >= need else { break }
                bodies.append(buffer.prefix(need))
                buffer.removeFirst(need)
                expectedBody = nil
                continue
            }
            guard let range = buffer.range(of: Self.headerTerminator) else {
                if buffer.count > StdioFramer.maxHeaderBytes { throw FramingError.malformedHeader }
                break
            }
            let header = buffer[buffer.startIndex ..< range.lowerBound]
            if header.count > StdioFramer.maxHeaderBytes { throw FramingError.malformedHeader }
            guard let length = Self.contentLength(header) else { throw FramingError.missingContentLength }
            if length > StdioFramer.maxBodyBytes { throw FramingError.bodyTooLarge(length) }
            buffer.removeSubrange(buffer.startIndex ..< range.upperBound)
            expectedBody = length
        }
        return bodies
    }

    private static func contentLength(_ header: Data) -> Int? {
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the test, verify pass**

Run: `swift test --filter StdioFramerTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/GallagerPluginProtocol/SidecarWire.swift \
        ClaudeSpyPackage/Tests/GallagerPluginProtocolTests/SidecarWireTests.swift
git commit -m "feat(plugin-v2): Content-Length stdio framer with header/body caps"
```

---

### Task 3: The JSON-RPC envelope + method vocabulary + wire DTOs

**Files:**
- Modify: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/SidecarWire.swift`
- Test: `ClaudeSpyPackage/Tests/GallagerPluginProtocolTests/SidecarWireTests.swift`

**Interfaces:**
- Produces:
  - `struct RPCMessage: Codable, Sendable, Equatable { var id: String?; var method: String?; var params: JSONValue?; var result: JSONValue?; var error: RPCError? }` — a single envelope covering request (`id`+`method`+`params`), response (`id`+`result`/`error`), and notification (`method`+`params`, no `id`). Helper constructors: `.request(id:method:params:)`, `.notification(method:params:)`, `.response(id:result:)`, `.failure(id:error:)`. Computed `var isRequest`, `var isNotification`, `var isResponse`.
  - `struct RPCError: Codable, Sendable, Equatable { var code: String; var message: String }` with `static let methodNotFound = RPCError(code: "method_not_found", message: ...)`.
  - `enum SidecarRPC` (App→Sidecar method names) and `enum HostRPC` (Sidecar→App names) as `String` constant holders matching spec §2.
  - `struct PluginEnvWire: Codable, Sendable` mirroring `PluginEnv` minus `host`, with `settings` carried as a **nested JSON value** (`JSONValue`), not base64. Plus `init(from: PluginEnv)` and the inverse used by the fixture.
- Consumed by: Task 4, Task 6, Task 10. `JSONValue` is the existing `ClaudeSpyNetworking.JSONValue`.

- [ ] **Step 1: Write the failing test** (append to `SidecarWireTests.swift`)

```swift
import ClaudeSpyNetworking

@Suite("RPCMessage")
struct RPCMessageTests {
    @Test("request round-trips through JSON")
    func requestRoundTrip() throws {
        let msg = RPCMessage.request(id: "1", method: SidecarRPC.initialize,
                                     params: .object(["appVersion": .string("2.0")]))
        let data = try JSONEncoder().encode(msg)
        let back = try JSONDecoder().decode(RPCMessage.self, from: data)
        #expect(back == msg)
        #expect(back.isRequest)
        #expect(!back.isNotification)
    }

    @Test("a notification has no id")
    func notificationHasNoID() throws {
        let n = RPCMessage.notification(method: HostRPC.emitEvent, params: .object([:]))
        #expect(n.id == nil)
        #expect(n.isNotification)
        let data = try JSONEncoder().encode(n)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"id\""))
    }

    @Test("method-name constants match the spec vocabulary")
    func methodNames() {
        #expect(SidecarRPC.translateEvent == "translate_event")
        #expect(SidecarRPC.commandForLaunch == "command_for_launch")
        #expect(HostRPC.setProjects == "set_projects")
        #expect(HostRPC.agentPanes == "agent_panes")
    }
}

@Suite("PluginEnvWire")
struct PluginEnvWireTests {
    @Test("settings ride as nested JSON, not base64")
    func settingsNested() throws {
        let env = PluginEnv(
            pluginRoot: URL(fileURLWithPath: "/p"), stateDir: URL(fileURLWithPath: "/s"),
            appVersion: "2.0", settings: Data(#"{"auto_run":true}"#.utf8),
            marketplaceSource: URL(fileURLWithPath: "/m"),
            otlpReceiverEndpoint: URL(string: "http://127.0.0.1:4318"))
        let wire = try PluginEnvWire(env)
        let json = try JSONEncoder().encode(wire)
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains(#""auto_run":true"#))      // embedded object, not a quoted blob
        #expect(!text.contains("eyJ"))                    // no base64
        // Round-trips back to the same settings bytes.
        let decoded = try JSONDecoder().decode(PluginEnvWire.self, from: json)
        #expect(decoded.settingsData() == env.settings)
    }
}
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --filter "RPCMessageTests|PluginEnvWireTests"`
Expected: FAIL — `cannot find 'RPCMessage' in scope`.

- [ ] **Step 3: Implement the envelope, vocabulary, and `PluginEnvWire`** (append to `SidecarWire.swift`)

```swift
import ClaudeSpyNetworking

public struct RPCError: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
    public static func methodNotFound(_ method: String) -> RPCError {
        RPCError(code: "method_not_found", message: "Unknown method: \(method)")
    }
}

public struct RPCMessage: Codable, Sendable, Equatable {
    public var id: String?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: RPCError?

    public init(id: String? = nil, method: String? = nil, params: JSONValue? = nil,
                result: JSONValue? = nil, error: RPCError? = nil) {
        self.id = id; self.method = method; self.params = params
        self.result = result; self.error = error
    }

    public static func request(id: String, method: String, params: JSONValue?) -> RPCMessage {
        RPCMessage(id: id, method: method, params: params)
    }
    public static func notification(method: String, params: JSONValue?) -> RPCMessage {
        RPCMessage(method: method, params: params)
    }
    public static func response(id: String, result: JSONValue?) -> RPCMessage {
        RPCMessage(id: id, result: result ?? .object([:]))
    }
    public static func failure(id: String, error: RPCError) -> RPCMessage {
        RPCMessage(id: id, error: error)
    }

    public var isResponse: Bool { id != nil && method == nil }
    public var isRequest: Bool { id != nil && method != nil }
    public var isNotification: Bool { id == nil && method != nil }
}

/// App→Sidecar method names (each `PluginCore` method, serialized).
public enum SidecarRPC {
    public static let initialize = "initialize"
    public static let translateEvent = "translate_event"        // handleIngress
    public static let deliverResponse = "deliver_response"
    public static let refreshProjects = "refresh_projects"
    public static let commandForLaunch = "command_for_launch"
    public static let install = "install"
    public static let uninstall = "uninstall"
    public static let installStatus = "install_status"
    public static let applySettings = "apply_settings"
    public static let shutdown = "shutdown"
    public static let detectPane = "detect_pane"                // optional capability
}

/// Sidecar→App message names (each `PluginHost` method, serialized).
public enum HostRPC {
    public static let setProjects = "set_projects"              // notification
    public static let emitEvent = "emit_event"                  // notification
    public static let sendText = "send_text"                    // notification
    public static let sendKeys = "send_keys"                    // notification
    public static let log = "log"                               // notification
    public static let agentPanes = "agent_panes"                // REQUEST (returns [String])
    public static let promptUser = "prompt_user"               // optional capability (notification)
}

/// `PluginEnv` minus the non-serializable `host`, with `settings` as nested JSON.
public struct PluginEnvWire: Codable, Sendable, Equatable {
    public var pluginRoot: String
    public var stateDir: String
    public var appVersion: String
    public var settings: JSONValue          // the parsed settings.json (or .object([:]) when empty)
    public var marketplaceSource: String
    public var otlpReceiverEndpoint: String?

    public init(_ env: PluginEnv) throws {
        self.pluginRoot = env.pluginRoot.path
        self.stateDir = env.stateDir.path
        self.appVersion = env.appVersion
        self.marketplaceSource = env.marketplaceSource.path
        self.otlpReceiverEndpoint = env.otlpReceiverEndpoint?.absoluteString
        if env.settings.isEmpty {
            self.settings = .object([:])
        } else {
            self.settings = try JSONDecoder().decode(JSONValue.self, from: env.settings)
        }
    }

    /// Re-encode the embedded settings object back to canonical JSON bytes.
    public func settingsData() -> Data {
        (try? JSONEncoder().encode(settings)) ?? Data()
    }
}
```

> Note: `JSONValue` must support `Decodable` from arbitrary JSON and `.object`/`.string`/`.bool` cases — confirm against `ClaudeSpyNetworking/Models/JSONRPC.swift`. If `JSONValue` lacks a `Decodable` that accepts a raw object, add it in that file as part of this task (a small, well-scoped extension) and cover it with one assertion in `PluginEnvWireTests`.

- [ ] **Step 4: Run, verify pass**

Run: `swift test --filter "RPCMessageTests|PluginEnvWireTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/GallagerPluginProtocol/SidecarWire.swift \
        ClaudeSpyPackage/Tests/GallagerPluginProtocolTests/SidecarWireTests.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/JSONRPC.swift
git commit -m "feat(plugin-v2): JSON-RPC envelope, method vocabulary, PluginEnvWire"
```

---

## Milestone B — Transport

### Task 4: `SidecarTransport` actor (bidirectional JSON-RPC over stdio)

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/SidecarTransport.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/SidecarTransportTests.swift`

The transport is *spawn-agnostic*: it is given a write `FileHandle` (child stdin) and a read byte-stream, and does request correlation, timeouts, and ordered notification/inbound-request delivery. The supervisor (Task 5) wires it to a real process; the test wires it to an in-memory pipe pair. This is the one genuinely new wire protocol — implement every hazard row from spec §3.

**Interfaces:**
- Produces:
  - `actor SidecarTransport` with:
    - `init(writeHandle: FileHandle, delegate: any SidecarTransportDelegate)`
    - `func start(reading bytes: AsyncStream<Data>)` — consumes the read stream in one ordered loop.
    - `func request(_ method: String, _ params: JSONValue?, timeout: Duration = .seconds(30)) async throws -> JSONValue` — registers the pending slot *before* writing; throws `TransportError.timeout`/`.peerClosed`/`.rpc(RPCError)`.
    - `func notify(_ method: String, _ params: JSONValue?) async throws` — fire-and-forget App→Sidecar.
    - `func close()` — fail all pending with `.peerClosed`, stop the loop.
  - `protocol SidecarTransportDelegate: AnyObject, Sendable` with `func handleNotification(_ method: String, _ params: JSONValue?) async` and `func handleInboundRequest(_ method: String, _ params: JSONValue?) async -> Result<JSONValue, RPCError>` (services the inbound `agent_panes` request).
  - `enum TransportError: Error, Equatable { case timeout(String); case peerClosed; case rpc(RPCError); case encodeFailed }`.
- Consumes: `StdioFramer`, `FrameDecoder`, `RPCMessage` (Task 2/3).

- [ ] **Step 1: Write the failing test** — drive two transports through a pipe pair, in-process.

```swift
// SidecarTransportTests.swift
import Foundation
import Testing
import ClaudeSpyNetworking
import GallagerPluginProtocol
@testable import ClaudeSpyServerFeature

/// A delegate that answers a fixed inbound request and records notifications.
private actor RecordingDelegate: SidecarTransportDelegate {
    var notifications: [(String, JSONValue?)] = []
    func handleNotification(_ method: String, _ params: JSONValue?) async {
        notifications.append((method, params))
    }
    func handleInboundRequest(_ method: String, _ params: JSONValue?) async -> Result<JSONValue, RPCError> {
        if method == HostRPC.agentPanes { return .success(.array([.string("%1"), .string("%2")])) }
        return .failure(.methodNotFound(method))
    }
}

@Suite("SidecarTransport")
struct SidecarTransportTests {
    /// Bridge a FileHandle's readability into an AsyncStream<Data> (the supervisor does this for real).
    private func byteStream(_ handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { continuation.finish() } else { continuation.yield(d) }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    @Test("request gets its matching response across a real pipe")
    func requestResponse() async throws {
        // app <-> peer, two pipes.
        let appToPeer = Pipe(), peerToApp = Pipe()
        let appDelegate = RecordingDelegate(), peerDelegate = RecordingDelegate()
        let app = SidecarTransport(writeHandle: appToPeer.fileHandleForWriting, delegate: appDelegate)
        let peer = SidecarTransport(writeHandle: peerToApp.fileHandleForWriting, delegate: peerDelegate)
        await app.start(reading: byteStream(peerToApp.fileHandleForReading))
        await peer.start(reading: byteStream(appToPeer.fileHandleForReading))

        // The "peer" answers any request with an echo of its params.
        // (For this test the peer auto-responds via a tiny responder task.)
        Task {
            // Peer loop is internal; simulate a server by having peerDelegate route
            // an inbound request — but requests App->Peer must be answered by Peer.
            // We instead exercise the inbound REQUEST direction below.
        }

        // App asks the peer for agent_panes (peer's delegate answers it).
        let result = try await app.request(HostRPC.agentPanes, nil)
        #expect(result == .array([.string("%1"), .string("%2")]))
    }

    @Test("a request with no responder times out")
    func timeout() async throws {
        let appToPeer = Pipe(), peerToApp = Pipe()
        let app = SidecarTransport(writeHandle: appToPeer.fileHandleForWriting, delegate: RecordingDelegate())
        // No peer reading appToPeer / writing peerToApp → no response ever arrives.
        await app.start(reading: byteStream(peerToApp.fileHandleForReading))
        await #expect(throws: TransportError.timeout(SidecarRPC.initialize)) {
            _ = try await app.request(SidecarRPC.initialize, nil, timeout: .milliseconds(200))
        }
    }

    @Test("notifications arrive in wire order")
    func orderedNotifications() async throws {
        let appToPeer = Pipe(), peerToApp = Pipe()
        let peerDelegate = RecordingDelegate()
        let app = SidecarTransport(writeHandle: appToPeer.fileHandleForWriting, delegate: RecordingDelegate())
        let peer = SidecarTransport(writeHandle: peerToApp.fileHandleForWriting, delegate: peerDelegate)
        await peer.start(reading: byteStream(appToPeer.fileHandleForReading))
        await app.start(reading: byteStream(peerToApp.fileHandleForReading))
        for i in 1...5 { try await app.notify(HostRPC.log, .object(["n": .int(i)])) }
        try await Task.sleep(for: .milliseconds(300))
        let got = await peerDelegate.notifications
        #expect(got.count == 5)
        #expect(got.map { ($0.1?.objectValue?["n"])?.intValue } == [1,2,3,4,5])
    }
}
```

> If `RecordingDelegate` answering `agent_panes` requires the *peer* transport to route inbound requests to its delegate and write the response, the production read loop (Step 3) already does exactly that — so `requestResponse` exercises the inbound-request lane end-to-end without a hand-written responder. Keep the test as written; the peer transport's loop is the responder.

- [ ] **Step 2: Run, verify fail**

Run: `swift test --filter SidecarTransportTests`
Expected: FAIL — `cannot find 'SidecarTransport' in scope`.

- [ ] **Step 3: Implement the transport** — model on `TmuxControlClient` (FIFO continuation queue + `Task.sleep` timeout race) but with id-keyed correlation and an inbound-request lane.

```swift
import Foundation
import ClaudeSpyNetworking
import GallagerPluginProtocol
import Logging

public protocol SidecarTransportDelegate: AnyObject, Sendable {
    func handleNotification(_ method: String, _ params: JSONValue?) async
    func handleInboundRequest(_ method: String, _ params: JSONValue?) async -> Result<JSONValue, RPCError>
}

public enum TransportError: Error, Equatable {
    case timeout(String)
    case peerClosed
    case rpc(RPCError)
    case encodeFailed
}

public actor SidecarTransport {
    private let writeHandle: FileHandle
    private weak var delegate: (any SidecarTransportDelegate)?
    private let logger = Logger(label: "com.claudespy.sidecar.transport")

    private var decoder = FrameDecoder()
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var counter = 0
    private var closed = false
    private var loop: Task<Void, Never>?

    // Writes are offloaded to a serial queue so a full stdin pipe never blocks the actor.
    private let writeQueue = DispatchQueue(label: "com.claudespy.sidecar.write")

    public init(writeHandle: FileHandle, delegate: any SidecarTransportDelegate) {
        self.writeHandle = writeHandle
        self.delegate = delegate
    }

    public func start(reading bytes: AsyncStream<Data>) {
        loop = Task { [weak self] in
            for await chunk in bytes {
                guard let self else { return }
                await self.ingest(chunk)
            }
            await self?.handlePeerClosed()
        }
    }

    private func ingest(_ chunk: Data) async {
        let bodies: [Data]
        do { bodies = try decoder.push(chunk) }
        catch {
            logger.error("framing error, dropping connection: \(error)")
            await handlePeerClosed()
            return
        }
        // Await each message inline → preserves wire order (no fire-and-forget).
        for body in bodies {
            guard let msg = try? JSONDecoder().decode(RPCMessage.self, from: body) else {
                logger.debug("dropping malformed RPC frame")
                continue
            }
            await route(msg)
        }
    }

    private func route(_ msg: RPCMessage) async {
        if msg.isResponse, let id = msg.id {
            guard let cont = pending.removeValue(forKey: id) else { return }
            if let error = msg.error { cont.resume(throwing: TransportError.rpc(error)) }
            else { cont.resume(returning: msg.result ?? .object([:])) }
        } else if msg.isRequest, let id = msg.id, let method = msg.method {
            let outcome = await delegate?.handleInboundRequest(method, msg.params)
                ?? .failure(.methodNotFound(method))
            switch outcome {
            case let .success(value): try? await send(.response(id: id, result: value))
            case let .failure(error): try? await send(.failure(id: id, error: error))
            }
        } else if msg.isNotification, let method = msg.method {
            await delegate?.handleNotification(method, msg.params)
        }
    }

    public func request(_ method: String, _ params: JSONValue?,
                        timeout: Duration = .seconds(30)) async throws -> JSONValue {
        if closed { throw TransportError.peerClosed }
        counter += 1
        let id = "rpc-\(counter)"
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failPending(id, with: TransportError.timeout(method))
        }
        do {
            // Register the slot synchronously, THEN write — never lose a fast response.
            let value = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSONValue, any Error>) in
                pending[id] = cont
                Task { try? await send(.request(id: id, method: method, params: params)) }
            }
            timeoutTask.cancel()
            return value
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    public func notify(_ method: String, _ params: JSONValue?) async throws {
        if closed { throw TransportError.peerClosed }
        try await send(.notification(method: method, params: params))
    }

    private func send(_ msg: RPCMessage) async throws {
        guard let body = try? JSONEncoder().encode(msg) else { throw TransportError.encodeFailed }
        let frame = StdioFramer.encode(body)
        let handle = writeHandle
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            writeQueue.async {
                do { try handle.write(contentsOf: frame); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func failPending(_ id: String, with error: any Error) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(throwing: error)
    }

    private func handlePeerClosed() async {
        guard !closed else { return }
        closed = true
        let waiters = pending; pending.removeAll()
        for (_, cont) in waiters { cont.resume(throwing: TransportError.peerClosed) }
        loop?.cancel()
    }

    public func close() async { await handlePeerClosed() }
}
```

> `Duration`/`Task.sleep(for:)` and `withCheckedThrowingContinuation` match the codebase's `TmuxControlClient.sendCommand` timeout-race idiom. `JSONValue` needs `objectValue`/`intValue`/`arrayValue` accessors — confirm they exist in `JSONRPC.swift`; add the missing thin accessors there if needed (covered by the Task-3 test's use of `.objectValue`).

- [ ] **Step 4: Run, verify pass**

Run: `swift test --filter SidecarTransportTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/SidecarTransport.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/SidecarTransportTests.swift
git commit -m "feat(plugin-v2): bidirectional JSON-RPC stdio transport actor"
```

---

## Milestone C — Sidecar core + supervisor

### Task 5: `SidecarSupervisor` (process lifecycle + crash policy)

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/SidecarSupervisor.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/PluginRootLayout.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/SidecarStderrLog.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/SidecarSupervisorTests.swift`

The supervisor spawns one child, wires its stdio to a `SidecarTransport`, mirrors stderr to `logs/stderr.log`, and applies the crash policy (spec §5). Tests use a tiny **shell-script sidecar** written to a temp dir (so this task has no dependency on the `EchoPluginSidecar` executable target, which lands in Task 10) — the script speaks just enough framing to echo `initialize`, or aborts on command.

**Interfaces:**
- Produces:
  - `struct PluginRootLayout: Sendable { let pluginRoot: URL; let stateDir: URL; let logDir: URL; let ingressSocketPath: String; let appVersion: String }`.
  - `actor SidecarSupervisor` with `init(manifest: PluginManifest, layout: PluginRootLayout)`, `func startTransport(delegate: any SidecarTransportDelegate) async throws -> SidecarTransport` (spawn + wire + return the ready transport), `func stop() async` (graceful), and state `enum State { case stopped, running, crashed, failedInit, disabled }` exposed via `func state() -> State`. A crash callback `var onAutoDisabled: (@Sendable (_ lastStderr: [String]) -> Void)?`.
  - `func restartIfNeeded(delegate:) async` — re-spawns under the crash policy.
- Consumes: `SidecarTransport`, `PluginManifest.Sidecar`.

- [ ] **Step 1: Write the failing test**

```swift
// SidecarSupervisorTests.swift
import Foundation
import Testing
import ClaudeSpyNetworking
import GallagerPluginProtocol
@testable import ClaudeSpyServerFeature

private actor NoopDelegate: SidecarTransportDelegate {
    func handleNotification(_: String, _: JSONValue?) async {}
    func handleInboundRequest(_ m: String, _: JSONValue?) async -> Result<JSONValue, RPCError> {
        .failure(.methodNotFound(m))
    }
}

@Suite("SidecarSupervisor")
struct SidecarSupervisorTests {
    /// Writes a minimal shell-script "sidecar" into a temp plugin root and
    /// returns its layout. `behavior == .echoInitialize` answers one
    /// `initialize` frame with `Content-Length: 2\r\n\r\n{}` then loops on stdin;
    /// `behavior == .abort` prints a marker to stderr and `exit 1`s immediately.
    /// (Full body in Step 3.)
    private enum Behavior { case echoInitialize, abort }
    private func makeScriptLayout(_ behavior: Behavior) throws -> PluginRootLayout {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sup-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script: String
        switch behavior {
        case .echoInitialize:
            script = "#!/bin/bash\nwhile IFS= read -r line; do :; done < <(cat) &\nprintf 'Content-Length: 2\\r\\n\\r\\n{}'\nsleep 3600\n"
        case .abort:
            script = "#!/bin/bash\necho 'echo-sidecar boom' 1>&2\nexit 1\n"
        }
        let exe = bin.appendingPathComponent("sidecar")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let state = root.appendingPathComponent("state")
        let logs = state.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return PluginRootLayout(pluginRoot: root, stateDir: state, logDir: logs,
                                ingressSocketPath: state.appendingPathComponent("ingress.sock").path,
                                appVersion: "2.0")
    }

    @Test("spawns, completes an initialize RPC, and stops cleanly")
    func happyPath() async throws {
        let layout = try makeScriptLayout(.echoInitialize)
        let manifest = PluginManifest.fixtureSidecar(executable: "bin/sidecar")
        let sup = SidecarSupervisor(manifest: manifest, layout: layout)
        let transport = try await sup.startTransport(delegate: NoopDelegate())
        let result = try await transport.request(SidecarRPC.initialize, .object([:]), timeout: .seconds(5))
        #expect(result == .object([:]))
        await sup.stop()
        #expect(await sup.state() == .stopped)
    }

    @Test("4 crashes in the window auto-disables and surfaces stderr")
    func crashLoopDisables() async throws {
        let layout = try makeScriptLayout(.abort)             // prints to stderr then exits 1
        let manifest = PluginManifest.fixtureSidecar(executable: "bin/sidecar")
        let sup = SidecarSupervisor(manifest: manifest, layout: layout)
        var lastStderr: [String] = []
        await sup.setOnAutoDisabled { lastStderr = $0 }
        _ = try? await sup.startTransport(delegate: NoopDelegate())
        // The supervisor restarts on each crash; after the 4th it disables.
        try await Task.sleep(for: .seconds(10))               // > 1+2+4s backoff
        #expect(await sup.state() == .disabled)
        #expect(!lastStderr.isEmpty)
    }
}
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --filter SidecarSupervisorTests`
Expected: FAIL — `cannot find 'SidecarSupervisor' in scope`.

- [ ] **Step 3: Implement the supervisor + layout + stderr log.**

`PluginRootLayout.swift`:

```swift
import Foundation
public struct PluginRootLayout: Sendable {
    public let pluginRoot: URL
    public let stateDir: URL
    public let logDir: URL
    public let ingressSocketPath: String
    public let appVersion: String
    public init(pluginRoot: URL, stateDir: URL, logDir: URL, ingressSocketPath: String, appVersion: String) {
        self.pluginRoot = pluginRoot; self.stateDir = stateDir; self.logDir = logDir
        self.ingressSocketPath = ingressSocketPath; self.appVersion = appVersion
    }
}
```

`SidecarStderrLog.swift` — a 5 MB-rotated sink for the child's stderr, separate from `host.log()`'s `sidecar.log`:

```swift
import Foundation
import Logging

/// Mirrors a child's stderr to `<logDir>/stderr.log`, rotating at 5 MB (one
/// generation), and keeps the last `tailCapacity` lines in memory for the
/// crash-loop banner (spec §5 step 4). An actor so the readabilityHandler's
/// appends serialize. Best-effort and trap-free.
public actor SidecarStderrLog {
    public static let maxBytes = 5 * 1024 * 1024
    private let fileURL: URL
    private let tailCapacity = 50
    private var tail: [String] = []
    private let fm = FileManager.default

    public init(logDir: URL) {
        self.fileURL = logDir.appendingPathComponent("stderr.log")
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        rotateIfNeeded(adding: data.count)
        if let h = try? FileHandle(forWritingTo: fileURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: data)
        } else { try? data.write(to: fileURL) }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            tail.append(String(line)); if tail.count > tailCapacity { tail.removeFirst(tail.count - tailCapacity) }
        }
    }

    public func lastLines() -> [String] { tail }

    private func rotateIfNeeded(adding: Int) {
        guard let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size + adding > Self.maxBytes, size > 0 else { return }
        let rotated = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: rotated)
        do { try fm.moveItem(at: fileURL, to: rotated) } catch { try? Data().write(to: fileURL) }
    }
}
```

`SidecarSupervisor.swift`:

```swift
import Foundation
import ClaudeSpyNetworking
import GallagerPluginProtocol
import Logging

public actor SidecarSupervisor {
    public enum State: Sendable, Equatable { case stopped, running, crashed, failedInit, disabled }

    private let manifest: PluginManifest
    private let layout: PluginRootLayout
    private let logger = Logger(label: "com.claudespy.sidecar.supervisor")
    private let stderrLog: SidecarStderrLog

    private var process: Process?
    private var transport: SidecarTransport?
    private var _state: State = .stopped

    // Crash policy: per-plugin counter over a 60 s sliding window.
    private var crashTimes: [Date] = []           // monotonic via injected clock in real impl
    private var backoffTask: Task<Void, Never>?
    private var onAutoDisabled: (@Sendable ([String]) -> Void)?

    public init(manifest: PluginManifest, layout: PluginRootLayout) {
        self.manifest = manifest
        self.layout = layout
        self.stderrLog = SidecarStderrLog(logDir: layout.logDir)
    }

    public func state() -> State { _state }
    public func setOnAutoDisabled(_ cb: @escaping @Sendable ([String]) -> Void) { onAutoDisabled = cb }

    /// Spawn the child, wire stdio to a transport, and return it ready to drive.
    public func startTransport(delegate: any SidecarTransportDelegate) async throws -> SidecarTransport {
        let exe = layout.pluginRoot.appendingPathComponent(manifest.sidecar?.executable ?? "bin/sidecar")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            _state = .failedInit
            throw SupervisorError.notExecutable(exe.path)
        }
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = manifest.sidecar?.args ?? []
        proc.currentDirectoryURL = layout.pluginRoot
        var env = ProcessInfo.processInfo.environment
        env["GALLAGER_PLUGIN_ROOT"] = layout.pluginRoot.path
        env["GALLAGER_STATE_DIR"] = layout.stateDir.path
        env["GALLAGER_APP_VERSION"] = layout.appVersion
        env["GALLAGER_INGRESS_SOCK"] = layout.ingressSocketPath          // NEW in v2 (spec §5/§6)
        proc.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = stderr

        // Mirror stderr to the rotated log (off-actor handler → actor append).
        stderr.fileHandleForReading.readabilityHandler = { [stderrLog] h in
            let d = h.availableData
            if !d.isEmpty { Task { await stderrLog.append(d) } }
        }

        let delegateBox = delegate
        proc.terminationHandler = { [weak self] p in
            Task { await self?.handleTermination(status: p.terminationStatus, delegate: delegateBox) }
        }

        try proc.run()
        // Close the parent's copies of the child-inherited pipe ends (spec §3) — keep only the ends we use.
        // (We keep stdin.fileHandleForWriting and stdout/stderr.fileHandleForReading; close the opposite ends.)
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let transport = SidecarTransport(writeHandle: stdin.fileHandleForWriting, delegate: delegate)
        let stdoutBytes = AsyncStream<Data> { continuation in
            stdout.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { continuation.finish() } else { continuation.yield(d) }
            }
            continuation.onTermination = { _ in stdout.fileHandleForReading.readabilityHandler = nil }
        }
        await transport.start(reading: stdoutBytes)

        self.process = proc
        self.transport = transport
        _state = .running
        return transport
    }

    private func handleTermination(status: Int32, delegate: any SidecarTransportDelegate) async {
        await transport?.close()
        transport = nil; process = nil
        if _state == .stopped || _state == .disabled { return }   // expected exit / already disabled
        _state = .crashed
        crashTimes.append(Date())
        crashTimes = crashTimes.filter { Date().timeIntervalSince($0) <= 60 }   // 60 s window
        let n = crashTimes.count
        logger.warning("sidecar '\(manifest.id)' crashed (status \(status)); count=\(n) in window")
        if n >= 4 {
            _state = .disabled
            let lines = await stderrLog.lastLines()
            onAutoDisabled?(lines)
            return
        }
        let backoff: Duration = [1, 2, 4][min(n - 1, 2)] |> { .seconds($0) }
        backoffTask = Task { [weak self] in
            try? await Task.sleep(for: backoff)
            guard let self, await self.state() == .crashed else { return }    // guard double-spawn
            _ = try? await self.startTransport(delegate: delegate)
        }
    }

    /// Graceful shutdown: shutdown RPC handled by the caller (SidecarPluginCore),
    /// then SIGTERM, then SIGKILL after 5 s. Resume via terminationHandler.
    public func stop() async {
        backoffTask?.cancel()
        _state = .stopped
        guard let proc = process else { return }
        proc.terminate()                                  // SIGTERM
        let killer = Task { try? await Task.sleep(for: .seconds(5)); if proc.isRunning { kill(proc.processIdentifier, SIGKILL) } }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // terminationHandler already nils process; poll-free wait via a short race.
            Task { while proc.isRunning { try? await Task.sleep(for: .milliseconds(50)) }; cont.resume() }
        }
        killer.cancel()
        process = nil
    }

    public func reEnable(delegate: any SidecarTransportDelegate) async throws -> SidecarTransport {
        backoffTask?.cancel()
        crashTimes.removeAll()
        _state = .stopped
        return try await startTransport(delegate: delegate)
    }
}

public enum SupervisorError: Error, Equatable { case notExecutable(String) }
```

> Replace the illustrative `|>` with a plain `switch`/array index — keep it boring. For deterministic crash-window tests, inject a clock (`@Dependency(\.continuousClock)` or a simple `now: () -> Date`) rather than `Date()`; the test's 10 s sleep tolerates wall-clock but a clock makes it fast and stable. Add a `PluginManifest.fixtureSidecar(executable:)` test helper in the test target. The two script-layout helpers write a `#!/bin/bash` file that either `read`s a frame and prints `Content-Length: 2\r\n\r\n{}` then loops, or prints to stderr and `exit 1`; `chmod +x`.

- [ ] **Step 4: Run, verify pass**

Run: `swift test --filter SidecarSupervisorTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/ \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/SidecarSupervisorTests.swift
git commit -m "feat(plugin-v2): sidecar supervisor with crash policy and stderr log"
```

---

### Task 6: `SidecarPluginCore` (PluginCore conformer; the seam)

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/SidecarPluginCore.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/SidecarPluginCoreTests.swift`

`SidecarPluginCore` is the only new `PluginCore` conformer. It retains the in-process `PluginHost` (never marshaled), drives each method as an RPC, and acts as the transport's delegate — translating inbound notifications into `host.*` and the inbound `agent_panes` request into `host.agentPanes()`. Tests use a `MockSidecarProcess` (an in-memory `SidecarTransport` peer + a scripted responder) so no real process is needed.

**Interfaces:**
- Produces: `actor SidecarPluginCore: PluginCore, SidecarTransportDelegate` with `init(manifest: PluginManifest, layout: PluginRootLayout, supervisor: SidecarSupervisor)`. Marshalling per spec §2: `initialize`→`initialize` (env only, via `PluginEnvWire`); `handleIngress`→`translate_event` (an `IngressFrameWire`); `deliverResponse`→`deliver_response`; `refreshProjects`→`refresh_projects`; `commandForLaunch`→`command_for_launch`; `install`/`uninstall`/`installStatus(configRoot:)`→same-named RPCs; `applySettings`→`apply_settings`; `shutdown`→`shutdown` then `supervisor.stop()`. Inbound: `set_projects`→`host.setProjects`, `emit_event`→`host.emit`, `send_text`→`host.sendText`, `send_keys`→`host.sendKeys`, `log`→`host.log`, request `agent_panes`→`host.agentPanes()`.
- Consumes: Task 4/5 outputs; the existing `PluginEvent`, `AgentResponse`, `AgentProject`, `LaunchCommand`, `PluginInstallStatus`, `InstallResult`, `SettingsResult`, `LogLine`, `IngressFrame` (all already Codable in `ClaudeSpyNetworking`/`GallagerPluginProtocol`).

- [ ] **Step 1: Write the failing test** (marshalling both directions, via `MockSidecarProcess`).

```swift
// SidecarPluginCoreTests.swift
import Foundation
import Testing
import ClaudeSpyNetworking
import GallagerPluginProtocol
@testable import ClaudeSpyServerFeature

@Suite("SidecarPluginCore marshalling")
struct SidecarPluginCoreTests {
    @Test("handleIngress marshals translate_event and decodes the returned PluginEvent")
    func translateEvent() async throws {
        let mock = MockSidecarProcess()
        // Scripted: when the sidecar receives translate_event, answer with a PluginEvent.
        await mock.onRequest { method, params in
            #expect(method == SidecarRPC.translateEvent)
            let event = PluginEvent(pluginID: "opencode", sessionID: "s1",
                                    state: .doneWorking(summary: nil), tmuxPane: "%4")
            return .success(try! JSONValue(encoding: event))
        }
        let core = try await mock.makeCore(manifestID: "opencode")
        let host = MockPluginHost()
        try await core.initialize(mock.env, host: host)
        let frame = IngressFrame(pluginID: "opencode", context: ["TMUX_PANE": "%4"], payload: Data("{}".utf8))
        let event = await core.handleIngress(frame)
        #expect(event?.pluginID == "opencode")
        #expect(event?.state?.needsAttention == true)
        #expect(event?.tmuxPane == "%4")
    }

    @Test("an inbound set_projects notification reaches host.setProjects")
    func inboundSetProjects() async throws {
        let mock = MockSidecarProcess()
        let core = try await mock.makeCore(manifestID: "opencode")
        let host = MockPluginHost()
        try await core.initialize(mock.env, host: host)
        // The sidecar pushes set_projects autonomously.
        let projects = [AgentProject(name: "Demo", path: "/demo", pluginID: "opencode")]
        await mock.pushNotification(HostRPC.setProjects, JSONValue(encoding: ["projects": projects]))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await host.projectsCalls.first?.first?.name == "Demo")
    }

    @Test("an inbound agent_panes request is answered from host.agentPanes()")
    func inboundAgentPanes() async throws {
        let mock = MockSidecarProcess()
        let core = try await mock.makeCore(manifestID: "opencode")
        let host = PanesHost(panes: ["%7", "%8"])
        try await core.initialize(mock.env, host: host)
        let answer = try await mock.request(HostRPC.agentPanes, nil)
        #expect(answer == .array([.string("%7"), .string("%8")]))
    }
}
```

> `MockSidecarProcess` is a small test double in the test target: it owns a `SidecarTransport` peer wired to the core's transport via in-memory `Pipe`s (the Task-4 pattern), exposes `onRequest`/`pushNotification`/`request`, and a `makeCore(manifestID:)` that injects the *app-side* transport into a `SidecarPluginCore` without a real `SidecarSupervisor` spawn (add an internal `init(manifest:layout:transport:)` to `SidecarPluginCore` used only by tests, or a `withInjectedTransport` test seam). `MockPluginHost` already exists in `GallagerPluginProtocolTests`; mirror it (or expose it) for `ClaudeSpyServerFeatureTests`. `JSONValue(encoding:)` is a small test helper that `JSONEncoder`-encodes a `Codable` then decodes to `JSONValue`.

- [ ] **Step 2: Run, verify fail**

Run: `swift test --filter SidecarPluginCoreTests`
Expected: FAIL — `cannot find 'SidecarPluginCore' in scope`.

- [ ] **Step 3: Implement `SidecarPluginCore`.**

```swift
import Foundation
import ClaudeSpyNetworking
import GallagerPluginProtocol
import Logging

public actor SidecarPluginCore: PluginCore, SidecarTransportDelegate {
    private let manifest: PluginManifest
    private let layout: PluginRootLayout
    private let supervisor: SidecarSupervisor
    private let logger = Logger(label: "com.claudespy.sidecar.core")

    private var host: (any PluginHost)?
    private var transport: SidecarTransport?

    public init(manifest: PluginManifest, layout: PluginRootLayout, supervisor: SidecarSupervisor) {
        self.manifest = manifest; self.layout = layout; self.supervisor = supervisor
    }

    // Test seam: inject a ready transport instead of spawning.
    init(manifest: PluginManifest, layout: PluginRootLayout, supervisor: SidecarSupervisor, transport: SidecarTransport) {
        self.init(manifest: manifest, layout: layout, supervisor: supervisor)
        self.transport = transport
    }

    // MARK: PluginCore

    public func initialize(_ env: PluginEnv, host: any PluginHost) async throws {
        self.host = host                                            // retained; NEVER marshaled
        let transport = try self.transport ?? supervisor.startTransport(delegate: self) // spawn if not injected
        // (spawn is async; in production: `try await supervisor.startTransport(delegate: self)`)
        self.transport = transport
        let wire = try PluginEnvWire(env)
        _ = try await transport.request(SidecarRPC.initialize, JSONValue(encoding: wire), timeout: .seconds(10))
    }

    public func handleIngress(_ frame: IngressFrame) async -> PluginEvent? {
        guard let transport else { return nil }
        do {
            let wire = IngressFrameWire(frame)
            let result = try await transport.request(SidecarRPC.translateEvent, JSONValue(encoding: wire))
            if case .null = result { return nil }
            return try result.decode(PluginEvent.self)
        } catch { logger.debug("translate_event failed: \(error)"); return nil }
    }

    public func deliverResponse(sessionID: String, requestID: String, _ response: AgentResponse) async {
        try? await transport?.request(SidecarRPC.deliverResponse,
            JSONValue(encoding: ["sessionID": sessionID, "requestID": requestID]).merging(response: response))
    }

    public func refreshProjects() async { _ = try? await transport?.request(SidecarRPC.refreshProjects, nil) }

    public func commandForLaunch(projectPath: String) async -> LaunchCommand? {
        guard let r = try? await transport?.request(SidecarRPC.commandForLaunch,
            .object(["projectPath": .string(projectPath)])) else { return nil }
        if case .null = r { return nil }
        return try? r.decode(LaunchCommand.self)
    }

    public func install(configRoot: String?) async throws -> InstallResult {
        let r = try await requireTransport().request(SidecarRPC.install, configRootParams(configRoot))
        return try r.decode(InstallResult.self)
    }
    public func uninstall(configRoot: String?) async throws {
        _ = try await requireTransport().request(SidecarRPC.uninstall, configRootParams(configRoot))
    }
    public func installStatus(configRoot: String?) async -> PluginInstallStatus {
        guard let r = try? await transport?.request(SidecarRPC.installStatus, configRootParams(configRoot)),
              let s = try? r.decode(PluginInstallStatus.self) else { return .agentUnavailable }
        return s
    }
    public func applySettings(_ raw: Data) async -> SettingsResult {
        let settings = (try? JSONDecoder().decode(JSONValue.self, from: raw)) ?? .object([:])
        guard let r = try? await transport?.request(SidecarRPC.applySettings, .object(["settings": settings])),
              let res = try? r.decode(SettingsResult.self) else { return .applied }
        return res
    }
    public func shutdown() async {
        _ = try? await transport?.request(SidecarRPC.shutdown, nil, timeout: .seconds(3))
        await supervisor.stop()
        transport = nil
    }

    // MARK: SidecarTransportDelegate (inbound)

    public func handleNotification(_ method: String, _ params: JSONValue?) async {
        guard let host else { return }
        switch method {
        case HostRPC.setProjects:
            if let p = try? params?.decode([String: [AgentProject]].self), let list = p["projects"] {
                await host.setProjects(list)
            }
        case HostRPC.emitEvent:
            if let e = try? params?.decode(PluginEvent.self) { await host.emit(e) }
        case HostRPC.sendText:
            if let o = params?.objectValue, let s = o["sessionID"]?.stringValue, let t = o["text"]?.stringValue {
                await host.sendText(sessionID: s, t)
            }
        case HostRPC.sendKeys:
            if let o = params?.objectValue, let s = o["sessionID"]?.stringValue,
               let keys = try? o["keys"]?.decode([PluginTmuxKey].self) {
                await host.sendKeys(sessionID: s, keys)
            }
        case HostRPC.log:
            if let l = try? params?.decode(LogLine.self) { await host.log(l) }
        default:
            logger.debug("unknown inbound notification \(method)")
        }
    }

    public func handleInboundRequest(_ method: String, _ params: JSONValue?) async -> Result<JSONValue, RPCError> {
        switch method {
        case HostRPC.agentPanes:
            let panes = await host?.agentPanes() ?? []
            return .success(.array(panes.map { .string($0) }))
        default:
            return .failure(.methodNotFound(method))
        }
    }

    // MARK: helpers
    private func requireTransport() throws -> SidecarTransport {
        guard let transport else { throw SupervisorError.notExecutable(manifest.id) }
        return transport
    }
    private func configRootParams(_ root: String?) -> JSONValue {
        .object(["configRoot": root.map { .string($0) } ?? .null])
    }
}
```

> Provide the small `JSONValue` ergonomics this uses (`init(encoding: Encodable)`, `decode(_:)`, `.null`, `.objectValue`, `.stringValue`, `.merging(response:)` for the deliver_response param shape) in `ClaudeSpyNetworking/Models/JSONRPC.swift` as a focused extension, each line covered by an assertion already present in these tests. Add `struct IngressFrameWire: Codable { let pluginID; let context: [String:String]; let payload: JSONValue }` to `SidecarWire.swift` (payload carried as nested JSON, mirroring `PluginEnvWire.settings`). Note the production `initialize` must `try await supervisor.startTransport(...)`; the injected-transport test seam skips the spawn.

- [ ] **Step 4: Run, verify pass**

Run: `swift test --filter SidecarPluginCoreTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/SidecarPluginCore.swift \
        ClaudeSpyPackage/Sources/GallagerPluginProtocol/SidecarWire.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/JSONRPC.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/SidecarPluginCoreTests.swift
git commit -m "feat(plugin-v2): SidecarPluginCore marshals the PluginCore seam over stdio"
```

---

## Milestone D — Registry wiring + folder-drop (end-to-end without download)

### Task 7: On-disk `registry.json` store

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/PluginRegistryStore.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/GallagerPaths.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRegistryStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct PluginRegistryEntry: Codable, Sendable, Equatable { let id: String; let version: String; let source: Source; let runtime: Runtime; var enabled: Bool; let manifestURL: URL?; let bundleURL: URL?; let bundleSHA256: String?; enum Source: String, Codable { case bundled, url, folder } }`.
  - `struct PluginRegistryFile: Codable, Sendable { var schemaVersion: Int; var plugins: [PluginRegistryEntry] }`.
  - `enum PluginRegistryStore { static func load(_ url: URL) -> PluginRegistryFile; static func save(_ file: PluginRegistryFile, to url: URL) throws }` (atomic temp-file + rename).
  - `GallagerPaths.pluginsDir` (`~/.gallager/plugins/`), `pluginInstallDir(_:)`, `pluginStagingDir(_:)` (`<id>.installing`), `pluginReplacingDir(_:)`, `pluginStderrLogPath(_:)`.

- [ ] **Step 1: Write the failing test**

```swift
// PluginRegistryStoreTests.swift
import Foundation
import Testing
import GallagerPluginProtocol
@testable import ClaudeSpyServerFeature

@Suite("PluginRegistryStore")
struct PluginRegistryStoreTests {
    private func tmp() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reg-\(UUID().uuidString).json")
    }

    @Test("save then load round-trips entries")
    func roundTrip() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let file = PluginRegistryFile(schemaVersion: 1, plugins: [
            .init(id: "claude-code", version: "1.0.0", source: .bundled, runtime: .inProcess,
                  enabled: true, manifestURL: nil, bundleURL: nil, bundleSHA256: nil),
            .init(id: "opencode", version: "1.2.0", source: .url, runtime: .sidecar, enabled: true,
                  manifestURL: URL(string: "https://opencode.ai/g.json"),
                  bundleURL: URL(string: "https://opencode.ai/o.zip"), bundleSHA256: "abc"),
        ])
        try PluginRegistryStore.save(file, to: url)
        let back = PluginRegistryStore.load(url)
        #expect(back.plugins.count == 2)
        #expect(back.plugins[1].source == .url)
        #expect(back.plugins[1].bundleSHA256 == "abc")
    }

    @Test("loading a missing file yields an empty registry")
    func missingFile() {
        let back = PluginRegistryStore.load(tmp())
        #expect(back.plugins.isEmpty)
        #expect(back.schemaVersion == 1)
    }
}
```

- [ ] **Step 2: Run, verify fail** — `swift test --filter PluginRegistryStoreTests` → FAIL (`cannot find 'PluginRegistryStore'`).

- [ ] **Step 3: Implement** the model + atomic store, and add the `GallagerPaths` accessors (`pluginsDir`, install/staging/replacing dirs, `pluginStderrLogPath`). Save writes to `url.appendingPathExtension("tmp")` then `replaceItemAt`. Load returns `PluginRegistryFile(schemaVersion: 1, plugins: [])` on any read/decode failure (trap-free).

- [ ] **Step 4: Run, verify pass** — PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/PluginRegistryStore.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/GallagerPaths.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRegistryStoreTests.swift
git commit -m "feat(plugin-v2): on-disk registry.json store + plugins-dir paths"
```

---

### Task 8: Teach `PluginRegistry` the `.sidecar` construction path

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/PluginRegistry.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRegistrySidecarTests.swift`

`makeCore`'s `.sidecar` branch currently logs a warning and returns nil. Replace it with `SidecarPluginCore` construction, and let the registry register *runtime-discovered* sidecar manifests (url/folder) — not just bundled ones. The registry needs `GallagerPaths` to build the `PluginRootLayout`.

**Interfaces:**
- Produces:
  - `PluginRegistry.attachPaths(_ paths: GallagerPaths)` (called once at setup before enabling sidecars).
  - `PluginRegistry.registerSidecar(manifest: PluginManifest, root: URL, source: PluginRegistryEntry.Source)` — adds the manifest + root so `makeCore`/`enable`/`listEntries`/`presentations` see it; `source` is surfaced by `listEntries().source`.
  - `makeCore(_:)` `.sidecar` arm: build `PluginRootLayout` from `paths` + manifest, a `SidecarSupervisor`, and a `SidecarPluginCore`.
  - `listEntries()` now reports the true `source` ("bundled"/"url"/"folder") from the registered entries (was hard-coded `"bundled"`).
- Consumes: Task 5/6/7.

- [ ] **Step 1: Write the failing test** — register a sidecar manifest pointing at a temp folder with an executable `bin/sidecar` script; assert `makeCore` returns a `SidecarPluginCore` and `listEntries()` reports `source == "folder"`.

```swift
// PluginRegistrySidecarTests.swift
import Foundation
import Testing
import GallagerPluginProtocol
@testable import ClaudeSpyServerFeature

@MainActor
@Suite("PluginRegistry sidecar path")
struct PluginRegistrySidecarTests {
    @Test("registerSidecar makes a SidecarPluginCore and reports its source")
    func makesSidecarCore() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let exe = root.appendingPathComponent("bin/sidecar")
        try "#!/bin/bash\ncat >/dev/null".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let manifest = PluginManifest(schemaVersion: 1, id: "opencode", displayName: "OpenCode",
            shortName: "OpenCode", version: "1.2.0", processNames: ["opencode"],
            ui: .init(icon: nil, color: "#3a7fcb"), runtime: .sidecar,
            sidecar: .init(executable: "bin/sidecar"))

        let registry = PluginRegistry()
        registry.attachPaths(GallagerPaths(stateRootOverride: root.appendingPathComponent("state")))
        registry.registerSidecar(manifest: manifest, root: root, source: .folder)

        let core = registry.makeCore("opencode")
        #expect(core is SidecarPluginCore)
        #expect(registry.listEntries().first(where: { $0.id == "opencode" })?.source == "folder")
    }
}
```

- [ ] **Step 2: Run, verify fail** — FAIL (`value of type 'PluginRegistry' has no member 'attachPaths'`).

- [ ] **Step 3: Implement.** Add `private var paths: GallagerPaths?`, `private var sources: [String: PluginRegistryEntry.Source] = [:]`. `attachPaths`/`registerSidecar` set the dictionaries (and merge into `manifests`/`pluginRoots`). Rewrite `makeCore`:

```swift
public func makeCore(_ id: String) -> (any PluginCore)? {
    let runtime = manifests[id]?.runtime ?? .inProcess
    switch runtime {
    case .inProcess:
        guard let factory = factories[id] else { return nil }
        return factory()
    case .sidecar:
        guard let manifest = manifests[id], let root = pluginRoots[id], let paths else {
            logger.warning("Cannot construct sidecar '\(id)': missing manifest/root/paths"); return nil
        }
        let layout = PluginRootLayout(
            pluginRoot: root,
            stateDir: paths.pluginStateDir(id),
            logDir: paths.pluginLogPath(id).deletingLastPathComponent(),
            ingressSocketPath: paths.ingressSocketPath.path,
            appVersion: VersionCompatibility.currentAppVersion)
        let supervisor = SidecarSupervisor(manifest: manifest, layout: layout)
        return SidecarPluginCore(manifest: manifest, layout: layout, supervisor: supervisor)
    }
}
```

Update `listEntries()` to read `sources[id] ?? .bundled` and emit its `rawValue`. `isRegistered(_:)` must also return true for sidecar ids (which have no factory) — change it to `factories[id] != nil || manifests[id]?.runtime == .sidecar`.

- [ ] **Step 4: Run, verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/PluginRegistry.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRegistrySidecarTests.swift
git commit -m "feat(plugin-v2): registry constructs SidecarPluginCore for sidecar runtime"
```

---

### Task 9: Folder-drop discovery + enable sidecars at launch

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginInstaller.swift` (discovery only this task; download lands in Task 12/13)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginFolderDropTests.swift`

`setupPluginRuntime` currently enables a hardcoded `["claude-code", "codex"]`. Add: after the bundled enable loop, scan `~/.gallager/plugins/<id>/` for valid `runtime: "sidecar"` manifests, sanitize each `id`, validate the tree, `registry.registerSidecar(..., source: .folder)`, persist a `registry.json` entry, and `registry.enable` them with a `PluginEnv` + `LivePluginHost` (the same construction the bundled loop uses). Tolerate a sidecar that fails init (left disabled, logged) — never block startup.

**Interfaces:**
- Produces: `enum PluginInstaller { static func discoverFolderDropped(pluginsDir: URL) -> [(manifest: PluginManifest, root: URL)] }` — enumerates subdirs, loads `plugin.json`, keeps only `.sidecar` with a sanitized id, an executable `bin/sidecar`, and a tree that passes validation (manifest at root, executable present + executable bit). `static func sanitize(id: String) -> String?` (regex `^[a-z0-9][a-z0-9._-]*$`, no `..`, ≤128).
- Consumes: Task 7/8.

- [ ] **Step 1: Write the failing test** — drop two folders (one valid sidecar, one with a traversal id `../evil`); assert discovery returns only the valid one and `sanitize("../evil") == nil`.

```swift
// PluginFolderDropTests.swift
import Foundation
import Testing
import GallagerPluginProtocol
@testable import ClaudeSpyServerFeature

@Suite("PluginInstaller folder-drop")
struct PluginFolderDropTests {
    @Test("sanitize rejects traversal and uppercase, accepts a clean id")
    func sanitize() {
        #expect(PluginInstaller.sanitize(id: "opencode") == "opencode")
        #expect(PluginInstaller.sanitize(id: "open.code_2-x") == "open.code_2-x")
        #expect(PluginInstaller.sanitize(id: "../evil") == nil)
        #expect(PluginInstaller.sanitize(id: "Open") == nil)
        #expect(PluginInstaller.sanitize(id: String(repeating: "a", count: 200)) == nil)
    }

    @Test("discovery returns valid sidecar folders only")
    func discovery() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // valid
        let ok = dir.appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: ok.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try #"{"schema_version":1,"id":"opencode","display_name":"OpenCode","short_name":"OC","version":"1.0.0","runtime":"sidecar","sidecar":{"executable":"bin/sidecar"},"process_names":["opencode"],"ui":{"color":"#3a7fcb"}}"#
            .write(to: ok.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        let exe = ok.appendingPathComponent("bin/sidecar")
        try "#!/bin/bash".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        // invalid: no executable
        let bad = dir.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try #"{"schema_version":1,"id":"broken","display_name":"B","short_name":"B","version":"1","runtime":"sidecar","ui":{}}"#
            .write(to: bad.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

        let found = PluginInstaller.discoverFolderDropped(pluginsDir: dir)
        #expect(found.map(\.manifest.id) == ["opencode"])
    }
}
```

- [ ] **Step 2: Run, verify fail** — FAIL (`cannot find 'PluginInstaller'`).

- [ ] **Step 3: Implement** `PluginInstaller.sanitize`/`discoverFolderDropped`, then wire `setupPluginRuntime` (in `AppCoordinator`): call `registry.attachPaths(paths)` before the enable loop; after enabling bundled ids, iterate `PluginInstaller.discoverFolderDropped(pluginsDir: paths.pluginsDir)`, `registerSidecar(..., source: .folder)`, persist to `registry.json`, and `enable` each via `makePluginHost`/`makePluginEnv` (extend `makePluginEnv`'s `marketplaceSource` switch: a sidecar resolves its marketplace inside its own plugin root — `root.appendingPathComponent("marketplace")`, falling back to `root`). Keep failures non-fatal.

- [ ] **Step 4: Run, verify pass** — PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginInstaller.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginFolderDropTests.swift
git commit -m "feat(plugin-v2): discover and enable folder-dropped sidecar plugins at launch"
```

---

### Task 10: `EchoPluginSidecar` executable fixture + first sidecar E2E

**Files:**
- Create: `ClaudeSpyPackage/Sources/EchoPluginSidecar/main.swift`
- Modify: `ClaudeSpyPackage/Package.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/PluginSidecarIngressScenario.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyE2E/ClaudeSpyE2ECommand.swift` (register scenario)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/TestOrchestrator.swift` (stage the fixture into the plugins dir)

This is the spec's headline test asset: a *real* out-of-process sidecar that proves the whole pipeline (spawn → JSON-RPC → supervision → ingress over the app-owned socket → `set_projects` → response round-trip). The same `EchoDirective` payload shape the in-process `EchoPluginCore` uses (so scenarios read familiarly), but answered by a separate process.

**Interfaces:**
- Produces: an executable that, on stdin `Content-Length` frames, answers `initialize` (empty), `translate_event` (decodes the `EchoDirective` from the frame payload and returns the `PluginEvent` it describes), `deliver_response` (drives `send_text`/`send_keys` per the structured response, mirroring `EchoPluginCore`), `refresh_projects` (pushes a `set_projects` notification), `install`/`uninstall`/`install_status`/`apply_settings`/`shutdown` (no-ops/echo). A control field `abort: true` in a `translate_event` payload makes it `abort()` (crash test, Task 18).
- Consumes: `GallagerPluginProtocol` (`StdioFramer`, `FrameDecoder`, `RPCMessage`, `SidecarRPC`/`HostRPC`, `EchoDirective`) + `ClaudeSpyNetworking`. `EchoDirective` must move from the DEBUG `EchoPluginCore.swift` to a non-DEBUG location in `GallagerPluginProtocol` (so the Release-built executable can use it) — relocate it, keep `EchoPluginCore` referencing it.

- [ ] **Step 1: Write the failing E2E scenario** (the test is the scenario; it fails until the fixture + staging exist).

```swift
// PluginSidecarIngressScenario.swift
import Foundation

/// Proves the v2 out-of-process pipeline: a real EchoPluginSidecar process,
/// folder-dropped into the per-scenario plugins dir, is spawned + initialized by
/// the supervisor; a hook frame tagged `plugin_id: "echo-sidecar"` routes to its
/// SidecarPluginCore, marshals translate_event to the child, and the returned
/// PluginEvent surfaces the session on iOS.
public enum PluginSidecarIngressScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Plugin Sidecar Ingress", tags: ["plugin", "sidecar", "ingress"]
    ) {
        ClaudeSessionsShowScenario.scenario        // pairing + two panes (${pane1Id})

        TestStep.macSendHookEvent(
            pluginID: "echo-sidecar",
            json: """
            { "sessionID": "sidecar-sess-1",
              "state": { "doneWorking": { "summary": null } },
              "projectPath": "/Users/test/SidecarLab" }
            """,
            tmuxPane: "${pane1Id}")

        TestStep.iosWaitForElement(.labelContains("SidecarLab"), timeout: 15)
        TestStep.iosScreenshot(label: "ios-sidecar-session-attention")
    }
}
```

- [ ] **Step 2: Run, verify fail** — run the scenario through `./scripts/e2e-test.sh --scenario "Plugin Sidecar Ingress"` (per the `e2e-testing` skill). Expected: FAIL — no `echo-sidecar` plugin registered (frame dropped for unknown plugin).

- [ ] **Step 3: Implement.**
  1. Add the executable target to `Package.swift`:

```swift
// products:
.executable(name: "EchoPluginSidecar", targets: ["EchoPluginSidecar"]),
// targets:
.executableTarget(
    name: "EchoPluginSidecar",
    dependencies: [.gallagerPluginProtocol, .claudeSpyNetworking, .logging],
    path: "Sources/EchoPluginSidecar")
```
  2. Relocate `EchoDirective` out of the `#if DEBUG` block in `GallagerPluginProtocol/EchoPluginCore.swift` into a new always-compiled `GallagerPluginProtocol/EchoDirective.swift`.
  3. Write `Sources/EchoPluginSidecar/main.swift`: a `while let frame = readFrame(stdin)` loop using `FrameDecoder`; decode `RPCMessage`; `switch msg.method` answering each RPC; for `translate_event`, decode the `EchoDirective` from the frame-wire payload, honor `abort`, build the `PluginEvent`, and respond; emit `set_projects`/`send_text` as `RPCMessage.notification`s written with `StdioFramer.encode`. Writes go to `FileHandle.standardOutput`; reads from `FileHandle.standardInput` via a blocking read loop on a background thread (the executable can use a simple `while` over `availableData`).
  4. In `TestOrchestrator`, before launching the app for a scenario tagged `sidecar`, copy the built `EchoPluginSidecar` binary into `<gallagerStateRoot>/plugins/echo-sidecar/bin/sidecar` (chmod +x) alongside a generated `plugin.json` (`id: "echo-sidecar"`, `runtime: "sidecar"`, `process_names: []`, `sidecar.executable: "bin/sidecar"`). Locate the built binary via the same build-products dir the orchestrator already uses for the app. Add a `TestStep.macStageSidecarFixture(id:)` if a DSL step is cleaner than tag-detection.

- [ ] **Step 4: Run, verify pass** — `./scripts/e2e-test.sh --scenario "Plugin Sidecar Ingress"`. Expected: PASS; `ios-sidecar-session-attention` shows the "SidecarLab" session. Also run `swift build` to confirm the new target compiles.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/EchoPluginSidecar/ \
        ClaudeSpyPackage/Sources/GallagerPluginProtocol/EchoDirective.swift \
        ClaudeSpyPackage/Sources/GallagerPluginProtocol/EchoPluginCore.swift \
        ClaudeSpyPackage/Package.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/PluginSidecarIngressScenario.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/TestOrchestrator.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2E/ClaudeSpyE2ECommand.swift
git commit -m "test(plugin-v2): real EchoPluginSidecar executable + ingress E2E"
```

---

## Milestone E — Ingress for sidecars (one socket; templated install)

### Task 11: `GALLAGER_INGRESS_SOCK` consumption + sidecar hook install

**Files:**
- Modify: `ClaudeSpyPackage/Sources/EchoPluginSidecar/main.swift` (consume the env var in its `install`)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/TestOrchestrator.swift` (per-scenario socket isolation note)
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/PluginSidecarManualLaunchScenario.swift`
- Test (unit): `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/SidecarSpawnEnvTests.swift`

The supervisor already injects `GALLAGER_INGRESS_SOCK` (Task 5). This task proves a sidecar's `install()` *templates* that path into its agent's hook mechanism (rather than shipping a static `hook.py` that hardcodes the socket), and that a frame written to the spawn-supplied socket routes correctly — the capability the E2E `--gallager-state-root` isolation needs.

**Interfaces:**
- Produces: a unit test asserting the supervisor sets `GALLAGER_INGRESS_SOCK` in the child env to `layout.ingressSocketPath`. The `EchoPluginSidecar.install` writes a tiny hook script under `<plugin_root>/generated/hook.sh` that bakes in `$GALLAGER_INGRESS_SOCK` + its own `plugin_id` (proving the templating contract); the E2E manual-launch scenario invokes that script directly to deliver a frame.
- Consumes: Task 5/10.

- [ ] **Step 1: Write the failing unit test**

```swift
// SidecarSpawnEnvTests.swift — assert the spawn env carries the socket path.
@Test("supervisor injects GALLAGER_INGRESS_SOCK")
func injectsSocket() async throws {
    let layout = /* temp layout with ingressSocketPath = "/tmp/x/ingress.sock" */ ...
    let manifest = PluginManifest.fixtureSidecar(executable: "bin/sidecar")
    // Use a script sidecar that writes its env to a file on initialize, then assert the file.
    ...
    #expect(capturedEnv["GALLAGER_INGRESS_SOCK"] == layout.ingressSocketPath)
}
```

- [ ] **Step 2: Run, verify fail** — FAIL until the env-capturing script + assertion are wired (the var name must match the supervisor's exact key).

- [ ] **Step 3: Implement.** Confirm the supervisor sets `GALLAGER_INGRESS_SOCK` (Task 5 already does — this test pins it). Extend `EchoPluginSidecar`'s `install` RPC handler to read `ProcessInfo.processInfo.environment["GALLAGER_INGRESS_SOCK"]`, write `<plugin_root>/generated/hook.sh` that connects to *that* path and writes a `{plugin_id:"echo-sidecar", context, payload}` 4-byte-prefixed frame (the durable bridge contract, unchanged from v1). Add `PluginSidecarManualLaunchScenario` that runs `hook.sh` directly (simulating a manually-launched agent) and asserts iOS sees the session — proving ingress fires for sessions Gallager didn't start.

- [ ] **Step 4: Run, verify pass** — unit test PASS; `./scripts/e2e-test.sh --scenario "Plugin Sidecar Manual Launch"` PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/EchoPluginSidecar/main.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/PluginSidecarManualLaunchScenario.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Orchestrator/TestOrchestrator.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2E/ClaudeSpyE2ECommand.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/SidecarSpawnEnvTests.swift
git commit -m "feat(plugin-v2): sidecars template GALLAGER_INGRESS_SOCK into their hook bridge"
```

> Telemetry (§6.1) needs no code for the hook path: `PluginEnv.otlpReceiverEndpoint` already marshals to the sidecar via `PluginEnvWire` (Task 3). Document in `docs/plugins/sidecar-authoring.md` (Task 19) that a sidecar agent with a non-`claude_code.`/`codex.` OTLP namespace is silently dropped by `OTLPTelemetryAccumulator` today — adapting it is a v2.x follow-on, not a blocker.

---

## Milestone F — Distribution (URL install / update / uninstall)

### Task 12: Manifest fetch (HTTPS, size cap, id sanitization)

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginInstaller.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/TrustDetails.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginManifestFetchTests.swift`

**Interfaces:**
- Produces:
  - `struct TrustDetails: Sendable, Equatable { let id, displayName, version: String; let publisher: String?; let sourceURL: URL; let bundleURL: URL?; let bundleSHA256: String?; let bundleSizeBytes: Int? }`.
  - `PluginInstaller.fetchManifest(_ url: URL, session: URLSessionProtocol) async throws -> (PluginManifest, TrustDetails)` — rejects non-`https` up front (`InstallError.notHTTPS`), streams with a 1 MiB cap (`InstallError.manifestTooLarge`), validates `schema_version`, and sanitizes `manifest.id` (`InstallError.invalidID`).
  - `enum InstallError: Error, Equatable` with the cases used across Tasks 12–14.
  - `protocol URLSessionProtocol` (a thin seam over `URLSession.bytes`/`data` for testing).
- Consumes: Task 1/9.

- [ ] **Step 1: Write the failing test** — inject a stub session returning a manifest body; assert `https` enforcement, the 1 MiB cap, and id sanitization.

```swift
@Test("rejects non-https") func rejectsHTTP() async {
    await #expect(throws: InstallError.notHTTPS) {
        _ = try await PluginInstaller.fetchManifest(URL(string: "http://x/m.json")!, session: StubSession.empty)
    }
}
@Test("rejects a manifest whose id is a traversal") func rejectsBadID() async {
    let body = #"{"schema_version":1,"id":"../evil","display_name":"E","short_name":"E","version":"1","runtime":"sidecar","ui":{}}"#
    await #expect(throws: InstallError.invalidID) {
        _ = try await PluginInstaller.fetchManifest(URL(string: "https://x/m.json")!, session: StubSession(body: Data(body.utf8)))
    }
}
```

- [ ] **Step 2: Run, verify fail** — FAIL (`cannot find 'fetchManifest'`).

- [ ] **Step 3: Implement** `URLSessionProtocol` + `fetchManifest` (stream with a running byte count, abort past 1 MiB; decode `PluginManifest`; `guard PluginInstaller.sanitize(id:) != nil`; build `TrustDetails`). `StubSession` is a test double.

- [ ] **Step 4: Run, verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/ \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginManifestFetchTests.swift
git commit -m "feat(plugin-v2): HTTPS manifest fetch with size cap and id sanitization"
```

---

### Task 13: Bundle download, SHA-256 verify, zip-slip-hardened unpack, atomic install

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginInstaller.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginInstallerTests.swift`

This is the highest-risk surface (untrusted code from the network). Every hardening step from spec §8.2 is a hard requirement.

**Interfaces:**
- Produces:
  - `PluginInstaller.downloadBundle(_ url: URL, expectedSHA256: String, session: URLSessionProtocol, into temp: URL) async throws` — streamed, 50 MiB hard ceiling enforced mid-stream (`InstallError.bundleTooLarge`), SHA-256 verified (`InstallError.hashMismatch`).
  - `PluginInstaller.unpackAndValidate(zip: URL, stagingDir: URL, manifest: PluginManifest) throws` — unzip, then **reject zip-slip**: enumerate every extracted entry, fail (`InstallError.zipSlip(String)`) if any `standardizedFileURL.resolvingSymlinksInPath()` escapes `stagingDir`; then validate the tree (manifest at root matching the fetched id/version, `bin/sidecar` present + executable, declared assets present).
  - `PluginInstaller.commitInstall(stagingDir: URL, finalDir: URL) throws` — atomic rename with a `.replacing/` swap of any existing dir.
- Consumes: Task 12. SHA-256 via `CryptoKit` (Mac-side; not the iOS-restricted module).

- [ ] **Step 1: Write the failing tests** — the critical ones:

```swift
@Test("hash mismatch aborts") func hashMismatch() async throws { /* download a body whose sha != expected → throws .hashMismatch */ }

@Test("zip-slip entry is rejected") func zipSlip() throws {
    // Build a zip containing an entry "../escape.txt"; unpack into staging; expect .zipSlip.
    let staging = makeTempDir()
    let evilZip = makeZipWithEntry(path: "../escape.txt", contents: "x")
    #expect(throws: InstallError.self) {
        try PluginInstaller.unpackAndValidate(zip: evilZip, stagingDir: staging,
                                              manifest: .fixtureSidecar(executable: "bin/sidecar"))
    }
}

@Test("a valid bundle installs atomically and is executable") func happyInstall() throws {
    let staging = makeTempDir(), final = makeTempDir().appendingPathComponent("opencode")
    let goodZip = makeValidSidecarZip(id: "opencode")
    try PluginInstaller.unpackAndValidate(zip: goodZip, stagingDir: staging, manifest: .fixtureSidecar(executable: "bin/sidecar"))
    try PluginInstaller.commitInstall(stagingDir: staging, finalDir: final)
    #expect(FileManager.default.isExecutableFile(atPath: final.appendingPathComponent("bin/sidecar").path))
}
```

- [ ] **Step 2: Run, verify fail** — FAIL (`cannot find 'unpackAndValidate'`).

- [ ] **Step 3: Implement.** `downloadBundle` streams `URLSession.bytes`, accumulating into a `SHA256` hasher + temp file with a running count (abort past 50 MiB), compares `hasher.finalize()` hex to `expectedSHA256` (case-insensitive). `unpackAndValidate` shells `/usr/bin/unzip -o <zip> -d <staging>` via the existing `ProcessRunner`, then — because `unzip` exits 0 even when it *skips* traversal entries — enumerates `staging` recursively and rejects any entry whose resolved path isn't under `staging.standardizedFileURL.resolvingSymlinksInPath()`. `commitInstall` moves any existing `finalDir` to a sibling `.replacing/`, renames `staging`→`finalDir`, deletes `.replacing/`. Provide the `makeZip*` test helpers (shell `zip`/`ditto`).

- [ ] **Step 4: Run, verify pass** — PASS (3+ tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginInstaller.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginInstallerTests.swift
git commit -m "feat(plugin-v2): hardened bundle download, sha256 verify, zip-slip-safe unpack"
```

---

### Task 14: Install / update / uninstall orchestration

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginInstaller.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginUpdateChecker.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginInstallFlowTests.swift`, `PluginUpdateCheckerTests.swift`

**Interfaces:**
- Produces:
  - `AppCoordinator.installPluginFromURL(_ url: URL, trustConfirmed: Bool) async -> Result<TrustDetails, InstallError>` — fetch manifest → return `TrustDetails` for the sheet when `!trustConfirmed`; when confirmed: download → verify → unpack → commit → `registry.registerSidecar(..., source: .url)` → persist `registry.json` → `enable`. On enable failure, mark failed-init, leave files for retry.
  - `AppCoordinator.removePlugin(id: String, deleteState: Bool) async -> String?` — `core.uninstall()` (best-effort) → `shutdown` → delete `~/.gallager/plugins/<id>/` → optionally delete state → remove registry entry. Bundled ids refuse.
  - `PluginUpdateChecker.check(_ entries: [PluginRegistryEntry], session:) async -> [PluginUpdate]` (`If-None-Match`/`If-Modified-Since`; newer `version` ⇒ an update; a changed `bundle_url` host ⇒ `sourceChanged: true`). Never auto-installs.
- Consumes: Task 12/13; the existing `registry.enable`/`makePluginHost`/`makePluginEnv`.

- [ ] **Step 1: Write failing tests** — install flow with a stub session installs+enables a sidecar; `removePlugin` deletes files + registry entry and refuses bundled; update-checker flags a newer version and a source-changed host.

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** the three coordinator methods + `PluginUpdateChecker`. Heavy steps run off the MainActor (the `Distribution` helpers are already non-`@MainActor`); the coordinator awaits results and then does the `@MainActor` registry mutation + persist.

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/ \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginInstallFlowTests.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginUpdateCheckerTests.swift
git commit -m "feat(plugin-v2): install/update/uninstall orchestration on the coordinator"
```

---

### Task 15: Settings UI — "Add Plugin from URL…" + trust sheet + sidecar lifecycle rows

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/AddPluginSheet.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/AgentsSettingsView.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyCommon/UI/Symbols.swift` (any new symbol, alphabetically)
- Test: covered by the E2E install-flow check in Task 18 + a SwiftUI compile build; no unit test (view layer, MV pattern).

**Interfaces:**
- Produces: `AddPluginSheet` modeled on `AddHostSheet` (`RemoteHostsSettingsView`) — a URL `TextField`, inline red error, `ProgressView` while fetching, then a two-stage flow: **fetch manifest → show `TrustDetails`** (display name, publisher, version, source URL, bundle size + sha256, and the verbatim warning **"This plugin runs arbitrary code on your Mac."**) with Cancel / **Trust and Install** buttons. On confirm it calls `coordinator.installPluginFromURL(url, trustConfirmed: true)`. The Agents tab gains an "Add Plugin from URL…" button and, for `source != .bundled` rows, a "Remove…" confirmation (`.confirmationDialog`) calling `coordinator.removePlugin`.
- Consumes: Task 14. Uses `@Environment` for the coordinator, `@State` for sheet/url/trust/error per the no-ViewModels rule; `.task`/async, never `Task {}` in `onAppear`.

- [ ] **Step 1:** Add the SF Symbol(s) needed (e.g. a download/link glyph) to `Symbols.swift` in sorted order; build to confirm `@SFSymbol` codegen.
- [ ] **Step 2: Write `AddPluginSheet`** with the two-stage layout (mirror `AddHostSheet`'s structure: `VStack(spacing: 20)`, `.padding(24)`, `.keyboardShortcut(.cancelAction)`/`.defaultAction`, inline error, `ProgressView`). Show the trust details in a bordered section once fetched.
- [ ] **Step 3: Wire the Agents tab** — an "Add Plugin from URL…" button presenting the sheet via `.sheet(isPresented:)`; a "Remove…" row for non-bundled plugins via `.confirmationDialog`.
- [ ] **Step 4: Build + manual smoke** — `swift build`, then run the app (`macos-app` skill) and confirm the sheet opens, fetches, shows trust details, and the warning copy is present. (Real HTTPS install is manual-smoke per spec §12.)
- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/AddPluginSheet.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/AgentsSettingsView.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyCommon/UI/Symbols.swift
git commit -m "feat(plugin-v2): Add-Plugin-from-URL trust sheet and sidecar lifecycle UI"
```

---

### Task 16: CLI verbs `install` / `remove` / `update` + router methods

**Files:**
- Modify: `ClaudeSpyPackage/Sources/Gallager/Commands/PluginCommands.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/APIRequestRouter.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift` (router callbacks)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/APIRouterPluginV2Tests.swift`

**Interfaces:**
- Produces:
  - CLI: `gallager plugin install <https-url> [--yes]` (enforce `https://`; print trust details; read y/n unless `--yes`; non-zero on rejection/failure), `gallager plugin remove <id> [--keep-state|--delete-state]` (bundled refuse), `gallager plugin update [<id>] [--apply]` (no id ⇒ all; without `--apply` print which are newer). Each follows the existing `pluginRequest(method:params:options:)` pattern over `SocketClient`.
  - Router: `plugin.install`, `plugin.remove`, `plugin.update` added to the allow-list (`APIRequestRouter.swift:63–68`) + `case` arms (after `plugin.call` at ~line 747), each calling a new `on…` callback injected by `AppCoordinator`. Widen the `plugin.call` passthrough so `callCore` forwards *arbitrary* sidecar method strings (spec §10): change `PluginRegistry.callCore`'s `default:` from `.unknownMethod` to a passthrough that, for an enabled `SidecarPluginCore`, sends the method over the transport (a new `callCore`-reachable hook on the core), keeping the in-process cores' 4-method allow-list.
- Consumes: Task 14.

- [ ] **Step 1: Write the failing router test** — a `LiveAPIRequestRouter` with stub `onPluginInstall`/`onPluginRemove`/`onPluginUpdate` returns the expected JSON-RPC envelopes for the new methods; an unknown method still errors.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the router allow-list additions + `case` arms + coordinator callbacks (`installPluginFromURL`/`removePlugin`/`checkPluginUpdates`), then the three `ParsableCommand` subcommands in `PluginCommands.swift` (register them in `PluginCommand.configuration.subcommands`), and the `callCore` passthrough for sidecars.
- [ ] **Step 4: Run, verify pass** — router tests PASS; `swift build` for the CLI target; manual `gallager plugin update` against a running app prints "up to date".
- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/Gallager/Commands/PluginCommands.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/APIRequestRouter.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/PluginRegistry.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/APIRouterPluginV2Tests.swift
git commit -m "feat(plugin-v2): gallager plugin install/remove/update verbs + router passthrough"
```

---

## Milestone G — Optional capabilities, crash E2E, docs

### Task 17: Optional capabilities — `rich_pane_detection` + `modal_prompts`

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/SidecarCapabilities.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/SidecarPluginCore.swift`
- Modify: the pane-detection call site (`TmuxService.detectAgentPanes` caller, via `AppCoordinator.handlePluginAgentPanes`)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/SidecarCapabilitiesTests.swift`

These attach *without* touching the `PluginCore` protocol — they are `SidecarPluginCore`-only RPCs, used only when the manifest declares the capability; absence ⇒ `MethodNotFound` ⇒ "feature unsupported" ⇒ fall back to `process_names`.

**Interfaces:**
- Produces:
  - `SidecarPluginCore.detectPane(_ paneInfo: PaneInfo) async -> PaneMatch?` (RPC `detect_pane`), guarded by `manifest.capabilities.richPaneDetection`. `struct PaneInfo: Codable` / `struct PaneMatch: Codable { let matches: Bool; let projectPath: String?; let sessionID: String? }`.
  - Inbound `prompt_user` notification → a Mac modal request surfaced through the coordinator, gated by `capabilities.modalPrompts`.
  - The pane-detection caller asks "is this an enabled sidecar declaring `rich_pane_detection`?" and calls `detectPane` only then; otherwise `process_names` (unchanged) — the agent-blind dispatcher and `PluginCore` stay exactly as v1.
- Consumes: Task 6/8.

- [ ] **Step 1: Write failing tests** — with `MockSidecarProcess`: a core whose manifest declares `richPaneDetection` calls `detect_pane` and returns the match; a core *without* the capability never calls it (and a `MethodNotFound` degrades to no-match). `modalPrompts` off ⇒ a `prompt_user` notification is ignored.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the capability-gated RPCs + the pane-detection call-site branch + the modal-prompt surface (reuse the macOS `.sheet`/alert pattern from the memory note; `modal_prompts` is rare/off by default).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/SidecarCapabilities.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/Sidecar/SidecarPluginCore.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/SidecarCapabilitiesTests.swift
git commit -m "feat(plugin-v2): opt-in rich_pane_detection and modal_prompts capabilities"
```

---

### Task 18: Crash/restart, crash-loop-disable, and response round-trip E2E

**Files:**
- Modify: `ClaudeSpyPackage/Sources/EchoPluginSidecar/main.swift` (control-payload abort + delivery script)
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/PluginCrashRestartScenario.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/PluginCrashLoopDisableScenario.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/PluginSidecarResponseRoundTripScenario.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyE2E/ClaudeSpyE2ECommand.swift` (register all three)
- Possibly add: a `TestStep` to assert the Settings "disabled / Re-enable" banner.

These are the three scenarios v1 marked v2-only (spec §12).

**Interfaces:**
- `PluginCrashRestartScenario`: send a `translate_event` with `abort:true` → the sidecar `abort()`s → supervisor restarts (1 s backoff) → a subsequent normal frame flows and surfaces on iOS.
- `PluginCrashLoopDisableScenario`: four aborts within 60 s → the plugin auto-disables → assert the Settings banner with stderr + a "Re-enable" button (no further auto-restart).
- `PluginSidecarResponseRoundTripScenario`: drive a blocking `awaitingPermission` form via the sidecar → answer deny-with-feedback on iOS → assert the marker text lands in the pane (the sidecar's `deliver_response` → `send_text` round-trip), mirroring `EchoResponseRoundTripScenario` but out-of-process.

- [ ] **Step 1: Write the three scenarios** (model the response one on `EchoResponseRoundTripScenario`; the crash ones drive `abort:true` payloads and assert restart/disable). They fail until the fixture supports the control payloads.
- [ ] **Step 2: Run, verify fail** — `./scripts/e2e-test.sh --scenario "Plugin Crash Restart"` etc.
- [ ] **Step 3: Implement** the `EchoPluginSidecar` control-payload handling (`abort:true` → `abort()`; a configurable delivery script for the response round-trip) + any banner-assert `TestStep` + register the scenarios in `allScenarios`.
- [ ] **Step 4: Run, verify pass** — all three scenarios PASS. Then run the **full** e2e suite to confirm no regression (`./scripts/e2e-test.sh`).
- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/EchoPluginSidecar/main.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/PluginCrash*.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/PluginSidecarResponseRoundTripScenario.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyE2E/ClaudeSpyE2ECommand.swift
git commit -m "test(plugin-v2): crash-restart, crash-loop-disable, sidecar response round-trip E2E"
```

---

### Task 19: Docs + CLAUDE.md + gallager skill

**Files:**
- Create: `docs/plugins/sidecar-authoring.md`
- Modify: `docs/superpowers/specs/2026-05-29-plugin-system-v2-external-sidecar-plugins.md` (status → Implemented; link the plan)
- Modify: `CLAUDE.md` (Reference Docs list)
- Modify: `docs/repo-hooks.md` / the `gallager` skill if any CLI surface changed (the PR-checklist hook will flag CLI/skill/docs/e2e chores)

**Interfaces:** documentation only — the durable external contract a third party builds against (manifest schema, the JSON-RPC method/notification vocabulary, the bridge frame, `GALLAGER_INGRESS_SOCK`, the OTLP namespace caveat, the security model's honest scope).

- [ ] **Step 1: Write `docs/plugins/sidecar-authoring.md`** — the manifest schema (Task 1 fields), the JSON-RPC vocabulary (`SidecarRPC`/`HostRPC`), the Content-Length framing, the `GALLAGER_*` spawn env (incl. `GALLAGER_INGRESS_SOCK`), the optional capabilities, and the §9 security scope ("trusted-on-install, hash-pinned, runs with your permissions" — **not** "safe to run untrusted plugins").
- [ ] **Step 2: Update `CLAUDE.md`** Reference Docs to point at the new doc; flip the v2 spec's status; note the `stderr.log` deviation.
- [ ] **Step 3: Run** the full unit suite + full e2e suite one final time; record counts in the plan's progress log.
- [ ] **Step 4: Commit**

```bash
git add docs/plugins/sidecar-authoring.md docs/superpowers/specs/2026-05-29-plugin-system-v2-external-sidecar-plugins.md CLAUDE.md docs/repo-hooks.md
git commit -m "docs(plugin-v2): sidecar authoring guide; mark v2 spec implemented"
```

---

## Self-review (spec → task coverage)

- **§2 seam (`SidecarPluginCore`, all marshalling rules):** Tasks 3 (`PluginEnvWire` settings-as-nested-JSON, `IngressFrameWire`), 6 (every method ↔ RPC, `host` retained not marshaled, inbound `agent_panes` request lane, `PluginEvent` whole via `AgentState.openForm`).
- **§3 transport (every hazard row):** Tasks 2 (header/body caps, `loadUnaligned` via `Data.range`/no unaligned int load needed in Content-Length path — note: the one unaligned-load rule applies to the ingress 4-byte path, already handled; the Content-Length path parses text), 4 (slot-before-write, inline ordered delivery, off-actor writes, per-RPC timeout, bidirectional correlation), 5 (close parent pipe ends after spawn, `readabilityHandler` byte stream not `AsyncBytes`).
- **§4 manifest:** Task 1.
- **§5 supervision (spawn, stderr→log, terminationHandler, crash policy 1/2/4s→disable@4, shutdown SIGTERM→SIGKILL, stale-beats-empty on restart):** Task 5; §5.1 optional probe is explicitly deferred (Global Constraints: no mandatory heartbeat).
- **§6 ingress (one socket, `GALLAGER_INGRESS_SOCK`, templated install, manual-launch):** Tasks 5 + 11. §6.1 telemetry: Task 3 (`otlpReceiverEndpoint` marshaled) + Task 11 doc note (the `OTLPTelemetryAccumulator` namespace caveat is surfaced, adaptation deferred per spec).
- **§7 optional capabilities:** Task 17.
- **§8 distribution (registry.json, install flow steps 1–8, update, uninstall, folder-drop):** Tasks 7, 9, 12, 13, 14.
- **§9 security model (https, sha256 integrity, trust prompt, zip-slip, "runs as user" copy):** Tasks 12, 13, 15, 19.
- **§10 CLI:** Task 16.
- **§11 error handling rows:** distributed across Tasks 5 (init/missing-exe/malformed-frame-restart), 12–14 (manifest invalid, install RPC fails), 17 (`MethodNotFound` degrade), 9 (event for disabled plugin dropped — existing ingress behavior).
- **§12 testing (`EchoPlugin` executable, `SidecarPluginCoreTests`+`MockSidecarProcess`, the three E2E scenarios):** Tasks 6, 10, 18.
- **§13 wire compat (no `VersionCompatibility` bump):** Global Constraints (asserted, not a task).
- **§14 migration (bundled stays in-process):** Tasks 8/9 keep the bundled path untouched; covered by re-running the full suite (Tasks 18/19).
- **§15 non-goals:** none built (signing, OS sandbox, marketplace browser, hot-reload, multi-instance) — explicitly out of scope.

**Open items the implementer must resolve in-task (flagged, not placeholders):** the `JSONValue` ergonomics (encode/decode/accessors) added in `JSONRPC.swift` (Tasks 3/6); injecting a clock into `SidecarSupervisor` for deterministic crash-window tests (Task 5); locating the built `EchoPluginSidecar` binary from the E2E orchestrator's build-products dir (Task 10). Each is a known, bounded decision with the approach specified.

---

## Execution note

This plan is large but is **one cohesive subsystem** (the sidecar tier behind a frozen contract). It is ordered so each *milestone* yields working, testable software: Milestone D (Task 10) is the first end-to-end proof (a folder-dropped sidecar mirrors a session), and Milestone F adds network distribution on top. If you prefer smaller review units, execute milestone-by-milestone (A→G), running the relevant `swift test --filter` after each task and the full e2e suite after Tasks 10, 11, and 18.
