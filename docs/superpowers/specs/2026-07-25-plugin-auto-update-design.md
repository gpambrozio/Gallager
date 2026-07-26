# Sidecar Plugin Auto-Update — Design

**Date:** 2026-07-25
**Status:** Approved

## Problem

URL-installed sidecar plugins never update. `PluginUpdateChecker` and the full
download/verify/install pipeline exist (`gallager plugin update [--apply]`), but
nothing triggers a check automatically, there is no UI, applying an update does
not reload the running sidecar (`PluginRegistry.enable` early-returns for active
plugins), and bridge files installed into agents' config locations (e.g.
`~/.pi/agent/extensions/gallager.ts`) are never refreshed — so an "updated"
plugin keeps running old code everywhere.

## Goals

- Per-plugin preference: check for updates automatically (default **on**), plus
  a manual "Check Now" button.
- Automatic checks when a new Gallager version is first launched (plugin
  releases usually accompany app releases), with a daily fallback.
- Updates install automatically into the Gallager plugin location and refresh
  the bridge in every agent location the user previously installed to.
- Inform the user a new version landed and that Gallager and/or agent sessions
  need restarting.

## Non-goals

- Updating bundled (`claude-code`, `codex`) or folder-dropped (dev-installed)
  plugins — they have no `manifestURL`.
- Auto-installing updates whose bundle host changed (`sourceChanged`) — those
  keep requiring the manual trust flow.
- Installing bridges into locations the user never opted into.
- Tracking whether agent sessions actually restarted.

## Architecture

### PluginUpdateManager (new)

`ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginUpdateManager.swift`
— `@MainActor @Observable`, created by `AppCoordinator` at boot, exposed to
SwiftUI via `@Environment`. Injected at init:

- `PluginRegistry` and `GallagerPaths`
- the existing `URLSessionProtocol` seam (streaming download stub for tests)
- `PreferencesService` (persists `lastRunAppVersion`, `lastPluginUpdateCheck`)
- `hasActiveSessions(pluginID:) -> Bool` closure from `AppCoordinator`
- the notification client (`TerminalNotificationService` pattern)
- a clock (for the daily timer; `TestClock` in tests)

Observable state: `checking: Bool`, `lastCheckDate: Date?`, per-plugin inline
result (up-to-date / updated / error), `manualReviewUpdates: [PluginUpdate]`
(source-changed), `restartNotices: [RestartNotice]` (in-memory; see UI).

### Registry model changes

Two fields on `PluginRegistryEntry`, both `decodeIfPresent` so existing
`registry.json` files load unchanged:

- `autoUpdate: Bool` — default `true`. The per-plugin toggle. Host-side
  concern, so it lives in the registry next to `source`/`enabled`, not in the
  plugin's `settings.json` (which is pushed to the sidecar).
- `needsBridgeRefresh: Bool` — default `false`. Set when an update commits but
  the sidecar could not be hot-swapped; consumed on the next `enable`.

The boot-time registry rewrite in `AppCoordinator` must preserve both fields
(same rule as `.url` source preservation).

### Triggers

Automatic checks cover entries with `source == .url`, non-nil `manifestURL`,
and `autoUpdate == true`:

1. **App-version change:** at launch, compare
   `VersionCompatibility.currentAppVersion` to the stored `lastRunAppVersion`.
   Different or absent → check now, then store the current version.
2. **Daily:** at launch if `lastPluginUpdateCheck` is >24h old, plus a
   24h repeating task while running (Gallager is long-lived; launch-only
   checks would starve).
3. **Manual:** per-plugin "Check Now" button — checks that single plugin
   regardless of its `autoUpdate` toggle, and applies a found update the same
   way (the button press is the consent; there is no separate
   "update available — Install" state except for source-changed updates).

### Check → apply

1. `PluginUpdateChecker.check(entries)` → `[PluginUpdate]` (existing, tested;
   best-effort, silently skips fetch errors).
2. `sourceChanged == false` → `PluginInstaller.install(manifestURL:,
   trustConfirmed: true)` — the existing pipeline unchanged: HTTPS-only
   manifest fetch, streaming SHA-256 verify, zip-slip/tree validation, atomic
   commit, registry rewrite.
3. `sourceChanged == true` → never auto-installed. Recorded in
   `manualReviewUpdates` and surfaced in the UI with a button into the
   existing `AddPluginSheet` trust flow.

### Post-install

Ordering matters: the bridge template ships inside the bundle, so the
`install` RPC must be served by the **new** sidecar — the old process would
write the old template.

1. **Hot-restart if idle:** if `hasActiveSessions(pluginID)` is false →
   explicit `disable(id)` then `enable(id)`. (Explicit disable-first avoids
   the known `enable` early-return no-op for active plugins.) If busy → skip
   the swap, set `needsBridgeRefresh = true`.
2. **Bridge refresh (only after a successful swap):** for each location in
   `[default] + additionalConfigFolders`, call `install_status`; wherever it
   reports `.installed`, call the `install` RPC. Only refreshes locations the
   user opted into. No version comparison — refresh is unconditional where
   installed, which also sidesteps the known trap of `install_status`
   reporting the sidecar's version constant instead of the on-disk bridge
   version.
3. **Deferred refresh:** the manager sweeps entries with
   `needsBridgeRefresh == true` after boot-time plugin enabling completes and
   after any hot-restart it performs, runs the same refresh, and clears the
   flag. Bridges can never be left stale.
4. Record a `RestartNotice` and fire one macOS notification per update batch.

## UI

### Per-plugin "Updates" section (`PluginAgentForm` in `AgentsSettingsView.swift`)

Shown only for URL-installed plugins; bundled and folder-dropped plugins show
no section (no dead toggles).

- Toggle **"Check for updates automatically"** → `autoUpdate` on the registry
  entry.
- Button **"Check Now"** with busy spinner; caption "Last checked: <relative
  date>"; inline result — "Up to date", "Updated to 0.2.2 — restart your pi
  sessions", or a red error (existing sibling-`Text` error pattern).
- Source-changed row: orange inline "Update 0.3.0 available from a new source —
  Review…" opening `AddPluginSheet`.

### Restart banner

Persistent orange `Section` banner at the top of the Agents settings pane
(same style as the existing agent-unavailable banner), one line per notice:

- Hot-swap succeeded → "pi updated to 0.2.0 — restart your pi sessions"
- Hot-swap skipped → "pi updated to 0.2.0 — restart Gallager and your pi
  sessions"

Banner state is in-memory on the manager: restarting the app is itself the
remedy for the Gallager half, and agent-session restarts can't be tracked, so
the notice clears on app restart. No settings-tab badge in v1.

### Notification

One macOS notification per batch via the existing Dependencies-injected
notification client: "Plugin updates installed: pi 0.2.0 — restart Gallager
and any pi sessions."

## Failure handling

- **Check failures:** automatic checks stay silent (existing checker
  behavior); the manual button surfaces the error inline.
- **Install failures:** atomic commit guarantees the old version keeps
  running. Log, show inline error, retry naturally at the next trigger — no
  retry loop.
- **Concurrency:** one in-flight check/apply at a time, guarded on the
  manager; a manual check during the daily check awaits it.
- **Downgrades:** `PluginUpdateChecker.isNewer` already rejects equal/older
  versions.

## Testing

- **Unit (`PluginUpdateManagerTests`):** version-change trigger, daily
  threshold, `autoUpdate` filtering, idle vs busy hot-restart,
  `needsBridgeRefresh` persistence + consumption on next enable,
  source-changed exclusion, concurrency guard. Uses the `URLSessionProtocol`
  stub, `PreferencesService.inMemory()`, and `TestClock` under
  `withMainSerialExecutor`.
- **Registry round-trip:** old `registry.json` without the new fields loads
  with defaults; fields survive the boot-time rewrite.
- **E2E:** echo-plugin-based scenario serving a bumped manifest locally;
  manual "Check Now"; verify banner + inline "Updated to…" status. Detailed in
  the implementation plan.

## Decisions log

- Trigger: version-change + daily fallback (user-approved).
- `autoUpdate` default **on** for URL-installed plugins (user-approved).
- Reload policy: **hot-restart if idle**, else restart notice (user-approved).
- Bridge scope: refresh **only where currently installed** (user-approved).
- Restart notice: **notification + persistent banner** (user-approved).
- Orchestration: new `PluginUpdateManager`, not AppCoordinator growth, not
  sidecar self-update (user-approved).
