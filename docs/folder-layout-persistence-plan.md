# Folder Layout Persistence Plan

Status: 🚧 **In progress** — Phases 1–3 implemented on branch
`feat/folder-layout-persistence`; Phase 4 (E2E) and flush-on-quit pending.
Last updated: 2026-06-18

> **Implementation notes vs. the plan below.** What actually shipped in the
> first cut, where it diverges from the design:
> - **Model + mappers + store** (`Services/LayoutPersistence/`):
>   `SavedFolderLayout` / `SavedSessionLayout` / `SavedTabRef`,
>   `LayoutSnapshotMapper`, `LayoutFolderKey`, and the `LayoutStore` dependency
>   (in-memory + disk-backed). Covered by `LayoutSnapshotMapperTests` and
>   `LayoutStoreTests` (11 tests).
> - **File/browser tab UUIDs are preserved** into the restored session (a fresh
>   session has nothing to collide with), so only `.window` refs are re-mapped
>   by index. Simpler than the original "regenerate all ids" framing.
> - **Auto-save is change-gated per tmux refresh**, not a timer debounce:
>   `persistChangedLayouts()` runs inside `MainView`'s existing
>   `.onChange(of: tmuxService.panes)` and writes only when a session's snapshot
>   actually changed (`SavedFolderLayout` is `Equatable`). Cheap and naturally
>   batched; the loss window on a hard crash is one refresh interval.
> - **Seeding is once-per-session and clobber-safe**: `seedLayoutIfNeeded()`
>   (called from `handleSelectionChanged()`, the initial `.task`, and the pane
>   refresh) seeds only while the workbench is empty (`openFileTabs` /
>   `openBrowserTabs` / `rightSide` all empty — `tabOrder` is ignored since the
>   strip auto-populates window entries). No 40-site creation-funnel refactor.
> - **Storage backend:** a single JSON file
>   `~/Library/Application Support/Gallager/Layouts/layouts.json` (the plan left
>   per-file vs. combined open; combined won because debounced writes are rare).
> - **Still pending:** flush-on-quit (per-refresh save makes it low-priority);
>   `SavedFileTree.expandedPaths` is captured as `[]` for now (only
>   `sidebarWidth` restores); the E2E scenario (Phase 4).

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

### 4.2 Two-tier store — but one source of truth

R7 (each running session restores *its own* state) requires **per-session
fidelity** that a single per-folder slot can't provide: two sessions on one
folder would both re-seed from the same slot. So records are keyed by a
**durable session identity**, with the folder recorded on each record. The
"folder default" (R2/R5) is then *derived by query* rather than stored
separately — keeping a single source of truth and avoiding dual-write drift.

```swift
struct SavedSessionLayout: Codable, Sendable {
    var host: String           // local host id (v1: local only)
    var sessionName: String    // tmux session name — stable across app restarts
    var folder: String         // canonical project path, for validation
    var lastActive: Date       // for folder-default "most recent" query + pruning
    var layout: SavedFolderLayout
}
// persisted store: [SessionKey(host, sessionName): SavedSessionLayout]
```

`tmux session name is the durable identity` — tmux sessions outlive the app and
keep their names, so on cold launch a running session named `myproj` maps
directly back to its record.

### 4.3 Resolution order at workbench birth

When `MainView` would otherwise create an empty `SessionFileTabsState` for a
session (a dictionary miss), resolve the session's canonical folder, then:

1. **Record for this `host+sessionName` whose stored `folder` still matches** the
   session's current folder → restore it **exactly**. *(R2 reopen, R7 cold-launch
   of an existing session, R3 each session restores distinctly.)*
2. Else → **folder default**: among all records with the same `folder`, take the
   one with the most-recent `lastActive` and seed from it. *(R2 new session on a
   known folder, R5 single default.)*
3. Else → empty workbench.

Step 1's **folder-match guard** is essential: tmux names get recycled (kill
`myproj`, later create a new `myproj` on a different project). If the stored
folder no longer matches the live folder, fall through to the folder default
instead of restoring a stale layout onto the wrong project.

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

- **Local host only.** This is a local-Mac workbench concept (file tabs open
  local files; the browser is a local `WKWebView`). Remote/viewer sessions
  (`remoteSessionTabsStates`) stay transient.
- **No named layouts** (R5). If "throwaway session clobbers the folder default"
  becomes a real annoyance, named layouts are the future escape hatch (see §7).
- **Pruning.** Records accumulate as session names come and go. Garbage-collect
  on launch (drop records older than N days and/or cap total count).

## 5. Data model & components

New code (all in `ClaudeSpyServerFeature`, with the Codable models in a shared
spot if iOS ever needs them — v1 keeps them macOS-side):

| Component | Responsibility |
|---|---|
| `SavedFolderLayout` | Codable snapshot: file tabs, browser tabs, split, tab order, selection, file-tree |
| `SavedSessionLayout` | Codable record: host, sessionName, folder, lastActive, layout |
| `SavedTabRef` | Logical tab reference (path / url / window index / explorer / git) |
| `LayoutSnapshotMapper` | `SessionFileTabsState` (+ `FileBrowserState`) ⇄ `SavedFolderLayout`, with id re-mapping |
| `LayoutStore` | `@DependencyClient`: load / upsert / folder-default query / prune / flush; `liveValue` (file-backed under Application Support, or `PreferencesService` data keyed per session) + `inMemory()` |
| MainView wiring | folder resolution, seed-on-birth, debounced write, flush-on-terminate |

`LayoutStore` follows the project DI convention (`@DependencyClient struct`,
`DependencyKey` with `liveValue` and `inMemory()`), so E2E/unit tests can set up
a folder with a saved layout and assert it restores.

### Storage layout

Per-session keys (one record rewritten per debounced change avoids churning a
single combined blob on every write):

```
Application Support/Gallager/Layouts/<host>/<sha256(sessionName)>.json
```

(or `PreferencesService.data("layout.session.<host>.<hash>")` if we prefer to
stay on UserDefaults — decided in Phase 2.)

## 6. Implementation plan

**Phase 1 — Model + mappers (pure, unit-testable).**
`SavedFolderLayout` / `SavedSessionLayout` / `SavedTabRef` + `LayoutSnapshotMapper`.
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
folder, screenshot that tabs/split/tree restored. Verify cold-launch path (record
keyed by session name restores exactly; recycled-name guard falls through).
Pruning + edge cases.

## 7. Future work / out of scope

- **Named layouts per folder** ("review", "debugging") — the principled fix if
  most-recent-wins clobbering annoys. Builds on the same store (add a name to the
  key).
- **Per-session foreground-only writes** or a **"lock folder layout" toggle** —
  cheaper mitigations for clobbering.
- **Remote/viewer persistence** — would need host-portable file references.
- **Folder re-key on mid-life `cd`** — see §4.6.

## 8. Open questions

- Storage backend: dedicated JSON files under Application Support vs.
  `PreferencesService` data keys. (Lean: files — frequent per-session writes
  shouldn't churn a combined UserDefaults blob.)
- Whether to also persist `FileBrowserState` tree expansion in v1 or defer (R6
  says yes; cost is the expanded-path set + sidebar width — cheap, keep it).
- Pruning policy constants (max age / max count).
