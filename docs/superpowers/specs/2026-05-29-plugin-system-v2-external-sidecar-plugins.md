# Coding-Agent Plugin System — v2 (external sidecar plugins)

Status: Design — additive on top of `2026-05-29-plugin-system-v1-in-process.md`
Date: 2026-05-29
Author: Brainstormed with Claude

> **Prerequisite:** read `2026-05-29-plugin-system-v1-in-process.md` first. v2 changes **nothing**
> in v1's contract — it adds a second way to *satisfy* that contract. Section numbers like "v1 §4"
> refer to the v1 document.

> **Reconciled with the implemented v1 (2026-06-22):** this spec was first drafted alongside v1's
> design, then revised to match the v1 contract as actually shipped — the OTEL telemetry work
> (issues #597/#602) and the move of `install()` onto the host agent's own plugin-marketplace. The
> contract shape that crosses the seam (`PluginCore` / `PluginHost` / `PluginEnv` / `PluginEvent`),
> the ingress story (§6), and the registry/distribution notes (§8) below reflect the current code,
> not the original draft.

## 1. Goal

Let third parties ship plugins for arbitrary coding agents (OpenCode, Aider, Cline, future agents)
**without modifying Gallager, iOS, or the relay** and **without recompiling Gallager** — the second
promise from v1 §1. A third-party plugin is an **out-of-process sidecar** process distributed by
URL, described by a **manifest**, and supervised by Gallager.

The entire v2 addition lives **behind the `PluginCore` seam** (v1 §4). The dispatcher, the app-owned
hook ingress socket (v1 §8), the OTLP telemetry receiver (§6.1), `PluginEvent` (v1 §5),
`AgentResponseRequest` (v1 §7), the iOS surface, and the existing CLI verbs are **untouched**.
Bundled first-party plugins **stay in-process**; only newly-installed third-party plugins are
sidecars. The two tiers coexist in one registry.

The headline win v2 buys: **crash isolation.** A sidecar crash no longer takes down Gallager (the
v1 §13 accepted-crash trade-off is lifted for out-of-process plugins). That, plus untrusted-code
distribution, is the entire reason the out-of-process machinery exists — and the reason it is
*deferred* out of v1.

## 2. The seam: `SidecarPluginCore`

v2 adds exactly one new `PluginCore` conformer to the agent-blind runtime:

```swift
/// A PluginCore that fronts an out-of-process sidecar. It conforms to the SAME
/// protocol every in-process core does, so the dispatcher/registry never know a
/// plugin is out-of-process. Each PluginCore method marshals its SERIALIZABLE
/// arguments to a JSON-RPC request over the sidecar's stdio (see "Marshalling
/// at the seam" below for the two that are not a plain serialization); inbound
/// JSON-RPC notifications from the sidecar are translated into PluginHost calls.
actor SidecarPluginCore: PluginCore {
    init(manifest: PluginManifest, layout: PluginRootLayout, supervisor: SidecarSupervisor)
    // initialize → "initialize" RPC; handleIngress → "translate_event" RPC;
    // deliverResponse → "deliver_response" RPC; refreshProjects → "refresh_projects";
    // commandForLaunch → "command_for_launch"; install / uninstall / installStatus
    // (all taking configRoot), applySettings, shutdown → the same-named RPCs.
    // Inbound notifications set_projects / emit_event / send_text / send_keys / log
    // → host.setProjects / host.emit / host.sendText / host.sendKeys / host.log;
    // the inbound REQUEST agent_panes → host.agentPanes() and returns its [String].
}
```

`PluginRegistry` (v1 §4.1) gains a second construction path. For a manifest with
`runtime: "sidecar"` it builds a `SidecarPluginCore`; for a bundled manifest it looks up the
compile-time factory as before:

```swift
func makeCore(for manifest: PluginManifest) -> any PluginCore {
    switch manifest.runtime {
    case .inProcess:  return factories[manifest.id]!()          // v1 bundled path
    case .sidecar:    return SidecarPluginCore(manifest: manifest, layout: layout,
                                               supervisor: SidecarSupervisor(manifest, layout))
    }
}
```

**Marshalling at the seam** (the parts that are *not* a plain Codable serialization):

- **`initialize(_ env:host:)` — the `host` argument is NOT marshaled.** A `PluginHost` is a live
  in-process callback object, not `Codable`; it cannot cross a process boundary. `SidecarPluginCore`
  receives the app's `PluginHost` at *its own* (in-process) construction/`initialize`, **retains it**,
  and synthesizes every callback from the sidecar's inbound messages: the supervisor's read loop
  decodes each one and invokes the retained host (`set_projects → host.setProjects`,
  `emit_event → host.emit`, `send_text → host.sendText`, `send_keys → host.sendKeys`, `log → host.log`).
  Only `env` crosses the wire on the `initialize` RPC; **the sidecar process never sees a `PluginHost`.**
- **`host.agentPanes()` is the one inbound message that is a request, not a notification.** Every
  other `PluginHost` method is fire-and-forget, but `agentPanes() async -> [String]` returns a value
  to the sidecar. The transport therefore carries a **Sidecar→App request** lane alongside the
  notification lane (§3): the sidecar sends an `agent_panes` request, the read loop calls
  `host.agentPanes()`, and the `[String]` result is written back as the response. A sidecar that
  never asks for panes never exercises it.
- **`PluginEnv` carries two URL fields the sidecar needs at `initialize`:** `marketplaceSource`
  (the on-disk dir handed to the agent's own marketplace installer) and `otlpReceiverEndpoint` (the
  Mac-local OTLP receiver, §6.1). Both are `Codable` and marshal 1:1. For a sidecar `marketplaceSource`
  resolves inside the sidecar's own plugin dir, not the app bundle.
- **`Data` parameters (`PluginEnv.settings`, `applySettings(_ raw:)`) cross the wire as a nested JSON
  value**, not a base64 blob or a double-encoded string. `settings.json` is already JSON, so the
  transport embeds it as a JSON object and the sidecar reads it directly — no double encode/parse.
- **`installStatus(configRoot:)` returns `PluginInstallStatus`** (`installed(version:)` /
  `notInstalled` / `agentUnavailable`), not a bool; `install` / `uninstall` / `installStatus` all
  take an optional `configRoot`. All three marshal 1:1.
- **`PluginEvent` is marshaled whole, in its current shape:** a single `state: AgentState?` (the open
  response form rides `AgentState`'s `awaiting*` cases via `AgentState.openForm`), plus `notification`,
  `appActions`, `tmuxPane`, `projectPath`, and `permissionMode` — there is no separate `working` /
  `attention` / `responseRequest`. It is `Codable` and crosses on `translate_event` / `emit_event`
  unchanged.
- Everything else (`PluginEnv` minus `host`, `IngressFrame`, `AgentResponse`, `LaunchCommand`,
  `InstallResult`, `SettingsResult`, `AgentState` / `AgentResponseRequest`) is already `Codable` and
  marshals 1:1. `AgentResponseRequest` / `AgentResponse` remain the closed 5-case vocabularies (v1 §7).

That is the whole architectural change. Everything below is the supporting machinery
`SidecarPluginCore` needs: a transport, supervision, a distribution flow, and a manifest that
describes an untrusted binary.

## 3. The transport (JSON-RPC over stdio)

The sidecar speaks JSON-RPC over its stdin/stdout, LSP-style framing: `Content-Length:` header +
blank line + JSON body, full duplex. The App→Sidecar request set and the Sidecar→App message set are
**exactly the `PluginCore` / `PluginHost` surface, serialized** — there is no new semantic
vocabulary, only an encoding of the contract. Sidecar→App traffic is mostly one-way *notifications*
(`set_projects` / `emit_event` / `send_text` / `send_keys` / `log`), plus the single *request*
`agent_panes` that expects a `[String]` response (the one `PluginHost` method that returns a value,
§2) — so the read loop must correlate responses in **both** directions, not just app→sidecar.

This is the one genuinely new wire protocol v2 introduces — a hand-rolled byte-level transport
across a process boundary, which is exactly the kind of code that hides subtle framing, lifecycle,
and concurrency bugs. (The existing ingress listener is a hand-rolled POSIX `AF_UNIX` server,
`Plugins/IngressSocketServer.swift`, not an `NWListener` — a useful in-repo reference for the same
quality bar.) The following are **hard requirements**, not suggestions:

| Hazard (low-level IPC pitfall) | Required handling |
|---|---|
| Unbounded header growth (hostile peer never sends `\r\n\r\n`) | Cap header at 16 KiB; throw `malformedHeader` past the cap. |
| Unbounded / huge `Content-Length` → `reserveCapacity` OOM | Reject `Content-Length` above a 32 MiB body cap **before** allocating. |
| Unaligned `Data` load of the length/int | Use `loadUnaligned(as:)`; never `load(as:)` on a `Data` buffer. |
| `FileHandle.AsyncBytes` does not deliver pipe bytes until the writer closes | Use a `readabilityHandler`-based byte stream, not `AsyncBytes`, for a long-lived pipe. |
| Per-byte `yield` into an unbounded `AsyncStream` | Yield **chunks**, bounded buffering. |
| Continuation registered *after* the frame is written → lost response | Register the pending-request slot **synchronously before** writing the request frame. |
| Fire-and-forget `Task` for inbound notifications → out-of-order delivery | Await the delegate **inline** in the read loop; preserve wire order (project rule: no fire-and-forget for ordered sends). |
| Synchronous `FileHandle.write` blocks the actor on a full stdin pipe | Offload writes to a per-connection serial `DispatchQueue` via a continuation; suspend the actor across I/O. |
| Parent retains child-inherited pipe ends → reader never EOFs | Close the parent's copies of the child-inherited pipe ends immediately after spawn. |

Per-RPC **timeouts** are mandatory (default 30 s; shorter for `initialize`). A timed-out RPC
surfaces an error to the caller and never hangs the app.

> **Lesson carried forward:** do **not** add a separate per-sidecar ingress socket, a `health`
> heartbeat, or a `detect_pane`-by-default. Ingress stays on the *one app-owned socket* (§6); crash
> detection is process-exit + RPC-timeout (§5); rich pane detection is an *optional* capability (§7).

## 4. Manifest (v2 additions)

v2 reads the fields v1 reserved (v1 §10). A third-party manifest:

```json
{
  "schema_version": 1,
  "id": "opencode",
  "display_name": "OpenCode",
  "short_name": "OpenCode",
  "version": "1.2.0",
  "publisher": "opencode.ai",
  "manifest_url": "https://opencode.ai/plugins/gallager.json",
  "bundle_url": "https://opencode.ai/plugins/opencode-1.2.0.zip",
  "bundle_sha256": "<hex>",
  "runtime": "sidecar",
  "sidecar": { "executable": "bin/sidecar", "args": [] },
  "process_names": ["opencode"],
  "capabilities": { "rich_pane_detection": false, "modal_prompts": false },
  "ui": { "icon": "assets/icon.png", "color": "#3a7fcb" }
}
```

- `runtime`: `"inProcess"` (bundled, v1) or `"sidecar"` (third-party, v2). Bundled manifests may
  omit it (defaults `inProcess`).
- `bundle_sha256` is **required** for `https://` bundles, ignored for bundled plugins.
- `capabilities` advertises **optional** sidecar features the app may use (§7). Absent ⇒ false.
- `signature` is **reserved** for a future publisher-identity scheme; v2 does not verify it.

The shipped `Manifest.swift` decodes only the v1 fields plus `runtime` — its `CodingKeys` currently
**excludes** `sidecar`, `manifest_url`, `bundle_url`, `bundle_sha256`, `publisher`, `capabilities`,
and `signature`, matching v1's "reserved" intent. v2 adds them, plus the `sidecar` / `capabilities`
sub-structs, to the model. `runtime` (`inProcess` / `sidecar`, tolerant-decoded to `.inProcess` when
absent) is the only one already decoded — which is what lets `makeCore` switch on it today.

## 5. Supervision

`SidecarSupervisor` (introduced here, where the process boundary makes it earn its keep) manages one
process per enabled sidecar plugin.

1. **Spawn**: locate `bin/sidecar`, spawn with `plugin_root` / `state_dir` / `app_version` **and
   `GALLAGER_INGRESS_SOCK`** (the app-owned hook ingress socket path, §6) in env. That env var is
   **new in v2** — v1's bundled bridges hardcode the socket path, so introducing it (and having the
   sidecar's `install()` consume it) is net-new work, not reuse. Stdin/stdout piped for JSON-RPC;
   **stderr → `~/.gallager/state/plugins/<id>/logs/sidecar.log`** (size-rotated, 5 MB). Close the
   parent's child-inherited pipe ends immediately (§3).
2. **Initialize**: `initialize` RPC, 10 s timeout. Timeout / non-success ⇒ **failed-init**, plugin
   stays disabled, error surfaced in Settings, no retry until user action.
3. **Crash detection**: `Process.terminationHandler` is the authoritative liveness signal for a
   local child; route an unexpected exit through the crash counter. The per-RPC timeout (§3) covers
   a wedged-but-alive sidecar that a caller hits. **No 30 s heartbeat** — it was redundant with
   process-exit and added churn. (Optional, §5.1.)
4. **Crash policy** (per-plugin counter, 60 s sliding window): 1st/2nd/3rd crash ⇒ restart with
   1 s / 2 s / 4 s backoff; **4th+ ⇒ auto-disable**, banner with the last 50 stderr lines + a
   "Re-enable" button, no further auto-restart. Guard against double-spawn: a backoff restart only
   fires if still in `.crashed`; cancel any pending backoff on an explicit re-enable.
5. **Quit / disable**: `shutdown` RPC (3 s deadline) → SIGTERM → SIGKILL after 5 s. Resume the
   wait via the `terminationHandler`, not by polling `isRunning`.

On restart the supervisor re-`initialize`s; the sidecar rescans and re-pushes `set_projects`. The
app keeps the previous project list visible until fresh data arrives (v1 §12, "stale beats empty").

### 5.1 Optional liveness probe

A sidecar can be **alive but wedged** (infinite loop) with no RPC in flight, which process-exit
won't catch. If that proves to be a real failure mode for some third-party agent, add an
**optional** `health` probe gated by a manifest capability — not a mandatory 30 s heartbeat for
every plugin. Default off.

## 6. Ingress for sidecars (still one hook socket)

v2 adds **no** new hook ingress socket. Hook-based third-party agents use the **same** app-owned
socket as v1 (v1 §8). At spawn the supervisor passes `GALLAGER_INGRESS_SOCK` (§5 step 1); the
sidecar's `install()` reads it and bakes that path + its own `plugin_id` into the host agent's hook
config. The bridge then fires for any session — Gallager-launched or manual — and writes one
self-identifying frame. The app routes by `plugin_id` to `SidecarPluginCore.handleIngress`, which
marshals the frame to the sidecar as a `translate_event` RPC.

**How this differs from the bundled bridges (v2 work, not reuse).** v1's first-party install does
*not* write `hooks.json` directly: `ClaudeCodePluginCore.install()` runs `<agent> plugin marketplace
add <marketplaceSource>` (`ClaudeCodeCLIInstaller.swift:31`), and the bundled `hook.py` **hardcodes**
`~/.gallager/state/ingress.sock` (`plugin/gallager/scripts/hook.py:9`) — there is no
`GALLAGER_INGRESS_SOCK` anywhere today. A sidecar's `install()` must therefore *template* the
spawn-supplied socket path into whatever hook mechanism its agent uses, rather than ship a static
script. The env-sourced path is also what would let the E2E `--gallager-state-root` isolation
redirect a sidecar's socket per scenario — a capability **to be added** with the sidecar bridge.
Today E2E hook ingress redirects by having the test driver write frames directly to the overridden
socket path (`macSendRawHookPayload`), which bypasses the bridge entirely.

Non-hook agents (streaming firehose, transcript tail, MCP/long-lived RPC) need no socket frame: the
sidecar attaches to its source internally and pushes events autonomously via the `emit_event`
notification (→ `host.emit`). Both ingress styles converge on the same `PluginEvent` envelope. The
language-agnostic bridge contract (the length-prefixed `{ plugin_id, context, payload }` frame) is
unchanged from v1 and is the durable external boundary a third party builds against.

### 6.1 Telemetry ingress — the second app-owned channel

There is a **second** app-owned ingress surface besides the hook socket: a loopback OTLP/JSON
receiver on `127.0.0.1:4318` (`POST /v1/metrics`, `/v1/logs`) added for agent telemetry (issues
#597/#602, `Telemetry/OTLPReceiver.swift`). It ingests **outside `PluginCore`** — telemetry never
passes through `handleIngress` / `PluginEvent`; the receiver parses OTLP and pushes results straight
into session state through its own handlers. So "one socket" describes the *hook* path; telemetry is
a parallel, app-owned, agent-blind channel.

For sidecars this is mostly free: a third-party agent points its OTLP exporter at the **same**
receiver — Claude reads `OTEL_*` env vars the host injects into the pane; an agent that doesn't
(Codex) is pointed there via `PluginEnv.otlpReceiverEndpoint`, handed to the core at `initialize`
and marshaled like the rest of `env`. No per-plugin telemetry socket is introduced, which keeps
faith with the one-socket philosophy. **Caveat to verify before relying on it:**
`OTLPTelemetryAccumulator` must be agent-blind enough to parse a non-Claude/Codex agent's OTLP, or a
sidecar's telemetry is silently dropped; if an agent's attributes don't fit, adapting it is a v2.x
follow-on, not a blocker for the hook path.

## 7. Optional sidecar capabilities

These are genuinely sidecar-shaped features deferred out of v1; v2 adds them as **opt-in via the
manifest `capabilities` block**, gracefully degrading when absent (a sidecar that doesn't implement
an RPC returns `MethodNotFound`, treated as "feature unsupported").

**They attach without touching the v1 `PluginCore` protocol.** They are *not* added as `PluginCore`
methods — they are `SidecarPluginCore`-only RPCs exposed through a sidecar-specific extension. The
caller checks the concrete type / advertised capability before using them (e.g. `TmuxService` asks
"is this core a rich-detection sidecar that declared `rich_pane_detection`?" and calls the extra RPC
only then). The agent-blind dispatcher and the `PluginCore` protocol stay exactly as v1 defines them;
`process_names` matching remains the fallback and the *only* mechanism any in-process plugin uses.

- **`rich_pane_detection`**: a `detect_pane(paneInfo) -> { matches, project_path?, session_id? }`
  RPC, called per discovered pane only for plugins that declare it. Falls back to `process_names`
  matching (v1 §6) otherwise. For agents whose process name is ambiguous or shared.
- **`modal_prompts`**: a `prompt_user(...)` notification asking Gallager to surface a Mac modal
  (e.g. "OpenCode needs you to approve a trust prompt"). Rare; off by default.

## 8. Distribution

This is the bulk of net-new v2 code and the highest-risk surface (untrusted code from the network).
All of it was correctly absent from v1.

### 8.1 Registry

`~/.gallager/registry.json` (v1 §9) carries `source: "url"` entries alongside `source: "bundled"`.
Third-party installs land in `~/.gallager/plugins/<id>/` (the directory v1 reserved).

**This file does not exist yet — it is net-new work.** Only `GallagerPaths.registryPath`
(`Plugins/GallagerPaths.swift:53`) is defined today; there is no Codable registry model and no
load/save code, and the live registry is in-memory + bundled manifests read from the app bundle at
launch. v2 must build the on-disk store **and** the `source` field for *both* tiers, not merely
extend an existing file.

### 8.2 Install flow

1. Settings → Plugins → **Add Plugin from URL…**; user pastes an `https://` manifest URL.
   Reject non-`https` schemes up front.
2. `HTTPS GET` the manifest with a **size cap** (1 MiB), streamed; validate well-formedness and
   `schema_version`. **Sanitize `manifest.id`** against a strict allow-list (`^[a-z0-9][a-z0-9._-]*$`,
   no `..`, ≤128 chars) **before** it is ever used to build an on-disk path.
3. Show a trust sheet: display name, publisher, version, source URL, bundle size + sha256, and an
   explicit **"This plugin runs arbitrary code on your Mac"** warning. Buttons: Cancel / Trust and
   Install.
4. On confirm, `HTTPS GET` `bundle_url` into a temp file, **streamed with a hard byte ceiling**
   (e.g. 50 MiB) enforced mid-stream, drained in chunks (not byte-by-byte). Verify SHA-256 against
   the manifest; mismatch ⇒ abort with a specific error.
5. Unpack the zip into `~/.gallager/plugins/<id>.installing/`. **After unpack, reject zip-slip /
   traversal**: enumerate every extracted entry and fail if any
   `standardizedFileURL.resolvingSymlinksInPath()` escapes the staging dir (`/usr/bin/unzip` exits 0
   even when it skips traversal entries, so the exit code is not sufficient). Validate the tree:
   manifest at root, `bin/sidecar` present + executable, declared assets present.
6. Atomic rename `<id>.installing/` → `<id>/` (swap any existing `<id>/` via a `.replacing/` step).
7. Append the registry entry via temp-file + rename.
8. Construct `SidecarPluginCore`, spawn, `initialize`. On failure mark **failed-init** with the
   error; leave files in place for retry.

Heavy steps (download, unzip + `waitUntilExit`) run **off the MainActor**; the UI only awaits the
result.

### 8.3 Update flow

On launch and on manual "Check for updates": for each `source: "url"` plugin, `HTTPS GET` the
manifest with `If-None-Match` / `If-Modified-Since`. If `version` is newer, surface an "Updates
available" badge — **never auto-install**. "Update" reruns the install flow; the trust prompt is
skipped (same manifest URL already trusted), but **re-appears with a "Source changed" warning** if
`bundle_url`'s host changes.

### 8.4 Uninstall flow

Confirm → `core.uninstall()` (best-effort) → `shutdown` → SIGTERM/SIGKILL → delete
`~/.gallager/plugins/<id>/` → prompt to also delete `~/.gallager/state/plugins/<id>/` (default yes)
→ remove the registry entry. Bundled plugins cannot be uninstalled (they can be disabled, v1 §14).

### 8.5 Folder-drop (power-user)

A folder dropped into `~/.gallager/plugins/<id>/` with a valid `runtime: "sidecar"` manifest and an
executable `bin/sidecar` is recognized on launch (discovered, registry entry added) **without**
download or hash verification — it is local, the user put it there. The same `manifest.id`
sanitization and tree validation (§8.2 steps 2, 5) still apply.

## 9. Security model & sandboxing (honest scope)

v2 ships **transport-level trust only**: `https://` manifest + bundle fetch, SHA-256 bundle
**integrity** pinning, an explicit trust prompt, and the install-time path/zip-slip hardening above.
Be precise about what the hash buys: **SHA-256 pins the bundle to its own manifest (integrity, not
authenticity).** With no publisher signature, whoever controls the manifest URL controls *both* the
manifest *and* the hash it will accept — so a compromised manifest host can serve a malicious bundle
with a matching hash. The hash defends against bundle tampering *in transit / at the bundle host*,
not against a malicious manifest. **Trust derives entirely from the user vetting the source URL.**
**A v2 third-party sidecar runs as the user with full permissions.** There is no code signing /
publisher identity verification, and no OS-level confinement.

macOS App Sandbox / seatbelt confinement — generating a sandbox profile from the manifest's
`capabilities` block so a plugin can only touch its `state_dir` and the host agent's files — is the
real mitigation for untrusted code and is a **deliberate follow-on (v2.x/v3), not part of initial
v2.** The manifest's `capabilities` block is shaped to drive it later; the `signature` field is
reserved for publisher identity. Do not represent v2 as safe to run untrusted plugins from
arbitrary sources — represent it as "trusted-on-install, hash-pinned, runs with your permissions."

## 10. CLI additions

v2 adds the install/lifecycle verbs deferred from v1 §14:

| Command | Description |
|---|---|
| `gallager plugin install <https-url> [--yes]` | run the install flow; print the trust details, read y/n from stdin unless `--yes`; non-zero on rejection/failure. Enforce `https://`. |
| `gallager plugin remove <id> [--keep-state\|--delete-state]` | uninstall; bundled plugins refuse. |
| `gallager plugin update [<id>] [--apply]` | check (no id ⇒ all); `--apply` installs. Without it, print which versions are newer. |

`plugin call <id> <method>` (v1) now also reaches sidecars: the CLI forwards the method string over
the supervisor rather than switching on a method enum. Note the current dispatch
(`PluginRegistry.callCore`, `Plugins/PluginRegistry.swift:218`) only recognizes a small allow-list —
`refreshProjects`, `installStatus`, `install`, `uninstall` — so to drive arbitrary sidecar RPCs from
the CLI, widen that allow-list (or make it a passthrough) as part of this work.

## 11. Error handling (out-of-process rows)

These rows are meaningful only with a child process — they are v2 additions to v1 §13:

| Failure | Response |
|---|---|
| Manifest invalid (install) | Reject before unpacking; leave state clean; name the offending field. |
| Sidecar binary missing / non-executable | failed-init; no spawn; surfaced in Settings. |
| RPC `MethodNotFound` | "feature unsupported"; degrade (e.g. no `detect_pane` ⇒ `process_names`). |
| Malformed JSON frame from sidecar | log + drop the frame; keep the connection; if persistent across N frames, supervisor restarts the process. |
| `install` RPC fails (agent binary not on PATH) | surface in Settings; offer retry + manual-install instructions. |
| Event for a disabled plugin | drop silently with a debug log (disable race). |

## 12. Testing

v2 adds the test scaffolding the in-process v1 doesn't need:

- **`EchoPlugin` as a real sidecar executable fixture** (built as part of the test target, not the
  app): proves the full out-of-process pipeline end-to-end — process spawn, JSON-RPC transport,
  supervision, ingress over the app-owned socket, `set_projects` push, response-request round-trip
  with a configurable delivery script. (A DEBUG-only **in-process** `EchoPluginCore` already exists
  and suffices for v1's contract tests; the executable fixture is the net-new piece, earning its keep
  only once there is a process boundary to exercise.)
- **`SidecarPluginCoreTests`**: a `MockSidecarProcess` verifies the marshalling both directions
  (PluginCore method → RPC; notification → PluginHost callback).
- **E2E**: `PluginCrashRestartScenario` (sidecar aborts on a control payload; supervisor restarts;
  next event flows), `PluginCrashLoopDisableScenario` (4 crashes in 60 s ⇒ disabled banner),
  `PluginResponseRequestScenario` (round-trip back to the sidecar). These are the scenarios v1
  marked as v2-only.

Still **out of automated scope** (manual smoke only): real third-party HTTPS install from a live
URL (needs network in CI), the update flow, and real `claude`/`codex`/`opencode` binary interaction.

## 13. Wire compatibility & rollout

**v2 needs no new flag-day for iOS or the relay.** The iOS wire format (`agent_session_status`,
`agent_response_request/submission`, `plugin_presentations`) already carries `plugin_id` and is
plugin-blind — a sidecar plugin is indistinguishable to iOS from a bundled one. v2 is a **Mac-app
capability addition** (the registry's second construction path + supervision + distribution); it
does not change anything an iOS or relay peer parses, so no `VersionCompatibility` bump is required
for v2 itself (it sits at `"2.0"` on both sides from the v1 flag-day and stays there). A paired Mac
on v1 and one on v2 interoperate with the same iOS app; the v2 Mac just has more plugins available.

## 14. Migration from v1

Nothing breaks. On upgrading a Mac from v1 to v2:

- Bundled plugins (`source: "bundled"`, `runtime: inProcess`) keep running **in-process** exactly
  as in v1. They are not converted to sidecars.
- The registry, settings, ingress socket, log files, and CLI are unchanged; v2 only adds the ability
  to install `source: "url"`, `runtime: "sidecar"` entries.
- The first sidecar plugin a user installs is the first time the supervision / transport code runs
  in production. Until then, a v2 build behaves identically to v1.

## 15. Non-goals (v2)

- Code signing / verified publisher identity (manifest leaves room; not built).
- OS-level sandbox confinement of sidecars (the real untrusted-code mitigation; a v2.x/v3 follow-on,
  capabilities-driven).
- In-app discovery marketplace / plugin browser (v2 install is "paste a URL").
- Hot-reload of sidecar code without a process restart.
- Cross-plugin event correlation; multiple sidecar instances per plugin.
- Converting bundled first-party plugins to sidecars (they stay in-process; isolating them is
  pointless — they're as trusted as the app).
