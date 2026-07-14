# Folder Layout Persistence Plan

Status: 🚧 **Implemented + E2E-proven** on branch
`feat/folder-layout-persistence`; flush-on-quit and file-tree expansion still
pending. Last updated: 2026-06-19

> **Layout is keyed by folder, not by session (revised 2026-06-19).** The first
> cut keyed records by `host + tmux sessionName` (to give each running session
> its own restore on cold launch — old R7). That backfired: tmux recycles
> session names (kill `ClaudeSpy-2`, create a new one on the same repo), so a
> freshly-created session would match the *dead* session's stale record and
> restore an old layout instead of the folder's current one. The folder-match
> guard only caught recycled names on a *different* folder, not the common
> same-folder case. **Fix:** one record per folder, keyed by `host + folder`
> (`SavedFolderRecord`). Any session on a folder restores that folder's layout;
> when two sessions share a folder, the most-recent live write wins. R7 is now
> "the folder restores its layout," not "each session restores its own."
>
> **Implementation notes vs. the plan below.** What actually shipped, where it
> diverges from the design:
> - **Model + mappers + store** (`Services/LayoutPersistence/`):
>   `SavedFolderLayout` / `SavedFolderRecord` / `SavedTabRef`,
>   `LayoutSnapshotMapper`, `LayoutFolderKey`, and the `LayoutStore` dependency
>   (in-memory + disk-backed). Covered by `LayoutSnapshotMapperTests` and
>   `LayoutStoreTests`.
> - **File/browser tab UUIDs are preserved** into the restored session (a fresh
>   session has nothing to collide with), so only `.window` refs are re-mapped
>   by index. Simpler than the original "regenerate all ids" framing.
> - **Auto-save runs on a 2s timer**, not on tmux events. The first cut hung it
>   on `.onChange(of: tmuxService.panes)`, but opening a file/browser tab or
>   splitting doesn't touch tmux, so a layout change could sit unsaved. A
>   periodic `MainView` `.task` calls `persistChangedLayouts()`, which writes
>   only when a session's snapshot actually changed (`SavedFolderLayout` is
>   `Equatable`). Loss window on a hard crash is ≤2s.
> - **Seeding is once-per-session and clobber-safe**: `seedLayoutIfNeeded()`
>   (called from `handleSelectionChanged()`, the initial `.task`, and the pane
>   refresh) seeds only while the workbench is empty (`openFileTabs` /
>   `openBrowserTabs` / `rightSide` all empty — `tabOrder` is ignored since the
>   strip auto-populates window entries). No 40-site creation-funnel refactor.
> - **Storage backend:** a single JSON file under the Gallager **state root**
>   (`~/.gallager/state/Layouts/layouts.json`, or the per-instance
>   `--gallager-state-root` under E2E) — consistent with the rest of the app's
>   state and isolated/auto-cleaned in tests. (The first cut used Application
>   Support; moved so E2E runs don't touch the real user library.)
> - **Same-folder cloning is intentional (decided 2026-06-18):** on the E2E tmux
>   socket every session shares one cwd, so selecting an empty sibling session
>   clones the folder's layout onto it. This broke `SplitTabScenario` Phase 5
>   (which expected an empty sibling); fixed by putting that scenario's `other`
>   session in a distinct cwd. Any scenario that opens tabs in one session and
>   asserts a same-folder sibling is empty needs the same treatment.
> - **E2E proof:** `FolderLayoutPersistenceScenario` (passes 3×) covers the
>   folder-default clone, post-clone divergence, and restore across a full app
>   restart (terminate + relaunch → the running session restores from disk).
> - **Still pending:** flush-on-quit (the 2s save makes it low-priority);
>   `SavedFileTree.expandedPaths` is captured as `[]` for now (only
>   `sidebarWidth` restores).

## 1. Goal

Persist and restore the macOS workbench layout — open file tabs, open browser
tabs, the split-view arrangement, and file-tree state — so that:

1. A session's workbench is **remembered across app restarts**. When the app
   launches fresh and re-attaches to the already-running tmux sessions, each
   running session restores *its own* prior layout.
2. A **brand-new session opened on a folder inherits that folder's last-known
   layout** as a starting point.
3. Saving and restoring are **fully automatic** — no buttons. The live state is
   continuously (debounced) persisted; restore happens when a session's
   workbench is first materialized.

There is **one layout "personality" per folder** (no named layouts in v1).

## 2. Background: how workbench layout works today

All workbench tab/layout state lives in one `@Observable` class,
`SessionFileTabsState` (`ServerFeature/Views/FileBrowserView.swift:271`), held in
`MainView` as transient `@State` dictionaries **keyed by tmux session name**:

```swift
// MainView.swift
@State private var sessionFileTabsStates: [String: SessionFileTabsState] = [:]
@State private var remoteSessionTabsStates: [RemoteSessionTabsKey: SessionFileTabsState] = [:]
@State private var fileBrowserStates: [String: FileBrowserState] = [:]
@State private var gitWorkbenchStores: [String: GitStoreEntry] = [:]
```

`SessionFileTabsState` holds exactly what we want to capture:

| Property | Meaning |
|---|---|
| `openFileTabs: [OpenFileTab]` | open files (`path`, `directoryPath`, `origin`) |
| `openBrowserTabs: [BrowserTab]` | in-app browser tabs (`url`, `displayTitle`, relationships) |
| `browserStates: [UUID: BrowserTabState]` | live `WKWebView` instances (NOT serializable) |
| `selectedFileTabId` / `selectedBrowserTabId` | active tab in the left pane |
| `tabOrder: [TabDragPayload]` | unified tab-strip ordering |
| `rightSide: Set<TabDragPayload>` | tabs moved to the right pane |
| `selectedRight: TabDragPayload?` | active right-pane tab |
| `splitRatio: CGFloat` | left-pane width fraction (`0.15…0.85`) |

`FileBrowserState` (`FileBrowserView.swift:77`) holds `sidebarWidth`, tree
expansion/selection (`viewState`), search state, and per-file scroll offsets.

Two facts drive the design:

- **It's already per-session and transient** — `@State`, gone on app restart.
  There is no per-folder persistence anywhere today.
- **The folder is derivable** from `PaneState.currentPath` (live, per-pane) or
  `AgentSession.detectedProjectPath` (snapshotted at session start).
  `PreferencesService` (UserDefaults wrapper) is the existing persistence
  primitive.

### Why we can't serialize the live state verbatim

`TabDragPayload` (`MainViewComponents/WindowTabBar.swift:800`) is `Codable`, but
its cases carry **instance-scoped** identifiers:

```swift
enum TabDragPayload: Codable, Hashable, Transferable {
    case window(String)   // tmux window id, e.g. "mysession:0" — session-name-scoped
    case fileExplorer
    case git
    case file(UUID)       // OpenFileTab.id — regenerated every session
    case browser(UUID)    // BrowserTab.id  — regenerated every session
}
```

None of `.file(UUID)` / `.browser(UUID)` / `.window("sess:0")` survive into a
new session. So `tabOrder` / `rightSide` cannot be persisted as-is. We persist a
**logical** representation (file *paths*, browser *URLs*, window *index*) and
re-map to fresh ids on restore.

## 3. Requirements recap

| # | Requirement | Source |
|---|---|---|
| R1 | Save a session's workbench layout per folder | Original ask |
| R2 | Restore on reopening the same folder in a session | Original ask |
| R3 | Handle two sessions on the same folder gracefully | Original ask |
| R4 | Auto-save live + auto-restore (no buttons) | Decision |
| R5 | Single default layout per folder (no named layouts) | Decision |
| R6 | Save: file tabs, browser tabs, split arrangement, file-tree state | Decision |
| R7 | On fresh app launch, already-running tmux sessions restore *their* state | Added requirement |

## 4. Design

### 4.1 The load-bearing invariant

> **Restore reads persisted layout only at a session workbench's *birth*. It
> never re-applies to a live workbench.**

Re-applying onto a session you've already arranged would destroy work, and there
is no sensible "continuously re-apply" semantic. "Auto-restore" therefore means:
**seed a freshly-materialized `SessionFileTabsState`**. "Auto-save" means: each
live session continuously (debounced) writes its snapshot.

This invariant is what makes R4's "auto" safe with R3's two-sessions case: live
state stays per-session and independent; nothing re-reads persisted layout into a
running workbench, so there is no live feedback loop.

### 4.2 One record per folder

Layout state is tied to the **folder**, not to a session. Records are keyed by
`host + folder`, so there is exactly one slot per folder and no per-session
bookkeeping, no "default" derivation, and no dual-write drift.

```swift
struct SavedFolderRecord: Codable, Sendable {
    var host: String           // local host id (v1: local only)
    var folder: String         // canonical project path — the identity
    var lastActive: Date       // most-recent-write-wins + pruning
    var layout: SavedFolderLayout
}
// persisted store: [Key(host, folder): SavedFolderRecord]
```

**Why folder, not `sessionName`?** tmux session names are recycled — kill
`ClaudeSpy-2`, later create a new one on the same repo and it reuses the name.
Keying by name meant a brand-new session matched the dead session's stale record
and restored an old layout instead of the folder's current one. A folder is a
durable identity; a recycled name is not.

**Trade-off (accepted):** when two sessions are live on the same folder at once,
they share the one record — whoever writes last defines what the next-born
session and the next app launch restore. This is the "single layout personality
per folder" decision (R5) taken to its conclusion. The alternative (per-session
records) is the named-layouts follow-up in §7 if it's ever wanted.

### 4.3 Resolution order at workbench birth

When `MainView` would otherwise create an empty `SessionFileTabsState` for a
session (a dictionary miss), resolve the session's canonical folder, then:

1. **Record for this `host+folder`** → seed the workbench from it. *(R2 reopen,
   R2 new session on a known folder, R7 cold-launch of a running session — all
   one path now.)*
2. Else → empty workbench.

Seeding is **once-per-session and only while the workbench is empty**, so a live,
already-arranged session is never re-read from disk (the §4.1 invariant). A
recycled session name re-seeds from scratch because its seed bookkeeping is
cleared when the old session disappears.

### 4.4 What gets saved, and how it maps back

| Saved (logical) | Restores to | Notes |
|---|---|---|
| File tab `path` + `directoryPath` | `OpenFileTab` (fresh UUID) | `origin` is dropped/neutralized — it referenced now-dead window ids |
| Browser tab `url` + `title` + parent | `BrowserTab` (fresh UUID) + new `BrowserTabState` | `WKWebView` is re-created from the URL, never serialized |
| `splitRatio` | `splitRatio` | clamped `0.15…0.85` |
| `rightSide` / selection as `[SavedTabRef]` | `rightSide` / selection (re-mapped) | logical refs, not UUIDs |
| `tabOrder` as `[SavedTabRef]` | `tabOrder` (re-mapped) | window refs by *index*; drop if absent |
| File-tree: `sidebarWidth`, expanded paths | `FileBrowserState` | scroll offsets / search query **not** saved (too ephemeral) |

The logical reference type:

```swift
enum SavedTabRef: Codable, Hashable, Sendable {
    case file(path: String)
    case browser(url: URL)
    case window(index: Int)   // best-effort: tmux window index in the session
    case fileExplorer
    case git
}
```

**Window tabs can't be recreated** — they are the agent's live tmux windows. On
restore, a `.window(index:)` maps only if the new session actually has a window
at that index, otherwise it is dropped. So a saved layout is mostly about the
*auxiliary* tabs (files / browser / git / explorer) and the split *shape*; the
terminal windows come from whatever the live session currently has.

### 4.5 Cold-launch specifics (R7)

- **Rides the existing birth hook.** On cold launch every `@State` dictionary is
  empty. As `MirrorWindowManager` discovers the running sessions/panes, MainView
  materializes each `SessionFileTabsState` on first render → dictionary miss →
  the resolution order in §4.3 fires. No separate batch path.
- **Lazy / staggered is fine and preferred.** Sessions/panes are discovered
  asynchronously (initial scan + 5 s validation). Seeding on first *view* means a
  background session restores when you look at it — we don't rebuild N
  `WKWebView`s at launch for sessions never opened, and there's nothing visible
  to restore for an unviewed session anyway.
- **Folder must be resolvable at seed time.** Don't seed before the session's
  folder is known (`detectedProjectPath` → git root → active pane `currentPath`).
  If discovery hasn't stamped it yet, defer the seed to the first render where it
  is available. (The dictionary-miss point is already after pane discovery, so
  this mostly holds — it's the one timing edge to verify.)
- **Flush on quit.** Auto-save is debounced (~750 ms); a pending write can be in
  flight at quit. Hook app termination to flush, otherwise the *last* change —
  exactly the one you'd notice — is lost on relaunch.

### 4.6 Folder identity

Canonical key resolution order, normalized (resolve symlinks, expand `~`, strip
trailing slash):

1. `AgentSession.detectedProjectPath`
2. git repository root of the active pane
3. active pane `currentPath`

Edge case (deferred): a session that `cd`s into a *different* project mid-life
should begin writing to the new folder's record. v1 may re-key on folder change
or simply keep the session's original folder; to be decided during
implementation.

### 4.7 Scope & limits (v1)

- **Local + remote/viewer (Scope A).** v1 shipped local-only. Remote/viewer
  sessions are now persisted too (issue #608) — see §4.8. Cross-viewer /
  host-authoritative layout sync (Scope B) remains out of scope (§7).
- **No named layouts** (R5). If "throwaway session clobbers the folder default"
  becomes a real annoyance, named layouts are the future escape hatch (see §7).
- **Pruning.** Records accumulate as folders come and go. Garbage-collect on
  launch (drop records older than N days and/or cap total count). For remote
  records there is a third axis: drop records whose host is no longer in
  `pairedHosts` (`LayoutStore.pruneHosts`, §4.8).

### 4.8 Remote / viewer persistence (Scope A — issue #608)

A Mac viewing a paired Mac host persists each remote session's workbench the
same way it persists local ones, so the viewer restores **its own** arrangement
for a remote session across reconnect / app restart. This is *viewer-local*: the
arrangement is never synced back to the host or to other viewers (that's Scope
B, §7).

The store and mapper are host-agnostic, so the same `layouts.json` holds both
local and remote records — distinguished by the `host` field:

- **Per-record host.** Local records use `host = "local"`; remote records use
  the host's `pairId` (the stable pairing id, persisted on both ends). A pairId
  is UUID-shaped, so it never collides with `"local"`.
- **Remote folder identity.** The remote session's folder comes from the synced
  pane state (`agentSession.detectedProjectPath ?? currentPath` in
  `SessionStore`). It is normalized **string-only**
  (`LayoutFolderKey.canonicalizeRemote`: strip a trailing slash, *no* `~` /
  symlink resolution) — a remote path lives on the host's disk, so resolving it
  against the *viewer's* filesystem would be wrong.
- **Browser-only.** Remote file browsing doesn't exist yet, so remote
  persistence covers **browser tabs + split arrangement + selection** only. The
  snapshot's `fileTabs` come out empty (the mapper already tolerates that) and
  there is no `FileBrowserState` to seed.
- **Same birth/save invariant (§4.1).** Seeding happens once per remote session
  while its workbench is empty (`seedRemoteLayoutIfNeeded`); auto-save runs on
  the same 2 s cadence (`persistChangedRemoteLayouts`). Bookkeeping
  (`seededRemoteSessions`, `lastPersistedRemoteLayouts`,
  `pendingRemoteLayoutSaves`) is keyed by `(hostId, sessionName)` and cleared
  when a host unpairs, in lockstep with `remoteSessionTabsStates`.

> **Note on the relaunch path under E2E.** A true viewer quit/relaunch restore
> reads the disk record back, but it can't be E2E-tested today: under
> `--e2e-test` each instance backs `PreferencesService` in-memory, so a
> relaunched viewer loses its pairing and can't reconnect. The E2E scenario
> (`RemoteLayoutPersistenceMacViewerScenario`) proves the live save → store →
> seed pipeline via the same-folder sibling-session clone instead; the disk
> round trip is covered by `LayoutStoreTests`.

## 5. Data model & components

New code (all in `ClaudeSpyServerFeature`, with the Codable models in a shared
spot if iOS ever needs them — v1 keeps them macOS-side):

| Component | Responsibility |
|---|---|
| `SavedFolderLayout` | Codable snapshot: file tabs, browser tabs, split, tab order, selection, file-tree |
| `SavedFolderRecord` | Codable record: host, folder, lastActive, layout — keyed by `(host, folder)` |
| `SavedTabRef` | Logical tab reference (path / url / window index / explorer / git) |
| `LayoutSnapshotMapper` | `SessionFileTabsState` (+ `FileBrowserState`) ⇄ `SavedFolderLayout`, with id re-mapping |
| `LayoutStore` | `@DependencyClient`: `record(forFolder)` / `save` / `remove` / `prune`; `liveValue` (single JSON under the Gallager state root) + `inMemory()` |
| MainView wiring | folder resolution, seed-on-birth, debounced write, flush-on-terminate |

`LayoutStore` follows the project DI convention (`@DependencyClient struct`,
`DependencyKey` with `liveValue` and `inMemory()`), so E2E/unit tests can set up
a folder with a saved layout and assert it restores.

### Storage layout

A single combined JSON file holding every folder record, rewritten atomically on
each (debounced) change — the write is rare enough that one blob is fine:

```
~/.gallager/state/Layouts/layouts.json   (or <--gallager-state-root>/Layouts/ under E2E)
```

## 6. Implementation plan

**Phase 1 — Model + mappers (pure, unit-testable).**
`SavedFolderLayout` / `SavedFolderRecord` / `SavedTabRef` + `LayoutSnapshotMapper`.
Round-trip tests: `SessionFileTabsState` → snapshot → new `SessionFileTabsState`
preserves file tabs, browser URLs, split ratio, and logical tab order; window
refs absent in the target session are dropped.

**Phase 2 — `LayoutStore` dependency.**
`liveValue` persistence + `inMemory()`; per-session upsert, folder-default query,
prune-on-launch, flush. Tests against `inMemory()`.

**Phase 3 — Wire into MainView.**
Folder resolution helper; seed at the `SessionFileTabsState` dictionary-miss;
debounced auto-save on layout mutation; flush on app terminate. Local sessions
only.

**Phase 4 — E2E + polish.**
E2E scenario: seed a folder layout via `inMemory()`, open a fresh session on that
folder, screenshot that tabs/split/tree restored. Verify cold-launch path (a
running session restores the folder record) and that a recycled session name on
the same folder picks up the folder's *current* layout, not a stale one.
Pruning + edge cases.

## 7. Future work / out of scope

- **Named layouts per folder** ("review", "debugging") — the principled fix if
  most-recent-wins clobbering annoys. Builds on the same store (add a name to the
  key).
- **Per-session foreground-only writes** or a **"lock folder layout" toggle** —
  cheaper mitigations for clobbering.
- **Remote/viewer persistence (Scope A)** — ✅ shipped (issue #608, §4.8):
  viewer-local persistence of remote sessions' browser tabs + split.
- **Cross-viewer / host-authoritative layout sync (Scope B)** — *out of scope.*
  Syncing a viewer's arranged layout back to the relay/host or to other viewers
  would need a new relay message type (today `CommandType` has no "set layout"
  verb) plus cross-viewer conflict handling. Tracked separately if ever needed.
- **Remote file tabs** — blocked on remote file browsing not existing yet; until
  then remote persistence is browser-tabs-only (§4.8).
- **Folder re-key on mid-life `cd`** — see §4.6.

## 8. Open questions

- Storage backend: dedicated JSON files under Application Support vs.
  `PreferencesService` data keys. (Lean: files — frequent per-session writes
  shouldn't churn a combined UserDefaults blob.)
- Whether to also persist `FileBrowserState` tree expansion in v1 or defer (R6
  says yes; cost is the expanded-path set + sidebar width — cheap, keep it).
- Pruning policy constants (max age / max count).
