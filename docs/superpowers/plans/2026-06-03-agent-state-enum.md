# AgentState Single-State-Enum Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `AgentSession.isWorking`/`needsAttention` and the separate open-form transport with one `AgentState` enum emitted by the plugin cores and carried on `AgentSession`.

**Architecture:** A new `AgentState` enum becomes `AgentSession`'s single source of truth; `isWorking`/`needsAttention` become computed properties so the ~50 read sites are untouched. `PluginEvent` carries `state: AgentState?`; the dispatcher fans it through one sink; the open form rides `AgentSession.state` (so it's in the snapshot for free). Build stays green at every phase because the computed Bools shield read sites.

**Tech Stack:** Swift 6, Swift Testing, Point-Free Dependencies, SwiftUI. Build/test via `./scripts/unit-tests.sh` (which runs `swift test --parallel` on the macOS host).

**Reference spec:** `docs/superpowers/specs/2026-06-03-agent-state-enum-design.md`

**Conventions:**
- Run a single suite with `./scripts/unit-tests.sh -- --filter <SuiteOrType>`.
- Commit messages: conventional commits (`feat(plugins):`, `refactor(plugins):`, `test(plugins):`). End every commit body with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.
- This branch already breaks wire compat — no dual-emit/deprecation shims.

---

## File Map

| File | Responsibility | Action |
|---|---|---|
| `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentState.swift` | The state enum + derivations | **Create** |
| `…/ClaudeSpyNetworking/Models/AgentSession.swift` | Store `state`, derive Bools | Modify |
| `…/ClaudeSpyNetworking/Models/Plugin/PluginEvent.swift` | `state: AgentState?` replaces working/attention/responseRequest | Modify |
| `…/ClaudeSpyNetworking/Models/Plugin/PluginWireMessages.swift` | `AgentSessionStatusMessage.state`; delete `AgentResponseRequestMessage` | Modify |
| `…/ClaudeSpyNetworking/Models/WebSocketMessage.swift` | Delete `agentResponseRequest` case | Modify |
| `…/ClaudeSpyNetworking/Models/RelayMessages.swift` | Delete `openResponseRequests` + `PaneOpenResponseRequest` | Modify |
| `…/ClaudeSpyServerFeature/Plugins/PluginEventDispatcher.swift` | One `onState` sink + yolo | Modify |
| `…/ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift` | `applyState`; delete 3 maps | Modify |
| `…/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift` | Re-wire dispatcher sinks + snapshot | Modify |
| `…/ClaudeCodePluginCore/ClaudeCodeTranslator.swift` | hook → `AgentState` | Modify |
| `…/CodexPluginCore/CodexTranslator.swift` | hook → `AgentState` | Modify |
| `…/ClaudeSpyCommon/Services/SessionStore.swift` | `state` from status; delete openResponseRequests | Modify |
| `…/ClaudeSpyCommon/UI/SessionStatusIndicator.swift` | Derive from computed Bools (unchanged glyphs) | Verify |
| `…/ClaudeSpyFeature/Services/SessionDetailService.swift` | `responseState` from `session.state` | Modify |

---

## Phase 1 — The model

### Task 1: Add the `AgentState` enum

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentState.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/AgentStateTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// AgentStateTests.swift
import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("AgentState")
struct AgentStateTests {
    @Test("needsAttention is true only for awaiting* and doneWorking")
    func needsAttentionDerivation() {
        #expect(AgentState.working.needsAttention == false)
        #expect(AgentState.idle.needsAttention == false)
        #expect(AgentState.doneWorking(summary: nil).needsAttention == true)
        #expect(AgentState.awaitingPermission(
            PermissionRequest(title: "Bash", description: "ls"), requestID: "r1"
        ).needsAttention == true)
        #expect(AgentState.awaitingReplies(
            AskUserQuestionRequest(questions: []), requestID: "r1"
        ).needsAttention == true)
        #expect(AgentState.awaitingPlanApproval(
            ApprovePlanRequest(title: "Plan", plan: "do it"), requestID: "r1"
        ).needsAttention == true)
    }

    @Test("isActiveWorking is true only for .working")
    func isActiveWorkingDerivation() {
        #expect(AgentState.working.isActiveWorking == true)
        #expect(AgentState.idle.isActiveWorking == false)
        #expect(AgentState.doneWorking(summary: "done").isActiveWorking == false)
    }

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        let states: [AgentState] = [
            .working, .idle, .doneWorking(summary: "bye"),
            .awaitingPermission(PermissionRequest(title: "t", description: "d"), requestID: "r1"),
        ]
        for state in states {
            let decoded = try JSONDecoder().decode(
                AgentState.self, from: JSONEncoder().encode(state)
            )
            #expect(decoded == state)
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/unit-tests.sh -- --filter AgentStateTests`
Expected: FAIL — `cannot find 'AgentState' in scope`.

- [ ] **Step 3: Create the enum**

```swift
// AgentState.swift
import Foundation

/// The single, agent-blind description of a coding-agent session's current
/// state. Cores emit this directly (spec §3); `AgentSession` stores exactly one.
/// The open response form, when any, rides the `awaiting*` cases — so it travels
/// to viewers as part of session state with no separate transport.
public enum AgentState: Codable, Sendable, Equatable {
    /// Actively processing.
    case working
    /// Blocked on a plan approval. `requestID` routes the structured answer back.
    case awaitingPlanApproval(ApprovePlanRequest, requestID: String)
    /// Blocked on a tool-use permission.
    case awaitingPermission(PermissionRequest, requestID: String)
    /// Blocked on one or more questions.
    case awaitingReplies(AskUserQuestionRequest, requestID: String)
    /// Stopped (clean or failure); `summary` carries the last message or error.
    case doneWorking(summary: String?)
    /// Fresh session, or one the user has viewed/handled.
    case idle

    /// Derived legacy "working" bit — true only while actively processing.
    public var isActiveWorking: Bool {
        if case .working = self { return true }
        return false
    }

    /// Derived legacy "attention" bit — true for any blocked/done state.
    public var needsAttention: Bool {
        switch self {
        case .working, .idle:
            return false
        case .awaitingPlanApproval, .awaitingPermission, .awaitingReplies, .doneWorking:
            return true
        }
    }

    /// The open response form this state represents, if any (the `awaiting*`
    /// cases). Used by viewers to render the form and submit the answer.
    public var openForm: (request: AgentResponseRequest, requestID: String)? {
        switch self {
        case let .awaitingPlanApproval(plan, id): return (.approvePlan(plan), id)
        case let .awaitingPermission(perm, id): return (.permission(perm), id)
        case let .awaitingReplies(q, id): return (.askUserQuestion(q), id)
        case .working, .doneWorking, .idle: return nil
        }
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `./scripts/unit-tests.sh -- --filter AgentStateTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentState.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/AgentStateTests.swift
git commit -m "feat(plugins): add AgentState enum with derived isActiveWorking/needsAttention/openForm"
```

### Task 2: Make `AgentSession` store `AgentState`, derive the Bools

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentSession.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/AgentSessionStateTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// AgentSessionStateTests.swift
import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("AgentSession state")
struct AgentSessionStateTests {
    @Test("isWorking / needsAttention derive from state")
    func derivedBools() {
        var s = AgentSession(paneId: "%1")
        #expect(s.state == .idle)            // default
        #expect(s.isWorking == false)
        #expect(s.needsAttention == false)

        s.state = .working
        #expect(s.isWorking == true)
        #expect(s.needsAttention == false)

        s.state = .doneWorking(summary: nil)
        #expect(s.isWorking == false)
        #expect(s.needsAttention == true)
    }

    @Test("markHandled clears only doneWorking; awaiting* survive")
    func markHandledOnlyClearsDone() {
        var done = AgentSession(paneId: "%1"); done.state = .doneWorking(summary: "x")
        done.markHandled()
        #expect(done.state == .idle)

        var awaiting = AgentSession(paneId: "%2")
        awaiting.state = .awaitingPermission(
            PermissionRequest(title: "Bash", description: "ls"), requestID: "r1"
        )
        awaiting.markHandled()
        #expect(awaiting.needsAttention == true)   // unchanged — needs explicit answer
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/unit-tests.sh -- --filter AgentSessionStateTests`
Expected: FAIL — `value of type 'AgentSession' has no member 'state'`.

- [ ] **Step 3: Rewrite `AgentSession`'s state storage**

In `AgentSession.swift`, replace the two stored Bools (lines 21-28) with a stored `state`, and turn `isWorking`/`needsAttention` into computed properties. Replace the `init`, the `CodingKeys`/`init(from:)`, and `markHandled`/`markAutoApproved`/`statusLabel` accordingly:

```swift
    /// The session's current state — the single source of truth (spec §3).
    public var state: AgentState

    // (remove `isWorking` and `needsAttention` stored properties)

    public init(
        paneId: String,
        pluginID: String = "claude-code",
        detectedProjectPath: String? = nil,
        state: AgentState = .idle
    ) {
        self.paneId = paneId
        self.pluginID = pluginID
        self.detectedProjectPath = detectedProjectPath
        self.state = state
    }

    /// Derived for the many UI/sort read sites that still ask these questions.
    public var isWorking: Bool { state.isActiveWorking }
    public var needsAttention: Bool { state.needsAttention }

    public var statusLabel: String {
        switch state {
        case .working: return "Working"
        case .awaitingPlanApproval: return "Plan approval"
        case .awaitingPermission: return "Permission"
        case .awaitingReplies: return "Questions"
        case .doneWorking: return "Done"
        case .idle: return "Idle"
        }
    }

    /// The user viewed/handled the session. Only a finished session goes idle;
    /// a session awaiting an explicit answer stays put (this replaces the former
    /// `panesWithBlockingForm` guard).
    public mutating func markHandled() {
        if case .doneWorking = state { state = .idle }
    }
```

Delete `markAutoApproved()` (yolo now keeps `.working` at the dispatcher; no session mutation needed). Update `CodingKeys` to `paneId, pluginID, detectedProjectPath, state` and `init(from:)` to `state = try container.decodeIfPresent(AgentState.self, forKey: .state) ?? .idle`.

- [ ] **Step 4: Run it to verify it passes**

Run: `./scripts/unit-tests.sh -- --filter AgentSessionStateTests`
Expected: PASS.

- [ ] **Step 5: Build the whole package to surface read-site breakage**

Run: `./scripts/unit-tests.sh -- --filter __none__ 2>&1 | tail -30` (compiles all targets; the filter matches nothing so only the build runs).
Expected: only errors at *write* sites (`session.isWorking = …`, `markAutoApproved`, `AgentSession(… isWorking:)`), which later tasks fix. If a *read* site errors, fix it in place (it should compile against the computed property). Note each failing file for the relevant later task; do not fix write sites yet.

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/AgentSession.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/AgentSessionStateTests.swift
git commit -m "refactor(plugins): AgentSession stores AgentState; isWorking/needsAttention derived"
```

---

## Phase 2 — The plugin contract

### Task 3: `PluginEvent.state` replaces working/attention/responseRequest

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/Plugin/PluginEvent.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/PluginEventStateTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// PluginEventStateTests.swift
import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("PluginEvent state")
struct PluginEventStateTests {
    @Test("carries an optional state delta plus notification/appActions")
    func carriesState() {
        let e = PluginEvent(
            pluginID: "echo", sessionID: "s1",
            state: .working, tmuxPane: "%1"
        )
        #expect(e.state == .working)
        #expect(e.notification == nil)

        let noOpinion = PluginEvent(pluginID: "echo", sessionID: "s1", state: nil)
        #expect(noOpinion.state == nil)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/unit-tests.sh -- --filter PluginEventStateTests`
Expected: FAIL — `extra argument 'state'` / missing `working`/`attention`.

- [ ] **Step 3: Edit `PluginEvent`**

Replace the `working`/`attention`/`responseRequest` stored properties (lines 13-24) and the matching init params (lines 38-41) with a single optional state. Delete the `ResponseRequestPayload` struct (lines 72-86):

```swift
    /// The session's new state, or `nil` for "no opinion, leave it unchanged".
    /// Replaces the former working/attention/responseRequest trio (spec §3).
    public let state: AgentState?
```

```swift
    public init(
        pluginID: String,
        sessionID: String,
        state: AgentState? = nil,
        notification: NotificationSpec? = nil,
        appActions: [AppAction] = [],
        tmuxPane: String? = nil,
        projectPath: String? = nil
    ) {
        self.pluginID = pluginID
        self.sessionID = sessionID
        self.state = state
        self.notification = notification
        self.appActions = appActions
        self.tmuxPane = tmuxPane
        self.projectPath = projectPath
    }
```

- [ ] **Step 4: Run it to verify it passes**

Run: `./scripts/unit-tests.sh -- --filter PluginEventStateTests`
Expected: PASS (the build will still fail elsewhere — translators/dispatcher — fixed next; if `swift test` won't link, that's expected until Task 6).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/Plugin/PluginEvent.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/PluginEventStateTests.swift
git commit -m "refactor(plugins): PluginEvent carries state: AgentState? (drop working/attention/responseRequest)"
```

> **Note:** Tasks 3–6 are one compile unit — the package won't fully build until the dispatcher and both translators are updated. Implement Tasks 4, 5, 6 before running the full suite again. Commit each task's source regardless (the per-task unit tests added in earlier networking tasks still run because they only import `ClaudeSpyNetworking`, which compiles independently).

### Task 4: Collapse the dispatcher to one `onState` sink

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/PluginEventDispatcher.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift` (sink wiring, ~lines 380-463)
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRuntimeResponseWiringTests.swift` (rewrite for the new sink)

- [ ] **Step 1: Rewrite the dispatcher's sink set**

In `PluginEventDispatcher.swift`, replace `StatusSink`, `OpenResponseRequestSink`, `RetractResponseRequestSink` and their stored properties with one:

```swift
    /// The session's state changed. Drives `AgentSession.state` and the
    /// `agent_session_status` push. Also the sole open/retract-form signal: an
    /// `awaiting*` state opens the form, any other state retracts it.
    public typealias StateSink = @Sendable (
        _ pluginID: String,
        _ sessionID: String,
        _ state: AgentState,
        _ tmuxPane: String?,
        _ projectPath: String?
    ) async -> Void
```

Keep `NotificationSink`, `AppActionSink`, `AutoApproveCheck`. Delete the `lastAttention` map. Rewrite `dispatch(_:)`:

```swift
    public func dispatch(_ event: PluginEvent) async {
        let paneID = event.tmuxPane ?? event.sessionID

        if let state = event.state {
            // Yolo auto-approve (spec §6): an auto-approvable permission on a yolo
            // pane is approved silently — deliver .allow, keep the session working,
            // and suppress the notification. The form is never shown.
            var effectiveState = state
            var suppressNotification = false
            if
                case let .awaitingPermission(permission, requestID) = state,
                permission.isAutoApprovable,
                await isYoloModeEnabled(paneID) {
                await onAutoApprove(event.pluginID, paneID, requestID)
                effectiveState = .working
                suppressNotification = true
            }
            await onState(event.pluginID, event.sessionID, effectiveState, event.tmuxPane, event.projectPath)
            if let notification = event.notification, !suppressNotification {
                await onNotification(event.pluginID, paneID, notification)
            }
        } else if let notification = event.notification {
            await onNotification(event.pluginID, paneID, notification)
        }

        for action in event.appActions {
            await onAppAction(action)
        }
    }
```

Add an `onAutoApprove` sink (`@Sendable (pluginID, sessionID, requestID) async -> Void`) — the coordinator wires it to deliver the approval (replacing the old inline yolo branch). Update the `init` to take `onState`, `onNotification`, `onAutoApprove`, `onAppAction`, `isYoloModeEnabled`.

- [ ] **Step 2: Re-wire the sinks in `AppCoordinator`**

In `AppCoordinator.swift` (the `PluginEventDispatcher(...)` construction, ~line 390-463): replace `onStatus`/`onOpenResponseRequest`/`onRetractResponseRequest` with:

```swift
                onState: { [weak self] pluginID, sessionID, state, tmuxPane, projectPath in
                    await self?.windowManager.applyState(
                        pluginID: pluginID,
                        sessionID: sessionID,
                        state: state,
                        tmuxPane: tmuxPane,
                        projectPath: projectPath
                    )
                    // Push the resulting per-session status to viewers (unchanged forward).
                },
                onAutoApprove: { [weak self] pluginID, sessionID, requestID in
                    await self?.pluginRegistry?.core(pluginID)?.deliverResponse(
                        sessionID: sessionID,
                        requestID: requestID,
                        .permission(decision: .allow, appliedSuggestionID: nil)
                    )
                },
```

Keep `onNotification`, `onAppAction`, `isYoloModeEnabled` as-is. Delete the `setBlockingResponseForm` / `setPendingApproval` / `setOpenResponseRequest` / `sendAgentResponseRequestToAll` calls from the deleted sinks (the form now rides the status/snapshot via `applyState`). Wherever the old `onStatus` forwarded `agent_session_status` to iOS, forward it from `onState` using `state` (Task 8 changes the message payload).

- [ ] **Step 3: Rewrite `PluginRuntimeResponseWiringTests.swift`**

Replace the `SendRecorder`/`makeDispatcher` (open/retract) with a recorder of `(sessionID, state)` and assert: an `awaiting*` state reaches `onState`; an auto-approvable permission under yolo reaches `onAutoApprove` and `onState` receives `.working`. Keep the inbound-submission tests (they're unchanged — `deliverResponse` still takes `requestID`).

```swift
@Test("an awaiting state reaches onState; yolo permission auto-approves and stays working")
func stateAndYolo() async {
    let states = StateRecorder(); let approvals = ApprovalRecorder()
    let dispatcher = PluginEventDispatcher(
        onState: { _, sid, state, _, _ in await states.record(sid, state) },
        onAutoApprove: { _, sid, rid in await approvals.record(sid, rid) },
        isYoloModeEnabled: { _ in true }
    )
    await dispatcher.dispatch(PluginEvent(
        pluginID: "echo", sessionID: "s1",
        state: .awaitingPermission(
            PermissionRequest(title: "Bash", description: "ls", isAutoApprovable: true),
            requestID: "r1"
        ),
        tmuxPane: "%1"
    ))
    #expect(await approvals.all == [("s1", "r1")])
    #expect(await states.last(for: "s1") == .working)   // yolo kept it working
}
```

- [ ] **Step 4: Defer running** (build completes after Task 6). Commit source now.

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/PluginEventDispatcher.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRuntimeResponseWiringTests.swift
git commit -m "refactor(plugins): dispatcher fans one AgentState sink; yolo keeps session working"
```

---

## Phase 3 — The translators (cores emit state)

### Task 5: `ClaudeCodeTranslator` emits `AgentState`

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeTranslator.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/ClaudeCodeTranslatorStateTests.swift`

- [ ] **Step 1: Write failing tests for the mapping rule**

```swift
// ClaudeCodeTranslatorStateTests.swift — assert the spec §"Translator mapping" table.
// permissionRequest -> .awaitingPermission; askUserQuestion -> .awaitingReplies;
// plan -> .awaitingPlanApproval; stop -> .doneWorking(summary:);
// sessionStart -> .idle; preToolUse/userPromptSubmit -> .working;
// notification -> state == nil (push only); fileChanged/compaction -> state == nil.
```
(Write one `@Test` per row using the existing `HookAction` fixtures already used in the core's other tests; assert `translate(...)?.event.state`.)

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/unit-tests.sh -- --filter ClaudeCodeTranslatorStateTests`
Expected: FAIL — `event.state` doesn't exist / translator still builds working/attention.

- [ ] **Step 3: Rewrite the translator's event construction**

Replace the `let working = hookEvent.isWorking` / `let attention = …` / `responseRequest` assembly (lines ~76-120) with a single `state: AgentState?` computed by this rule, in priority order, then build `PluginEvent(state:notification:appActions:…)`:

```swift
let state: AgentState? = {
    // 1. Blocking forms win.
    switch action {
    case let .permissionRequest(body):
        if case let .askUserQuestion(params) = body.toolInput {
            return .awaitingReplies(askUserQuestionRequest(from: params), requestID: requestID)
        }
        return .awaitingPermission(permissionRequest(from: body), requestID: requestID)
    case let /* plan action */:
        return .awaitingPlanApproval(approvePlanRequest(...), requestID: requestID)
    case let .stop(b):
        return .doneWorking(summary: b.lastAssistantMessage)
    case let .stopFailure(b):
        return .doneWorking(summary: b.errorType)
    case .sessionStart:
        return .idle
    default:
        // 2. Otherwise fall back to the working bit.
        switch hookEvent.isWorking {
        case true?:  return .working
        case false?: return nil          // SessionEnd handled via appAction
        case nil:    return nil          // no opinion
        }
    }
}()
```

Keep the `notification`, `appActions`, `pending` computation unchanged. The `pending` (keystroke context) is still retained by `requestID` in the core (Task unchanged). Keep the early `return nil` drop guard, updating it to `state == nil && notification == nil && appActions.isEmpty`.

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/unit-tests.sh -- --filter ClaudeCodeTranslatorStateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeTranslator.swift \
        ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/ClaudeCodeTranslatorStateTests.swift
git commit -m "refactor(claude): translate hooks into AgentState"
```

### Task 6: `CodexTranslator` emits `AgentState`

**Files:**
- Modify: `ClaudeSpyPackage/Sources/CodexPluginCore/CodexTranslator.swift`
- Test: `ClaudeSpyPackage/Tests/CodexPluginCoreTests/CodexTranslatorStateTests.swift`

- [ ] **Step 1–4:** Mirror Task 5 exactly (Codex shares `HookEvent.isWorking` and the same form-producing structure). Write per-row mapping tests, run-fail, apply the identical `state` rule (lines ~83-120), run-pass.
- [ ] **Step 5: Verify the full package builds and the suite is green again**

Run: `./scripts/unit-tests.sh 2>&1 | tail -20`
Expected: All targets compile; only pre-existing tests that asserted on the deleted message types/fields fail (fixed in Phase 5/6). Note them.

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/CodexPluginCore/CodexTranslator.swift \
        ClaudeSpyPackage/Tests/CodexPluginCoreTests/CodexTranslatorStateTests.swift
git commit -m "refactor(codex): translate hooks into AgentState"
```

---

## Phase 4 — Mac retention

### Task 7: `MirrorWindowManager.applyState`; delete the three maps

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRuntimeStatusWiringTests.swift`

- [ ] **Step 1: Update the wiring tests**

Replace `applyPluginStatus(...)` calls with `applyState(pluginID:sessionID:state:tmuxPane:projectPath:)`. Rewrite the existing assertions:
- "working/attention set the bools" → `applyState(state: .working)` then `#expect(session.state == .working)`.
- "a blocking-form attention survives mark-handled-on-view" → `applyState(state: .awaitingPermission(...))`, call `markSessionHandled`, `#expect(session.needsAttention == true)`.
- The retain/clear/working-clear tests from `eef20ae9` (`retainsOpenResponseFormsForSnapshot`, `workingStatusClearsRetainedForm`) → **delete** (the form now lives on `session.state`; replaced by asserting `session.state.openForm != nil` after `applyState(.awaitingReplies(...))` and `== nil` after `applyState(.working)`).

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/unit-tests.sh -- --filter PluginRuntimeStatusWiring`
Expected: FAIL — `applyState` not found.

- [ ] **Step 3: Replace `applyPluginStatus` with `applyState`; delete the maps**

Rename/rewrite `applyPluginStatus` (lines ~211-260) to:

```swift
public func applyState(
    pluginID: String,
    sessionID: String,
    state: AgentState,
    tmuxPane: String?,
    projectPath: String?
) {
    guard let paneId = tmuxPane, !paneId.isEmpty else { /* same drop-log */ return }
    updateSession(paneId: paneId) { session in
        session.pluginID = pluginID
        if let projectPath, !projectPath.isEmpty { session.detectedProjectPath = projectPath }
        session.state = state
    }
    lastActivityByPane[paneId] = Date()
    // … keep any CLI-override clearing that lived here …
}
```

Delete: `panesWithBlockingForm` and its mutations; `pendingApprovalByPane`, `PendingApproval`, `setPendingApproval`, `pendingApproval(for:)`; `setBlockingResponseForm`; `openResponseRequestByPane`, `setOpenResponseRequest`, `openResponseRequests`. Update `endAgentSession` to drop only `paneStates[paneId]?.agentSession` (remove the now-deleted map cleanups). Update `markSessionHandled` to just call `paneStates[paneId]?.agentSession?.markHandled()` (the guard is now inside `markHandled`). For the yolo-enable-later path (#315), read the pending approval from `paneStates[paneId]?.agentSession?.state` (`if case .awaitingPermission(let p, let id) = state, p.isAutoApprovable`).

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/unit-tests.sh -- --filter PluginRuntimeStatusWiring`
Expected: PASS. Fix any AppCoordinator references to the deleted methods (yolo-enable path, snapshot builder) revealed by the build.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRuntimeStatusWiringTests.swift
git commit -m "refactor(plugins): MirrorWindowManager applies AgentState; delete blocking-form/pending-approval/open-form maps"
```

---

## Phase 5 — Wire format

### Task 8: `AgentSessionStatusMessage` carries `state`

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/Plugin/PluginWireMessages.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/ConnectedViewer*.swift` + `AppCoordinator.swift` (status forward), `ExternalServerClient.swift` (decode dispatch)
- Test: extend `ClaudeSpyNetworkingTests`

- [ ] **Step 1: Failing test** — encode/decode an `AgentSessionStatusMessage` carrying `.awaitingReplies(...)`, assert the state survives and `withPairId` forwards it.

- [ ] **Step 2: Run-fail.** `./scripts/unit-tests.sh -- --filter <newTest>` → FAIL (no `state` field).

- [ ] **Step 3:** Replace `working: Bool` + `attention: Bool` with `state: AgentState` in `AgentSessionStatusMessage` (init + `withPairId`). Update every constructor (the status-forward in `AppCoordinator`'s `onState` sink, `ConnectedViewer.sendAgentStatus`, and any test helper like `SessionDetailServiceTests.pushStatus`).

- [ ] **Step 4: Run-pass.**

- [ ] **Step 5: Commit** `refactor(plugins): AgentSessionStatusMessage carries AgentState`.

### Task 9: Delete the now-dead response-request transport

**Files:**
- Modify: `PluginWireMessages.swift` (delete `AgentResponseRequestMessage`)
- Modify: `WebSocketMessage.swift` (delete `case agentResponseRequest` + its CodingKey, ~lines 104/195)
- Modify: `RelayMessages.swift` (delete `openResponseRequests` field, `withPairId` forward, and `PaneOpenResponseRequest`)
- Modify: `ConnectedViewer.swift` / `ConnectedViewerManager.swift` (delete `sendAgentResponseRequest*`), `ExternalServerClient.swift` (delete its decode/dispatch), `AppCoordinator.swift` snapshot builder (delete `openResponseRequests:`)
- Delete: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/SessionStateOpenRequestSyncTests.swift`

- [ ] **Step 1:** Delete the types/cases/fields above and every reference (the compiler enumerates them). Delete the `SessionStateOpenRequestSyncTests.swift` file (its concern is now `AgentSession.state` in the snapshot, covered by Task 10).
- [ ] **Step 2: Build** `./scripts/unit-tests.sh -- --filter __none__` → compiles clean.
- [ ] **Step 3: Commit** `refactor(plugins): remove standalone response-request message; form rides AgentSession.state`.

---

## Phase 6 — Viewer

### Task 10: `SessionStore` reads state; delete `openResponseRequests`

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/SessionStore.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyFeatureTests/SessionDetailServiceTests.swift`

- [ ] **Step 1: Update tests.** The `openRequest(...)` helper now pushes a status with an `awaiting*` state. The snapshot catch-up tests (added in `eef20ae9`) become: build a `SessionStateMessage` whose `paneStates["%1"].agentSession.state == .awaitingReplies(...)`, call `handleStateUpdate`, assert the service shows the form. Add: a `.working` status clears a prior `awaiting*` (it transitions, no separate dict). Delete tests that referenced `sessionStore.openResponseRequest(for:)` as a separate store.

- [ ] **Step 2: Run-fail.**

- [ ] **Step 3: Edit `SessionStore`.** In `handleAgentStatus` (lines 158-183) set `session.state = status.state` (remove the Bool assignments and the `if status.working == true { openResponseRequests.removeValue }` block). Apply the viewed→idle rule where the store currently auto-clears attention on `pendingSessionCount` change: call `session.markHandled()` (only `doneWorking` clears; `awaiting*` is automatically exempt — delete any explicit blocking-form check). Delete `openResponseRequests`, `OpenResponseRequest`, `handleAgentResponseRequest`, `openResponseRequest(for:hostId:)`, and the `handleStateUpdate` reconcile block from `eef20ae9`. Replace `markSessionHandled`'s blocking check (line 247) — `markHandled()` now encapsulates it.

- [ ] **Step 4: Run-pass.** `./scripts/unit-tests.sh -- --filter SessionDetailServiceTests`.

- [ ] **Step 5: Commit** `refactor(plugins): SessionStore derives open form from AgentSession.state`.

### Task 11: `SessionDetailService.responseState` from `session.state`

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyFeature/Services/SessionDetailService.swift`
- Test: covered by `SessionDetailServiceTests` (Task 10).

- [ ] **Step 1:** In `updateResponseState`, source the open form from `sessionStore.session(for:hostId:)?.state.openForm` instead of `sessionStore.openResponseRequest(...)`. Build `ResponseState` from `(request, requestID)`; clear it when `openForm == nil`.
- [ ] **Step 2: Run** `./scripts/unit-tests.sh -- --filter SessionDetailServiceTests` → PASS.
- [ ] **Step 3: Commit** `refactor(ios): derive responseState from AgentSession.state`.

### Task 12: Verify `SessionStatusIndicator` and other read sites

**Files:**
- Verify: `ClaudeSpyCommon/UI/SessionStatusIndicator.swift`, `MenuBarExtraView.swift`, `SessionFieldsView.swift`, `WindowLayoutView.swift`.

- [ ] **Step 1:** Confirm each compiles against the computed `isWorking`/`needsAttention` (they should, unchanged). Decide per the spec's open question whether to add per-state glyphs now; **default: keep the existing attention/working/idle mapping** to avoid baseline churn.
- [ ] **Step 2: Build** the full package: `./scripts/unit-tests.sh -- --filter __none__` → clean.
- [ ] **Step 3: Commit** only if changes were needed.

---

## Phase 7 — Suite + E2E

### Task 13: Green suite and E2E baselines

- [ ] **Step 1: Full unit suite** — `./scripts/unit-tests.sh 2>&1 | tail -20`. Expected: all green. Fix any stragglers (test helpers still referencing `working:`/`attention:`/deleted messages).
- [ ] **Step 2: E2E** — run the three affected scenarios per the e2e-testing skill (`ClaudeSessionUpdatesScenario`, `BadgeAggregationScenario`, `MarkHandledScenario`). If the status glyphs are unchanged (Task 12 default), baselines should match; if not, reshoot and **verify each screenshot visually**, then let CI regenerate baselines (`feedback_baselines-ci-generated` — don't commit locally-regenerated baselines).
- [ ] **Step 3: Commit** any scenario code changes (not baselines): `test(plugins): update session-state scenarios for AgentState`.

---

## Self-review notes

- **Spec coverage:** model (T1-2), contract (T3-4), translators (T5-6), Mac (T7), wire incl. deletions (T8-9), viewer + indicator (T10-12), behavior changes (markHandled guard subsumption in T2/T7/T10; SessionStart→idle and Notification-decouple in T5-6; permission isWorking=false via derivation in T1), tests/E2E (T13). All spec sections map to a task.
- **Type consistency:** `applyState`, `onState`/`StateSink`, `AgentState.openForm`, `state.isActiveWorking`/`needsAttention` are used identically across tasks.
- **Compile-unit caveat:** Tasks 3–6 break the build mid-phase (documented in Task 3's note); the package only re-greens at Task 6 Step 5. Networking-only unit tests still run throughout.
