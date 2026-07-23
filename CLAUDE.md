# ClaudeSpy

Distributed system for monitoring coding-agent sessions (Anthropic Claude Code and OpenAI Codex CLI, behind a shared `CodingAgent` abstraction in `ClaudeSpyNetworking`). Three components:
1. **Mac App** - tmux pane mirroring, receives hooks from both agents, forwards to server
2. **External Server** - Vapor relay (Docker/Linux), device pairing, WebSocket routing
3. **iOS App** - Remote monitoring, command dispatch

**Stack:** Swift 6.3+, SwiftUI (MV pattern), Swift Concurrency, SwiftTerm, Vapor, CryptoKit (E2EE)

**Targets:** macOS 15.0+, iOS 17.0+

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
- **E2E testing:** `docs/e2e-testing.md` - Test framework, running tests, writing scenarios, video recording (`--record`, issue #621), in-browser proof-video watching (`scripts/e2e-watch-video.sh <asset|url|scenario>` — resolves the ~1h signed URL via gh and opens the static player `scripts/e2e-video-player.html`; release-asset links otherwise download), automatic proof-video cleanup (daily sweep, 3-day grace after PR close; watch hints struck alongside links), shell-history isolation (every e2e shell runs under a `$ZDOTDIR` shim so typed commands never reach `~/.zsh_history`)
- **Self-hosting:** `docs/self-hosting.md` - Deploy your own relay server. Also documents the optional **server-side minimum-client-version gate** (#659): `MinClientVersionGate` (ExternalServerLib), default-off via `MIN_CLIENT_VERSION` (+ `MIN_CLIENT_VERSION_REJECT_UNKNOWN`). Clients report their version in the pre-E2EE `clientVersion` WebSocket query param; the relay refuses those below the minimum on connect with a typed `CLIENT_TOO_OLD` error (separate from the peer-to-peer `peerHello` version handshake, which the relay can't read). Enforced in `WebSocketController` for host+viewer connects; unknown-version (pre-reporting) clients allowed unless `rejectUnknown`.
- **Hosted-relay licensing (#392):** `docs/superpowers/specs/2026-07-13-hosted-relay-monetization-design.md` (trial-start/UI follow-on: `docs/superpowers/specs/2026-07-15-trial-status-badge-and-pairing-trial-start-design.md`) - Lemon Squeezy subscription gate for host Macs on the hosted relay: `LicensingService` actor (7-day trial keyed by host deviceId — **the trial clock starts when a viewer completes pairing** (`completePairing`→`startTrialIfNeeded`), NOT on register/first-touch; `checkEntitlement` is a pure gate with a `.preTrial` allowed state; license keys with cached verdicts; enforcement/gating at pairing register + host WS connect + daily sweep). Host WS connect *also* starts the trial for pre-existing **ACTIVE** pairs (gated on `getPair`≠nil, pending pairs excluded) — a one-time migration so pairings completed before licensing was enabled aren't grandfathered into permanent free access. UI: Mac License section in Remote Access settings **plus a trial/expired badge in the panes-window toolbar (left of Disconnect, shown only for paired hosts) opening a buy/activate popover** (`TrialStatusToolbarItem`), viewer "subscription expired" states. Entirely disabled unless `LEMONSQUEEZY_STORE_ID`/`LEMONSQUEEZY_PRODUCT_ID` are set — self-hosting needs no config. Enablement gates (LS dashboard setup, real `LicensingLinks` URLs replacing `CHECKOUT-VARIANT-UUID`, `VersionCompatibility` bump) live in the plan's Task 18 checklist (`docs/superpowers/plans/2026-07-13-hosted-relay-monetization.md`)
- **Update hosting (maintainers, #664):** Sparkle appcast (`ClaudeSpy.xml`) + DMGs + plugin bundles are served from `/opt/claudespy-updates` on the relay box behind `updates.gallager.app` (Caddy `file_server`, `ClaudeSpyPackage/caddy/updates.caddy`, installed by `deploy.sh` on every prod deploy). `release.sh` uploads over rsync/SSH (host: `DEPLOY_HOST` > `hcloud` `cleancast`; no more FTP/lftp/1Password). The legacy `updates.gustavo.eng.br` hostname is baked into every shipped `SUFeedURL` and must keep serving forever — it's an ACTIVE alias in `updates.caddy` (both hostnames live on the box with per-hostname LE certs since the 2026-07-17 DNS flip; don't remove it). `docs/ClaudeSpy.xml` keeps only the last 2 versions.
- **Staging relay (maintainers):** `docs/staging-relay.md` - A second, isolated hosted-relay copy on the SAME box behind `staging.gallager.app` (Caddy → `127.0.0.1:8081`, container `claudespy-relay-staging`, dir `/opt/claudespy-staging`) for testing relay changes (esp. Lemon Squeezy licensing in test mode) without touching prod. Driven by `scripts/deploy.sh staging` / `staging-logs` / `staging-status` / `staging-stop`; config in `ClaudeSpyPackage/docker-compose.staging.yml` (note `ports: !override` to avoid Compose list-merge appending prod's 8080), `caddy/claudespy-staging.caddy`, and `.env.staging.example`. The deploy excludes `.env`+`secrets` from rsync (managed on-server, licensing-enabled).
- **Emoji search:** `docs/emoji-search.md` - `GallagerEmoji` module (keyword-aware emoji index shared by the Mac/iOS picker and the `gallager` CLI; replaced `SwiftEmojiPicker`, issue #630). Data is generated by `scripts/generate-emoji-data.py` from CLDR annotations into `EmojiData.swift`; add missing synonyms to that script's `EXTRA_KEYWORDS` overlay and regenerate.
- **Repo hooks:** `docs/repo-hooks.md` - Project-scoped Claude Code hooks (swiftformat, PR checklist)
- **Terminal sizing (macOS):** `docs/swiftterm-sizing.md`
- **Terminal scrolling (iOS):** `docs/swiftterm-ios-scrolling.md`
- **Terminal rendering bugs:** `docs/terminal-rendering-investigation.md` - Hypotheses, test results, fix priorities
- **Sidecar plugin authoring:** `docs/plugins/sidecar-authoring.md` - External contract for v2 sidecar plugins: manifest schema, JSON-RPC vocabulary, spawn env, hook ingress, crash policy, distribution, security model. A manifest `otlp` field (`{namespace, token_event}`, #617) opts a plugin's OTLP log records into the per-session token/cost/latency meter: records named `<namespace>.<token_event>` must mirror Claude's `api_request` attribute keys (additive semantics, `session.id` join); the resolved namespace table is pushed to `OTLPReceiver` whenever the enabled-plugin set changes (`refreshOTLPPluginNamespaces`), and built-in namespaces can't be claimed. Note: sidecar child stderr goes to `~/.gallager/state/plugins/<id>/logs/stderr.log` (separate from `host.log()`'s `sidecar.log`). The bundled `gallager:create-agent-plugin` skill (`plugin/gallager/skills/create-agent-plugin/`) scaffolds one from a Python template + self-contained contract copy. Wire casing trap: `plugin.json` and the ingress *socket* frame are snake_case (`plugin_id`); the stdio *transport* (RPC params/results) is camelCase (`pluginID`, `sessionID`, …).
- **pi sidecar plugin (real example):** `plugins/pi/` - a complete working sidecar adding pi (`@earendil-works/pi-coding-agent`) support: Python `bin/sidecar` + a pi *extension* bridge (`pi-bridge/gallager.ts`, TypeScript via jiti, installed to `~/.pi/agent/extensions/gallager.ts`, marker `GallagerPiBridge`; per-project installs go to `<configRoot>/.pi/extensions/`). pi's event bus is complete — real `session_start` (launch + `/new`//`/resume`//`/fork`) and `session_shutdown` (quit incl. Ctrl+C/Ctrl+D/SIGHUP/SIGTERM) — so **no synthetic lifecycle frames and no WORKING/SEEN state machine** (contrast opencode): `session_start`→idle, `agent_start`→working, `agent_end`→doneWorking (summary = last assistant text, bridge-trimmed to 300 chars; stopReason `error`→errorMessage, `aborted`→"Interrupted"), `session_shutdown reason=quit`→`sessionEnded` keyed by PANE id (other reasons ignored — a `session_start` re-stamps the pane immediately; ending there would flicker the sidebar row). **Telemetry (#617):** the bridge POSTs one OTLP record per assistant `message_end` (event `pi.api_request`, Claude's attribute keys; usage comes complete on pi's AssistantMessage — thinking already folded into `output`; `duration_ms` = wall-clock `message_start`→`message_end`; `session.id` = pi's session UUID from `ctx.sessionManager.getSessionId()`, same id every PluginEvent reports). Projects scan reads `~/.pi/agent/sessions/*/` — dir names are lossy cwd munges, but each session file's FIRST line is a `SessionHeader` with the exact `cwd`; newest file per dir wins, `lastUsed` = mtime. Gotchas: pi's `ps` comm is `node` (a script), so manifest `process_names: ["pi"]` never matches a live pane — bridge events cover detection, but a pi already idle when Gallager launches stays invisible until its next event; pi quits on *rapid double* Ctrl+C (a lone one clears input); `-ne`/`--no-extensions` also disables provider packages (e.g. `pi-ollama-cloud`) → "No API key" (smoke-test with `-e path/to/gallager.ts`, not `-ne -e`). Core pi has no permission gating → no awaiting* forms. Tests: `python3 plugins/pi/tests/test_sidecar.py` (30). `./scripts/dev-install.sh` copies to `~/.gallager/plugins/pi/`.
- **opencode sidecar plugin (real example):** `plugins/opencode/` - a complete working sidecar adding opencode (sst) support: Python `bin/sidecar` + an opencode `event`-bus bridge plugin (`opencode-bridge/gallager.js`, installed to `~/.config/opencode/plugin/`) since opencode removed shell hooks. Maps `session.status`/`session.idle`/`session.error` to working/done/idle (per-session machine so a turn-end `idle` raises attention but a fresh-session `idle` doesn't); `permission.asked` → `awaitingPermission`; `question.asked` → `awaitingReplies` (multi-question + multi-select + free text). **Subagents (#670):** opencode runs each `task`-tool subagent in a child session (`info.parentID` set) that emits its own busy/idle — but `session.status`/`session.idle` OMIT `parentID` (opencode #30043), so the bridge also forwards `session.created`/`session.updated` (the only events carrying it), the sidecar records children in a `CHILD` map (child→parent), and DROPS all lifecycle events (`session.status`/`session.idle`/`session.error`) for child sessions. Only the root session drives the pane, so N subagents → exactly one "Finished working". Child `permission.asked`/`question.asked` are NOT dropped — opencode's TUI shows a child's prompt in the root session's view and blocks the turn — but are re-keyed to the root session (`_root_session` walks the parent chain) so a child id never becomes the pane's session. Ordering: opencode fires plugin `event` hooks without awaiting, so the bridge serializes all ingress frames through a FIFO send chain (awaited in the hook) — `session.created` always beats the child's churn. Bridge change ⇒ existing installs must re-Install for the fix. **Turn summaries:** opencode's idle events carry no text, so at a root session's turn-end idle the bridge fetches `client.session.messages` on the in-process SDK client (reachable in-process despite the unix-socket server that blocks the *sidecar*'s HTTP route), attaches the last assistant message's text (synthetic/ignored parts filtered, 300-char trim) as `properties.gallagerSummary` — fetched at idle-arrival but awaited INSIDE the FIFO send chain (awaiting in the hook would let a new turn's `busy` overtake the idle frame), 2s self-timeout, never rejects; sidecar surfaces it as `doneWorking(summary)` + notification body, falling back to "Finished — project". **Session lifecycle:** opencode fires NO event on a fresh idle launch or on quit, and the host's process scan only re-detects on pane add/remove (not when a process starts/dies in a live pane) — so the bridge emits two *synthetic* frames: `gallager.lifecycle.started` (on plugin load ≈ TUI start → sidecar emits `idle`, session appears) and `gallager.lifecycle.stopped` (from opencode's `dispose` hook ≈ graceful quit → sidecar emits `AppAction.sessionEnded` keyed by the PANE id → host removes the session). Mirrors Claude's SessionStart/SessionEnd (no notifications); `closePaneEligible` honors `close_pane_on_session_end`. dispose fires on `/exit` AND Ctrl-C (verified v1.17.11); a hard SIGKILL skips it (stale session lingers). **Forms are answered by KEYSTROKE injection** into the pane (opencode's TUI talks to its server over a unix socket — no reachable HTTP endpoint; the sidecar emits `send_keys` and Gallager just relays, so each agent's keystroke mapping is plugin-owned). opencode's question prompt uses number keys `1`-`9` (jump+toggle/pick) with a tabbed Confirm-submit for multi/multi-question. Projects surface in the sidebar "+" menu by reading opencode's SQLite store (`~/.local/share/opencode/opencode.db`, `project` table). opencode keys a project by its git *repo*, not folder, and stores only the FIRST worktree it saw — so a repo with multiple `git worktree`s would show just one, whichever opencode recorded. The scan expands each stored `worktree` into EVERY worktree of its repo via `git worktree list --porcelain` (so main + linked worktrees are each launchable, deduped across rows; falls back to the raw path for non-git dirs / missing git). The stored worktree keeps opencode's own `name`; other worktrees are labeled by basename. The scan opens the DB `mode=ro` (WAL-aware) not `immutable=1`, so a freshly-created project sitting in the WAL surfaces immediately (WAL readers never block the writer); it falls back to `immutable=1` only when `mode=ro` can't open (stale `-wal`, no `-shm`, no dir write access = opencode not running). **Telemetry (#617):** the bridge POSTs one OTLP/JSON record per *completed* assistant message (`message.updated` with `time.completed`, deduped by message id, never forwarded to the ingress socket) to the receiver's `/v1/logs`, event name `opencode.api_request`, Claude's exact attribute keys (reasoning folded into `output_tokens`), `session.id` = **opencode's `ses_…` session id** — the host re-stamps the pane's join key from every sidecar-reported event, and real opencode events report the ses id (the pane id, reported only by the synthetic launch frame, would stop joining at the first turn); the meter follows the pane's active session, resetting on session switch like `/clear`; the sidecar bakes the endpoint into the bridge at install via `__GALLAGER_OTLP_ENDPOINT__` (from initialize's `otlpReceiverEndpoint`; `GALLAGER_OTLP_ENDPOINT` env fallback for repo smoke tests; stale if the receiver's port changes → re-Install). Gotcha: `PluginEvent.appActions` is non-optional — a hand-built event JSON MUST include `"appActions": []` (or a populated list) or the host silently drops it. Tests: `python3 plugins/opencode/tests/test_sidecar.py` (42). `./scripts/dev-install.sh` **copies** it into `~/.gallager/plugins/` (folder-drop discovery skips symlinks).
- **Website (gallager.app):** `website/` - Astro static site (index/docs/pricing/security) replacing the old self-contained artifact bundles; one design system (`website/src/styles/modernist.css`), shared Nav/Footer/Hero components, content-as-data in page frontmatter. `npm run dev|build` in `website/`; deployed by `scripts/deploy.sh website` → `/opt/gallager-website` behind Caddy (`ClaudeSpyPackage/caddy/website.caddy`, DNS one-time step). See `website/README.md`.
