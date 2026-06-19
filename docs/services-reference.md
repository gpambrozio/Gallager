# Services Reference

Detailed documentation for ClaudeSpy services. Reference when modifying specific components.

## macOS Services

### AppCoordinator (`ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift`)

`@Observable @MainActor` central coordinator for all services.

**Responsibilities:**
- Creates and owns all services
- Wires callbacks between services (hook events, pane changes, commands)
- Two-phase init: sync (core services) + async (`setupAllServices()` for E2EE, connections)
- Auto-connects to paired devices on startup
- Observes system wake for reconnection

### TmuxService (`ClaudeSpyServerFeature/Services/TmuxService.swift`)

`@Observable @MainActor` class abstracting tmux CLI interactions.

**Methods:**
- `refreshPanes()` - discovers all panes across sessions
- `validatePane()` - checks if pane target exists
- `capturePane()` - captures scrollback with ANSI sequences
- `capturePaneWithScrollbackForStreaming()` - captures with cursor positioning for streaming init
- `getPaneDimensions()` / `getPaneId()` - dimension tracking
- `sendKeys()` / `sendInterrupt()` - send input to panes
- `createSession()` - creates new tmux session with dimensions
- `probeVisualConflict()` - detects whether the user's rc files clobber the `$VISUAL` Gallager sets (see [Editor Override](#editor-override-ctrl-g) below)
- `injectVisualOverrideIntoExistingShellPanes()` / `clearInjectedOverrideTracking()` - manage the opt-in `export VISUAL` injection

**Config:** `tmuxPath` (default: `/opt/homebrew/bin/tmux`), optional `socketPath`, `overrideVisualInShellPanes` (mirrors `AppSettings.editorOverrideMode`)

### Editor Override (Ctrl-G)

Gallager points `$VISUAL` at the bundled `gallager edit` CLI (via tmux `-e` on every session) so Ctrl-G in Claude Code / Codex opens the in-app prompt editor. Spawned panes run a login shell that sources the user's rc files **after** the session env is applied, so a user with `export VISUAL=<their editor>` in `~/.zshrc`/`~/.bashrc` clobbers Gallager's value and Ctrl-G opens *their* editor instead. The override is **consent-based** (issue #591) — Gallager's env is a default, never a silent override.

Key files: `EditorOverride.swift` (pure helpers + `EditorOverrideMode`/`VisualProbeResult`), `TmuxService` (probe + injection), `AppCoordinator` (coordination), `EditorOverrideDialog.swift` (the dialog), `EditorsSettingsView.swift` (`PromptEditorOverrideSection`).

**1. Conflict probe.** At startup (only when `GallagerCLI` is bundled, and in either `ask` or `overrideInGallagerSessions` mode), `TmuxService.probeVisualConflict()` creates a detached probe session named `__gallager_probe` with `-e VISUAL=__gallager_probe__` and the normal `default-command` wrapper (real pty / env / startup), types `printf 'GALLAGER_PROBE=%s\n' "$VISUAL"`, and polls `capture-pane` (~10s) for the marker. Sentinel intact → no conflict; a different value or empty → conflict (the user's value is remembered for the dialog copy). No CLI / unknown shell (nushell) / timeout → treated as no-conflict. The probe session is filtered out of every user-facing list by its name prefix (so injection never touches it — the probe stays honest even while override is active). Re-run on demand from Settings ("Re-check now").

**2. Dialog.** Deferred from launch to the **first session creation** (when "Ctrl-G" has context). Shows the conflicting value and three choices:
- **Fix it in your shell config (recommended)** — keeps the setting at *Ask*; shows a copyable guarded line `[ -n "$GALLAGER_SOCKET" ] || export VISUAL='<their value>'` (Gallager exports `GALLAGER_SOCKET` before rc files run, so the rc can detect a Gallager pane). The next launch's probe verifies; if fixed, the dialog never returns.
- **Override in Gallager sessions** — enables keystroke injection (below).
- **Keep my editor, stop asking** — never override, never ask.
- Dismissing ("Decide later") leaves it at *Ask* — re-prompts on a later conflict probe.

**3. Injection (override mode).** Instead of tampering with shell startup, Gallager types the export into shell panes:
- **New panes:** `refreshPanes()` injects a leading-space `export VISUAL='<gallager> edit'` (POSIX) / `set -gx VISUAL …` (fish) into each new known-shell pane. The bytes buffer until the first prompt, so they run *after* all rc files. The leading space keeps it out of history under `HISTCONTROL=ignorespace` / `HIST_IGNORE_SPACE`.
- **Existing panes** are injected when the setting is turned on.
- **App-launched agents** chain the export onto the agent command line in `createSession` (a direct-command pane never ran rc files, so the new-pane injector skips it).
- Per-pane dedup keeps it to one line per shell pane.

**4. Startup reconciliation.** A user who opted into the override only needs it while their rc actually clobbers `$VISUAL`. If they later remove their `export VISUAL` and Gallager's `-e VISUAL` wins on its own, the per-pane injection becomes pure redundancy. So on launch in `overrideInGallagerSessions` mode, `AppCoordinator` re-probes and, if the probe **positively** reports `.intact`, falls back to `.ask` (stops injecting) via `EditorOverride.shouldDropRedundantOverride(mode:probe:)`. A `.skipped` / not-yet-run probe is *not* treated as proof the conflict is gone, so the override is left in place. The same reconciliation runs on Settings → "Re-check now". If the conflict later returns, `.ask` re-prompts.

**Settings:** `AppSettings.editorOverrideMode` (`ask` / `overrideInGallagerSessions` / `useMyEditor`). `AppCoordinator.setEditorOverrideMode(_:)` is the single mutation point — it persists the choice and mirrors it onto `TmuxService.overrideVisualInShellPanes`.

**Limitations:** the injected line is visible in scrollback; a nested shell (`exec zsh`) re-sources rc with no re-injection; changing the setting doesn't affect already-running agents; the override also affects `git commit`/`crontab` in those panes; typing within the first ~second of a pane opening (or an rc ending in `exec`) can interleave with / swallow the injected line. All are accepted trade-offs for users who explicitly opted in.

`baseEnvironmentVars` (injected via tmux `-e`, so they reach both app-launched and manually-typed `claude`) sets the Claude rendering/update flags **and** the OTEL export vars that point Claude Code at the Mac-local `OTLPReceiver` (`CLAUDE_CODE_ENABLE_TELEMETRY=1`, `OTEL_*` → `http://127.0.0.1:<OTLPReceiver.resolvedPort>`; issue #597). No content gates are enabled. The endpoint port is `OTLPReceiver.resolvedPort` — the single source of truth the env injection and the receiver bind share, so they can't drift (`4318` in production, or a per-instance `--otlp-port` under E2E).

### TmuxControlClient (`ClaudeSpyServerFeature/Services/TmuxControlClient.swift`)

Actor managing a `tmux -C attach -f no-output,ignore-size` control mode connection for commands and event notifications. Live terminal data is delivered separately via `PipePaneReader`.

**Features:**
- Connects to tmux session in control mode with `-f no-output,ignore-size` (suppresses `%output` events)
- Sends commands and receives responses via `%begin/%end` blocks (FIFO command queue)
- Parses event notifications: `%layout-change`, `%session-changed`, `%exit`
- Tracks per-pane cached dimensions for change detection
- Uses AsyncStream + single consumer for strict ordering of control mode messages

**Callbacks:**
- `onDimensionChange(paneId, width, height)` - pane resized (from `%layout-change`)
- `onPaneExited(paneId)` - pane closed
- `onSessionChanged(sessionId, name)` - session switched
- `onExit(reason)` - control mode connection closed

### TmuxControlClientManager (`ClaudeSpyServerFeature/Services/TmuxControlClientManager.swift`)

`@Observable @MainActor` managing `TmuxControlClient` instances per session.

**Methods:**
- `getClient(for:)` - returns existing or creates new client for session
- `registerPaneDimensions()` / `unregisterPane()` - register/unregister pane for dimension tracking
- `sendCommand(_:sessionName:)` - send tmux command through the control client
- `setOnDimensionChange()` - forward dimension changes to PaneStreamManager
- `setOnPanesChanged()` - callback when panes exit (for cleanup)
- `extractSessionName(from:)` - parses session from pane target

Multiple panes in the same session share one control client connection. The control client operates in `no-output` mode — it only handles commands and event notifications.

### PipePaneReader (`ClaudeSpyServerFeature/Services/PipePaneReader.swift`)

`actor` managing FIFO-based raw byte delivery from tmux `pipe-pane` for a single pane. One reader instance lives for the pane's full lifetime — mirror toggling never restarts it.

**Features:**
- Creates per-pane FIFO (`/tmp/claudespy-pipe-<id>.fifo`)
- Starts `pipe-pane -O "cat > fifo"` via control mode command
- Reads raw PTY bytes, filtering tmux `ESC k ... ESC \` title sequences and parsing OSC 9/777/9;4/0/2/52 events
- AsyncStream + single consumer task for strict FIFO ordering
- Forwards events through a single `PipePaneReaderDelegate` (`@MainActor` protocol, one method per event type)

**Three data-delivery modes:**
- **`scanOnly`** (default after `startPipePane`): parser doesn't build `filteredData`, data bytes are discarded. OSC events still flow.
- **`buffering`** (`setBuffering(true)`): bytes queued instead of forwarded. Used while a `capture-pane` snapshot is being taken.
- **`live`** (`flushBuffer`): drains the queue to the delegate in order, then forwards subsequent bytes directly.

**Lifecycle:**
- `setDelegate(_:)` - attach the delegate that receives data + OSC events
- `startPipePane(controlClientManager:sessionName:)` - create FIFO, send pipe-pane command, open for reading. Reader starts in scan-only mode
- `setBuffering(_:)` - flip into buffering mode (bytes queued) or back to scan-only mode (queue dropped, bytes discarded)
- `flushBuffer()` - drain the queue through the delegate and switch to live mode
- `stopPipePane()` - clean up FIFO, close file handle (called when the pane disappears)

### PaneStreamManager (`ClaudeSpyServerFeature/Services/PaneStreamManager.swift`)

`@Observable @MainActor` owning one `PipePaneReader` per known pane and multiplexing its events to subscribers. Conforms to `PipePaneReaderDelegate`, so all event wiring lives in one place.

**Per-pane lifecycle:**
- New pane discovered → `startReader` creates a `PipePaneReader`, attaches the manager as delegate, calls `startPipePane()` (scan-only mode)
- Pane disappears → `tearDownReader` calls `stopPipePane`, unregisters dimensions, drops the entry

**Data Flow:**
```
tmux PTY ──pipe-pane──→ FIFO ──→ PipePaneReader ──→ PipePaneReaderDelegate
                                                            ↓
                                                   subscriber callbacks

TmuxControlClient ──%layout-change──→ updateDimensions → subscriber onDimensionChange
```

**Subscribe flow (first subscriber on a pane):**
1. `setBuffering(true)` — start retaining live bytes
2. Refresh dimensions via `tmuxService.getPaneDimensions`, register pane for control-mode dimension tracking
3. `capture-pane` snapshot via control mode
4. Add subscriber to the reader's context
5. `flushBuffer()` — buffered bytes flow through `didReceiveData` → `forwardData` → subscriber's `onData`. Subsequent bytes flow live.

**Unsubscribe flow (last subscriber leaves):**
- `setBuffering(false)` returns the reader to scan-only mode. The reader stays attached to the FIFO so OSC events keep flowing for desktop notifications + sidebar UI.

**Methods:**
- `startMonitoring(panes:)` - create readers for all initial panes (called once on startup)
- `updateMonitoring(panes:)` - tear down readers for dead panes, start readers for new panes (called on periodic refresh and on `%session-changed`)
- `subscribe(paneId:target:onData:onDimensionChange:onTitleChange:onNotification:onClipboard:)` - subscribe with callbacks
- `unsubscribe(_:)` - remove subscription (returns reader to scan-only if last)
- `currentContent(for:)` - capture current terminal content without subscribing (for multi-device initial state)
- `updateDimensions(paneId:width:height:)` - propagate dimension changes
- `reportTitleChange(paneId:title:fromSubscription:)` - forward a title detected by a subscriber's SwiftTerm to other subscribers
- `mouseModeSequences(for:)` - DEC private mode escape sequences for the pane's current mouse tracking mode
- `disconnectAll()` - shutdown cleanup

**Internal state:** A single `readers: [String: ReaderContext]` dictionary keyed by paneId. Each context holds the reader, target, sessionName, dimensions, subscriber UUIDs, and the latest known title.

### MirrorWindowManager (`ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift`)

`@Observable @MainActor` managing NSWindow lifecycle.

- Tracks sessions and windows by pane target
- Handles hook events (SessionStart opens window, SessionEnd closes)
- Respects user-closed state (won't reopen until session ends)
- Periodic session validation cleans up stale sessions
- `updatePaneStates(from:)` syncs pane state from tmux, removing stale entries
- Persists the Claude `session.id` as `PaneState.claudeSessionID` (the OTEL join key, issue #597) and exposes `applyTelemetry` / `applyPermissionMode` to stamp the joined pane; cleared on session end
- `refreshGitBranches()` (run on the validation tick) detects each pane's git
  branch with a single cheap `git rev-parse --abbrev-ref HEAD`. The Git tab's
  changed-file badge (issue #573) is separate — read live from the per-session
  GitWorkbench store's `summary`, kept fresh by the store's own repository
  watcher — so it isn't computed here

### TerminalContainerView (`ClaudeSpyServerFeature/Views/TerminalContainerView.swift`)

`@Observable @MainActor` bridging SwiftTerm to SwiftUI.

- Wraps SwiftTerm's `TerminalView`
- Uses **FlippedClipView** for top alignment
- Fixed dimensions in character cells
- CoreText font metrics for cell size
- Theme support (DefaultDark/Light, SolarizedDark/Light)

### HookServerService (`ClaudeSpyServerFeature/Hooks/HookServerService.swift`)

`actor` HTTP server on a dynamically allocated port (written to `~/.claudespy-port`). Accepts hook events from both Claude Code and Codex CLI.

**Endpoints:**
- `GET /health` - Health check
- `POST /api/hooks` - Hook event receiver

**Query params on `/api/hooks`:**
- `tmux_pane` - tmux pane target (e.g. `main:0.1`)
- `agent` - `claude-code` (default) or `codex`. Resolved via `HookQueryParams.resolvedAgent()` and stamped onto the resulting `HookEvent` so downstream UI and notification copy can branch on agent.

**Events:**
- `SessionStart` - auto-opens mirror window
- `SessionEnd` - auto-closes window (Claude Code only; Codex has no `SessionEnd` — see `docs/codex-cli-integration-plan.md` §5)
- `NotificationSend` - notification events
- `Stop` - stop events

Codex contributes additional events (`PreCompact`/`PostCompact`, `SubagentStart`, `PermissionRequest`); the server accepts any JSON payload of the right shape and does not validate event names against a Claude-specific enum.

### OTLPReceiver (`ClaudeSpyServerFeature/Telemetry/OTLPReceiver.swift`)

`actor` — a Mac-local OpenTelemetry receiver that **augments** the hook channel with quantitative, content-free data from a coding agent's OTEL export — Claude Code (issue #597) and Codex (issue #602). One-way push only; nothing is ever sent back into the agent. The receiver/decoder/accumulator are agent-blind; each log record is classified by its event-name namespace (`claude_code.` vs `codex.`) and parsed with that agent's vocabulary into the same `SessionTelemetry`.

- Loopback-only `NWListener` on `127.0.0.1:<OTLPReceiver.resolvedPort>` (`requiredInterfaceType = .loopback`, so no Local Network Privacy prompt and unreachable off-host). Accepts `POST /v1/metrics` and `POST /v1/logs` as OTLP/JSON; responds `200 {}`. No protobuf/gRPC dependency.
- **Port** = `OTLPReceiver.resolvedPort`, the one value the bind and the injected endpoint both read (so they can't drift): `defaultPort` (`4318`) in production, or an `--otlp-port <port>` launch override. E2E passes a per-instance port (`MacOSDriver.defaultOTLPPort + instance`, base `14318`) so concurrent app instances — and a developer's real app already holding `4318` — never share a receiver. The OTEL channel's counterpart to the per-instance accessibility port / ingress socket / tmux socket.
- Decoding lives in `OTLPModels.swift` (tolerant: int64 may arrive as a JSON string or number). Accumulation lives in `OTLPTelemetryAccumulator.swift` (pure value logic, unit-tested), keyed by the session join id (Claude `session.id` / Codex `conversation.id`):
  - **Claude** `claude_code.api_request` log events → summed tokens (by type), summed `cost_usd`, latest `duration_ms`/`model`, and a capped ring of the last ~20 turns.
  - **Claude** `claude_code.commit.count` / `pull_request.count` counters → milestone deltas between exports.
  - **Claude** `claude_code.permission_mode_changed` events → the pane's current permission mode + trigger.
  - **Codex** `codex.sse_event` (`event.kind = response.completed`) → tokens + `model`. OpenAI's `cached_token_count` is nested *inside* `input_token_count` (unlike Claude's disjoint buckets), so it's mapped to the cache-read field and excluded from the headline. **`input_token_count`/`cached_token_count` are cumulative** — `response.completed` fires once per model call (several per turn with tool use), each re-reporting the whole growing context — so the accumulator adds only the positive **delta** per session (output is per-call and summed as-is); summing raw per-event input would multiply-count the same context (~1.5× over on a 3-tool turn, confirmed live on Codex 0.140). Codex emits no cost.
  - **Codex** `codex.turn_ttft` → the turn's time-to-first-token `duration_ms` (`SessionTelemetry.recordTurnLatency`, which back-fills the just-completed token turn's sparkline point; the headline is authoritative, the back-fill best-effort). Tokens and latency arrive on *separate* events. Both `codex.sse_event` and `codex.turn_ttft` carry `conversation.id`; `codex.api_request` does **not** (it's the `/models` capability check, and turn calls run over websocket), so it can't be joined. Codex metrics also omit `conversation.id` (openai/codex#15905), so the `codex.turn.*` metrics can't be joined to a pane and are ignored.
- The permission-mode chip is seeded from the **hook channel** for both agents. For Claude it has a second source — OTEL `permission_mode_changed` (which only fires on a *change*) — so `UserPromptSubmit`/`PreToolUse`/`PostToolUse`/`Stop` also carry `permission_mode`, which the translator puts on the `PluginEvent` and `MirrorWindowManager.applyState` stamps onto the pane (a `nil` never clobbers a known mode). Codex reports a Claude-compatible `permission_mode` on the same events (`CodexTranslator` passes it through); it has no OTEL mode-change signal, so the hook channel is its sole source.
- **Injection differs by agent.** Claude reads `OTEL_*` env vars, injected via `TmuxService.baseEnvironmentVars` (`CLAUDE_CODE_ENABLE_TELEMETRY=1`, `OTEL_*`). Codex does *not* read `OTEL_*` — OTEL is configured only through its `config.toml` schema, and `otel` is denylisted from project-local config — so app-launched Codex panes instead get `-c otel.…` runtime overrides (`CodexOtelConfig.launchOverrides`, gated on the per-agent `export_telemetry` setting), which point `otel.exporter` at `http://127.0.0.1:<port>/v1/logs` (`protocol = "json"`), set `otel.metrics_exporter = "none"`, and leave `log_user_prompt = false`. The runtime-override layer is exempt from the `otel` denylist, and nothing is written to the user's global `~/.codex/config.toml` (so a launch can't corrupt the user's own config). No content gates are enabled for either agent, so no prompt/tool/body content leaves the process.
- `AppCoordinator` wires the receiver's callbacks: telemetry → `MirrorWindowManager.applyTelemetry` (joined to a pane by `claudeSessionID`, then a throttled ~1/sec viewer push); milestones → one notification each via the existing `handlePluginNotification` path; mode changes → `MirrorWindowManager.applyPermissionMode`. The accumulated state is evicted on session end. See `MirrorWindowManager` and `PaneState.telemetry` / `.permissionMode`.

### DeviceConnectionManager (`ClaudeSpyServerFeature/Services/DeviceConnectionManager.swift`)

`@Observable @MainActor` managing connections to all paired iOS devices.

**Features:**
- Wraps multiple `DeviceConnection` instances (one per paired device)
- Broadcasts events to all connected devices
- Combined state for UI display (`combinedState`)
- Auto-reconnect on system wake

**Broadcasting Methods:**
- `sendHookEventToAll()` - forward hook events
- `sendTerminalStreamToAll()` - forward terminal data
- `pushSessionStateToAll()` - sync session state

**Callbacks (set by AppCoordinator):**
- `onCommand` - handle commands from any iOS device
- `onSessionStateRequest` - provide current session state
- `onPartnerKeyReceived` - persist E2EE partner keys

### DeviceConnection (`ClaudeSpyServerFeature/Services/DeviceConnection.swift`)

`@Observable @MainActor` WebSocket connection to a single paired iOS device.

**States:** `disconnected` → `connecting` → `connected` | `reconnecting(attempt)` | `error`

- Manages WebSocket lifecycle with relay server
- E2EE encryption per device
- Auto-reconnects with exponential backoff
- Sends/receives all message types (hook events, commands, terminal stream, session state)

### PairingManager (`ClaudeSpyServerFeature/Services/PairingManager.swift`)

`@Observable @MainActor` managing device pairing.

**States:** `idle` → `generatingCode` → `waitingForPairing(code, expiresAt)` | `error`

- Generates 6-char alphanumeric codes (excludes I and O)
- Registers with external server (includes E2EE public key)
- Polls for pairing completion
- Supports multiple paired devices
- `onDevicePaired` callback triggers connection to newly paired device
- Partner public keys received via WebSocket after pairing

### TerminalStreamService (`ClaudeSpyServerFeature/Services/TerminalStreamService.swift`)

`@Observable @MainActor` streaming terminal data to iOS devices.

**Batching:** 50ms minimum interval, 8KB max batch size (20 updates/sec max)

**Multi-Device Support:**
- Reference-counted streams (`deviceSubscriberCount` per pane)
- `startStreaming()` reuses existing stream if one exists (increments count, sends current content)
- `stopStreaming()` decrements count; only fully stops when count reaches 0
- `stopStreaming(force: true)` bypasses count for system-level cleanup
- `stopAllStreams()` / `stopStreamsForClosedPanes()` always use `force: true`

**Message Types:** `initialState`, `dataChunk`, `dimensionChange`, `streamEnd`

### TmuxCommandExecutor (`ClaudeSpyServerFeature/Services/TmuxCommandExecutor.swift`)

Actor executing commands from iOS devices.

- Receives `CommandMessage` from `DeviceConnectionManager`
- Dispatches to `TmuxService` (sendKeys, sendInterrupt, etc.)
- Returns `CommandResponseMessage` (success/failure)

### PluginService (`ClaudeSpyServerFeature/Services/PluginService.swift`)

`@Observable @MainActor` managing Claude Code plugin detection and installation.

**States:** `unknown` → `checking` → `installed(version)` | `notInstalled` → `installing` → `installed` | `installationFailed`

- Detects plugin at `~/.claude/plugins/`
- Installs bundled plugin from app resources
- First-launch setup flow via `PluginSetupView`

### CodexPluginInstaller (`ClaudeSpyServerFeature/Services/CodexPluginInstaller.swift`)

`Sendable struct` (Point-Free `@DependencyClient`) that installs the bundled `gallager` Codex plugin so Codex forwards hook events to the local hook server.

- Locates the bundled marketplace under `~/.claudespy/marketplaces/gallager/` (copied out of the app resources at install time so Codex can re-discover it)
- Registers the marketplace via `codex plugin marketplace add` and installs the plugin via `codex plugin install gallager`
- Writes hooks at the **global layer** (`~/.codex/hooks.json`) to avoid per-project trust prompts on every repo
- Exposes `install` / `uninstall` / `isInstalled` closures; surfaced in Settings via `CodexPluginInstallerRow`

### ClaudeProjectScanner (`ClaudeSpyServerFeature/Services/ClaudeProjectScanner.swift`)

Actor scanning for Claude Code projects.

- Reads `~/.claude.json` for project paths
- Validates projects have `.claude` subdirectory
- Sorts by most recently used (session timestamps)
- Tags each result with `agent: .claudeCode`
- Results merged with `CodexProjectScanner` output by `AppCoordinator.scanProjects()` and sent to iOS for project list display

### CodexProjectScanner (`ClaudeSpyServerFeature/Services/CodexProjectScanner.swift`)

`Sendable struct` (Point-Free `@DependencyClient`) discovering Codex projects.

- Walks `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, honoring `CODEX_HOME` if set (rollouts are date-partitioned, not project-partitioned, so the scanner must read each file's header)
- Reads each rollout's first JSON line (a `SessionMetaLine`) to recover the working directory. Accepts `cwd`, `working_directory`, or `payload.cwd` because Codex's schema is evolving
- Groups rollouts by working directory and emits one `ClaudeProjectInfo` per project with `agent: .codex`
- Output is merged with `ClaudeProjectScanner` results in `AppCoordinator.scanProjects()` and the project-list relay payload, so the iOS picker shows a unified "most recently used" list with a per-row agent badge

### ClaudePathDetector (`ClaudeSpyServerFeature/Services/ClaudePathDetector.swift`)

Static utility detecting the `claude` CLI path.

- Checks common locations (`/usr/local/bin/claude`, homebrew paths, etc.)
- Used by `TerminalLauncher` for auto-running Claude in new sessions
- The matching `codex` path is resolved against `AppSettings.codexCommandPath` (default `codex`) rather than auto-detection

### TerminalLauncher (`ClaudeSpyServerFeature/Services/TerminalLauncher.swift`)

`@MainActor` utility for launching tmux sessions in external terminals.

- Supports Terminal.app, iTerm2, Warp, Kitty, Alacritty, custom
- Attaches to existing tmux sessions
- Used from iOS "open in terminal" commands

### DockIconManager (`ClaudeSpyServerFeature/Managers/DockIconManager.swift`)

`@MainActor` managing dock icon visibility.

- App runs as accessory (no dock icon) when no windows visible
- Switches to regular mode when windows open
- Ignores menu bar and popover windows

### SleepPreventionManager (`ClaudeSpyServerFeature/Managers/SleepPreventionManager.swift`)

`@MainActor` preventing Mac sleep during active sessions.

- Uses IOKit `IOPMAssertionCreateWithName` assertions
- Enabled/disabled via settings toggle
- Automatically releases when all sessions end

### LoginItemService (`ClaudeSpyServerFeature/Services/LoginItemService.swift`)

Static utility for launch-at-login management.

- Uses `SMAppService.mainApp` for registration
- Appears in System Settings > General > Login Items

### GitWorkbenchProviderClient (`ClaudeSpyServerFeature/Services/GitWorkbenchProviderClient.swift`)

`@Dependency` factory that vends a `GitWorkbenchProvider` for the Git tab (the
[GitWorkbench](https://github.com/gpambrozio/GitWorkbench) component embedded to
the right of the file explorer).

- `provider(repositoryURL:)` returns a provider rooted at a repo directory (the
  same folder the file explorer uses for the session)
- `liveValue` → `CLIGitProvider` (system `git` CLI, from `GitWorkbenchGitKit`)
- `mock` / `previewValue` / `testValue` → `MockGitProvider` (stable fixtures,
  zero latency); the E2E entry point installs `.mock` under `--e2e-test`
- `MainView` retains one `GitWorkbenchStore` per session (`gitWorkbenchStores`),
  rebuilt when the working directory changes, so the git UI state survives
  tab/session switches like `FileBrowserState`

**Changes-tab file actions** (`GitBrowserView`): right-clicking a changed file
shows the *same* native context menu as the file explorer, and double-clicking
opens it in its default app.

- The store's `WorkbenchConfiguration.repositoryURL` is set to the working-tree
  root so GitWorkbench's `onChangesRightClick` / `onChangesDoubleClick` hooks
  hand back **absolute** file URLs.
- The right-click menu is built by the shared `fileContextMenuItems(…)`
  (extracted from `FileContextMenu`, also used by the file tree / search list /
  tab strips) and shown via `presentStableContextMenu(items:with:for:)`, which
  goes through AppKit's `NSMenu.popUpContextMenu(_:with:for:)`. GitWorkbench
  reports the click from `rightMouseDown`; the AppKit contextual-menu path keeps
  the menu open across the press/release and exposes it to accessibility,
  whereas a bare `NSMenu.popUp` would be dismissed by the trailing mouse-up.
- `MainView.gitPane` supplies the "Open in New Tab" / "Show in File Explorer"
  handlers (the reveal logic is the shared `revealInFileExplorer`) so the menu
  reaches full parity with the file explorer.

### UpdaterController (`ClaudeSpyServerFeature/Services/UpdaterController.swift`)

`@Observable @MainActor` wrapping Sparkle updater for SwiftUI.

- Exposes `canCheckForUpdates` binding
- `checkForUpdates()` action

## iOS Services

### RelayClient (`ClaudeSpyFeature/Services/RelayClient.swift`)

`@Observable @MainActor` managing WebSocket from iOS to relay server.

- Connects via `MacConnection` wrapper per paired Mac
- Receives session state, hook events, terminal stream data
- Sends commands (keystroke, cancel, start/stop stream)
- Auto-reconnects with exponential backoff

### SessionStore (`ClaudeSpyFeature/Services/SessionStore.swift`)

`@Observable @MainActor` tracking sessions from Mac.

- Stores sessions by pane ID
- Handles hook events
- Updates on full sync
- Clears on disconnect

## Utilities

### ProcessRunner (`ClaudeSpyServerFeature/Utilities/ProcessRunner.swift`)

Actor for external processes.

- Async execution, stdout/stderr collection
- Thread-safe `OutputCollector` with NSLock
- Returns `ProcessResult` (exit code, stdout, stderr)

## Models

### CodingAgent (`ClaudeSpyNetworking/Models/CodingAgent.swift`)

```swift
public enum CodingAgent: String, Codable, Sendable, CaseIterable, Hashable {
    case claudeCode = "claude-code"   // Anthropic Claude Code CLI (`claude`)
    case codex                         // OpenAI Codex CLI (`codex`)
}
```

Carries display metadata used to render agent-aware UI:

- `displayName` — `"Claude Code"` / `"Codex"` (full notification titles)
- `shortName` — `"Claude"` / `"Codex"` (sidebar badges, compact toasts)
- `processName` — `"claude"` / `"codex"` (matched against tmux pane process trees in `TmuxService.detectAgentPanes`)

`HookEvent`, `ClaudeSession`, and `ClaudeProjectInfo` all carry an `agent` field that defaults to `.claudeCode` when missing, so older Mac builds and older relay payloads still decode cleanly.

### PaneInfo (`ClaudeSpyServerFeature/Models/PaneInfo.swift`)

```swift
id, target, sessionName, windowIndex, paneIndex
command, currentPath, width, height, isActive
```

### AppSettings (`ClaudeSpyServerFeature/Models/Settings.swift`)

`@Observable @MainActor` with UserDefaults:

- **Terminal:** fontName, fontSize, scrollbackLines, theme
- **Behavior:** openPanesWindowOnLaunch, showStatusBar, autoConnectToServer, preventSleepDuringSessions
- **Tmux:** tmuxPath, tmuxSocket
- **Remote Access:** externalServerURL, deviceId, pairedDevices
- **Coding agents:** autoRunClaudeInProjects, claudeCommandPath, codexCommandPath. `commandPath(for: CodingAgent)` returns the right binary path for an agent
- **Prompt editor (Ctrl-G):** editorOverrideMode (`ask` / `overrideInGallagerSessions` / `useMyEditor`) — see [Editor Override](#editor-override-ctrl-g)
- **Plugin:** hasCompletedPluginSetup

### PairedDevice (`ClaudeSpyServerFeature/Models/Settings.swift`)

```swift
id, deviceName, partnerPublicKey, partnerPublicKeyId, pairedAt, customName
```

Represents a paired iOS device with E2EE key info.

## Push Notifications

**Configuration** (`.env`):
```bash
APNS_KEY_PATH=/secrets/AuthKey.p8
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=XXXXXXXXXX
APNS_BUNDLE_ID=com.example.app
APNS_ENVIRONMENT=development  # or "production"
```

**Key files:**
- `ClaudeSpyExternalServer/Services/APNsService.swift`
- `ClaudeSpyExternalServer/Services/PushTokenStore.swift`
- `ClaudeSpyFeature/Services/PushNotificationService.swift`

**Events:** sessionStart, sessionEnd, permissionRequest, stop, notification

**Important:** APNs environment must match build type (Xcode=development, App Store=production)

## E2EE Encryption

See `docs/e2ee-encryption-plan.md` for full design.

**Primitives:**
- Key Exchange: X25519 ECDH
- Symmetric: ChaChaPoly (ChaCha20-Poly1305 AEAD)
- Storage: Keychain with shared access group

**Key files:**
- `ClaudeSpyEncryption/E2EEService.swift`
- `ClaudeSpyEncryption/KeyManager.swift`
- `ClaudeSpyNotificationExtension/NotificationService.swift`

**Encrypted types:** hookEvent, sessionState, command, commandResponse, terminalStream

**Unencrypted types:** registerMac/registerIOS, ping/pong, iosConnected/Disconnected, encryptedPush
