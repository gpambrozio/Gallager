# Apple-Intelligence check for premature `Stop` hooks

**Issue:** #644
**Date:** 2026-07-11
**Status:** Approved

## Problem

Claude Code now sometimes sends a `Stop` hook while it is *still working* — paused,
waiting on a background task or scheduled cron to wake it back up. The Stop payload
carries two arrays, `background_tasks` and `session_crons`, that are non-empty when
work is in flight ([hook docs](https://code.claude.com/docs/en/hooks#stop-input)).

But non-empty arrays alone do **not** prove Claude is still running: it may genuinely
be done while a background task is merely pending termination. Today Gallager maps
every message-bearing `Stop` to `.doneWorking`, so these premature Stops flip a
mid-task session to "Done" and fire a spurious "done" notification.

## Goal

When a `Stop` arrives **with in-flight background work**, use the on-device Apple
Intelligence model (Foundation Models framework) to judge whether Claude's last
assistant message reads like a genuine wrap-up or like it is still waiting for
something to finish. Suppress the premature "Done" when it reads as still-waiting.

## Behavior

On a `Stop` hook:

1. If the setting is **off**, or the payload has **no** in-flight background work
   (`background_tasks` and `session_crons` both empty/absent), or there is no
   `last_assistant_message` → **unchanged** current behavior (`.doneWorking`).
2. Otherwise run the last assistant message through the classifier:
   - **`.finished`** → normal behavior: `.doneWorking(summary:)` + the usual
     notification.
   - **`.stillWaiting`** → **suppress**: emit a `.working` state (spinner), **no**
     notification, **no** app actions. Claude's real final Stop (fired when the
     background task completes, with empty arrays) then legitimately marks it done.
3. Any failure or unavailability (device ineligible, Apple Intelligence off, model
   not downloaded, macOS < 26, decode/inference error) → classifier returns
   `.finished` → fall back to current behavior. **Fail-safe:** we never get *stuck*
   because of the AI; the worst case is the pre-existing premature-Done.

### Product decisions (locked with the user)

- **Setting:** on by default, per-agent toggle to disable (Settings → Agents →
  Claude Code).
- **Suppressed-Stop UX:** keep the normal "Working" spinner — no distinct sub-state.
- **No safety net:** if the AI is wrong and no further Stop ever arrives, the session
  stays "Working"; we rely on Claude's next Stop plus the existing pane-scan idle
  detection. A timeout fallback is explicitly out of scope for v1.

## Architecture

The whole decision lives in the **Claude core** (`ClaudeCodePluginCore`), the single
async ingress point that already parses hooks and already drops message-less Stops.
It stays out of the agent-blind `PluginEventDispatcher`, which must not learn
Claude-specific `background_tasks` semantics.

```
IngressFrame
  → ClaudeCodePluginCore.handleIngress   (async; NEW false-stop branch here)
      → HookAction.from(jsonData:)        (StopBody now carries the arrays)
      → [background work? setting on? message?] → StopCompletionClassifier.classify
          → .stillWaiting → build a .working PluginEvent (no notification)
          → .finished     → fall through to ClaudeCodeTranslator.translate (.doneWorking)
```

### 1. Data model — `HookModels.swift`

Add to `StopBody`:

```swift
public let backgroundTasks: [StopBackgroundItem]?
public let sessionCrons: [StopBackgroundItem]?

/// True when the Stop payload reports any in-flight background task or scheduled
/// cron — the signal that this Stop *might* be premature.
public var hasInFlightBackgroundWork: Bool {
    !(backgroundTasks?.isEmpty ?? true) || !(sessionCrons?.isEmpty ?? true)
}
```

`StopBackgroundItem` is a **presence-only** permissive decodable — an empty
`init(from:) {}` that reads no keys, so it decodes any element shape and can never
break parsing when Claude changes the element schema. We only need the array counts.

- CodingKeys: `background_tasks`, `session_crons`.
- Synthesized `Decodable` + optional properties → `decodeIfPresent` semantics, so
  older payloads (no arrays) still decode. Update the memberwise `init` (default nil).

### 2. Setting — `ClaudeCodeSettings.swift`

Add `detectFalseStops: Bool` (key `detect_false_stops`), **default `true`**; wire into
the init, custom `init(from:)` (`decodeIfPresent … ?? true`), and memberwise init.

### 3. Classifier service — new files in `ClaudeCodePluginCore`

`ClaudeCodePluginCore` already links `Dependencies` + `DependenciesMacros`.

```swift
public enum StopCompletion: Sendable, Equatable { case finished, stillWaiting }

@DependencyClient
public struct StopCompletionClassifier: Sendable {
    /// Returns `.finished` when it cannot decide, so behavior falls back to
    /// honoring the Stop.
    public var classify: @Sendable (_ message: String) async -> StopCompletion = { _ in .finished }
}

extension StopCompletionClassifier: DependencyKey {
    public static let liveValue = StopCompletionClassifier(
        classify: { await FoundationModelsStopClassifier.classify(message: $0) }
    )
    public static let testValue = StopCompletionClassifier()   // always .finished
}
```

`FoundationModelsStopClassifier` (same module, `#if canImport(FoundationModels)` +
`@available(macOS 26, iOS 26, *)`):

- Guard `SystemLanguageModel.default.availability == .available`, else `.finished`.
- `LanguageModelSession(instructions:)` with **static** instructions describing the
  classification task.
- `session.respond(to:generating:)` with a `@Generable` verdict struct exposing a
  single `Bool` (`stillWaiting`), plus `@Guide` description.
- The untrusted assistant message is placed in the **prompt as data**, never in the
  instructions (prompt-injection hygiene). Worst case of a manipulated message is a
  wrong verdict, which is low-stakes (keeps working / marks done).
- `do/catch` around the call → `.finished` on any error.

### 4. Ingress wiring — `ClaudeCodePluginCore.swift`

Inject `@Dependency(StopCompletionClassifier.self) private var stopClassifier`.

Immediately after the existing message-less-Stop drop, before `translate(...)`:

```swift
if
    settings.detectFalseStops,
    case let .stop(stopBody) = action,
    stopBody.hasInFlightBackgroundWork,
    let message = stopBody.lastAssistantMessage,
    await stopClassifier.classify(message: message) == .stillWaiting {
    await log(.info, "Suppressing premature Stop — message reads as still waiting on background work")
    return workingEvent(for: stopBody, frame: frame)
}
```

`workingEvent(for:frame:)` builds a minimal `PluginEvent` directly: `state: .working`,
`notification: nil`, `appActions: []`, `projectPath = frame.context["CLAUDE_PROJECT_DIR"]
?? stopBody.cwd`, `permissionMode: stopBody.permissionMode`, pane from the frame.
Emitting `.working` explicitly (rather than dropping the frame) guarantees the spinner
regardless of the prior state and is directly assertable in tests.

### 5. UI — `AgentsSettingsView.swift`

A Claude-only toggle in the **Behaviour** section (mirroring the existing Codex-only
`exportTelemetry` toggle):

```swift
if pluginID == "claude-code" {
    Toggle("Verify completion with Apple Intelligence", isOn: $detectFalseStops)
        .onChange(of: detectFalseStops) { _, _ in persist() }
        .accessibilityIdentifier("agentDetectFalseStops-\(pluginID)")
        .help("When Claude stops while a background task or cron is still running, use "
            + "on-device Apple Intelligence to check whether the last message really reads "
            + "as finished. Requires Apple Intelligence (macOS 26+).")
}
```

Add `@State private var detectFalseStops = true` and wire it in `loadSettings()`,
`encodeSettings()` for the `claude-code` case.

### 6. Testing — `ClaudeCodePluginCoreTests`

Wrap `makeCore()` + `handleIngress` in
`withDependencies { $0[StopCompletionClassifier.self] = … }` so the core (constructed
inside the operation) captures the overridden classifier. Cases:

- Stop + non-empty `background_tasks` + verdict `.stillWaiting` → event `state == .working`,
  `notification == nil`, `appActions.isEmpty`.
- Stop + non-empty arrays + verdict `.finished` → `.doneWorking`.
- Stop + **empty** arrays → classifier never consulted → `.doneWorking` (assert with a
  classifier stub that would `fatalError`/flip if called, or a call-count spy).
- Setting off (`detect_false_stops: false` in env settings) + non-empty arrays →
  `.doneWorking`.
- `StopBody` decode: arrays present/absent, `hasInFlightBackgroundWork` true/false.

## Non-goals

- No timeout / safety-net auto-Done.
- No distinct "waiting on background work" UI sub-state.
- No prewarming of the model (documented as possible future work — the classify call
  runs inside the serial ingress FIFO, so a suppressed Stop briefly stalls other
  sessions' hook processing; acceptable given how rarely this path fires).
- No iOS behavior change (the Mac receives hooks; the model call simply no-ops where
  Foundation Models is unavailable).

## Files touched

- `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/HookModels.swift` — `StopBody`.
- `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeSettings.swift` — setting.
- `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/StopCompletionClassifier.swift` — new.
- `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodePluginCore.swift` — wiring.
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/AgentsSettingsView.swift` — toggle.
- `ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/…` — tests.
- Docs: `docs/plugins/claude-code.md` (+ CLAUDE.md reference line if warranted).
