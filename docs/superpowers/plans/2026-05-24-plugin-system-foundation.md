# Plugin System — Phase 1.A: Types, Protocol, and Connection

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the static foundation of the plugin system — package targets, Codable wire types in `ClaudeSpyNetworking`, the `GallagerPluginProtocol` module, and the `ClaudeSpyPluginRuntime` infrastructure that can communicate with a sidecar (paths, registry, JSON-RPC connection). No process spawning, no app integration, no CLI surface yet.

**Architecture:** Two new modules (`GallagerPluginProtocol` shared; `ClaudeSpyPluginRuntime` macOS-only) plus new Codable types added alongside the existing `ClaudeSession`/`ClaudeProjectInfo`/`HookEvent` types. No existing behavior changes — the legacy code paths stay live. Everything in this plan is exercised through unit tests; nothing in the running Mac or iOS app uses these new types yet.

**Tech Stack:** Swift 6.1 (`@MainActor`, async/await, `Sendable`), Swift Package Manager (new targets in `ClaudeSpyPackage/Package.swift`), Point-Free `Dependencies` for DI, swift-testing (`@Test` / `#expect`), Foundation `JSONEncoder`/`JSONDecoder`, `FileHandle`, `Pipe`.

**Scope — Plan 1.A of 4 plans for Phase 1.** The spec's Phase 1 (Foundation) is too large to fit in a single plan that respects the no-placeholders rule, so it's split into four sequential plans (1.A → 1.D). Each plan ships a coherent, tested slice with passing CI.

| Plan | Contents | Verifiable when done |
|---|---|---|
| **1.A (this plan)** | Package skeleton, Codable types, paths, registry, `SidecarConnection` JSON-RPC framing | `swift test` passes; unit-level only |
| 1.B (follow-up) | `SidecarSupervisor`, `IngressBroker`, `PluginEventDispatcher`, `PluginRouter`, `PluginManager`, `MockSidecar` | Integration tests using mock sidecar |
| 1.C (follow-up) | `gallager plugin <verb>` CLI subcommands + `plugin.*` server-side RPC handlers in `APIRequestRouter` | CLI smoke tests against a running app instance |
| 1.D (follow-up) | `EchoPluginSidecar` executable + `--gallager-state-root` launch arg + dormant `PluginManager` instantiation in `AppCoordinator` + end-to-end Echo integration tests | Echo plugin loads and round-trips RPCs |

**Out of scope for all of Phase 1** (becomes Phases 2–4 from the spec):
- Extracting Claude Code into `ClaudeCodePluginCore` + `ClaudeCodePluginSidecar` → Plan 2.
- Extracting Codex into `CodexPluginCore` + `CodexPluginSidecar` → Plan 3.
- Deleting `HookEvent`/`HookAction`/`ClaudeSession`/`ClaudeProjectInfo`, renaming pane state fields, updating iOS, bumping `VersionCompatibility`, marketplace UI, log viewer UI, E2E migration → Plan 4.

---

## File structure

### New Swift package targets in `ClaudeSpyPackage/Sources/`

| New module / target | Type | Platform | Purpose |
|---|---|---|---|
| `GallagerPluginProtocol/` | library | iOS + macOS (built everywhere but only used by Mac) | Codable types crossing the sidecar boundary: `PluginManifest`, `PluginEvent`, `AppAction`, JSON-RPC envelopes, method-name constants. |
| `ClaudeSpyPluginRuntime/` | library | macOS only | Runtime services: `PluginPaths`, `PluginRegistry`, `SidecarConnection`, `SidecarSupervisor`, `IngressBroker`, `PluginRouter`, `PluginEventDispatcher`, `PluginManager`. |
| `EchoPluginSidecar/` | executable | macOS only | Reference sidecar binary for tests. Built into `.build/.../EchoPluginSidecar`, copied into test resources. |
| `ClaudeSpyPluginRuntimeTests/` | testTarget | macOS only | Unit + integration tests for the runtime. |

### New files in existing modules

| Module | New file | Purpose |
|---|---|---|
| `ClaudeSpyNetworking/Models/` | `PluginID.swift` | `typealias PluginID = String` |
| `ClaudeSpyNetworking/Models/` | `NotificationSpec.swift` | Pre-baked notification payload (title + body). |
| `ClaudeSpyNetworking/Models/` | `AgentSession.swift` | Session type plugin-aware version (added alongside `ClaudeSession`). |
| `ClaudeSpyNetworking/Models/` | `AgentProject.swift` | Project type plugin-aware version (added alongside `ClaudeProjectInfo`). |
| `ClaudeSpyNetworking/Models/` | `AgentResponseRequest.swift` | Closed enum + 5 payload structs. |
| `ClaudeSpyNetworking/Models/` | `AgentResponse.swift` | Closed enum + 5 payload structs (iOS→Mac response shapes). |
| `ClaudeSpyNetworking/Models/` | `PluginWireMessages.swift` | `AgentSessionStatusUpdate`, `PluginPresentation`, `PluginPresentationBundle`, `AgentResponseRequestMessage`, `AgentResponseSubmissionMessage`. |
| `ClaudeSpyServerFeature/Services/` | `PluginRPCHandlers.swift` | Bridges `plugin.*` RPC methods between `APIRequestRouter` and the `PluginManager`. |
| `Gallager/Commands/` | `PluginCommands.swift` | All `gallager plugin <verb>` ArgumentParser subcommands. |

### Test infrastructure

| Target | New file | Purpose |
|---|---|---|
| `ClaudeSpyPluginRuntimeTests/` | `MockSidecar.swift` | In-process fake sidecar conforming to the JSON-RPC protocol — used to drive runtime tests without spawning real subprocesses. |
| `ClaudeSpyPluginRuntimeTests/` | various `*Tests.swift` | Per-component test files. |

---

## Conventions for every task

- **TDD strict**: failing test first, then minimal implementation. Steps below show the order.
- **Per-file commits**: each task ends with a `git add` listing exact files + a one-line commit message. Keep commits small for easy review and bisecting.
- **No emojis** in any code, comments, or commit messages (per project convention).
- **Run command** for tests is always `swift test --filter <TestSuiteName>` from `ClaudeSpyPackage/`. If a test target name is in the filter, all tests in that target run; for a single suite or test, use the full `Target.Suite/test`.
- **Build verification** in the Task's last step: `swift build` from `ClaudeSpyPackage/` — must produce no warnings introduced by this task.

---

## Task 1: `Package.swift` — declare the new targets

**Files:**
- Modify: `ClaudeSpyPackage/Package.swift`

- [ ] **Step 1: Add new product entries**

Open `ClaudeSpyPackage/Package.swift`. In the `products` array, after the `ClaudeSpyExternalServerLib` library, add:

```swift
    .library(
        name: "GallagerPluginProtocol",
        targets: ["GallagerPluginProtocol"]
    ),
    .library(
        name: "ClaudeSpyPluginRuntime",
        targets: ["ClaudeSpyPluginRuntime"]
    ),
    .executable(
        name: "EchoPluginSidecar",
        targets: ["EchoPluginSidecar"]
    ),
```

- [ ] **Step 2: Add new target entries**

In the `targets` array, after the `ClaudeSpyExternalServerLib` target, add:

```swift
    // Codable types crossing the plugin-sidecar boundary. Built on all
    // platforms (so types can be referenced from both iOS and macOS code if
    // ever needed) but only consumed by Mac modules in Phase 1.
    .target(
        name: "GallagerPluginProtocol",
        dependencies: [
            .claudeSpyNetworking,
        ]
    ),
    // Mac-only runtime: plugin registry, sidecar supervisor, JSON-RPC router,
    // ingress broker, event dispatcher, manager facade.
    .target(
        name: "ClaudeSpyPluginRuntime",
        dependencies: [
            "GallagerPluginProtocol",
            .claudeSpyNetworking,
            .logging,
            .dependencies,
            .dependenciesMacros,
        ]
    ),
    // Reference sidecar binary used as a test fixture. Built as an executable
    // so the test target can invoke it via Process(); shipped only inside the
    // test resources, never in the app bundle.
    .executableTarget(
        name: "EchoPluginSidecar",
        dependencies: [
            "GallagerPluginProtocol",
            .logging,
        ]
    ),
```

In the test targets section, after `ClaudeSpyServerFeatureTests`, add:

```swift
    .testTarget(
        name: "ClaudeSpyPluginRuntimeTests",
        dependencies: [
            "ClaudeSpyPluginRuntime",
            "GallagerPluginProtocol",
            "EchoPluginSidecar",
            .dependenciesTestSupport,
            .clocks,
            .concurrencyExtras,
        ]
    ),
```

- [ ] **Step 3: Add the `ClaudeSpyServerFeature` and `Gallager` dependencies on `ClaudeSpyPluginRuntime`**

`ClaudeSpyServerFeature` will host the `PluginRPCHandlers` glue, and `GallagerCLI` (`Sources/Gallager/`) needs the protocol types for the new commands. Locate the `ClaudeSpyServerFeature` target and add `"ClaudeSpyPluginRuntime"` to its dependencies. Locate the `GallagerCLI` target and add `"GallagerPluginProtocol"` to its dependencies.

- [ ] **Step 4: Create empty target source directories**

These directories must exist so SPM finds them. Create empty placeholder files so SPM doesn't error on empty target dirs:

```bash
mkdir -p ClaudeSpyPackage/Sources/GallagerPluginProtocol
mkdir -p ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime
mkdir -p ClaudeSpyPackage/Sources/EchoPluginSidecar
mkdir -p ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests
touch ClaudeSpyPackage/Sources/GallagerPluginProtocol/_Placeholder.swift
touch ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/_Placeholder.swift
touch ClaudeSpyPackage/Sources/EchoPluginSidecar/_Placeholder.swift
touch ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/_Placeholder.swift
```

- [ ] **Step 5: Verify the package resolves and builds**

```bash
cd ClaudeSpyPackage && swift package resolve && swift build
```

Expected: builds with no errors. The placeholder files contribute no symbols.

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Package.swift \
        ClaudeSpyPackage/Sources/GallagerPluginProtocol/_Placeholder.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/_Placeholder.swift \
        ClaudeSpyPackage/Sources/EchoPluginSidecar/_Placeholder.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/_Placeholder.swift
git commit -m "Add plugin-system target skeletons to Package.swift"
```

---

## Task 2: `PluginID` and `NotificationSpec` in `ClaudeSpyNetworking`

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/PluginID.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/NotificationSpec.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/NotificationSpecTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/NotificationSpecTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("NotificationSpec")
struct NotificationSpecTests {
    @Test func roundTripsJSON() throws {
        let original = NotificationSpec(
            title: "Claude is waiting",
            body: "Project Foo: explain the change"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotificationSpec.self, from: data)
        #expect(decoded.title == original.title)
        #expect(decoded.body == original.body)
    }

    @Test func usesSnakeCaseOnTheWire() throws {
        let spec = NotificationSpec(title: "T", body: "B")
        let data = try JSONEncoder().encode(spec)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"title\":"))
        #expect(json.contains("\"body\":"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyNetworkingTests.NotificationSpec 2>&1 | tail -20
```

Expected: fails with "cannot find 'NotificationSpec' in scope".

- [ ] **Step 3: Create `PluginID.swift`**

```swift
import Foundation

/// Stable plugin identifier (matches `id` in the plugin manifest, e.g. `"claude-code"`).
///
/// Modeled as a typealias instead of a value type so it serializes as a plain
/// JSON string on the wire and interoperates with `Dictionary<String, …>` keys
/// without adapters. Treat as opaque; never construct one from arbitrary user
/// input without manifest validation.
public typealias PluginID = String
```

- [ ] **Step 4: Create `NotificationSpec.swift`**

```swift
import Foundation

/// A fully-formatted notification ready to surface on macOS (`UserNotifications`)
/// and forward to iOS as a push. Sidecars bake the title + body — no
/// app-side template interpolation.
public struct NotificationSpec: Codable, Sendable, Equatable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyNetworkingTests.NotificationSpec 2>&1 | tail -10
```

Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/PluginID.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/NotificationSpec.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/NotificationSpecTests.swift
git commit -m "Add PluginID typealias and NotificationSpec wire type"
```

---

## Task 3: `AgentSession` and `AgentProject` (added alongside existing types)

These are added now so subsequent code can compile against them. The existing `ClaudeSession` / `ClaudeProjectInfo` continue to be used in the running code; Phase 4 will swap usage.

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentSession.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentProject.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/AgentTypesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("AgentSession + AgentProject")
struct AgentTypesTests {
    @Test func agentSessionRoundtrips() throws {
        let session = AgentSession(
            paneId: "%5",
            pluginID: "claude-code",
            detectedProjectPath: "/tmp/proj"
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        #expect(decoded.paneId == "%5")
        #expect(decoded.pluginID == "claude-code")
        #expect(decoded.detectedProjectPath == "/tmp/proj")
        #expect(decoded.isWorking == false)
        #expect(decoded.needsAttention == false)
    }

    @Test func agentSessionApplyStatusUpdate() {
        var session = AgentSession(paneId: "%5", pluginID: "claude-code")
        session.applyStatus(working: true, attention: false)
        #expect(session.isWorking)
        #expect(!session.needsAttention)
        session.applyStatus(working: false, attention: true)
        #expect(!session.isWorking)
        #expect(session.needsAttention)
    }

    @Test func agentProjectRoundtrips() throws {
        let project = AgentProject(
            id: "abc",
            pluginID: "codex",
            name: "MyProj",
            path: "/Users/u/MyProj",
            lastUsed: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(AgentProject.self, from: data)
        #expect(decoded.id == "abc")
        #expect(decoded.pluginID == "codex")
        #expect(decoded.name == "MyProj")
        #expect(decoded.path == "/Users/u/MyProj")
        #expect(decoded.lastUsed?.timeIntervalSince1970 == 1_700_000_000)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyNetworkingTests.AgentSession 2>&1 | tail -20
```

Expected: fails with "cannot find 'AgentSession' in scope".

- [ ] **Step 3: Create `AgentSession.swift`**

```swift
import Foundation

/// Plugin-aware session state. Sits alongside `ClaudeSession` during Phase 1;
/// Phase 4 swaps consumers over and deletes `ClaudeSession`.
///
/// Unlike `ClaudeSession`, this type carries no `events` buffer and no
/// `latestEvent` — the trailing-5 buffer was used by the iOS event-row UI,
/// which is being removed. Working/attention state is mutated by inbound
/// `AgentSessionStatusUpdate` messages via `applyStatus(working:attention:)`.
public struct AgentSession: Codable, Sendable, Equatable {
    public let paneId: String
    public let pluginID: PluginID
    public var detectedProjectPath: String?
    public private(set) var isWorking: Bool
    public private(set) var needsAttention: Bool

    public init(
        paneId: String,
        pluginID: PluginID,
        detectedProjectPath: String? = nil,
        isWorking: Bool = false,
        needsAttention: Bool = false
    ) {
        self.paneId = paneId
        self.pluginID = pluginID
        self.detectedProjectPath = detectedProjectPath
        self.isWorking = isWorking
        self.needsAttention = needsAttention
    }

    /// Update status bits. `working == nil` leaves the current value untouched
    /// (some events don't carry a working transition).
    public mutating func applyStatus(working: Bool?, attention: Bool) {
        if let working { isWorking = working }
        needsAttention = attention
    }

    public var statusLabel: String {
        if needsAttention { return "Attention" }
        if isWorking { return "Working" }
        return "Idle"
    }
}
```

- [ ] **Step 4: Create `AgentProject.swift`**

```swift
import Foundation

/// Plugin-aware project entry. Sits alongside `ClaudeProjectInfo` during Phase 1.
public struct AgentProject: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let pluginID: PluginID
    public let name: String
    public let path: String
    public let lastUsed: Date?
    /// Free-form per-plugin payload (e.g. session ids, transcript paths) — opaque
    /// to the app, used by the sidecar to resolve its own state when the user
    /// re-opens a project. Decoded as an arbitrary JSON object.
    public let agentData: AnyCodable?

    public init(
        id: String,
        pluginID: PluginID,
        name: String,
        path: String,
        lastUsed: Date? = nil,
        agentData: AnyCodable? = nil
    ) {
        self.id = id
        self.pluginID = pluginID
        self.name = name
        self.path = path
        self.lastUsed = lastUsed
        self.agentData = agentData
    }
}
```

> `AnyCodable` already exists in `ClaudeSpyNetworking` — it's used by the existing `HookEvent.toolResponse`. Verify with `grep -r "struct AnyCodable\|enum AnyCodable" ClaudeSpyPackage/Sources/ClaudeSpyNetworking/` before this step. If it's not there, fall back to `[String: String]?` for now and file a follow-up.

- [ ] **Step 5: Run test to verify it passes**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyNetworkingTests.AgentSession 2>&1 | tail -10
```

Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentSession.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentProject.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/AgentTypesTests.swift
git commit -m "Add AgentSession and AgentProject types alongside existing"
```

---

## Task 4: `AgentResponseRequest` enum and payload structs

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentResponseRequest.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/AgentResponseRequestTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("AgentResponseRequest")
struct AgentResponseRequestTests {
    @Test func promptRoundtrips() throws {
        let req = AgentResponseRequest.prompt(PromptRequest(placeholder: "Send a message…"))
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(AgentResponseRequest.self, from: data)
        guard case let .prompt(payload) = decoded else { Issue.record("wrong case"); return }
        #expect(payload.placeholder == "Send a message…")
    }

    @Test func askUserQuestionRoundtrips() throws {
        let q = AskUserQuestionRequest.Question(
            prompt: "Which approach?",
            options: [
                AskUserQuestionRequest.Option(label: "A", detail: nil),
                AskUserQuestionRequest.Option(label: "B", detail: "with details"),
            ],
            allowMultiple: false,
            allowFreeText: true
        )
        let req = AgentResponseRequest.askUserQuestion(AskUserQuestionRequest(questions: [q]))
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(AgentResponseRequest.self, from: data)
        guard case let .askUserQuestion(payload) = decoded else { Issue.record("wrong case"); return }
        #expect(payload.questions.count == 1)
        #expect(payload.questions[0].prompt == "Which approach?")
        #expect(payload.questions[0].options.count == 2)
        #expect(payload.questions[0].allowFreeText)
    }

    @Test func permissionCarriesAutoApprovableFlag() throws {
        let req = AgentResponseRequest.permission(PermissionRequest(
            toolName: "Bash",
            description: "rm -rf /tmp/foo",
            suggestions: [
                PermissionSuggestion(id: "s1", label: "Allow once", badge: nil),
            ],
            isAutoApprovable: true
        ))
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(AgentResponseRequest.self, from: data)
        guard case let .permission(payload) = decoded else { Issue.record("wrong case"); return }
        #expect(payload.toolName == "Bash")
        #expect(payload.isAutoApprovable)
        #expect(payload.suggestions.count == 1)
    }

    @Test func approvePlanCarriesAllowEditFlag() throws {
        let req = AgentResponseRequest.approvePlan(ApprovePlanRequest(
            plan: "Step 1\nStep 2",
            allowEdit: true
        ))
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(AgentResponseRequest.self, from: data)
        guard case let .approvePlan(payload) = decoded else { Issue.record("wrong case"); return }
        #expect(payload.plan == "Step 1\nStep 2")
        #expect(payload.allowEdit)
    }

    @Test func replyAfterStopRoundtrips() throws {
        let req = AgentResponseRequest.replyAfterStop(ReplyAfterStopRequest(
            lastAssistantMessage: "Done."
        ))
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(AgentResponseRequest.self, from: data)
        guard case let .replyAfterStop(payload) = decoded else { Issue.record("wrong case"); return }
        #expect(payload.lastAssistantMessage == "Done.")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyNetworkingTests.AgentResponseRequest 2>&1 | tail -20
```

Expected: fails with "cannot find type 'AgentResponseRequest' in scope" (or similar).

- [ ] **Step 3: Implement `AgentResponseRequest.swift`**

```swift
import Foundation

/// Closed-set vocabulary of interactive forms iOS knows how to render. Plugin
/// sidecars translate their agent-specific concepts into one of these shapes.
/// Anything outside this set stays Mac-only (no iOS form).
///
/// Encoded as `{ "type": "<case>", "body": <payload> }` for stable JSON shape.
public enum AgentResponseRequest: Codable, Sendable, Equatable {
    case prompt(PromptRequest)
    case replyAfterStop(ReplyAfterStopRequest)
    case permission(PermissionRequest)
    case askUserQuestion(AskUserQuestionRequest)
    case approvePlan(ApprovePlanRequest)

    private enum CodingKeys: String, CodingKey { case type, body }

    private enum Kind: String, Codable {
        case prompt, replyAfterStop, permission, askUserQuestion, approvePlan
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .prompt:           self = .prompt(try c.decode(PromptRequest.self, forKey: .body))
        case .replyAfterStop:   self = .replyAfterStop(try c.decode(ReplyAfterStopRequest.self, forKey: .body))
        case .permission:       self = .permission(try c.decode(PermissionRequest.self, forKey: .body))
        case .askUserQuestion:  self = .askUserQuestion(try c.decode(AskUserQuestionRequest.self, forKey: .body))
        case .approvePlan:      self = .approvePlan(try c.decode(ApprovePlanRequest.self, forKey: .body))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .prompt(p):          try c.encode(Kind.prompt, forKey: .type);          try c.encode(p, forKey: .body)
        case let .replyAfterStop(p):  try c.encode(Kind.replyAfterStop, forKey: .type);  try c.encode(p, forKey: .body)
        case let .permission(p):      try c.encode(Kind.permission, forKey: .type);      try c.encode(p, forKey: .body)
        case let .askUserQuestion(p): try c.encode(Kind.askUserQuestion, forKey: .type); try c.encode(p, forKey: .body)
        case let .approvePlan(p):     try c.encode(Kind.approvePlan, forKey: .type);     try c.encode(p, forKey: .body)
        }
    }
}

public struct PromptRequest: Codable, Sendable, Equatable {
    public let placeholder: String?
    public init(placeholder: String? = nil) { self.placeholder = placeholder }
}

public struct ReplyAfterStopRequest: Codable, Sendable, Equatable {
    public let lastAssistantMessage: String?
    public init(lastAssistantMessage: String? = nil) { self.lastAssistantMessage = lastAssistantMessage }
}

public struct PermissionRequest: Codable, Sendable, Equatable {
    public let toolName: String?
    public let description: String
    public let suggestions: [PermissionSuggestion]
    /// Sidecar's judgment that this action is safe to auto-approve when the
    /// Mac has yolo mode enabled for the pane. Sidecar doesn't know about
    /// yolo; it just states safety.
    public let isAutoApprovable: Bool

    public init(
        toolName: String?,
        description: String,
        suggestions: [PermissionSuggestion],
        isAutoApprovable: Bool
    ) {
        self.toolName = toolName
        self.description = description
        self.suggestions = suggestions
        self.isAutoApprovable = isAutoApprovable
    }
}

public struct PermissionSuggestion: Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let badge: String?

    public init(id: String, label: String, badge: String? = nil) {
        self.id = id
        self.label = label
        self.badge = badge
    }
}

public struct AskUserQuestionRequest: Codable, Sendable, Equatable {
    public let questions: [Question]

    public init(questions: [Question]) { self.questions = questions }

    public struct Question: Codable, Sendable, Equatable {
        public let prompt: String
        public let options: [Option]
        public let allowMultiple: Bool
        public let allowFreeText: Bool

        public init(
            prompt: String,
            options: [Option],
            allowMultiple: Bool,
            allowFreeText: Bool
        ) {
            self.prompt = prompt
            self.options = options
            self.allowMultiple = allowMultiple
            self.allowFreeText = allowFreeText
        }
    }

    public struct Option: Codable, Sendable, Equatable {
        public let label: String
        public let detail: String?

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }
}

public struct ApprovePlanRequest: Codable, Sendable, Equatable {
    public let plan: String
    public let allowEdit: Bool

    public init(plan: String, allowEdit: Bool) {
        self.plan = plan
        self.allowEdit = allowEdit
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyNetworkingTests.AgentResponseRequest 2>&1 | tail -10
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentResponseRequest.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/AgentResponseRequestTests.swift
git commit -m "Add AgentResponseRequest closed enum with 5 payload types"
```

---

## Task 5: `AgentResponse` enum and payload structs

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentResponse.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/AgentResponseTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("AgentResponse")
struct AgentResponseTests {
    @Test func promptResponseRoundtrips() throws {
        let r = AgentResponse.prompt(PromptResponse(text: "hello"))
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: JSONEncoder().encode(r))
        guard case let .prompt(p) = decoded else { Issue.record("wrong case"); return }
        #expect(p.text == "hello")
    }

    @Test func permissionResponseCarriesSuggestionId() throws {
        let r = AgentResponse.permission(PermissionResponse(decision: .allow, appliedSuggestionId: "s1"))
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: JSONEncoder().encode(r))
        guard case let .permission(p) = decoded else { Issue.record("wrong case"); return }
        #expect(p.decision == .allow)
        #expect(p.appliedSuggestionId == "s1")
    }

    @Test func askUserQuestionResponseEncodesAnswers() throws {
        let r = AgentResponse.askUserQuestion(AskUserQuestionResponse(answers: [
            AskUserQuestionResponse.QuestionAnswer(selectedOptionIndices: [0, 2], freeText: nil),
            AskUserQuestionResponse.QuestionAnswer(selectedOptionIndices: [], freeText: "custom"),
        ]))
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: JSONEncoder().encode(r))
        guard case let .askUserQuestion(p) = decoded else { Issue.record("wrong case"); return }
        #expect(p.answers.count == 2)
        #expect(p.answers[0].selectedOptionIndices == [0, 2])
        #expect(p.answers[0].freeText == nil)
        #expect(p.answers[1].freeText == "custom")
    }

    @Test func approvePlanCarriesEditedPlan() throws {
        let r = AgentResponse.approvePlan(ApprovePlanResponse(decision: .approve, editedPlan: "new plan"))
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: JSONEncoder().encode(r))
        guard case let .approvePlan(p) = decoded else { Issue.record("wrong case"); return }
        #expect(p.decision == .approve)
        #expect(p.editedPlan == "new plan")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyNetworkingTests.AgentResponse 2>&1 | tail -10
```

Expected: fails with "cannot find type 'AgentResponse' in scope".

- [ ] **Step 3: Implement `AgentResponse.swift`**

```swift
import Foundation

/// Closed-set responses iOS sends back when the user submits an
/// `AgentResponseRequest`. Plugin sidecars translate these into whatever
/// the host agent expects (keystrokes, HTTP, MCP, …).
public enum AgentResponse: Codable, Sendable, Equatable {
    case prompt(PromptResponse)
    case replyAfterStop(ReplyAfterStopResponse)
    case permission(PermissionResponse)
    case askUserQuestion(AskUserQuestionResponse)
    case approvePlan(ApprovePlanResponse)

    private enum CodingKeys: String, CodingKey { case type, body }

    private enum Kind: String, Codable {
        case prompt, replyAfterStop, permission, askUserQuestion, approvePlan
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .prompt:           self = .prompt(try c.decode(PromptResponse.self, forKey: .body))
        case .replyAfterStop:   self = .replyAfterStop(try c.decode(ReplyAfterStopResponse.self, forKey: .body))
        case .permission:       self = .permission(try c.decode(PermissionResponse.self, forKey: .body))
        case .askUserQuestion:  self = .askUserQuestion(try c.decode(AskUserQuestionResponse.self, forKey: .body))
        case .approvePlan:      self = .approvePlan(try c.decode(ApprovePlanResponse.self, forKey: .body))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .prompt(p):          try c.encode(Kind.prompt, forKey: .type);          try c.encode(p, forKey: .body)
        case let .replyAfterStop(p):  try c.encode(Kind.replyAfterStop, forKey: .type);  try c.encode(p, forKey: .body)
        case let .permission(p):      try c.encode(Kind.permission, forKey: .type);      try c.encode(p, forKey: .body)
        case let .askUserQuestion(p): try c.encode(Kind.askUserQuestion, forKey: .type); try c.encode(p, forKey: .body)
        case let .approvePlan(p):     try c.encode(Kind.approvePlan, forKey: .type);     try c.encode(p, forKey: .body)
        }
    }
}

public struct PromptResponse: Codable, Sendable, Equatable {
    public let text: String
    public init(text: String) { self.text = text }
}

public struct ReplyAfterStopResponse: Codable, Sendable, Equatable {
    /// Empty string means "send nothing, just interrupt".
    public let text: String
    public init(text: String) { self.text = text }
}

public struct PermissionResponse: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable { case allow, deny }
    public let decision: Decision
    public let appliedSuggestionId: String?

    public init(decision: Decision, appliedSuggestionId: String? = nil) {
        self.decision = decision
        self.appliedSuggestionId = appliedSuggestionId
    }
}

public struct AskUserQuestionResponse: Codable, Sendable, Equatable {
    public let answers: [QuestionAnswer]
    public init(answers: [QuestionAnswer]) { self.answers = answers }

    public struct QuestionAnswer: Codable, Sendable, Equatable {
        public let selectedOptionIndices: [Int]
        public let freeText: String?

        public init(selectedOptionIndices: [Int], freeText: String? = nil) {
            self.selectedOptionIndices = selectedOptionIndices
            self.freeText = freeText
        }
    }
}

public struct ApprovePlanResponse: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable { case approve, reject }
    public let decision: Decision
    public let editedPlan: String?

    public init(decision: Decision, editedPlan: String? = nil) {
        self.decision = decision
        self.editedPlan = editedPlan
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyNetworkingTests.AgentResponse 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentResponse.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/AgentResponseTests.swift
git commit -m "Add AgentResponse closed enum (iOS-to-Mac response shapes)"
```

---

## Task 6: Plugin wire messages (status / presentation / response envelopes)

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/PluginWireMessages.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/PluginWireMessagesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("PluginWireMessages")
struct PluginWireMessagesTests {
    @Test func sessionStatusRoundtrips() throws {
        let u = AgentSessionStatusUpdate(
            sessionId: "abc",
            pluginID: "claude-code",
            working: true,
            attention: false,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let d = try JSONDecoder().decode(AgentSessionStatusUpdate.self, from: JSONEncoder().encode(u))
        #expect(d.sessionId == "abc")
        #expect(d.pluginID == "claude-code")
        #expect(d.working == true)
        #expect(d.attention == false)
    }

    @Test func presentationBundleHoldsManyPlugins() throws {
        let bundle = PluginPresentationBundle(presentations: [
            PluginPresentation(id: "p1", version: "1.0", displayName: "P1",
                                shortName: "P1", color: "#ff0000", iconB64: "xxxx"),
            PluginPresentation(id: "p2", version: "0.1", displayName: "P2",
                                shortName: "P2", color: "#00ff00", iconB64: "yyyy"),
        ])
        let d = try JSONDecoder().decode(PluginPresentationBundle.self, from: JSONEncoder().encode(bundle))
        #expect(d.presentations.count == 2)
        #expect(d.presentations[0].id == "p1")
        #expect(d.presentations[1].displayName == "P2")
    }

    @Test func responseRequestMessageCarriesAllFields() throws {
        let m = AgentResponseRequestMessage(
            sessionId: "s",
            pluginID: "claude-code",
            requestId: "uuid-1",
            request: .prompt(PromptRequest(placeholder: "p"))
        )
        let d = try JSONDecoder().decode(AgentResponseRequestMessage.self, from: JSONEncoder().encode(m))
        #expect(d.requestId == "uuid-1")
        guard case .prompt = d.request else { Issue.record("wrong case"); return }
    }

    @Test func responseSubmissionMessageRoundtrips() throws {
        let m = AgentResponseSubmissionMessage(
            sessionId: "s",
            pluginID: "claude-code",
            requestId: "uuid-1",
            response: .prompt(PromptResponse(text: "hi"))
        )
        let d = try JSONDecoder().decode(AgentResponseSubmissionMessage.self, from: JSONEncoder().encode(m))
        #expect(d.requestId == "uuid-1")
        guard case let .prompt(p) = d.response else { Issue.record("wrong case"); return }
        #expect(p.text == "hi")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyNetworkingTests.PluginWireMessages 2>&1 | tail -10
```

Expected: fails — types not in scope.

- [ ] **Step 3: Implement `PluginWireMessages.swift`**

```swift
import Foundation

/// Mac → iOS message: a session's working/attention state changed.
public struct AgentSessionStatusUpdate: Codable, Sendable, Equatable {
    public let sessionId: String
    public let pluginID: PluginID
    public let working: Bool?
    public let attention: Bool
    public let timestamp: Date

    public init(
        sessionId: String,
        pluginID: PluginID,
        working: Bool?,
        attention: Bool,
        timestamp: Date
    ) {
        self.sessionId = sessionId
        self.pluginID = pluginID
        self.working = working
        self.attention = attention
        self.timestamp = timestamp
    }
}

/// Per-plugin presentation metadata iOS uses for session sidebar icons + labels.
public struct PluginPresentation: Codable, Sendable, Equatable {
    public let id: PluginID
    public let version: String
    public let displayName: String
    public let shortName: String
    public let color: String        // hex string, e.g. "#cb6f3a"
    public let iconB64: String      // base64-encoded PNG, usually <50 KB

    public init(
        id: PluginID,
        version: String,
        displayName: String,
        shortName: String,
        color: String,
        iconB64: String
    ) {
        self.id = id
        self.version = version
        self.displayName = displayName
        self.shortName = shortName
        self.color = color
        self.iconB64 = iconB64
    }
}

/// Sent at WebSocket connect time (and when a plugin's bundle version changes)
/// so iOS can cache per-plugin presentation by `(id, version)`.
public struct PluginPresentationBundle: Codable, Sendable, Equatable {
    public let presentations: [PluginPresentation]

    public init(presentations: [PluginPresentation]) {
        self.presentations = presentations
    }
}

/// Mac → iOS: the user must respond to something. iOS opens a form for the
/// matching `AgentResponseRequest` case.
public struct AgentResponseRequestMessage: Codable, Sendable, Equatable {
    public let sessionId: String
    public let pluginID: PluginID
    public let requestId: String
    public let request: AgentResponseRequest

    public init(
        sessionId: String,
        pluginID: PluginID,
        requestId: String,
        request: AgentResponseRequest
    ) {
        self.sessionId = sessionId
        self.pluginID = pluginID
        self.requestId = requestId
        self.request = request
    }
}

/// iOS → Mac: user submitted a response. Mac matches `requestId` to the
/// originating sidecar and calls `deliver_response` on it.
public struct AgentResponseSubmissionMessage: Codable, Sendable, Equatable {
    public let sessionId: String
    public let pluginID: PluginID
    public let requestId: String
    public let response: AgentResponse

    public init(
        sessionId: String,
        pluginID: PluginID,
        requestId: String,
        response: AgentResponse
    ) {
        self.sessionId = sessionId
        self.pluginID = pluginID
        self.requestId = requestId
        self.response = response
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyNetworkingTests.PluginWireMessages 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/PluginWireMessages.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/PluginWireMessagesTests.swift
git commit -m "Add plugin wire messages: status, presentation, response envelopes"
```

---

## Task 7: `GallagerPluginProtocol` — `PluginManifest`

**Files:**
- Delete: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/_Placeholder.swift`
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginManifest.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/PluginManifestTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import GallagerPluginProtocol

@Suite("PluginManifest")
struct PluginManifestTests {
    @Test func parsesABundledManifest() throws {
        let json = #"""
        {
            "schema_version": 1,
            "id": "echo",
            "display_name": "Echo",
            "short_name": "Echo",
            "version": "0.1.0",
            "publisher": "ClaudeSpy",
            "manifest_url": "bundle://echo/plugin.json",
            "bundle_sha256": null,
            "runtime": "sidecar",
            "sidecar": { "executable": "bin/sidecar", "args": [] },
            "capabilities": {
                "pushes_projects": true,
                "translate_event": true,
                "install": false,
                "detect_pane": false,
                "settings_schema": null
            },
            "process_names": [],
            "ui": {
                "icon": "assets/icon.png",
                "icon_ios": "assets/icon@2x.png"
            }
        }
        """#

        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(m.id == "echo")
        #expect(m.displayName == "Echo")
        #expect(m.version == "0.1.0")
        #expect(m.manifestUrl == "bundle://echo/plugin.json")
        #expect(m.bundleSha256 == nil)
        #expect(m.sidecar.executable == "bin/sidecar")
        #expect(m.capabilities.pushesProjects == true)
        #expect(m.capabilities.installCapable == false)
        #expect(m.processNames.isEmpty)
    }

    @Test func snakeCaseDecodingForAllFields() throws {
        // Spot-check that every snake_case key in the JSON above maps to a
        // camelCase Swift field — if a property is added/renamed, the decoder
        // must keep using snake_case on the wire.
        let json = #"{ "schema_version": 99, "id": "x", "display_name": "X", "short_name": "X", "version": "0.0.0", "publisher": "p", "manifest_url": "bundle://x", "bundle_sha256": null, "runtime": "sidecar", "sidecar": { "executable": "x", "args": [] }, "capabilities": { "pushes_projects": false, "translate_event": false, "install": false, "detect_pane": false, "settings_schema": null }, "process_names": [], "ui": { "icon": "x", "icon_ios": "x" } }"#
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        #expect(m.schemaVersion == 99)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyPluginRuntimeTests.PluginManifest 2>&1 | tail -10
```

Expected: fails — `PluginManifest` not in scope.

- [ ] **Step 3: Delete the placeholder file**

```bash
rm ClaudeSpyPackage/Sources/GallagerPluginProtocol/_Placeholder.swift
```

- [ ] **Step 4: Implement `PluginManifest.swift`**

```swift
import Foundation
import ClaudeSpyNetworking

/// On-disk plugin manifest (`plugin.json` at the root of every bundled or
/// installed plugin folder). Snake-case on the wire; camelCase in Swift.
public struct PluginManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: PluginID
    public let displayName: String
    public let shortName: String
    public let version: String
    public let publisher: String
    public let manifestUrl: String
    public let bundleSha256: String?
    public let runtime: Runtime
    public let sidecar: Sidecar
    public let capabilities: Capabilities
    public let processNames: [String]
    public let ui: UI

    public enum Runtime: String, Codable, Sendable, Equatable {
        case sidecar
    }

    public struct Sidecar: Codable, Sendable, Equatable {
        public let executable: String
        public let args: [String]

        public init(executable: String, args: [String] = []) {
            self.executable = executable
            self.args = args
        }
    }

    public struct Capabilities: Codable, Sendable, Equatable {
        public let pushesProjects: Bool
        public let translateEvent: Bool
        /// `install` is a reserved Codable property name on some platforms,
        /// so the Swift name uses `installCapable`. The wire field stays
        /// `install`.
        public let installCapable: Bool
        public let detectPane: Bool
        public let settingsSchema: String?

        enum CodingKeys: String, CodingKey {
            case pushesProjects = "pushes_projects"
            case translateEvent = "translate_event"
            case installCapable = "install"
            case detectPane = "detect_pane"
            case settingsSchema = "settings_schema"
        }

        public init(
            pushesProjects: Bool,
            translateEvent: Bool,
            installCapable: Bool,
            detectPane: Bool,
            settingsSchema: String? = nil
        ) {
            self.pushesProjects = pushesProjects
            self.translateEvent = translateEvent
            self.installCapable = installCapable
            self.detectPane = detectPane
            self.settingsSchema = settingsSchema
        }
    }

    public struct UI: Codable, Sendable, Equatable {
        public let icon: String
        public let iconIos: String?

        enum CodingKeys: String, CodingKey {
            case icon
            case iconIos = "icon_ios"
        }

        public init(icon: String, iconIos: String? = nil) {
            self.icon = icon
            self.iconIos = iconIos
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case displayName = "display_name"
        case shortName = "short_name"
        case version
        case publisher
        case manifestUrl = "manifest_url"
        case bundleSha256 = "bundle_sha256"
        case runtime
        case sidecar
        case capabilities
        case processNames = "process_names"
        case ui
    }

    public init(
        schemaVersion: Int = 1,
        id: PluginID,
        displayName: String,
        shortName: String,
        version: String,
        publisher: String,
        manifestUrl: String,
        bundleSha256: String? = nil,
        runtime: Runtime = .sidecar,
        sidecar: Sidecar,
        capabilities: Capabilities,
        processNames: [String] = [],
        ui: UI
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.shortName = shortName
        self.version = version
        self.publisher = publisher
        self.manifestUrl = manifestUrl
        self.bundleSha256 = bundleSha256
        self.runtime = runtime
        self.sidecar = sidecar
        self.capabilities = capabilities
        self.processNames = processNames
        self.ui = ui
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyPluginRuntimeTests.PluginManifest 2>&1 | tail -10
```

Expected: 2 tests pass.

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginManifest.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/PluginManifestTests.swift
git rm ClaudeSpyPackage/Sources/GallagerPluginProtocol/_Placeholder.swift
git commit -m "Add PluginManifest Codable in GallagerPluginProtocol"
```

---

## Task 8: `GallagerPluginProtocol` — `PluginEvent` and `AppAction`

**Files:**
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/AppAction.swift`
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginEvent.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/PluginEventTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import GallagerPluginProtocol
import ClaudeSpyNetworking

@Suite("PluginEvent")
struct PluginEventTests {
    @Test func minimalEnvelopeRoundtrips() throws {
        let evt = PluginEvent(
            pluginId: "echo",
            sessionId: "s1",
            working: true,
            attention: false
        )
        let d = try JSONDecoder().decode(PluginEvent.self, from: JSONEncoder().encode(evt))
        #expect(d.pluginId == "echo")
        #expect(d.sessionId == "s1")
        #expect(d.working == true)
        #expect(d.attention == false)
        #expect(d.notification == nil)
        #expect(d.responseRequest == nil)
        #expect(d.appActions.isEmpty)
    }

    @Test func envelopeCarriesAllFields() throws {
        let evt = PluginEvent(
            pluginId: "claude-code",
            sessionId: "s1",
            working: false,
            attention: true,
            notification: NotificationSpec(title: "T", body: "B"),
            responseRequest: .permission(PermissionRequest(
                toolName: "Bash",
                description: "do thing",
                suggestions: [],
                isAutoApprovable: false
            )),
            appActions: [.openFileSuggestion(
                sessionId: "s1",
                path: "/tmp/x.md",
                displayName: "x.md",
                isPlan: false
            )]
        )
        let d = try JSONDecoder().decode(PluginEvent.self, from: JSONEncoder().encode(evt))
        #expect(d.notification?.title == "T")
        #expect(d.appActions.count == 1)
        guard case let .openFileSuggestion(_, path, _, _) = d.appActions[0] else {
            Issue.record("wrong case"); return
        }
        #expect(path == "/tmp/x.md")
    }

    @Test func appActionEnumEncoding() throws {
        let actions: [AppAction] = [
            .openFileSuggestion(sessionId: "s", path: "/p", displayName: "p", isPlan: true),
            .dismissFileSuggestions(sessionId: "s"),
            .closePaneIfPreferenceAllows(sessionId: "s"),
        ]
        for action in actions {
            let d = try JSONDecoder().decode(AppAction.self, from: JSONEncoder().encode(action))
            #expect(d == action)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyPluginRuntimeTests.PluginEvent 2>&1 | tail -10
```

Expected: fails — types not in scope.

- [ ] **Step 3: Implement `AppAction.swift`**

```swift
import Foundation

/// Closed set of Mac-side feature triggers a sidecar can request via a
/// `PluginEvent`. New cases are added in coordinated app+plugin changes.
public enum AppAction: Codable, Sendable, Equatable {
    case openFileSuggestion(sessionId: String, path: String, displayName: String, isPlan: Bool)
    case dismissFileSuggestions(sessionId: String)
    case closePaneIfPreferenceAllows(sessionId: String)

    private enum CodingKeys: String, CodingKey { case type, body }
    private enum Kind: String, Codable {
        case openFileSuggestion, dismissFileSuggestions, closePaneIfPreferenceAllows
    }

    private struct OpenFileBody: Codable {
        let sessionId: String, path: String, displayName: String, isPlan: Bool
    }
    private struct SessionOnlyBody: Codable {
        let sessionId: String
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .openFileSuggestion:
            let b = try c.decode(OpenFileBody.self, forKey: .body)
            self = .openFileSuggestion(sessionId: b.sessionId, path: b.path,
                                        displayName: b.displayName, isPlan: b.isPlan)
        case .dismissFileSuggestions:
            let b = try c.decode(SessionOnlyBody.self, forKey: .body)
            self = .dismissFileSuggestions(sessionId: b.sessionId)
        case .closePaneIfPreferenceAllows:
            let b = try c.decode(SessionOnlyBody.self, forKey: .body)
            self = .closePaneIfPreferenceAllows(sessionId: b.sessionId)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .openFileSuggestion(sid, path, name, plan):
            try c.encode(Kind.openFileSuggestion, forKey: .type)
            try c.encode(OpenFileBody(sessionId: sid, path: path, displayName: name, isPlan: plan), forKey: .body)
        case let .dismissFileSuggestions(sid):
            try c.encode(Kind.dismissFileSuggestions, forKey: .type)
            try c.encode(SessionOnlyBody(sessionId: sid), forKey: .body)
        case let .closePaneIfPreferenceAllows(sid):
            try c.encode(Kind.closePaneIfPreferenceAllows, forKey: .type)
            try c.encode(SessionOnlyBody(sessionId: sid), forKey: .body)
        }
    }
}
```

- [ ] **Step 4: Implement `PluginEvent.swift`**

```swift
import Foundation
import ClaudeSpyNetworking

/// Envelope a sidecar emits per agent event it observes. Mac-internal —
/// never crosses the relay; its fields are unpacked into wire types
/// (`AgentSessionStatusUpdate`, `AgentResponseRequestMessage`, etc.) on the
/// app side.
public struct PluginEvent: Codable, Sendable, Equatable {
    public let pluginId: PluginID
    public let sessionId: String
    public let working: Bool?
    public let attention: Bool
    public let notification: NotificationSpec?
    public let responseRequest: AgentResponseRequest?
    public let appActions: [AppAction]

    public init(
        pluginId: PluginID,
        sessionId: String,
        working: Bool? = nil,
        attention: Bool = false,
        notification: NotificationSpec? = nil,
        responseRequest: AgentResponseRequest? = nil,
        appActions: [AppAction] = []
    ) {
        self.pluginId = pluginId
        self.sessionId = sessionId
        self.working = working
        self.attention = attention
        self.notification = notification
        self.responseRequest = responseRequest
        self.appActions = appActions
    }

    enum CodingKeys: String, CodingKey {
        case pluginId = "plugin_id"
        case sessionId = "session_id"
        case working
        case attention
        case notification
        case responseRequest = "response_request"
        case appActions = "app_actions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pluginId = try c.decode(PluginID.self, forKey: .pluginId)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        working = try c.decodeIfPresent(Bool.self, forKey: .working)
        attention = try c.decodeIfPresent(Bool.self, forKey: .attention) ?? false
        notification = try c.decodeIfPresent(NotificationSpec.self, forKey: .notification)
        responseRequest = try c.decodeIfPresent(AgentResponseRequest.self, forKey: .responseRequest)
        appActions = try c.decodeIfPresent([AppAction].self, forKey: .appActions) ?? []
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyPluginRuntimeTests.PluginEvent 2>&1 | tail -10
```

Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/GallagerPluginProtocol/AppAction.swift \
        ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginEvent.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/PluginEventTests.swift
git commit -m "Add PluginEvent envelope and AppAction enum"
```

---

## Task 9: `GallagerPluginProtocol` — JSON-RPC envelope + method names

**Files:**
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/JSONRPCFrame.swift`
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/SidecarMethods.swift`
- Create: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/AppMethods.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/JSONRPCFrameTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import GallagerPluginProtocol

@Suite("JSONRPCFrame")
struct JSONRPCFrameTests {
    @Test func encodesRequestAsLSPFrame() throws {
        let req = JSONRPCFrame.request(id: "1", method: "initialize", params: "{\"plugin_root\":\"/tmp\"}")
        let bytes = try req.encodeFrame()
        let s = String(decoding: bytes, as: UTF8.self)
        #expect(s.hasPrefix("Content-Length: "))
        #expect(s.contains("\r\n\r\n"))
        // Body must be valid JSON
        let bodyStart = s.range(of: "\r\n\r\n")!.upperBound
        let body = String(s[bodyStart...])
        let obj = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        #expect(obj?["jsonrpc"] as? String == "2.0")
        #expect(obj?["method"] as? String == "initialize")
        #expect(obj?["id"] as? String == "1")
    }

    @Test func parsesResponse() throws {
        let raw = #"{"jsonrpc":"2.0","id":"1","result":{"capabilities":{"pushes_projects":true}}}"#
        let frame = try JSONRPCFrame.parseBody(Data(raw.utf8))
        guard case let .response(id, result, error) = frame else { Issue.record("wrong case"); return }
        #expect(id == "1")
        #expect(error == nil)
        #expect(result != nil)
    }

    @Test func parsesErrorResponse() throws {
        let raw = #"{"jsonrpc":"2.0","id":"1","error":{"code":-32601,"message":"Method not found"}}"#
        let frame = try JSONRPCFrame.parseBody(Data(raw.utf8))
        guard case let .response(_, _, error) = frame else { Issue.record("wrong case"); return }
        #expect(error?.code == -32601)
        #expect(error?.message == "Method not found")
    }

    @Test func methodNameConstantsExist() {
        #expect(SidecarMethod.initialize.rawValue == "initialize")
        #expect(SidecarMethod.translateEvent.rawValue == "translate_event")
        #expect(SidecarMethod.deliverResponse.rawValue == "deliver_response")
        #expect(AppMethod.setProjects.rawValue == "set_projects")
        #expect(AppMethod.sendText.rawValue == "send_text")
        #expect(AppMethod.sendKeys.rawValue == "send_keys")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyPluginRuntimeTests.JSONRPCFrame 2>&1 | tail -10
```

Expected: fails — types not in scope.

- [ ] **Step 3: Implement `JSONRPCFrame.swift`**

```swift
import Foundation

/// Bidirectional JSON-RPC 2.0 frame used between the app and the sidecar.
/// Wire format: LSP-style `Content-Length:` header + CRLFCRLF + JSON body.
public enum JSONRPCFrame: Sendable, Equatable {
    /// A method call expecting a response (id ≠ nil).
    case request(id: String, method: String, params: String?)
    /// A response to a previous request, identified by `id`.
    case response(id: String, result: String?, error: JSONRPCError?)
    /// A method call that does not expect a response (id == nil).
    case notification(method: String, params: String?)

    public struct JSONRPCError: Codable, Sendable, Equatable {
        public let code: Int
        public let message: String
    }

    /// Encodes the frame as `Content-Length: N\r\n\r\n<json>`.
    public func encodeFrame() throws -> Data {
        let body = try encodeBody()
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var out = Data()
        out.append(Data(header.utf8))
        out.append(body)
        return out
    }

    /// Encodes only the JSON body (no header). Useful for tests.
    public func encodeBody() throws -> Data {
        var obj: [String: Any] = ["jsonrpc": "2.0"]
        switch self {
        case let .request(id, method, params):
            obj["id"] = id
            obj["method"] = method
            if let params {
                obj["params"] = try JSONSerialization.jsonObject(with: Data(params.utf8))
            }
        case let .response(id, result, error):
            obj["id"] = id
            if let result {
                obj["result"] = try JSONSerialization.jsonObject(with: Data(result.utf8))
            }
            if let error {
                obj["error"] = [
                    "code": error.code,
                    "message": error.message,
                ]
            }
        case let .notification(method, params):
            obj["method"] = method
            if let params {
                obj["params"] = try JSONSerialization.jsonObject(with: Data(params.utf8))
            }
        }
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    /// Parses a frame body (no LSP header — just the JSON).
    public static func parseBody(_ data: Data) throws -> JSONRPCFrame {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FrameParseError.notAnObject
        }
        // Response: has `id` and `result` or `error`
        if let id = obj["id"] as? String, obj["method"] == nil {
            let resultData: String? = try (obj["result"]).map { v in
                String(decoding: try JSONSerialization.data(withJSONObject: v), as: UTF8.self)
            }
            let error: JSONRPCError? = (obj["error"] as? [String: Any]).flatMap { dict in
                guard let code = dict["code"] as? Int,
                      let message = dict["message"] as? String else { return nil }
                return JSONRPCError(code: code, message: message)
            }
            return .response(id: id, result: resultData, error: error)
        }
        // Request or Notification
        guard let method = obj["method"] as? String else {
            throw FrameParseError.missingMethod
        }
        let params: String? = try (obj["params"]).map { v in
            String(decoding: try JSONSerialization.data(withJSONObject: v), as: UTF8.self)
        }
        if let id = obj["id"] as? String {
            return .request(id: id, method: method, params: params)
        } else {
            return .notification(method: method, params: params)
        }
    }

    public enum FrameParseError: Error, Equatable {
        case notAnObject
        case missingMethod
    }
}
```

- [ ] **Step 4: Implement `SidecarMethods.swift`**

```swift
/// All RPC method names the App invokes on the Sidecar.
public enum SidecarMethod: String, Sendable {
    case initialize
    case shutdown
    case refreshProjects = "refresh_projects"
    case detectPane = "detect_pane"
    case install
    case uninstall
    case isInstalled = "is_installed"
    case translateEvent = "translate_event"
    case deliverResponse = "deliver_response"
    case getSettingsSchema = "get_settings_schema"
    case applySettings = "apply_settings"
    case commandForLaunch = "command_for_launch"
    case health
}
```

- [ ] **Step 5: Implement `AppMethods.swift`**

```swift
/// All RPC method names the Sidecar invokes on the App.
public enum AppMethod: String, Sendable {
    case setProjects = "set_projects"
    case emitEvent = "emit_event"
    case sendText = "send_text"
    case sendKeys = "send_keys"
    case dismissResponseRequest = "dismiss_response_request"
    case requestNotification = "request_notification"
    case updateSessionStatus = "update_session_status"
    case log
    case promptUser = "prompt_user"
}
```

- [ ] **Step 6: Run test to verify it passes**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyPluginRuntimeTests.JSONRPCFrame 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 7: Commit**

```bash
git add ClaudeSpyPackage/Sources/GallagerPluginProtocol/JSONRPCFrame.swift \
        ClaudeSpyPackage/Sources/GallagerPluginProtocol/SidecarMethods.swift \
        ClaudeSpyPackage/Sources/GallagerPluginProtocol/AppMethods.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/JSONRPCFrameTests.swift
git commit -m "Add JSONRPCFrame and method-name constants to GallagerPluginProtocol"
```

---

## Task 10: `ClaudeSpyPluginRuntime` — `PluginPaths` utility

**Files:**
- Delete: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/_Placeholder.swift`
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/PluginPaths.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/PluginPathsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import ClaudeSpyPluginRuntime

@Suite("PluginPaths")
struct PluginPathsTests {
    @Test func defaultsToHomeGallagerStateRoot() {
        let paths = PluginPaths(stateRoot: nil, bundledRoot: URL(fileURLWithPath: "/Apps/Gallager.app/Contents/Resources/plugins"))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(paths.userPluginsDir.path == "\(home)/.gallager/plugins")
        #expect(paths.statePluginsDir.path == "\(home)/.gallager/state/plugins")
        #expect(paths.registryFile.path == "\(home)/.gallager/registry.json")
    }

    @Test func honoursExplicitStateRoot() {
        let root = URL(fileURLWithPath: "/tmp/test-gallager-\(UUID().uuidString)")
        let paths = PluginPaths(stateRoot: root, bundledRoot: URL(fileURLWithPath: "/B"))
        #expect(paths.userPluginsDir.path == "\(root.path)/plugins")
        #expect(paths.statePluginsDir.path == "\(root.path)/state/plugins")
        #expect(paths.registryFile.path == "\(root.path)/registry.json")
    }

    @Test func perPluginPathsAreDerived() {
        let root = URL(fileURLWithPath: "/tmp/test")
        let paths = PluginPaths(stateRoot: root, bundledRoot: URL(fileURLWithPath: "/B"))
        #expect(paths.userPluginDir(for: "echo").path == "/tmp/test/plugins/echo")
        #expect(paths.statePluginDir(for: "echo").path == "/tmp/test/state/plugins/echo")
        #expect(paths.ingressSocket(for: "echo").path == "/tmp/test/state/plugins/echo/ingress.sock")
        #expect(paths.logsDir(for: "echo").path == "/tmp/test/state/plugins/echo/logs")
        #expect(paths.sidecarLog(for: "echo").path == "/tmp/test/state/plugins/echo/logs/sidecar.log")
        #expect(paths.settingsFile(for: "echo").path == "/tmp/test/state/plugins/echo/settings.json")
    }

    @Test func resolveAcceptsBundledOrUserPlugin() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundled = tmp.appendingPathComponent("bundled")
        let user = tmp.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: bundled.appendingPathComponent("foo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user.appendingPathComponent("bar"), withIntermediateDirectories: true)

        let paths = PluginPaths(stateRoot: tmp, bundledRoot: bundled, userPluginsDirOverride: user)
        #expect(paths.resolveInstalledPluginRoot(for: "foo")?.lastPathComponent == "foo")
        #expect(paths.resolveInstalledPluginRoot(for: "bar")?.lastPathComponent == "bar")
        #expect(paths.resolveInstalledPluginRoot(for: "missing") == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyPluginRuntimeTests.PluginPaths 2>&1 | tail -10
```

Expected: fails — `PluginPaths` not found.

- [ ] **Step 3: Delete the placeholder and implement `PluginPaths.swift`**

```bash
rm ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/_Placeholder.swift
```

```swift
import Foundation
import ClaudeSpyNetworking

/// Resolves every filesystem path the plugin runtime uses. A single instance
/// is constructed at app launch with the runtime's chosen `stateRoot` (default
/// `~/.gallager`; overridden in E2E tests via `--gallager-state-root`).
public struct PluginPaths: Sendable {
    /// Base for the registry, user plugins, and per-plugin state.
    /// `~/.gallager` in production.
    public let stateRoot: URL

    /// Read-only plugins shipped inside the .app
    /// (`Gallager.app/Contents/Resources/plugins`).
    public let bundledRoot: URL

    /// Where user-installed plugins live. Defaults to `<stateRoot>/plugins`;
    /// only the test fixture overrides this.
    public let userPluginsDir: URL

    public init(
        stateRoot: URL?,
        bundledRoot: URL,
        userPluginsDirOverride: URL? = nil
    ) {
        let resolved: URL = stateRoot ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".gallager", isDirectory: true)
        self.stateRoot = resolved
        self.bundledRoot = bundledRoot
        self.userPluginsDir = userPluginsDirOverride ?? resolved
            .appendingPathComponent("plugins", isDirectory: true)
    }

    public var registryFile: URL {
        stateRoot.appendingPathComponent("registry.json")
    }

    public var statePluginsDir: URL {
        stateRoot.appendingPathComponent("state/plugins", isDirectory: true)
    }

    public func userPluginDir(for id: PluginID) -> URL {
        userPluginsDir.appendingPathComponent(id, isDirectory: true)
    }

    public func bundledPluginDir(for id: PluginID) -> URL {
        bundledRoot.appendingPathComponent(id, isDirectory: true)
    }

    public func statePluginDir(for id: PluginID) -> URL {
        statePluginsDir.appendingPathComponent(id, isDirectory: true)
    }

    public func ingressSocket(for id: PluginID) -> URL {
        statePluginDir(for: id).appendingPathComponent("ingress.sock")
    }

    public func logsDir(for id: PluginID) -> URL {
        statePluginDir(for: id).appendingPathComponent("logs", isDirectory: true)
    }

    public func sidecarLog(for id: PluginID) -> URL {
        logsDir(for: id).appendingPathComponent("sidecar.log")
    }

    public func settingsFile(for id: PluginID) -> URL {
        statePluginDir(for: id).appendingPathComponent("settings.json")
    }

    /// Returns the installed-plugin root for `id`. Bundled (read-only) wins
    /// over user-installed if both exist with the same id — that should never
    /// happen in practice but the deterministic resolution matters for
    /// migrations.
    public func resolveInstalledPluginRoot(for id: PluginID) -> URL? {
        let fm = FileManager.default
        let bundled = bundledPluginDir(for: id)
        if fm.fileExists(atPath: bundled.path) { return bundled }
        let user = userPluginDir(for: id)
        if fm.fileExists(atPath: user.path) { return user }
        return nil
    }

    /// Ensure all state dirs exist for `id`. Idempotent.
    public func prepareStateDir(for id: PluginID) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: statePluginDir(for: id), withIntermediateDirectories: true)
        try fm.createDirectory(at: logsDir(for: id), withIntermediateDirectories: true)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyPluginRuntimeTests.PluginPaths 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/PluginPaths.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/PluginPathsTests.swift
git rm ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/_Placeholder.swift
git commit -m "Add PluginPaths utility in ClaudeSpyPluginRuntime"
```

---

## Task 11: `PluginRegistry` with atomic load/save

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/PluginRegistry.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/PluginRegistryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import ClaudeSpyPluginRuntime

@Suite("PluginRegistry")
struct PluginRegistryTests {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func emptyOnFirstLoad() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PluginPaths(stateRoot: root, bundledRoot: root)

        let registry = try PluginRegistry.loadOrCreate(paths: paths)
        #expect(registry.plugins.isEmpty)
    }

    @Test func roundTripsThroughDisk() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PluginPaths(stateRoot: root, bundledRoot: root)

        var registry = try PluginRegistry.loadOrCreate(paths: paths)
        registry.upsert(PluginRegistryEntry(
            id: "echo",
            manifestUrl: "bundle://echo/plugin.json",
            installedVersion: "0.1.0",
            bundleSha256: nil,
            enabled: true,
            source: .bundled,
            trustedAt: nil,
            lastUpdateCheck: nil
        ))
        try registry.save(paths: paths)

        let reloaded = try PluginRegistry.loadOrCreate(paths: paths)
        #expect(reloaded.plugins.count == 1)
        #expect(reloaded.plugins.first?.id == "echo")
        #expect(reloaded.plugins.first?.enabled == true)
    }

    @Test func upsertReplacesExisting() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PluginPaths(stateRoot: root, bundledRoot: root)

        var registry = try PluginRegistry.loadOrCreate(paths: paths)
        registry.upsert(PluginRegistryEntry(
            id: "echo", manifestUrl: "bundle://echo", installedVersion: "0.1.0",
            bundleSha256: nil, enabled: true, source: .bundled,
            trustedAt: nil, lastUpdateCheck: nil
        ))
        registry.upsert(PluginRegistryEntry(
            id: "echo", manifestUrl: "bundle://echo", installedVersion: "0.2.0",
            bundleSha256: nil, enabled: false, source: .bundled,
            trustedAt: nil, lastUpdateCheck: nil
        ))
        #expect(registry.plugins.count == 1)
        #expect(registry.plugins.first?.installedVersion == "0.2.0")
        #expect(registry.plugins.first?.enabled == false)
    }

    @Test func removeDeletesEntry() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PluginPaths(stateRoot: root, bundledRoot: root)
        var registry = try PluginRegistry.loadOrCreate(paths: paths)
        registry.upsert(PluginRegistryEntry(
            id: "echo", manifestUrl: "bundle://echo", installedVersion: "0.1.0",
            bundleSha256: nil, enabled: true, source: .bundled,
            trustedAt: nil, lastUpdateCheck: nil
        ))
        registry.remove(id: "echo")
        #expect(registry.plugins.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyPluginRuntimeTests.PluginRegistry 2>&1 | tail -10
```

Expected: fails — `PluginRegistry` not in scope.

- [ ] **Step 3: Implement `PluginRegistry.swift`**

```swift
import Foundation
import ClaudeSpyNetworking

public struct PluginRegistryEntry: Codable, Sendable, Equatable {
    public let id: PluginID
    public let manifestUrl: String
    public let installedVersion: String
    public let bundleSha256: String?
    public var enabled: Bool
    public let source: Source
    public let trustedAt: Date?
    public var lastUpdateCheck: Date?

    public enum Source: String, Codable, Sendable { case bundled, url }

    public init(
        id: PluginID,
        manifestUrl: String,
        installedVersion: String,
        bundleSha256: String?,
        enabled: Bool,
        source: Source,
        trustedAt: Date?,
        lastUpdateCheck: Date?
    ) {
        self.id = id
        self.manifestUrl = manifestUrl
        self.installedVersion = installedVersion
        self.bundleSha256 = bundleSha256
        self.enabled = enabled
        self.source = source
        self.trustedAt = trustedAt
        self.lastUpdateCheck = lastUpdateCheck
    }

    enum CodingKeys: String, CodingKey {
        case id
        case manifestUrl = "manifest_url"
        case installedVersion = "installed_version"
        case bundleSha256 = "bundle_sha256"
        case enabled
        case source
        case trustedAt = "trusted_at"
        case lastUpdateCheck = "last_update_check"
    }
}

/// In-memory snapshot of `~/.gallager/registry.json`. Mutations are made on a
/// value type; `save(paths:)` writes the result atomically via temp + rename.
public struct PluginRegistry: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public private(set) var plugins: [PluginRegistryEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case plugins
    }

    public init(plugins: [PluginRegistryEntry] = []) {
        self.schemaVersion = 1
        self.plugins = plugins
    }

    public mutating func upsert(_ entry: PluginRegistryEntry) {
        if let idx = plugins.firstIndex(where: { $0.id == entry.id }) {
            plugins[idx] = entry
        } else {
            plugins.append(entry)
        }
    }

    public mutating func remove(id: PluginID) {
        plugins.removeAll { $0.id == id }
    }

    public func entry(for id: PluginID) -> PluginRegistryEntry? {
        plugins.first(where: { $0.id == id })
    }

    public static func loadOrCreate(paths: PluginPaths) throws -> PluginRegistry {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.stateRoot, withIntermediateDirectories: true)
        let file = paths.registryFile
        if !fm.fileExists(atPath: file.path) {
            return PluginRegistry()
        }
        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        return try decoder.decode(PluginRegistry.self, from: data)
    }

    public func save(paths: PluginPaths) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let file = paths.registryFile
        let tmp = file.deletingLastPathComponent()
            .appendingPathComponent("registry.\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        // Atomic replace
        _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyPluginRuntimeTests.PluginRegistry 2>&1 | tail -10
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/PluginRegistry.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/PluginRegistryTests.swift
git commit -m "Add PluginRegistry with atomic disk roundtrip"
```

---

## Task 12: `SidecarConnection` — JSON-RPC framing over Pipe stdio

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/SidecarConnection.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/SidecarConnectionTests.swift`

> Note: `SidecarConnection` is the trickiest piece in this plan. It reads LSP-style frames off a `FileHandle` (the sidecar's stdout) and dispatches them; it writes frames to another `FileHandle` (the sidecar's stdin). Tests use a pair of in-memory `Pipe` objects.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import ClaudeSpyPluginRuntime
import GallagerPluginProtocol

@Suite("SidecarConnection")
struct SidecarConnectionTests {
    @Test func roundTripsRequestAndResponse() async throws {
        // Two pipes simulate the sidecar's stdin (we write) / stdout (we read).
        let stdoutPipe = Pipe()        // sidecar writes here, app reads
        let stdinPipe = Pipe()         // app writes here, sidecar reads

        let conn = SidecarConnection(
            reader: stdoutPipe.fileHandleForReading,
            writer: stdinPipe.fileHandleForWriting
        )
        await conn.start()

        // Simulate the sidecar: read what the app sends, then reply.
        let sidecarTask = Task { @Sendable in
            // Read one frame from stdin (LSP-style)
            let req = try await Self.readOneFrame(from: stdinPipe.fileHandleForReading)
            // Send response with matching id back via stdout
            guard case let .request(id, _, _) = req else {
                throw TestError("unexpected frame: \(req)")
            }
            let resp = JSONRPCFrame.response(id: id, result: #"{"ok":true}"#, error: nil)
            let bytes = try resp.encodeFrame()
            try stdoutPipe.fileHandleForWriting.write(contentsOf: bytes)
        }

        let result = try await conn.call(
            method: "ping",
            paramsJSON: nil,
            timeout: .seconds(5)
        )
        #expect(result == #"{"ok":true}"#)

        try await sidecarTask.value
        await conn.shutdown()
    }

    @Test func surfacesErrorResponse() async throws {
        let stdoutPipe = Pipe(); let stdinPipe = Pipe()
        let conn = SidecarConnection(
            reader: stdoutPipe.fileHandleForReading,
            writer: stdinPipe.fileHandleForWriting
        )
        await conn.start()

        let sidecarTask = Task { @Sendable in
            let req = try await Self.readOneFrame(from: stdinPipe.fileHandleForReading)
            guard case let .request(id, _, _) = req else { throw TestError("bad") }
            let resp = JSONRPCFrame.response(
                id: id, result: nil,
                error: JSONRPCFrame.JSONRPCError(code: -32601, message: "Method not found")
            )
            try stdoutPipe.fileHandleForWriting.write(contentsOf: try resp.encodeFrame())
        }

        await #expect(throws: SidecarConnection.CallError.self) {
            _ = try await conn.call(method: "missing", paramsJSON: nil, timeout: .seconds(5))
        }
        try await sidecarTask.value
        await conn.shutdown()
    }

    @Test func deliversNotificationsToHandler() async throws {
        let stdoutPipe = Pipe(); let stdinPipe = Pipe()
        let conn = SidecarConnection(
            reader: stdoutPipe.fileHandleForReading,
            writer: stdinPipe.fileHandleForWriting
        )
        await conn.start()

        // Capture the inbound notification
        let receivedBox = ActorBox<JSONRPCFrame?>(nil)
        await conn.setNotificationHandler { frame in
            await receivedBox.set(frame)
        }

        // Push a notification from the "sidecar" side
        let notif = JSONRPCFrame.notification(method: "log", params: #"{"level":"info","message":"hi"}"#)
        try stdoutPipe.fileHandleForWriting.write(contentsOf: try notif.encodeFrame())

        // Wait for handler
        try await Task.sleep(for: .milliseconds(200))
        let value = await receivedBox.get()
        #expect(value != nil)
        if case let .notification(method, _) = value {
            #expect(method == "log")
        } else {
            Issue.record("expected notification")
        }
        await conn.shutdown()
    }

    // MARK: - Helpers

    /// Reads one LSP-style frame off the given handle and parses it.
    static func readOneFrame(from handle: FileHandle) async throws -> JSONRPCFrame {
        var buf = Data()
        while true {
            let chunk = handle.availableData
            buf.append(chunk)
            // Try to extract a frame
            if let frame = try Self.extractFrame(&buf) { return frame }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func extractFrame(_ buf: inout Data) throws -> JSONRPCFrame? {
        // Look for header terminator \r\n\r\n
        guard let range = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buf.subdata(in: 0..<range.lowerBound)
        let header = String(decoding: headerData, as: UTF8.self)
        guard let line = header.split(separator: "\r\n").first(where: { $0.hasPrefix("Content-Length:") }) else {
            return nil
        }
        let len = Int(line.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        let bodyStart = range.upperBound
        guard buf.count >= bodyStart + len else { return nil }
        let body = buf.subdata(in: bodyStart..<(bodyStart + len))
        buf.removeSubrange(0..<(bodyStart + len))
        return try JSONRPCFrame.parseBody(body)
    }

    struct TestError: Error { let msg: String; init(_ m: String) { msg = m } }
}

/// Small actor wrapper used to thread captured values out of `@Sendable` closures.
private actor ActorBox<T: Sendable> {
    var value: T
    init(_ initial: T) { self.value = initial }
    func set(_ v: T) { value = v }
    func get() -> T { value }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyPluginRuntimeTests.SidecarConnection 2>&1 | tail -20
```

Expected: fails — `SidecarConnection` not in scope.

- [ ] **Step 3: Implement `SidecarConnection.swift`**

```swift
import Foundation
import Logging
import GallagerPluginProtocol

/// Reads/writes LSP-style JSON-RPC frames over a pair of `FileHandle`s
/// (typically the sidecar's stdin + stdout). Pairs in-flight requests by id
/// and surfaces responses via async `call(...)`. Inbound notifications
/// (sidecar → app) are dispatched to a single `notificationHandler`.
///
/// Owned by a `SidecarSupervisor`; one instance per running sidecar.
public actor SidecarConnection {
    public enum CallError: Error, Equatable {
        case timeout
        case rpcError(code: Int, message: String)
        case shuttingDown
        case decodeFailure(String)
    }

    private let logger = Logger(label: "com.claudespy.plugin.connection")
    private let reader: FileHandle
    private let writer: FileHandle

    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var notificationHandler: (@Sendable (JSONRPCFrame) async -> Void)?
    private var readerTask: Task<Void, Never>?
    private var isShutdown = false

    public init(reader: FileHandle, writer: FileHandle) {
        self.reader = reader
        self.writer = writer
    }

    /// Start the background reader. Call once after construction.
    public func start() {
        precondition(readerTask == nil, "SidecarConnection.start() called twice")
        readerTask = Task { [weak self] in
            await self?.runReader()
        }
    }

    public func setNotificationHandler(_ handler: @Sendable @escaping (JSONRPCFrame) async -> Void) {
        notificationHandler = handler
    }

    /// Send a request and await its response. `timeout == nil` waits indefinitely.
    public func call(
        method: String,
        paramsJSON: String?,
        timeout: Duration?
    ) async throws -> String {
        if isShutdown { throw CallError.shuttingDown }
        let id = UUID().uuidString
        let frame = JSONRPCFrame.request(id: id, method: method, params: paramsJSON)
        let bytes = try frame.encodeFrame()
        try writer.write(contentsOf: bytes)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            pending[id] = cont
            if let timeout {
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.timeoutPending(id: id)
                }
            }
        }
    }

    /// Send a notification (no response expected).
    public func notify(method: String, paramsJSON: String?) async throws {
        if isShutdown { throw CallError.shuttingDown }
        let frame = JSONRPCFrame.notification(method: method, params: paramsJSON)
        let bytes = try frame.encodeFrame()
        try writer.write(contentsOf: bytes)
    }

    /// Send a response to an inbound app→sidecar request. Used by `PluginRouter`.
    public func respond(to id: String, result: String?, error: JSONRPCFrame.JSONRPCError?) async throws {
        if isShutdown { return }
        let frame = JSONRPCFrame.response(id: id, result: result, error: error)
        let bytes = try frame.encodeFrame()
        try writer.write(contentsOf: bytes)
    }

    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        readerTask?.cancel()
        // Fail any outstanding callers
        for (_, cont) in pending {
            cont.resume(throwing: CallError.shuttingDown)
        }
        pending.removeAll()
        try? reader.close()
        try? writer.close()
    }

    // MARK: - Reader loop

    private func runReader() async {
        var buf = Data()
        while !Task.isCancelled {
            do {
                let chunk = try reader.read(upToCount: 4096) ?? Data()
                if chunk.isEmpty {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                }
                buf.append(chunk)
                while let frame = try extractFrame(&buf) {
                    await dispatch(frame)
                }
            } catch {
                logger.warning("reader loop error: \(error)")
                break
            }
        }
    }

    private func extractFrame(_ buf: inout Data) throws -> JSONRPCFrame? {
        guard let r = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: buf.subdata(in: 0..<r.lowerBound), as: UTF8.self)
        guard let line = header.split(separator: "\r\n").first(where: { $0.hasPrefix("Content-Length:") }) else {
            return nil
        }
        let len = Int(line.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        let bodyStart = r.upperBound
        guard buf.count >= bodyStart + len else { return nil }
        let body = buf.subdata(in: bodyStart..<(bodyStart + len))
        buf.removeSubrange(0..<(bodyStart + len))
        return try JSONRPCFrame.parseBody(body)
    }

    private func dispatch(_ frame: JSONRPCFrame) async {
        switch frame {
        case let .response(id, result, error):
            if let cont = pending.removeValue(forKey: id) {
                if let error {
                    cont.resume(throwing: CallError.rpcError(code: error.code, message: error.message))
                } else {
                    cont.resume(returning: result ?? "null")
                }
            } else {
                logger.warning("response with unknown id: \(id)")
            }
        case .request, .notification:
            if let handler = notificationHandler {
                await handler(frame)
            }
        }
    }

    private func timeoutPending(id: String) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(throwing: CallError.timeout)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd ClaudeSpyPackage && swift test --filter ClaudeSpyPluginRuntimeTests.SidecarConnection 2>&1 | tail -10
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyPluginRuntime/SidecarConnection.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyPluginRuntimeTests/SidecarConnectionTests.swift
git commit -m "Add SidecarConnection (JSON-RPC framing over FileHandles)"
```

---

## After Plan 1.A ships

Once Tasks 1 – 12 land and `swift test` is green:

- All new modules are wired into `Package.swift` and produce compileable libraries / executable / test target.
- `ClaudeSpyNetworking` has the full new type set (`PluginID`, `NotificationSpec`, `AgentSession`, `AgentProject`, `AgentResponseRequest`, `AgentResponse`, plus 5 wire messages) — all sitting alongside the existing `HookEvent`/`ClaudeSession`/`ClaudeProjectInfo`.
- `GallagerPluginProtocol` defines `PluginManifest`, `PluginEvent`, `AppAction`, `JSONRPCFrame`, and the method-name constants.
- `ClaudeSpyPluginRuntime` has `PluginPaths`, `PluginRegistry`, and `SidecarConnection`.
- Nothing in the running Mac or iOS app uses these new types yet — they're inert.

The next plan (**Plan 1.B**) layers `SidecarSupervisor` (process lifecycle), `IngressBroker` (Unix-socket frame listener), `PluginEventDispatcher` (PluginEvent fan-out), `PluginRouter` (sidecar→app callbacks), `PluginManager` (facade), and `MockSidecar` (test utility) on top of `SidecarConnection`. After 1.B, you can drive a mock sidecar through the runtime end-to-end without spawning a real subprocess.

Then **Plan 1.C** adds the `gallager plugin <verb>` CLI subcommands and `plugin.*` server-side RPC handlers — enabling the user to interrogate the runtime even though no real plugins exist yet.

Then **Plan 1.D** ships the `EchoPluginSidecar` executable as a reference plugin, the `--gallager-state-root` launch arg, and dormantly wires `PluginManager` into `AppCoordinator`. End-to-end integration tests then exercise a real subprocess via the runtime.

After 1.D ships, Phase 1 is complete and the foundation is ready for **Plan 2** (Claude Code extraction).
