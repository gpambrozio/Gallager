# Design: `AgentState` — one session state enum

**Date:** 2026-06-03
**Branch:** `plugin-system-v1-in-process`
**Status:** Approved design, pre-implementation

## Goal

Replace `AgentSession`'s two independent Bools (`isWorking`, `needsAttention`) and
the separately-transmitted open-form payload with a single `AgentState` enum that
carries everything about a session's current state, including the open response
form. The cores emit this state directly; the system owns only the
"viewed → idle" transition.

This subsumes three fragile mechanisms that have each caused real bugs:

1. The `panesWithBlockingForm` guard (the documented "stuck on Working" bug —
   `project_attention-mark-handled-on-view`). With the enum, "don't clear on
   view" is just "the state isn't `doneWorking`", so the guard is unnecessary.
2. The status-before-response-request dispatch ordering dependency
   (`project_ingress-event-ordering`). One atomic value has nothing to order.
3. The open-form-not-in-snapshot bug fixed in `eef20ae9` — the form now lives on
   `AgentSession.state`, which the snapshot already carries, so it is replayed to
   a reconnecting viewer for free (the original insight that motivated this work).

Compatibility is **not** a concern: this branch already breaks wire compat, so
every host and viewer updates together. No dual-emit, no decode shims beyond a
defensive default.

## The model

```swift
public enum AgentState: Codable, Sendable, Equatable {
    /// The agent is actively processing.
    case working

    /// Blocked on a plan approval. `requestID` routes the answer back.
    case awaitingPlanApproval(ApprovePlanRequest, requestID: String)

    /// Blocked on a tool-use permission.
    case awaitingPermission(PermissionRequest, requestID: String)

    /// Blocked on one or more questions.
    case awaitingReplies(AskUserQuestionRequest, requestID: String)

    /// The agent stopped (clean or failure); `summary` carries the last
    /// assistant message or the error text. Maps the former `.replyAfterStop`.
    case doneWorking(summary: String?)

    /// Fresh session, or one the user has viewed/handled. The former `.prompt`
    /// "send a message" affordance is implicit here.
    case idle
}
```

`AgentSession` stores **one** `state: AgentState` (default `.idle`). The two Bools
become computed, so the ~50 read sites are unaffected:

```swift
public var isWorking: Bool { state == .working }

public var needsAttention: Bool {
    switch state {
    case .working, .idle: false
    case .awaitingPlanApproval, .awaitingPermission, .awaitingReplies, .doneWorking: true
    }
}
```

`Codable` for `AgentSession` decodes `state` with a defensive `?? .idle` (no real
older wire exists, but keep the tolerant-decode house style).

## Ownership of transitions

- **Cores** set lifecycle/form states (`working`, `awaiting*`, `doneWorking`) by
  translating hooks into an `AgentState`.
- **System** owns `→ idle`:
  ```swift
  public mutating func markHandled() {
      if case .doneWorking = state { state = .idle }
  }
  ```
  Viewing only clears `doneWorking`; `awaiting*` states are never cleared on view
  because the code never transitions them there. **This replaces the
  `panesWithBlockingForm` guard entirely.**

## The plugin contract (deep refactor)

`PluginEvent` collapses `working` + `attention` + `responseRequest` into:

```swift
public let state: AgentState?   // nil = "no opinion, leave unchanged"
// notification, appActions, tmuxPane, projectPath, pluginID, sessionID: unchanged
```

`ResponseRequestPayload` is deleted; the `requestID` it carried now lives inside
the `awaiting*` cases.

Note the optional-vs-stored distinction: `PluginEvent.state` is an **optional
delta** (`nil` = "no opinion, leave the session's state unchanged"), whereas
`AgentSession.state` and the `AgentSessionStatusMessage` that transmits it are the
**non-optional result** after the event is applied. A `nil`-state event still
flows for its `notification` / `appActions`.

The dispatcher's **three sinks** (`onStatus`, `onOpenResponseRequest`,
`onRetractResponseRequest`) become **one** `onState` sink:

```swift
typealias StateSink = @Sendable (
    _ pluginID: String, _ sessionID: String,
    _ state: AgentState, _ tmuxPane: String?, _ projectPath: String?
) async -> Void
```

- **Retraction disappears.** Moving to `.working` / `.doneWorking` / `.idle` *is*
  the retract — there is no `request == nil` special case.
- **Yolo auto-approve** moves into the state sink: an incoming
  `.awaitingPermission(p, id)` with `p.isAutoApprovable` on a yolo pane →
  deliver `.permission(.allow)` to the owning core, **keep the session
  `.working`** (drop the awaiting transition), and suppress the notification
  push. The "pending approval, approve when yolo is enabled later" case (#315)
  reads `session.state` instead of a separate `pendingApprovalByPane` map.
- Change-detection (the former `lastAttention` map that fired a push when
  attention changed) becomes "did the state change", which is simpler.

## Translator mapping (both cores)

Both cores share `HookEvent.isWorking` and the form-producing `translate` logic,
so they follow one rule. Per hook, in priority order:

| Condition | `AgentState` |
|---|---|
| Blocking form: permission | `.awaitingPermission(PermissionRequest, requestID)` |
| Blocking form: AskUserQuestion | `.awaitingReplies(AskUserQuestionRequest, requestID)` |
| Blocking form: plan approval | `.awaitingPlanApproval(ApprovePlanRequest, requestID)` |
| Stop / StopFailure | `.doneWorking(summary:)` (failure → error text in summary) |
| SessionStart | `.idle` (the "session started" push still fires) |
| `isWorking == true` (prompt-submit, tool use, etc.) | `.working` |
| SessionEnd | `state = nil` + `.sessionEnded` app action (pane detection removes the session) |
| bare Notification hook | `state = nil`; notification push only (decoupled) |
| everything else (`isWorking == nil`: compaction, file/config/cwd changes, subagent, setup, unknown) | `state = nil`; may still carry `notification` / `appActions` |

`requestID` is the existing per-hook id (e.g. `"%1:PermissionRequest"`); the
core's `pendingRequests` keystroke-context map stays keyed by it, unchanged.

## Wire changes

- `AgentSessionStatusMessage` carries `state: AgentState` instead of
  `working` / `attention`. This is the incremental per-session push; it now also
  carries the open form (a permission fires **one** message, not a status message
  plus a form message).
- `AgentSession.state` rides `SessionStateMessage.paneStates` as today → the form
  is in the snapshot automatically.
- **Deleted from the wire:** the `agentResponseRequest` `WebSocketMessage` case,
  `AgentResponseRequestMessage`, `ResponseRequestPayload`, `PaneOpenResponseRequest`,
  and `SessionStateMessage.openResponseRequests` (all added in `eef20ae9`).
- `AgentResponseSubmissionMessage` (viewer → host answer) is **unchanged**.

## Response submission

- **Blocking states** carry `requestID` → existing `AgentResponseSubmissionMessage`
  → `core.deliverResponse(sessionID:requestID:_:)` → `pendingRequests` keystroke
  mapping. Unchanged.
- **Free-text to an `idle` / `doneWorking` session** is delivered as plain pane
  keystrokes through the existing remote-keystroke pipeline
  (`project_keystroke-pipeline`) — no `requestID` round-trip. This is why
  `.prompt` and `.replyAfterStop` do not need to be states: typing into a pane
  needs no blocked-hook match, unlike a structured permission/question/plan answer.

## iOS / viewer changes

- `SessionStore`: delete the `openResponseRequests` dict and
  `handleAgentResponseRequest`. The open form is read from
  `paneState.agentSession.state`.
- `SessionStore.handleAgentStatus`: assign `session.state = status.state`; the
  "viewed session auto-clears needsAttention on `pendingSessionCount` change"
  logic becomes "viewed `doneWorking` → `idle`", and the blocking-form exemption
  is automatic (`awaiting*` never auto-clears). Drop the
  `if status.working == true { openResponseRequests.removeValue }` line.
- `SessionDetailService.responseState`: derive from `session.state` — build a
  `ResponseState` when the state is an `awaiting*` case.
- `SessionStatusIndicator`: may render distinct glyphs per `awaiting*` case
  (permission / question / plan / done) instead of one generic bell — optional
  polish; at minimum keep the current attention/working/idle mapping via the
  computed Bools.

## Consolidated deletions (the payoff)

- Mac: `panesWithBlockingForm`, `pendingApprovalByPane`, `openResponseRequestByPane`.
- Wire: `agentResponseRequest` message + `AgentResponseRequestMessage` +
  `ResponseRequestPayload` + `PaneOpenResponseRequest` +
  `SessionStateMessage.openResponseRequests`.
- iOS: `SessionStore.openResponseRequests` + `handleAgentResponseRequest`.
- Dispatcher: two of three sinks; the ordering concern; the `lastAttention` map.

Net: the change deletes more than it adds.

## Intentional behavior changes

- A `permissionRequest` derives `isWorking == false` (was `true` underneath). The
  visible glyph is unchanged (the bell already won), and sort priority moves from
  "working" to "attention" (arguably better).
- `SessionStart` → `.idle` (`needsAttention == false`); the "session started"
  push still fires. A just-started session no longer shows a bell.
- A bare `Notification` hook is a push only; it no longer flips state.

## Blast radius & testing

Touches: the plugin contract (`PluginEvent`), both translators, the dispatcher,
`MirrorWindowManager`, `SessionStore`, `AgentSession`, `AgentSessionStatusMessage`,
`WebSocketMessage`, `SessionDetailService`, the status-indicator UI, and the
associated unit tests + 3 E2E scenarios (`ClaudeSessionUpdatesScenario`,
`BadgeAggregationScenario`, `MarkHandledScenario`).

Testing strategy:
- Unit: an `AgentState` round-trip + derivation test; translator
  hook→state mapping tests (replace the working/attention assertions); dispatcher
  one-sink + yolo-suppression test; `markHandled` only-clears-`doneWorking` test;
  `SessionStore` state-from-status + viewed→idle test; the snapshot still renders
  an open form on connect (port the `eef20ae9` regression test to read
  `agentSession.state`).
- E2E: reshoot the 3 scenarios' baselines if the indicator glyphs change; verify
  visually (per `feedback_test-before-ci`, `feedback_baselines-ci-generated`).

## Suggested sequencing (bottom-up)

1. Add `AgentState`; convert `AgentSession` to store it with computed Bools.
2. Change `PluginEvent` + the dispatcher to one state sink (+ yolo path).
3. Update both translators to emit `AgentState`.
4. Update `MirrorWindowManager` (apply state; delete the three maps).
5. Wire: `AgentSessionStatusMessage` carries state; delete the response-request
   message and snapshot field.
6. iOS: `SessionStore`, `SessionDetailService`, indicator.
7. Tests + E2E baselines.

Each step keeps the package compiling (computed Bools shield read sites), so the
work can land incrementally.

## Open questions / risks

- **Indicator polish vs. baselines:** richer per-state glyphs are nice but force
  baseline reshoots. Decide during implementation whether to ship them in this
  change or keep the glyph mapping identical to minimize E2E churn.
- **`doneWorking` loses `replyAfterStop`'s title/placeholder** (keeps `summary`);
  the viewer renders a default reply box. Accepted as a minor loss.
