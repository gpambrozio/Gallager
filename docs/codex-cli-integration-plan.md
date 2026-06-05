# Codex CLI Integration Plan

Status: ✅ **Shipped** — Phases 0–4 landed via [PR #549](https://github.com/gpambrozio/ClaudeSpy/pull/549) on branch `feat/codex-cli-integration`.
Last updated: 2026-05-22

> **Upstream source:** Codex CLI is open source at <https://github.com/openai/codex> (Rust workspace under `codex-rs/`). When behavior, hook payload shape, theme handling, or terminal-background detection is ambiguous, read the upstream code directly — Codex's release cadence is fast and the published docs lag. Useful entry points:
> - `codex-rs/tui/` — TUI renderer, status line, "Working" indicator color resolution
> - `codex-rs/tui/src/render/highlight.rs` — `[tui].theme` (syntect) wiring
> - `codex-rs/app-server-protocol/` — full event firehose schema (richer than hooks)
> - `codex-rs/core/src/hooks/` — hook event names, payload shape, exit-code semantics
>
> The sections below are kept as the historical research / planning record. For the current code shape, see:
> - `docs/architecture.md` — `CodingAgent` abstraction in the service overview
> - `docs/services-reference.md` — `CodingAgent`, `CodexProjectScanner`, `CodexPluginInstaller` reference entries
> - `ClaudeSpyNetworking/Models/CodingAgent.swift` — the enum itself
>
> Implementation notes vs. the plan below:
> - **CodexHookInstaller was renamed to `CodexPluginInstaller`**, and install/uninstall now go through `codex plugin install gallager` against a bundled marketplace at `~/.claudespy/marketplaces/gallager/` (instead of writing `~/.codex/hooks.json` directly). The bridge script is shipped via the same `gallager` plugin that backs Claude Code.
> - **Out of scope (deferred):** type renames (`ClaudeProjectInfo` → `AgentProjectInfo` etc.), `codex exec --json` streaming firehose, embedded OpenTelemetry collector, and auto-install on first launch.

## 1. Goal

Add first-class support for OpenAI's **Codex CLI** (`github.com/openai/codex`) alongside the existing Claude Code integration, so that ClaudeSpy can:

- Discover Codex projects on the user's machine the same way it discovers Claude Code projects.
- Auto-launch Codex sessions into managed tmux panes.
- Ingest lifecycle events (SessionStart, PreToolUse, PostToolUse, Stop, etc.) and surface them in the Mac and iOS UIs.
- Correlate a running `codex` process to a tmux pane and a known project.

This is positioned as a **second backend behind a `CodingAgent` abstraction**, not a fork or a parallel app. The app's identity stays "ClaudeSpy" for now; whether to rebrand is out of scope.

## 2. Background: how Claude Code is wired in today

| Concern | File / Mechanism |
|---|---|
| Hook ingestion | `HookServerService.swift:74-116` — local HTTP on port 6111+offset; POST `/api/hooks?projectPath=…&tmuxPane=…` |
| Hook installer | Gallager plugin: `plugin/gallager/hooks/hooks.json` + `plugin/gallager/scripts/hook.py` |
| Project scanner | `ClaudeProjectScanner.swift:14-277` reads `~/.claude.json` + `~/.claude/projects/<encoded-cwd>/*.jsonl` |
| Session model | `ClaudeSession` in `HookModels.swift:24-153`, `ClaudeProjectInfo` in `RelayMessages.swift` |
| Auto-start | `AppCoordinator.swift:798-829` constructs a tmux command with `claudeCommandPath` (default `claude`) |
| Pane correlation | `TmuxService.swift:399-403` walks each pane's process tree for a `claude` descendant |
| Branding lock-in | `ClaudeSession`, `ClaudeProjectInfo`, `ClaudeProjectScanner`, `ClaudeBinaryLocator`, `ClaudeCodeTool`, `ClaudePane`, `.claudeFirst`, `.claudeNotInstalled`, `claudeCommandPath`, hardcoded "Claude Code" notification titles in `HookNotificationExtensions.swift:4-16` |

The hook server itself is **already generic enough** to accept any JSON event payload of the right shape — it does not validate event names against a Claude-specific enum. Most of the porting work is upstream of it.

## 3. Codex CLI: what we found

Surveyed against Codex CLI v0.132.0 (released 2026-05-20). Hooks reached GA on 2026-05-14.

### 3.1 Hook system

Codex has a first-class hook system clearly modeled on Claude Code's. Events:

```
PreToolUse, PermissionRequest, PostToolUse,
PreCompact, PostCompact,
SessionStart, UserPromptSubmit,
SubagentStart, SubagentStop, Stop
```

Mapping to Claude Code:

| Claude Code | Codex CLI | Notes |
|---|---|---|
| `SessionStart` | `SessionStart` | `source ∈ startup\|resume\|clear\|compact` |
| `UserPromptSubmit` | `UserPromptSubmit` | identical |
| `PreToolUse` | `PreToolUse` | identical wire shape |
| `PostToolUse` | `PostToolUse` | identical wire shape |
| `Stop` / `SubagentStop` | `Stop` / `SubagentStop` | identical |
| `PreCompact` | `PreCompact` **+** `PostCompact` | Codex adds a post-compact event |
| `Notification` | **none** — closest is `PermissionRequest` | semantic gap, see §5 |
| `SessionEnd` | **none** | semantic gap — now synthesized by a process-exit monitor (`CodexPluginCore.pollSessionEnds`), see §5 |
| — | `SubagentStart` | new in Codex |

**Wire format:** JSON over stdin, `snake_case` keys, includes `hook_event_name`, `session_id`, `tool_name`, `tool_input`, `transcript_path`, `cwd`, `permission_mode`, `model`. Output JSON also mirrors Claude Code: `hookSpecificOutput.permissionDecision = allow|deny|ask`, exit code 2 + stderr to block, etc.

**Registration:** TOML or JSON, discovered in:
- `~/.codex/hooks.json` or inline `[hooks]` in `~/.codex/config.toml`
- `<repo>/.codex/hooks.json` or inline `[hooks]` in `<repo>/.codex/config.toml` — **only loaded if the project is trusted**
- Plugin bundles: `<plugin>/hooks/hooks.json` when `[features].plugin_hooks = true`

Only `type = "command"` runs today; `type = "prompt"` and `type = "agent"` parse but are no-ops. `async = true` is parsed but ignored.

### 3.2 Configuration & project model

- Global config: `~/.codex/config.toml` (`CODEX_HOME` env overrides `~/.codex`).
- Per-project config: `<repo>/.codex/config.toml` and `<repo>/.codex/hooks.json`, gated by trust.
- **No required project marker file.** `AGENTS.md` is optional and hierarchical (every level from git root to cwd, plus `~/.codex/AGENTS.md`).
- Session transcripts: `~/.codex/sessions/YYYY/MM/DD/rollout-YYYY-MM-DDThh-mm-ss-<uuid>.jsonl`. **Date-partitioned, not project-partitioned.** cwd is recoverable only from the `SessionMetaLine` at the head of each rollout.
- SQLite session index at `~/.codex/state.db` (undocumented schema).
- Resume: `codex resume [--last | <SESSION_ID>]`.

### 3.3 Other surfaces

- **OpenTelemetry**: first-class. `[otel]` in config.toml, OTLP HTTP/gRPC exporters, tool-call counters/histograms. Richer than anything Claude Code offers.
- **MCP**: both directions. `codex mcp` runs Codex as an MCP server. The app-server protocol (`codex-rs/app-server-protocol/`) exposes a richer streaming firehose than hooks do (token deltas, exec output streams, item lifecycle).
- **Headless mode**: `codex exec --json` emits NDJSON of the full app-server-protocol event stream.
- **Process model**: single Rust TUI, binary name `codex`. **No env var announces the active session.**
- **Auth**: ChatGPT subscription OAuth, OpenAI API key, or Codex access tokens (added with hooks GA).

## 4. What ports cleanly

1. **Hook HTTP endpoint.** The existing `HookEvent` decoder handles the snake_case payload shape directly; only the event-name enum needs to grow.
2. **Hook bridge script.** `plugin/gallager/scripts/hook.py` reads stdin, looks up the local port from `~/.claudespy-port`, POSTs to `/api/hooks`. The same script can be the Codex hook target — no Codex-specific code needed in it.
3. **8 of 10 hook events overlap exactly** (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PreCompact, Stop, SubagentStop, PermissionRequest). PostCompact and SubagentStart are additive.
4. **Tmux process detection.** `TmuxService.swift:399-403` already walks the process tree; adding `codex` / `codex exec` to the candidate set is one-line work.
5. **Headless observation channel** (`codex exec --json`) is available as a future enhancement without any trust prompts — useful for CI / scheduled-agent use cases.

## 5. What we genuinely miss

| Gap | Impact | Mitigation |
|---|---|---|
| No `Notification` event | "Claude has X questions" badge logic in `ClaudeSession.needsAttention` doesn't fire | Treat `PermissionRequest` as the equivalent; rule needs an agent-aware branch |
| No `SessionEnd` event | `SessionStore` can't know cleanly when a Codex pane went quiet | **Resolved:** `CodexPluginCore` runs a ~5s process-exit monitor that polls `host.agentPanes()` and emits a synthetic `.sessionEnded` when a recorded pane's `codex` process exits (yolo-reset + opt-in pane-close) |
| No `CODEX_SESSION_ID` in pane env | Can't directly correlate a tmux pane to a `session_id` | Have our `SessionStart` hook write a sidecar keyed by `$TMUX_PANE` (or parent PID) |
| Project hooks require explicit trust | First launch in a repo prompts the user; hook-config changes re-prompt | Install at the **global** layer (`~/.codex/hooks.json`) to keep it one-time; document in onboarding |
| `async = true` / `prompt` / `agent` hook types not functional | Can't use async hooks for non-blocking observation | Live with synchronous command hooks for now; revisit when Codex ships these |
| Sessions are date-partitioned | Existing `ClaudeProjectScanner` strategy doesn't transfer | New `CodexProjectScanner` that aggregates rollouts by cwd from `SessionMetaLine` |
| `AGENTS.md` is hierarchical (git root → cwd) | Any future "project instructions" UI must walk the chain, not just project root | Defer until we add such a UI |

## 6. Implementation plan

The work is structured so each phase is **independently shippable** — none of them require all-or-nothing migration. Phases 1–2 are mostly mechanical; phase 3 is where Codex-specific behavior lands.

### Phase 1 — Introduce a `CodingAgent` abstraction (mechanical refactor)

**Goal:** every Claude-specific identifier that crosses module boundaries grows an agent-aware variant. No behavior change.

1. Add `CodingAgent` enum (cases `.claudeCode`, `.codex`) in `ClaudeSpyNetworking` — `Sendable`, `Codable`, stable raw values.
2. Rename network/model types:
   - `ClaudeProjectInfo` → `AgentProjectInfo` with `agent: CodingAgent` field (default `.claudeCode` for back-compat decoders — but per project-memory rule **no Codable back-compat shims**; since all components deploy together, do a flag-day rename).
   - `ClaudeSession` → `AgentSession` with `agent: CodingAgent`.
3. Settings: keep `claudeCommandPath`, add `codexCommandPath` (default `codex`). Do **not** collapse them into a single field — different defaults, different validators.
4. Sidebar enum cases: keep `.claude` / add `.codex`, drop `.claudeFirst` in favor of a more general sort enum.
5. Notification copy: replace hardcoded `"Claude Code"` in `HookNotificationExtensions.swift:4-16` with `agent.displayName`.
6. Update `HookEvent` to carry `agent: CodingAgent` (Mac app sets this when it forwards to relay; iOS reads it).

**Acceptance:** all existing Claude Code flows still work end-to-end; no functional change on iOS or the relay.

### Phase 2 — Codex project discovery

**Goal:** sidebar can list Codex projects alongside Claude Code projects.

1. New `CodexProjectScanner` actor that:
   - Walks `~/.codex/sessions/**/rollout-*.jsonl`.
   - Reads only the first JSON line of each rollout (the `SessionMetaLine`) to extract `cwd`, `session_id`, `started_at`, git info.
   - Aggregates by `cwd`, producing `AgentProjectInfo` entries with `agent = .codex`, `lastUsed = max(started_at)`.
   - Falls back to scanning the filesystem for `<repo>/.codex/` and `AGENTS.md` markers if `~/.codex/sessions/` is empty (fresh-install case).
   - Respects `CODEX_HOME` env override.
2. Decide on SQLite vs. file-walking. **Recommended: file-walking only for v1**, because `state.db` schema is undocumented and may break. If perf becomes an issue, add an `~/.codex/state.db` fast-path later.
3. Plumb the new scanner into `AppCoordinator.scanProjects()` (`AppCoordinator.swift:383-400`). Merge results from both scanners; de-duplicate by `(agent, path)`.
4. UI: sidebar groups projects by agent or keeps them mixed with a small agent badge — pick one in design review.

**Acceptance:** opening the app on a machine with both Claude Code and Codex usage shows projects from both, with correct `lastUsed`.

### Phase 3 — Codex hook ingestion + auto-start

**Goal:** when the user launches a Codex project from ClaudeSpy, lifecycle events flow into the UI just like Claude Code's.

1. **Hook installer for Codex.** Write `~/.codex/hooks.json` pointing every supported event at the existing Python bridge:
   ```json
   {
     "hooks": {
       "SessionStart":      [{ "matcher": ".*", "hooks": [{ "type": "command", "command": "python3 /…/hook.py", "timeout": 30 }] }],
       "UserPromptSubmit":  [...],
       "PreToolUse":        [...],
       "PostToolUse":       [...],
       "PermissionRequest": [...],
       "PreCompact":        [...],
       "PostCompact":       [...],
       "Stop":              [...],
       "SubagentStart":     [...],
       "SubagentStop":      [...]
     }
   }
   ```
   Install at the **global** layer to avoid per-project trust prompts.
2. **Bridge script change.** Update `plugin/gallager/scripts/hook.py` to read `CODEX_*` env vars when present (Codex sets a different env vocabulary than Claude Code) and pass an explicit `agent=codex` query param to `/api/hooks`. Read `tmuxPane` from `$TMUX_PANE` regardless of agent.
3. **HookEvent extension.** Add Codex-only events (`PostCompact`, `SubagentStart`) to `HookAction`. Map `PermissionRequest` → existing "needs attention" pathway, gated by agent kind so Claude Code keeps using `Notification`.
4. **SessionStart sidecar.** Have the bridge script, on `SessionStart`, write `~/.claudespy/codex-sessions/<tmux_pane>.json` with `{session_id, cwd, pid, started_at}`. The Mac app reads this to correlate.
5. **Auto-start.** Extend `AppCoordinator.swift:798-829` so the constructed tmux command uses `codexCommandPath` when `project.agent == .codex`. Add `codex` (and `codex exec`) to the descendant-process matcher in `TmuxService.swift:399-403`.
6. **Window naming.** Mirror the existing "claude" window name convention with "codex" for Codex projects (`AppCoordinator.swift:1450`, `TmuxService.swift:2301`).

**Acceptance:** a user clicks "start Codex" on a discovered project; a tmux pane spawns `codex`; SessionStart fires and the session appears in the iOS app; PreToolUse / PostToolUse stream live; Stop transitions the session to idle.

### Phase 4 — UX polish

1. Disambiguate notification titles per agent (`"Codex needs approval"` vs. `"Claude has 2 questions"`).
2. Sidebar agent badge (small icon next to project name).
3. Onboarding flow that explains the **one-time Codex trust prompt** the user will see on first launch.
4. "Codex not installed" empty-state mirroring `.claudeNotInstalled`.
5. Settings UI: per-agent command path with validation (resolve binary via `which`).

### Phase 5 (optional, future) — Richer observation

Out of scope for v1, but worth tracking:

- **App-server-protocol stream** (`codex exec --json` or a long-running app-server connection): gives token-by-token deltas and command-exec streams. Useful for a richer "what is Codex doing right now" view than discrete hooks provide.
- **OpenTelemetry collector** embedded in the Mac app: zero-trust-prompt, structured metrics, but a much bigger lift.
- **Codex-as-MCP-server** (`codex mcp`): would let ClaudeSpy *drive* a Codex session, not just observe one.

## 7. Open questions

1. **Sidebar grouping**: group by agent, or mix with badges? Affects Phase 2's UI work.
2. **Per-project Codex config**: do we ever write `<repo>/.codex/hooks.json` (and eat the trust prompt) to support project-specific behavior, or stay global-only? Recommend global-only for v1.
3. **Trust-prompt onboarding**: do we ship a short docs page, or a first-run modal, or both?
4. **Renaming impact**: are there iOS-side persisted records (UserDefaults, cached project lists) keyed on `ClaudeProjectInfo` that would break on Phase 1's rename? Needs audit before flag-day.
5. **gallager plugin**: keep the Claude Code gallager plugin as-is, or rename / generalize it? Recommend keeping it Claude-Code-specific and shipping a separate Codex installer that writes `~/.codex/hooks.json` directly.

## 8. Risks

- **Codex release cadence.** Multiple releases per week; hook schema is GA but auxiliary surfaces (async hooks, prompt/agent hook types) are in flux. Pin documentation reads to a known version when implementing, and add a "tested against" badge in the Codex scanner.
- **SQLite state.db**: tempting for fast scans but undocumented. Avoid for v1.
- **Trust prompt UX**: easy to underestimate. First-time users will get a Codex-side prompt that ClaudeSpy didn't generate — clear in-app messaging is essential to avoid confused bug reports.
- **Naming refactor blast radius**: Phase 1 touches a lot of files. Land it as one focused PR, not interleaved with feature work.

## 9. References

- Codex CLI Hooks: https://developers.openai.com/codex/hooks
- Codex Config Reference: https://developers.openai.com/codex/config-reference
- Codex Advanced Config (trust, OTEL): https://developers.openai.com/codex/config-advanced
- Codex CLI Reference (resume, exec, mcp): https://developers.openai.com/codex/cli/reference
- AGENTS.md guide: https://developers.openai.com/codex/guides/agents-md
- Repo source of truth: https://github.com/openai/codex (`codex-rs/hooks/`, `codex-rs/rollout/`, `codex-rs/app-server-protocol/`)
