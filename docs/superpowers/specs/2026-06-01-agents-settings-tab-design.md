# Agents Settings Tab + CLI-based Plugin Install + Codex Multi-Folder

**Date:** 2026-06-01
**Status:** Approved (design)
**Branch:** `plugin-system-v1-in-process` (PR #562)
**Supersedes/extends:** `docs/superpowers/specs/2026-05-29-plugin-system-v1-in-process.md` (§8 install, §11 settings)

## Summary

Three connected changes to the macOS app's settings and plugin install path:

1. **Add Codex multi-folder support** — let Gallager scan and install into multiple Codex
   config roots (`CODEX_HOME`), mirroring what Claude already does with `CLAUDE_CONFIG_DIR`.
2. **Remove the legacy per-agent controls from the General settings tab.**
3. **Rename the "Plugin" settings tab to "Agents"** and give it real, wired-up Claude and
   Codex settings, including per-folder plugin install state and Install/Uninstall buttons
   for both agents.

The install mechanism stays **CLI-driven**: Gallager installs a *proper plugin* via each
agent's own command line (`claude plugin …`, `codex plugin …`) and **never edits an agent's
settings files directly**. The branch's current file-writing installers
(`ClaudeCodeInstaller`/`CodexInstaller`, which write `~/.claude/settings.json` /
`~/.codex/hooks.json`) are removed in favor of this. The bundled plugins' hook scripts are
updated to talk to the new ingress socket instead of the removed HTTP server.

## Motivation

On the current branch:

- The General tab's Claude/Codex command + auto-run fields and the Project Folders list bind
  to legacy `AppSettings` (UserDefaults). The plugin cores read their config from
  `~/.gallager/state/plugins/<id>/settings.json`, which is seeded **once** by
  `PluginSettingsMigration` and never updated from the UI again — so edits after first launch
  are silently ineffective.
- The "Plugin" tab and its manual-install commands still install the **legacy marketplace
  plugin** whose `hook.py` POSTs to `~/.claudespy-port` — an endpoint this branch deleted. The
  install "succeeds" and shows a green "Plugin Installed" badge, but no events reach the app.
- Codex has no equivalent to Claude's multi-folder support: `CodexSettings` has no
  `additionalConfigFolders`, and the scanner reads exactly one `CODEX_HOME`/`~/.codex` root.

This design wires the settings surface to the real cores, makes install actually work against
the ingress-socket architecture, and brings Codex to parity with Claude.

## Decisions (resolved during brainstorming)

| Decision | Choice |
|---|---|
| Install mechanism | Agent CLI plugin install (marketplace + plugin); app never edits agent settings files; uninstall + status via the CLI. |
| Where install logic lives | In the `PluginCore` (each core shells out to its agent CLI), not in Mac-feature services. |
| Hook transport | Update both bundled `hook.py` scripts to write ingress-socket frames. |
| Close-pane toggle | **Per-agent** (per-plugin), not one global toggle. |
| Agents tab layout | **Segmented switcher** (Claude / Codex) showing the selected agent's settings + folders. |
| Codex multi-folder | Add `additionalConfigFolders` to Codex settings; scan + watch each root; install per root. |

## Architecture

### 1. `PluginCore` protocol changes

Install/uninstall/status are per-config-root and return a richer status:

```swift
/// nil configRoot = the agent's default root (~/.claude, ~/.codex).
func install(configRoot: String?) async throws -> InstallResult
func uninstall(configRoot: String?) async throws
func installStatus(configRoot: String?) async -> PluginInstallStatus

enum PluginInstallStatus: Sendable, Equatable {
    case installed(version: String?)
    case notInstalled
    case agentUnavailable   // the agent CLI binary could not be located
}
```

- Replaces `func isInstalled() async -> Bool`.
- `configRoot` is the folder value used as `CLAUDE_CONFIG_DIR` (Claude) / `CODEX_HOME` (Codex).
- Transient `installing` / `failed(reason)` states are **view state**, not core state.
- Conformers updated: `ClaudeCodePluginCore`, `CodexPluginCore`, `EchoPluginCore` (returns
  `.notInstalled`, install is a no-op), and the `gallager plugin call` CLI + `PluginRegistry.callCore`.

The cores shell out via the existing `ProcessRunner` dependency (already in `ClaudeSpyCommon`,
already a dependency of both core modules). The marketplace **source path** (the bundled
`plugin/gallager` for Claude, `plugin/codex` for Codex) is provided through `PluginEnv` —
populated by the registry from the app bundle — so install logic is unit-testable against a
fixture path and a mock `ProcessRunner`.

### 2. Per-agent CLI install

**Claude** (`ClaudeCodePluginCore`, porting the existing `PluginService` logic into the core):

```
[CLAUDE_CONFIG_DIR=<folder>] claude plugin marketplace add <bundle>/plugin
[CLAUDE_CONFIG_DIR=<folder>] claude plugin install gallager --scope user
[CLAUDE_CONFIG_DIR=<folder>] claude plugin list           # → installStatus
[CLAUDE_CONFIG_DIR=<folder>] claude plugin uninstall gallager
```

**Codex** (`CodexPluginCore`, restoring the logic deleted from `main`'s `CodexPluginInstaller`):

```
[CODEX_HOME=<folder>] codex plugin marketplace add <bundle>/plugin/codex
[CODEX_HOME=<folder>] codex plugin add gallager@gallager
[CODEX_HOME=<folder>] codex plugin list                   # → installStatus
[CODEX_HOME=<folder>] codex plugin remove gallager@gallager
```

`nil` configRoot omits the env prefix (default root). "Already installed" stderr is treated as
success. Each core locates its CLI binary (reuse `ClaudeBinaryLocator`; add a Codex locator)
and returns `.agentUnavailable` if absent.

### 3. Bundled plugins: hook transport → ingress socket

Both bundled hook scripts switch from the removed HTTP path (`~/.claudespy-port`) to the
ingress socket, reusing the frame-writing Python currently embedded as
`ClaudeCodeInstaller.bridgeScript`:

- `plugin/gallager/scripts/hook.py` → connects to `~/.gallager/state/ingress.sock`, writes one
  length-prefixed frame `{plugin_id:"claude-code", context, payload}` (context carries
  `TMUX_PANE` and `CLAUDE_PROJECT_DIR`).
- `plugin/codex/gallager/scripts/hook.py` → same, with `plugin_id:"codex"` and Codex's env
  (`TMUX_PANE`; Codex passes `cwd` in the payload, which `CodexTranslator` already parses).
- Bump `plugin/gallager/.claude-plugin/plugin.json` and
  `plugin/codex/gallager/.codex-plugin/plugin.json` versions so an existing (older, HTTP)
  install updates on reinstall.

The marketplace/plugin directory layout is otherwise unchanged, so the existing
`plugin/.claude-plugin/marketplace.json` and `plugin/codex/.agents/plugins/marketplace.json`
keep working and `verify_bundled_plugin` in `release.sh` still passes.

### 4. Per-plugin settings — wired to the cores

`ClaudeCodeSettings` / `CodexSettings` (Gallager's own
`~/.gallager/state/plugins/<id>/settings.json`) become the single source of truth and gain:

- `closePaneOnSessionEnd: Bool` — **per-agent** (both settings types).
- `additionalConfigFolders: [String]` — added to **`CodexSettings`** (`ClaudeCodeSettings`
  already has it).

The Agents tab edits a decoded copy and, on change (debounced), **writes settings.json and
calls `core.applySettings(raw)`** so the running core picks up the change live. This closes the
"edits don't reach the core" gap.

**Close-pane behavior folds into the core.** Today the app does
`guard closePaneEligible, settings.closePaneOnSessionEnd`. Instead, the core computes
`closePaneEligible = cleanExitAtPrompt && settings.closePaneOnSessionEnd`, and the app drops the
second clause and just honors the flag. This keeps the app agent-blind while making the toggle
per-agent (the app already tags each `AgentSession` with `pluginID`, so nothing else is needed).

**Legacy settings removal + migration.** The `AppSettings` agent fields
(`claudeCommandPath`, `autoRunClaudeInProjects`, `codexCommandPath`, `autoRunCodexInProjects`,
`closePaneOnSessionEnd`, `additionalClaudeFolders`) are deleted. `PluginSettingsMigration` reads
the **raw legacy UserDefaults keys directly** (not via `AppSettings` properties, which no longer
exist) once, guarded by its existing done-flag, and is extended to seed `additionalConfigFolders`
(Claude) and `closePaneOnSessionEnd` (both) into settings.json.

### 5. Codex multi-folder scanning + watching

- `CodexPluginCore` resolves its root set as `{default CODEX_HOME/~/.codex} ∪ additionalConfigFolders`.
- For each root it scans `<root>/sessions/` via `CodexScanner` and watches it via a
  `CodexSessionsWatcher` instance, merging discovered `AgentProject`s (deduped by path,
  most-recently-used wins) before `host.setProjects`.
- Mirrors the Claude scanner's existing multi-root shape.

### 6. Agents settings tab (renamed, segmented layout)

- `SettingsTab.plugin` → `.agents`; tab label "Agents".
- `AgentsSettingsView` replaces `PluginSettingsView`:
  - A segmented `Picker` (Claude Code / Codex), sourced from the registry's **registered** plugins
    (shown regardless of enabled state, so the user can install/configure either agent).
  - A `PluginAgentForm(pluginID:)` (the hand-written per-plugin form the `ClaudeCodeSettings`
    doc comment anticipates):
    - Agent-binary banner when `installStatus == .agentUnavailable`.
    - **Command** + Browse, **Auto-run**, **Log level**, per-agent **Close pane when <agent> exits**
      — bound to a decoded settings struct; on change → write settings.json + `applySettings`.
    - **Config folders** list = default root + `additionalConfigFolders`. Each row shows path,
      `installStatus` (`installed v… ✓` / Install button / "agent not found"), an
      Install/Uninstall action (with local `installing`/`failed` state), and a remove button on
      non-default rows. Plus **Add Folder…**.
  - Folder rows generalize today's `ClaudeFolderRow`, driven by `core.installStatus/install/uninstall`
    through `PluginRegistry`, not the legacy `PluginService`.

### 7. General tab

Remove the `Section("Claude Code")`, `Section("Codex CLI")`, and `Section("Project Folders")`
blocks from `SettingsView`. tmux, terminal app, and the rest stay. `browseForClaudeFolder` and
the folder-row helpers move to the Agents tab (generalized to take an agent/plugin id).

### 8. Removals & cleanup

- Delete `ClaudeCodePluginCore/ClaudeCodeInstaller.swift` and `CodexPluginCore/CodexInstaller.swift`
  and their tests (`ClaudeCodeInstallerTests`, `CodexInstallerTests`). The Python bridge content is
  preserved in the bundled `hook.py` scripts.
- Replace `PluginSettingsView`, `PluginService`, `ClaudeFolderRow`, `CustomFolderPluginSetupView`,
  and `PluginFailureDetailsButton` with the Agents-tab equivalents. The structured
  install-failure UI pattern (summary, failed step, command line, log, copy-to-clipboard) is
  reused, generalized to both agents.

## Data flow (install, one folder)

```
Agents tab Install button (folder F, plugin P)
  → PluginRegistry.callCore(P, install, configRoot: F)
    → core.install(configRoot: F)
      → ProcessRunner: [<ENV>=F] <agent> plugin marketplace add <bundle path>
      → ProcessRunner: [<ENV>=F] <agent> plugin {install|add} gallager…
    → returns InstallResult
  → view re-queries core.installStatus(configRoot: F) → row shows "installed v… ✓"
Later: agent runs in tmux → bundled hook.py → frame to ~/.gallager/state/ingress.sock
  → IngressSocketServer → core.handleIngress → PluginEvent → dispatcher → session UI
```

## Error handling

- All CLI shell-outs go through `ProcessRunner` with timeouts; non-zero exit → typed error
  carrying captured stderr, surfaced inline on the folder row (reused failure-detail UI).
- "Already installed" / "already registered" stderr is treated as success.
- Missing agent binary → `.agentUnavailable`, shown as a banner + disabled install buttons.
- settings.json write / `applySettings` failures are surfaced inline and logged to the plugin log
  sink; the in-memory edit is not lost.
- Defensive parsing throughout (spec §13): malformed `plugin list` output or settings JSON falls
  back to defaults, never traps.

## Testing

**Unit**

- Core `install`/`uninstall`/`installStatus` with a mock `ProcessRunner`: assert exact argv and
  that `CLAUDE_CONFIG_DIR` / `CODEX_HOME` env is set for non-nil `configRoot` and absent for nil.
  Assert "already installed" → success, non-zero → typed error, missing binary → `.agentUnavailable`.
- `ClaudeCodeSettings` / `CodexSettings` round-trip with the new `closePaneOnSessionEnd` /
  `additionalConfigFolders` fields and missing-key defaults.
- `PluginSettingsMigration` seeds the new fields from raw legacy UserDefaults keys, idempotently.
- `CodexScanner` multi-root merge with temp fixtures (dedup, most-recent-wins, home excluded).
- Close-pane: core sets `closePaneEligible` from clean-exit AND its setting; app honors the flag.

**E2E**

- An Agents-tab scenario: segmented switch Claude↔Codex; per-agent settings render and persist;
  folder rows show install status; the Install button drives a (faked) CLI install and flips the
  row to installed; General tab no longer shows the removed sections. CLI execution is behind the
  `ProcessRunner` dependency so the e2e harness injects a fake.

## Verification items (confirm during implementation)

1. **Codex `plugin` subcommands + `CODEX_HOME` scoping.** Confirm the installed Codex exposes
   `codex plugin marketplace add` / `plugin add` / `plugin list` / `plugin remove`, and that they
   honor `CODEX_HOME` for per-folder install/list. If Codex ignores `CODEX_HOME` for plugins,
   Codex install collapses to a single global install (scanning can still be multi-folder); update
   the Codex folder UI accordingly.
2. **Upgrade path.** Confirm `claude plugin install` / `codex plugin add` *update* an existing
   older "gallager" (hence the version bump). If they no-op on an existing install, the install
   action does uninstall-then-install when a version mismatch is detected.

## Out of scope

- iOS changes. The Agents tab is macOS-only; iOS plugin settings remain read-only
  ("Configured by Mac"). The wire protocol and `AgentResponseRequest` vocabulary are unchanged.
- New `AppAction` / `PluginEvent` vocabulary. Close-pane reuses the existing
  `AppAction.sessionEnded(closePaneEligible:)`; only the eligibility computation moves.
- Adding plugins beyond Claude Code and Codex.

## Rollout

Within the existing `plugin-system-v1-in-process` flag-day change (host + viewer ≥ 2.0); no
additional version floor. Users who installed an older gallager plugin get the updated
ingress-socket hook on reinstall from the Agents tab.
