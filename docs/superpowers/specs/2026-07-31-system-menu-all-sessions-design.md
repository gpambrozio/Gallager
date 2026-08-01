# System menu lists every tmux session (follow-on to issue #702 / PR #703)

**Date:** 2026-07-31
**Branch/PR:** `claude/issue-702` / PR #703 (added to the same PR)

## Problem

The macOS menu bar dropdown only lists sessions that own an agent session
(`MirrorWindowManager.sortedSessions` locally, `SessionStore.agentSessions(for:)`
per remote host). Terminal-only tmux sessions — local or remote — never appear,
and a remote host with only plain terminals is skipped entirely. With the manual
"Set State" override (#695/#702) a terminal-only session can carry a pinned
state, which the sidebar shows but the system menu cannot.

## Decisions (user-confirmed)

1. **Row unit stays per-agent for agent rows.** One row per agent pane exactly
   as today (project-name label, override-aware icon). Terminal-only sessions
   (no agent in *any* pane) each get ONE new row.
2. **A terminal-only session pinned to "Waiting for input" counts in the
   pending badge** (menu bar capsule, Dock tile, iOS badge pushes). This
   supersedes PR #703's scope note that a pinned plain terminal never inflates
   the badge. Invariant: **the badge number equals the number of bell rows in
   the dropdown**, in both override directions.
3. **The badge-decrease push gap is fixed in this PR** (section "Badge-decrease
   push" below).

## Design

### 1. Row composition (`MenuBarExtraView`)

- **Local agent rows:** unchanged (`windowManager.sortedSessions`).
- **Local terminal-only rows:** group `windowManager.paneStates` values by
  `sessionName`; keep sessions where no pane has an `agentSession`. One row per
  such session:
  - **Label:** the tmux session name.
  - **Icon:** the session's override state icon when a "Set State" pin is set
    (bell / figure.run / moon — same mapping as agent rows), else the plain
    terminal glyph (`Symbols.terminal`, matching `SessionStatusBadge`).
  - **Click:** existing `pendingMenuBarSelection = .local(paneId:)` using the
    session's active-window active pane (`isWindowActive && isActive`), falling
    back to the first pane by `(windowIndex, paneIndex)`. `MainView`'s handler
    already resolves any pane, agent or not.
  - **Order:** after the agent rows; pinned-to-Waiting sessions first, then by
    session name.
- **Remote rows (per host):** agent rows unchanged
  (`sessionStore.agentSessions(for:)`), then terminal-only sessions from
  `sessionStore.sessions(for: host.id)` filtered to `agentSession == nil`,
  using the existing `TmuxSession.displayedState` for the icon and
  `activeWindow?.activePane` for the click target. Same ordering rule.
- **Host section visibility:** a host section appears when the host has *any*
  panes (today: only when it has agent sessions).
- **Empty state:** "No active sessions" only when there are no panes at all,
  local or remote.

### 2. Pending badge count

A shared helper in `ClaudeSpyNetworking` (next to `PaneState.displayedState`),
operating on a collection of `PaneState`:

> pendingSessionCount = (agent panes with `displayedState == .waiting`)
> &nbsp;&nbsp;+ (distinct terminal-only sessions whose override is `.waiting`)

- The agent half keeps today's per-agent-pane counting.
- The terminal half counts a session **once** even though
  `setCLISessionState(_:forSession:)` stamps the override on every sibling
  pane, and only when *no* pane of that session owns an agent (a mixed session
  is already counted via its agent pane(s)).
- Call sites: `MirrorWindowManager.pendingSessionCount` (drives the menu bar
  capsule, Dock badge, and `pendingCountDecrease()` for iOS pushes) and the
  remote half of `totalPendingSessionCount` in `ClaudeSpyServerApp` — applied
  **per host** so same-named sessions on different hosts count separately.

### 3. Badge-decrease push

Neither "Set State" path calls `broadcastBadgeDecreaseIfNeeded()`:

- local: the sidebar context menu (`MainView`, `StateContextMenuButtons`
  callback);
- remote: the `setSessionState` command handler in `AppCoordinator`.

A pin that lowers the count (e.g. pinning a needs-attention session to Idle)
therefore never pushes the iOS badge down, violating the "every attention-clear
path emits a silent decrement push" invariant. Fix: invoke the broadcast after
both mutation paths.

### 4. Testing

- **`ClaudeSpyNetworkingTests`:** the count helper — agent-waiting panes,
  pinned terminal-only session counted once across multiple panes, mixed
  session not double-counted, pin-to-idle suppression unchanged.
- **`PluginRuntimeStatusWiringTests`:** extend the existing #702 wiring test so
  a pinned terminal-only session (no agent anywhere) bumps
  `pendingSessionCount` and unpinning drops it.
- **E2E:** none — the menu bar dropdown and badges are system surfaces the e2e
  harness cannot screenshot (same rationale recorded in PR #703). The sidebar
  half of the override is already covered by `SessionStateMenuScenario`.

## Out of scope

- Restructuring agent rows into one-row-per-tmux-session (explicitly declined).
- Badge *increase* pushes for pins (increases ride alert pushes by design;
  a pin has no notification — unchanged behavior).
- iOS app UI (viewer already renders sessions via the sidebar model).
