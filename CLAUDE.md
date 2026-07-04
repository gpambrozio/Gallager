# ClaudeSpy

Distributed system for monitoring coding-agent sessions (Anthropic Claude Code and OpenAI Codex CLI, behind a shared `CodingAgent` abstraction in `ClaudeSpyNetworking`). Three components:
1. **Mac App** - tmux pane mirroring, receives hooks from both agents, forwards to server
2. **External Server** - Vapor relay (Docker/Linux), device pairing, WebSocket routing
3. **iOS App** - Remote monitoring, command dispatch

**Stack:** Swift 6.3+, SwiftUI (MV pattern), Swift Concurrency, SwiftTerm, Vapor, CryptoKit (E2EE)

**Targets:** macOS 15.0+, iOS 17.0+

## Project Structure

```
ClaudeSpy/
├── Config/                        # XCConfig (Debug/Release/Shared/Tests.xcconfig)
├── ClaudeSpy/                     # iOS @main entry
├── ClaudeSpyServer/               # macOS @main entry
├── ClaudeSpyNotificationExtension/  # iOS push decryption extension
├── ClaudeSpyPackage/              # ALL business logic + server deployment
│   ├── Sources/
│   │   ├── ClaudeSpyCommon/       # Shared UI (Symbols, extensions)
│   │   ├── ClaudeSpyEncryption/   # E2EE (Mac/iOS only)
│   │   ├── ClaudeSpyNetworking/   # Shared models (Mac/Server/iOS)
│   │   ├── ClaudeSpyFeature/      # iOS feature module
│   │   ├── ClaudeSpyServerFeature/  # macOS feature module
│   │   └── ClaudeSpyExternalServer/ # Vapor relay server
│   ├── Dockerfile                 # Server container build
│   ├── docker-compose.yml         # Server orchestration
│   └── caddy/                     # Reverse proxy configs
└── docs/                          # Architecture docs
```

**Development by platform:**
- macOS → `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/`
- iOS → `ClaudeSpyPackage/Sources/ClaudeSpyFeature/`
- Shared → `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/`
- Encryption → `ClaudeSpyPackage/Sources/ClaudeSpyEncryption/`
- Server → `ClaudeSpyPackage/Sources/ClaudeSpyExternalServer/`

## Critical Rules

### Only necessary code outside Packages

The code in the Xcode project should be the absolute minimal. If code can be in a package then it should. 

### No ViewModels

Use native SwiftUI data flow:
- `@State` for view-specific state
- `@Observable` for model classes
- `@Environment` for app-wide services
- `@Binding` / `@Bindable` for two-way flow
- `.task` for async (auto-cancels), never `Task {}` in `onAppear`

### SF Symbols

Never use string literals. Add to `ClaudeSpyCommon/UI/Symbols.swift`:
```swift
@SFSymbol
public enum Symbols: String {
    case starFill = "star.fill"
}
```
Use: `Symbols.starFill.image` or `Label("Text", symbol: .starFill)`

### Concurrency

- `@MainActor` for all UI
- actors for I/O (ProcessRunner, TmuxControlClient)
- No GCD, Swift Concurrency only
- All cross-boundary types must be `Sendable`

### Dependencies (Dependency Injection)

Use [Point-Free Dependencies](https://github.com/pointfreeco/swift-dependencies) for services that wrap system APIs or perform I/O. This enables testability without real system interaction.

**When to use `@DependencyClient`:**
- Stateless utilities wrapping system APIs (UserDefaults, Keychain, SMAppService, IOKit, etc.)
- Process execution and filesystem access
- Services that are hard to test without mocking (network, push notifications)

**When NOT to use it:**
- `@Observable` classes with complex state and many wired callbacks (use init injection instead)
- Services already using Vapor's DI container (external server)
- Simple value types or pure functions

**Pattern:** Define as `@DependencyClient struct`, conform to `DependencyKey`, provide `liveValue` and optional `inMemory()`. See `docs/swift-patterns.md` for full examples.

**Usage in `@Observable` classes:**
```swift
@ObservationIgnored
@Dependency(MyService.self) private var myService
```

**Usage in initializers:**
```swift
@Dependency(MyService.self) var service
```

**Testing:**
```swift
try await withDependencies {
    $0[MyService.self] = .testValue
} operation: {
    // code under test
}
```

### Error Handling

- `guard let` / `if let` for optionals
- No force-unwrap without certainty
- `do/try/catch` with meaningful errors
- No empty catch blocks

## Building & Testing

Use XcodeBuildTools skills. Scheme: `ClaudeSpyServer` (macOS), `ClaudeSpy` (iOS).

**Killing Mac app:** Use `osascript -e 'quit app "Gallager"'` — `pkill`/`killall` don't work reliably.

**Opening a PR:** A `PostToolUse` hook (`.claude/hooks/pr-checklist.py`) fires on `gh pr create` and injects a checklist of post-PR chores (docs, CLAUDE.md, CLI/`gallager`-skill, e2e scenarios). Work through it before stopping. See `docs/repo-hooks.md`.

## Reference Docs

- **Code examples:** `docs/swift-patterns.md` - SwiftUI patterns, Sendable, Dependencies, testing
- **Services:** `docs/services-reference.md` - TmuxService, PaneStream, CodingAgent, project scanners, etc.
- **Architecture:** `docs/architecture.md` (Mac app) and `docs/distributed-architecture-plan.md` (Mac/Server/iOS)
- **Codex CLI integration:** `docs/codex-cli-integration-plan.md` - `CodingAgent` abstraction, hook bridge, project discovery
- **Folder layout persistence (macOS):** `docs/folder-layout-persistence-plan.md` - Per-folder workbench restore (file/browser tabs, split, sidebar); `LayoutStore`, seed-on-birth, auto-save. Covers local *and* remote/viewer sessions (§4.8 — remote is browser-tabs + split only, keyed by host `pairId`)
- **Encryption:** `docs/e2ee-encryption-plan.md`
- **E2E testing:** `docs/e2e-testing.md` - Test framework, running tests, writing scenarios, video recording (`--record`, issue #621), automatic proof-video cleanup (daily sweep, 3-day grace after PR close), shell-history isolation (every e2e shell runs under a `$ZDOTDIR` shim so typed commands never reach `~/.zsh_history`)
- **Self-hosting:** `docs/self-hosting.md` - Deploy your own relay server
- **Emoji search:** `docs/emoji-search.md` - `GallagerEmoji` module (keyword-aware emoji index shared by the Mac/iOS picker and the `gallager` CLI; replaced `SwiftEmojiPicker`, issue #630). Data is generated by `scripts/generate-emoji-data.py` from CLDR annotations into `EmojiData.swift`; add missing synonyms to that script's `EXTRA_KEYWORDS` overlay and regenerate.
- **Repo hooks:** `docs/repo-hooks.md` - Project-scoped Claude Code hooks (swiftformat, PR checklist)
- **Known issues:** `docs/known-issues.md`
- **Terminal sizing (macOS):** `docs/swiftterm-sizing.md`
- **Terminal scrolling (iOS):** `docs/swiftterm-ios-scrolling.md`
- **Terminal rendering bugs:** `docs/terminal-rendering-investigation.md` - Hypotheses, test results, fix priorities
- **Sidecar plugin authoring:** `docs/plugins/sidecar-authoring.md` - External contract for v2 sidecar plugins: manifest schema, JSON-RPC vocabulary, spawn env, hook ingress, crash policy, distribution, security model. A manifest `otlp` field (`{namespace, token_event}`, #617) opts a plugin's OTLP log records into the per-session token/cost/latency meter: records named `<namespace>.<token_event>` must mirror Claude's `api_request` attribute keys (additive semantics, `session.id` join); the resolved namespace table is pushed to `OTLPReceiver` whenever the enabled-plugin set changes (`refreshOTLPPluginNamespaces`), and built-in namespaces can't be claimed. Note: sidecar child stderr goes to `~/.gallager/state/plugins/<id>/logs/stderr.log` (separate from `host.log()`'s `sidecar.log`). The bundled `gallager:create-agent-plugin` skill (`plugin/gallager/skills/create-agent-plugin/`) scaffolds one from a Python template + self-contained contract copy. Wire casing trap: `plugin.json` and the ingress *socket* frame are snake_case (`plugin_id`); the stdio *transport* (RPC params/results) is camelCase (`pluginID`, `sessionID`, …).
- **opencode sidecar plugin (real example):** `plugins/opencode/` - a complete working sidecar adding opencode (sst) support: Python `bin/sidecar` + an opencode `event`-bus bridge plugin (`opencode-bridge/gallager.js`, installed to `~/.config/opencode/plugin/`) since opencode removed shell hooks. Maps `session.status`/`session.idle`/`session.error` to working/done/idle (per-session machine so a turn-end `idle` raises attention but a fresh-session `idle` doesn't); `permission.asked` → `awaitingPermission`; `question.asked` → `awaitingReplies` (multi-question + multi-select + free text). **Session lifecycle:** opencode fires NO event on a fresh idle launch or on quit, and the host's process scan only re-detects on pane add/remove (not when a process starts/dies in a live pane) — so the bridge emits two *synthetic* frames: `gallager.lifecycle.started` (on plugin load ≈ TUI start → sidecar emits `idle`, session appears) and `gallager.lifecycle.stopped` (from opencode's `dispose` hook ≈ graceful quit → sidecar emits `AppAction.sessionEnded` keyed by the PANE id → host removes the session). Mirrors Claude's SessionStart/SessionEnd (no notifications); `closePaneEligible` honors `close_pane_on_session_end`. dispose fires on `/exit` AND Ctrl-C (verified v1.17.11); a hard SIGKILL skips it (stale session lingers). **Forms are answered by KEYSTROKE injection** into the pane (opencode's TUI talks to its server over a unix socket — no reachable HTTP endpoint; the sidecar emits `send_keys` and Gallager just relays, so each agent's keystroke mapping is plugin-owned). opencode's question prompt uses number keys `1`-`9` (jump+toggle/pick) with a tabbed Confirm-submit for multi/multi-question. Projects surface in the sidebar "+" menu by reading opencode's SQLite store (`~/.local/share/opencode/opencode.db`, `project` table). opencode keys a project by its git *repo*, not folder, and stores only the FIRST worktree it saw — so a repo with multiple `git worktree`s would show just one, whichever opencode recorded. The scan expands each stored `worktree` into EVERY worktree of its repo via `git worktree list --porcelain` (so main + linked worktrees are each launchable, deduped across rows; falls back to the raw path for non-git dirs / missing git). The stored worktree keeps opencode's own `name`; other worktrees are labeled by basename. The scan opens the DB `mode=ro` (WAL-aware) not `immutable=1`, so a freshly-created project sitting in the WAL surfaces immediately (WAL readers never block the writer); it falls back to `immutable=1` only when `mode=ro` can't open (stale `-wal`, no `-shm`, no dir write access = opencode not running). **Telemetry (#617):** the bridge POSTs one OTLP/JSON record per *completed* assistant message (`message.updated` with `time.completed`, deduped by message id, never forwarded to the ingress socket) to the receiver's `/v1/logs`, event name `opencode.api_request`, Claude's exact attribute keys (reasoning folded into `output_tokens`), `session.id` = **opencode's `ses_…` session id** — the host re-stamps the pane's join key from every sidecar-reported event, and real opencode events report the ses id (the pane id, reported only by the synthetic launch frame, would stop joining at the first turn); the meter follows the pane's active session, resetting on session switch like `/clear`; the sidecar bakes the endpoint into the bridge at install via `__GALLAGER_OTLP_ENDPOINT__` (from initialize's `otlpReceiverEndpoint`; `GALLAGER_OTLP_ENDPOINT` env fallback for repo smoke tests; stale if the receiver's port changes → re-Install). Gotcha: `PluginEvent.appActions` is non-optional — a hand-built event JSON MUST include `"appActions": []` (or a populated list) or the host silently drops it. Tests: `python3 plugins/opencode/tests/test_sidecar.py` (36). `./scripts/dev-install.sh` **copies** it into `~/.gallager/plugins/` (folder-drop discovery skips symlinks).
