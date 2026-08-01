# System Menu Lists Every Tmux Session — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The macOS menu bar dropdown lists terminal-only tmux sessions (local and remote) alongside agent sessions, a pinned terminal-only session counts in the pending badge, and every "Set State" mutation path emits the iOS badge-decrease push.

**Architecture:** A new `TerminalOnlySession` value + two collection helpers in `ClaudeSpyNetworking` (grouping panes into terminal-only session rows, and the badge count) feed `MenuBarExtraView` (rows), `MirrorWindowManager.pendingSessionCount` (local badge), and `ClaudeSpyServerApp.totalPendingSessionCount` (remote badge half, applied per host). Three existing "Set State" mutation paths gain the badge-decrease broadcast.

**Tech Stack:** Swift 6.3, SwiftUI (MV, no ViewModels), Swift Testing (`@Test`/`#expect`), Point-Free Dependencies (tests only).

**Spec:** `docs/superpowers/specs/2026-07-31-system-menu-all-sessions-design.md` (approved). Builds on PR #703 (branch `claude/issue-702`).

## Global Constraints

- Swift 6.3+, Swift Concurrency only (no GCD); all cross-boundary types `Sendable`.
- SF Symbols only via the `Symbols` enum (`Symbols.terminal` already exists).
- Build/test ONLY via XcodeBuildTools skills: `swift-package` for package tests, `xcodebuild` for the `ClaudeSpyServer` scheme. Never raw `swift`/`xcodebuild` in Bash.
- A `PostToolUse` swiftformat hook rewrites edited Swift files — re-read a file if an edit is reported as amended.
- No wire-format changes in this plan (no new Codable fields), so no `VersionCompatibility` bump.
- The badge invariant: **badge number == number of bell rows in the dropdown**, in both override directions.
- Commit after each task on branch `claude/issue-702` (it feeds existing PR #703). Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `TerminalOnlySession` + collection helpers in ClaudeSpyNetworking

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/PaneStateCollections.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/TerminalOnlySessionTests.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift:370-379` (adopt helper)
- Modify (test): `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRuntimeStatusWiringTests.swift` (add one test after `pendingSessionCountHonorsOverride`, which ends near line 407)

**Interfaces:**
- Consumes: `PaneState` (fields `sessionName`, `windowIndex`, `paneIndex`, `isActive`, `isWindowActive`, `agentSession`, `cliSessionState`, `displayedState`), `CLISessionState`.
- Produces (later tasks rely on these exact names):
  - `public struct TerminalOnlySession: Equatable, Sendable, Identifiable { let sessionName: String; let displayedState: CLISessionState?; let representativePaneId: String }`
  - `extension Collection where Element == PaneState { public func terminalOnlySessions() -> [TerminalOnlySession]; public var pendingSessionCount: Int }`

- [ ] **Step 1: Write the failing tests**

Create `ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/TerminalOnlySessionTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("TerminalOnlySession grouping")
struct TerminalOnlySessionGroupingTests {
    @Test("Panes group into one row per agent-less session; a session with any agent pane is excluded")
    func groupsAgentlessSessionsOnly() {
        let panes = [
            // "scratch": two windows, no agent anywhere -> one row.
            PaneState(paneId: "%1", sessionName: "scratch", windowIndex: 0, paneIndex: 0),
            PaneState(paneId: "%2", sessionName: "scratch", windowIndex: 1, paneIndex: 0),
            // "work": agent in one window, plain terminal in another -> excluded
            // (its agent pane is already a menu row).
            PaneState(paneId: "%3", sessionName: "work", windowIndex: 0, paneIndex: 0),
            PaneState(
                paneId: "%4", sessionName: "work", windowIndex: 1, paneIndex: 0,
                agentSession: AgentSession(paneId: "%4")
            ),
        ]
        let rows = panes.terminalOnlySessions()
        #expect(rows.map(\.sessionName) == ["scratch"])
        #expect(rows.first?.displayedState == nil)
    }

    @Test("Representative pane is the active window's active pane, else the first by (window, pane) index")
    func picksRepresentativePane() {
        let active = [
            PaneState(paneId: "%1", sessionName: "s", windowIndex: 0, paneIndex: 0),
            PaneState(paneId: "%2", sessionName: "s", windowIndex: 1, paneIndex: 0, isActive: true, isWindowActive: true),
        ]
        #expect(active.terminalOnlySessions().first?.representativePaneId == "%2")

        // No pane flagged active (stale scan): fall back to lowest (window, pane).
        let stale = [
            PaneState(paneId: "%9", sessionName: "s", windowIndex: 2, paneIndex: 1),
            PaneState(paneId: "%8", sessionName: "s", windowIndex: 0, paneIndex: 0),
        ]
        #expect(stale.terminalOnlySessions().first?.representativePaneId == "%8")
    }

    @Test("A pinned session carries its override as displayedState; rows sort waiting-first then by name")
    func overrideAndSorting() {
        let panes = [
            PaneState(paneId: "%1", sessionName: "alpha", windowIndex: 0, paneIndex: 0),
            PaneState(paneId: "%2", sessionName: "zeta", windowIndex: 0, paneIndex: 0, cliSessionState: .waiting),
            PaneState(paneId: "%3", sessionName: "beta", windowIndex: 0, paneIndex: 0, cliSessionState: .idle),
        ]
        let rows = panes.terminalOnlySessions()
        #expect(rows.map(\.sessionName) == ["zeta", "alpha", "beta"])
        #expect(rows.map(\.displayedState) == [.waiting, nil, .idle])
    }

    @Test("Panes with an empty session name never form a row")
    func skipsEmptySessionName() {
        let panes = [PaneState(paneId: "%1", cliSessionState: .waiting)]
        #expect(panes.terminalOnlySessions().isEmpty)
    }
}

@Suite("PaneState collection pendingSessionCount")
struct PendingSessionCountTests {
    @Test("Agent panes count per pane when displayed waiting; override wins both directions")
    func agentHalf() {
        let panes = [
            // doneWorking -> displayed .waiting, counts.
            PaneState(
                paneId: "%1", sessionName: "a", windowIndex: 0, paneIndex: 0,
                agentSession: AgentSession(paneId: "%1", state: .doneWorking(summary: nil))
            ),
            // idle agent pinned to waiting -> counts.
            PaneState(
                paneId: "%2", sessionName: "b", windowIndex: 0, paneIndex: 0,
                agentSession: AgentSession(paneId: "%2", state: .idle),
                cliSessionState: .waiting
            ),
            // needs-attention agent pinned to idle -> suppressed.
            PaneState(
                paneId: "%3", sessionName: "c", windowIndex: 0, paneIndex: 0,
                agentSession: AgentSession(paneId: "%3", state: .doneWorking(summary: nil)),
                cliSessionState: .idle
            ),
        ]
        #expect(panes.pendingSessionCount == 2)
    }

    @Test("A pinned terminal-only session counts once across its panes; unpinned or pinned-idle counts zero")
    func terminalHalf() {
        let pinned = [
            PaneState(paneId: "%1", sessionName: "s", windowIndex: 0, paneIndex: 0, cliSessionState: .waiting),
            PaneState(paneId: "%2", sessionName: "s", windowIndex: 1, paneIndex: 0, cliSessionState: .waiting),
        ]
        #expect(pinned.pendingSessionCount == 1)

        let unpinned = [PaneState(paneId: "%1", sessionName: "s", windowIndex: 0, paneIndex: 0)]
        #expect(unpinned.pendingSessionCount == 0)

        let pinnedIdle = [PaneState(paneId: "%1", sessionName: "s", windowIndex: 0, paneIndex: 0, cliSessionState: .idle)]
        #expect(pinnedIdle.pendingSessionCount == 0)
    }

    @Test("A mixed session pinned to waiting counts via its agent pane only — never double")
    func mixedSessionNotDoubleCounted() {
        // setCLISessionState(forSession:) stamps every sibling pane, so the
        // terminal sibling also carries .waiting — it must not add a second count.
        let panes = [
            PaneState(
                paneId: "%1", sessionName: "work", windowIndex: 0, paneIndex: 0,
                agentSession: AgentSession(paneId: "%1", state: .idle),
                cliSessionState: .waiting
            ),
            PaneState(paneId: "%2", sessionName: "work", windowIndex: 1, paneIndex: 0, cliSessionState: .waiting),
        ]
        #expect(panes.pendingSessionCount == 1)
    }
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Use the `XcodeBuildTools:swift-package` skill to run tests for package `ClaudeSpyPackage`, filter `TerminalOnlySessionGroupingTests`/`PendingSessionCountTests`.
Expected: build FAILURE — `terminalOnlySessions()`/`pendingSessionCount` don't exist yet.

- [ ] **Step 3: Implement the helpers**

Create `ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/PaneStateCollections.swift`:

```swift
import Foundation

/// A tmux session none of whose panes owns an agent session — the system
/// menu's terminal-only rows (issue #702 follow-on). Agent-owning sessions are
/// represented in the menu by their agent panes instead, so a session appears
/// exactly once whichever bucket it falls in.
public struct TerminalOnlySession: Equatable, Sendable, Identifiable {
    /// The tmux session name; also the menu row label.
    public let sessionName: String

    /// The manual "Set State" override, if the session is pinned. With no
    /// agent anywhere in the session this IS the displayed state
    /// (`CLISessionState.displayed(override:agentState:)` with a nil agent);
    /// `nil` renders the plain terminal glyph.
    public let displayedState: CLISessionState?

    /// The pane a menu-row click should select: the active window's active
    /// pane, else the first pane by `(windowIndex, paneIndex)`.
    public let representativePaneId: String

    public var id: String { sessionName }

    public init(sessionName: String, displayedState: CLISessionState?, representativePaneId: String) {
        self.sessionName = sessionName
        self.displayedState = displayedState
        self.representativePaneId = representativePaneId
    }
}

extension Collection where Element == PaneState {
    /// Groups these panes into terminal-only sessions: one entry per session
    /// whose panes ALL lack an agent session, sorted pinned-to-Waiting first,
    /// then by session name. The override is scanned across every pane
    /// (mirroring `TmuxSession.cliSessionState`) so a partial stamp still
    /// surfaces. Panes with an empty session name (agent-only upserts that
    /// haven't been reconciled with a tmux scan yet) never form a row.
    public func terminalOnlySessions() -> [TerminalOnlySession] {
        Dictionary(grouping: self, by: \.sessionName)
            .compactMap { sessionName, panes -> TerminalOnlySession? in
                guard !sessionName.isEmpty,
                      panes.allSatisfy({ $0.agentSession == nil })
                else { return nil }
                let ordered = panes.sorted {
                    ($0.windowIndex, $0.paneIndex) < ($1.windowIndex, $1.paneIndex)
                }
                guard let representative = ordered.first(where: { $0.isWindowActive && $0.isActive })
                    ?? ordered.first
                else { return nil }
                return TerminalOnlySession(
                    sessionName: sessionName,
                    displayedState: panes.compactMap(\.cliSessionState).first,
                    representativePaneId: representative.paneId
                )
            }
            .sorted {
                if ($0.displayedState == .waiting) != ($1.displayedState == .waiting) {
                    return $0.displayedState == .waiting
                }
                return $0.sessionName < $1.sessionName
            }
    }

    /// The pending badge count over these panes: agent panes whose displayed
    /// state is `.waiting` (per agent pane, honoring the manual override in
    /// both directions — issue #702) PLUS terminal-only sessions pinned to
    /// `.waiting`, counted once per session even though the override stamps
    /// every sibling pane. Equals the number of bell rows the menu dropdown
    /// renders for the same panes. Callers with panes from several hosts must
    /// apply this per host so same-named sessions don't merge.
    public var pendingSessionCount: Int {
        let agentPending = filter { $0.agentSession != nil && $0.displayedState == .waiting }.count
        let terminalPending = terminalOnlySessions().count { $0.displayedState == .waiting }
        return agentPending + terminalPending
    }
}
```

- [ ] **Step 4: Run the new tests to verify they pass**

Same `swift-package` invocation as Step 2. Expected: all 7 new tests PASS.

- [ ] **Step 5: Adopt the helper in `MirrorWindowManager.pendingSessionCount`**

In `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift` replace the property (currently lines 370-379) with:

```swift
    /// Number of sessions that need user attention: agent panes displayed as
    /// Waiting (the manual "Set State" override wins in both directions —
    /// issue #702) plus terminal-only sessions pinned to Waiting, counted once
    /// per session (`Collection.pendingSessionCount`). Matches the number of
    /// bell rows the menu bar dropdown shows.
    public var pendingSessionCount: Int {
        paneStates.values.pendingSessionCount
    }
```

- [ ] **Step 6: Add the wiring test for the terminal-only half**

In `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRuntimeStatusWiringTests.swift`, directly after the `pendingSessionCountHonorsOverride` test (ends near line 407), add:

```swift
        @Test("a pinned terminal-only session counts once; unpinning drops the count and reports the decrease")
        func pendingCountCountsPinnedTerminalSession() {
            let windowManager = makeWindowManager()

            // Two windows in one tmux session, no agent anywhere.
            windowManager.updatePaneStates(from: [
                PaneInfo(
                    paneId: "%7", target: "scratch:0.0", sessionName: "scratch",
                    windowIndex: 0, paneIndex: 0, command: "zsh", currentPath: "/tmp",
                    width: 80, height: 24, isActive: true
                ),
                PaneInfo(
                    paneId: "%8", target: "scratch:1.0", sessionName: "scratch",
                    windowIndex: 1, paneIndex: 0, command: "zsh", currentPath: "/tmp",
                    width: 80, height: 24, isActive: true
                ),
            ])
            #expect(windowManager.pendingSessionCount == 0)

            // Pin the whole session to Waiting: one bell row, one count —
            // even though the override lands on both panes.
            windowManager.setCLISessionState(.waiting, forSession: "scratch")
            #expect(windowManager.pendingSessionCount == 1)
            // Advance the high-water mark (increase -> no decrease reported).
            #expect(windowManager.pendingCountDecrease() == nil)

            // Unpin: count drops and the drop is reported for the iOS badge push.
            windowManager.setCLISessionState(nil, forSession: "scratch")
            #expect(windowManager.pendingSessionCount == 0)
            #expect(windowManager.pendingCountDecrease() == 0)
        }
```

- [ ] **Step 7: Run both affected suites**

Via `swift-package` skill: run `ClaudeSpyNetworkingTests` (filter `TerminalOnlySession`/`PendingSessionCount` plus the existing `PaneStateDisplayedStateTests`) and `ClaudeSpyServerFeatureTests` (filter `PluginRuntimeStatusWiringTests`).
Expected: PASS, including the pre-existing `pendingSessionCountHonorsOverride` (the helper must not change agent-half semantics).

- [ ] **Step 8: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyNetworking/Models/PaneStateCollections.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyNetworkingTests/TerminalOnlySessionTests.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Managers/MirrorWindowManager.swift \
        ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRuntimeStatusWiringTests.swift
git commit -m "Add TerminalOnlySession grouping + shared pending count helper (#702)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Remote plumbing — `SessionStore.terminalOnlySessions(for:)` + per-host badge half

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/SessionStore.swift:103-108` (add method after `panes(for:)`)
- Modify: `ClaudeSpyServer/ClaudeSpyServerApp.swift:597-610` (`totalPendingSessionCount`)

**Interfaces:**
- Consumes: `Collection.pendingSessionCount`, `Collection.terminalOnlySessions()`, `TerminalOnlySession` (Task 1); `SessionStore.paneStates: [PaneKey: PaneState]`.
- Produces: `SessionStore.terminalOnlySessions(for hostId: String) -> [TerminalOnlySession]` (used by Task 3's menu view).

- [ ] **Step 1: Add the per-host accessor to `SessionStore`**

In `ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/SessionStore.swift`, after `panes(for:)` (line 108), add:

```swift
    /// Terminal-only tmux sessions on a host (no agent session in any pane),
    /// one entry per session — the system menu's terminal rows (issue #702
    /// follow-on). Sorted pinned-to-Waiting first, then by session name.
    public func terminalOnlySessions(for hostId: String) -> [TerminalOnlySession] {
        paneStates
            .filter { $0.key.pairId == hostId }
            .map(\.value)
            .terminalOnlySessions()
    }
```

(`SessionStore.swift` already imports `ClaudeSpyNetworking`.)

- [ ] **Step 2: Make the remote badge half override-aware and per-host**

In `ClaudeSpyServer/ClaudeSpyServerApp.swift` replace `totalPendingSessionCount` (lines 597-610) with:

```swift
    /// Total number of sessions needing attention across local and remote
    /// sources. Both halves use the shared `pendingSessionCount` helper, so the
    /// manual "Set State" override is honored in both directions and a pinned
    /// terminal-only session counts once (issue #702). The remote half is
    /// computed per host so same-named sessions on different hosts don't merge.
    private var totalPendingSessionCount: Int {
        let localCount = coordinator.windowManager.pendingSessionCount
        let remoteCount = coordinator.remoteSessionStore.map { store in
            Dictionary(grouping: store.paneStates, by: \.key.pairId)
                .values
                .reduce(0) { $0 + $1.map(\.value).pendingSessionCount }
        } ?? 0
        return localCount + remoteCount
    }
```

- [ ] **Step 3: Build both targets**

Via `swift-package` skill: build `ClaudeSpyPackage` (covers `ClaudeSpyCommon`). Then via `xcodebuild` skill: build scheme `ClaudeSpyServer` (covers the app file).
Expected: both succeed. (The app target has no test bundle; the helper's counting semantics are already covered by Task 1's tests — this is glue.)

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/SessionStore.swift \
        ClaudeSpyServer/ClaudeSpyServerApp.swift
git commit -m "Count pinned terminal-only sessions in the Dock/menu badge, per host (#702)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Menu rows — terminal-only sessions, local and remote

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/MenuBarExtraView.swift`

**Interfaces:**
- Consumes: `Collection.terminalOnlySessions()` (Task 1), `SessionStore.terminalOnlySessions(for:)` (Task 2), existing `pendingMenuBarSelection` cases `.local(paneId:)` / `.remote(hostId:hostName:paneId:)`, `Symbols.terminal`.
- Produces: nothing consumed later; pure UI.

- [ ] **Step 1: Add the terminal row sources**

In `MenuBarExtraView`, after the `localSessions` property (line 15-17), add:

```swift
    /// Terminal-only local tmux sessions (no agent in any pane), one menu row
    /// each — pinned sessions carry their override icon (issue #702 follow-on).
    private var localTerminalSessions: [TerminalOnlySession] {
        windowManager.paneStates.values.terminalOnlySessions()
    }
```

Replace `remoteSessionsByHost` (lines 19-26) with:

```swift
    private var remoteSessionsByHost:
        [(host: PairedHost, sessions: [AgentSession], terminalSessions: [TerminalOnlySession])] {
        guard let sessionStore = coordinator.remoteSessionStore else { return [] }
        return settings.pairedHosts.compactMap { host in
            let sessions = sessionStore.agentSessions(for: host.id).map(\.session)
            let terminalSessions = sessionStore.terminalOnlySessions(for: host.id)
            // A host section appears when the host has ANY panes — a
            // terminals-only host used to vanish from the menu entirely.
            guard !sessions.isEmpty || !terminalSessions.isEmpty else { return nil }
            return (host: host, sessions: sessions, terminalSessions: terminalSessions)
        }
    }
```

- [ ] **Step 2: Render the rows**

In `body`, replace the session-list `Group` content (lines 28-65) so terminal rows follow agent rows in each scope:

```swift
        let local = localSessions
        let localTerminal = localTerminalSessions
        let remote = remoteSessionsByHost
        let hasAny = !local.isEmpty || !localTerminal.isEmpty || !remote.isEmpty
```

and inside the `Group`:

```swift
            if !hasAny {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(local, id: \.paneId) { session in
                    localSessionButton(for: session)
                }
                ForEach(localTerminal) { session in
                    localTerminalSessionButton(for: session)
                }

                ForEach(remote, id: \.host.id) { entry in
                    Divider()
                    Text(entry.host.displayName(showUsername: settings.hasDuplicateHostName(for: entry.host)))
                        .foregroundStyle(.secondary)

                    ForEach(entry.sessions, id: \.paneId) { session in
                        remoteSessionButton(for: session, host: entry.host)
                    }
                    ForEach(entry.terminalSessions) { session in
                        remoteTerminalSessionButton(for: session, host: entry.host)
                    }
                }
            }
```

- [ ] **Step 3: Add the terminal-row buttons and unify the label builder**

In the "Session Buttons" MARK section, after `remoteSessionButton`, add:

```swift
    private func localTerminalSessionButton(for session: TerminalOnlySession) -> some View {
        Button {
            coordinator.pendingMenuBarSelection = .local(paneId: session.representativePaneId)
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "panes")
            Self.bringAppToFront()
        } label: {
            rowLabel(title: session.sessionName, displayedState: session.displayedState)
        }
    }

    private func remoteTerminalSessionButton(for session: TerminalOnlySession, host: PairedHost) -> some View {
        Button {
            coordinator.pendingMenuBarSelection = .remote(
                hostId: host.id,
                hostName: host.displayName,
                paneId: session.representativePaneId
            )
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "panes")
            Self.bringAppToFront()
        } label: {
            rowLabel(title: session.sessionName, displayedState: session.displayedState)
        }
    }
```

Then replace `sessionLabel(for:displayedState:)` (lines 171-201) with a title-based builder plus a `nil -> terminal glyph` arm, and update the two agent-row call sites to keep their defensive moon fallback:

```swift
    /// Shared menu-row label. Menu items can't render ProgressView, so every
    /// state maps to an SF Symbol. The state honors the manual "Set State"
    /// override (issue #702) so rows match the sidebar's indicator; `nil` is
    /// the plain terminal glyph for an unpinned terminal-only session.
    @ViewBuilder
    private func rowLabel(title: String, displayedState: CLISessionState?) -> some View {
        switch displayedState {
        case .waiting:
            Label {
                Text(title)
            } icon: {
                // NSMenuItem renders SF Symbols as template images, stripping
                // foregroundStyle. Pre-render through ImageRenderer with
                // isTemplate=false so the accent color survives.
                if let image = Self.attentionIconImage {
                    Image(nsImage: image)
                } else {
                    Symbols.handsAndSparklesFill.image
                }
            }
        case .working:
            Label(title, symbol: .figureRun)
        case .idle:
            Label(title, symbol: .moonFill)
        case nil:
            Label(title, symbol: .terminal)
        }
    }
```

Agent-row call sites (in `localSessionButton` / `remoteSessionButton`) become:

```swift
        } label: {
            // An agent row always owns an agent session, so displayedState is
            // non-nil; fall back to idle (moon) defensively rather than the
            // terminal glyph.
            rowLabel(
                title: session.displayName,
                displayedState: localDisplayedState(for: session) ?? .idle
            )
        }
```

(and `remoteDisplayedState(for: session, host: host) ?? .idle` in the remote button). Delete the old `sessionLabel`.

- [ ] **Step 4: Build and run the feature test suite**

Via `swift-package` skill: build `ClaudeSpyPackage` and run `ClaudeSpyServerFeatureTests`.
Expected: build succeeds, suites pass (view-only change; menus have no snapshot coverage — the menu bar dropdown is a system surface the e2e harness can't screenshot, per PR #703).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/MenuBarExtraView.swift
git commit -m "List terminal-only tmux sessions in the system menu, local and remote (#702)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Badge-decrease push on every "Set State" mutation path

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/MainView.swift:741-746` (sidebar context menu)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift:3097-3103` (remote `setSessionState` command)
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift:2197-2201` (CLI `onSessionSetState`)

**Interfaces:**
- Consumes: `AppCoordinator.broadcastBadgeDecreaseIfNeeded()` (existing, internal), `MirrorWindowManager.pendingCountDecrease()`, `connectionManager?.broadcastBadgeUpdate(badge:)` (existing pattern at AppCoordinator:3054).
- Produces: nothing new — behavior only.

Background: a pin that LOWERS the count (pin-to-Idle over a needs-attention agent, or unpinning a Waiting terminal session) has no notification of its own, so without an explicit silent push the iOS app-icon badge stays stuck (the badge is entirely push-driven). Increases still ride alert pushes by design — do NOT add increase pushes.

- [ ] **Step 1: Sidebar context menu (local)**

In `MainView.swift`, change the `StateContextMenuButtons` callback (lines 741-746) to:

```swift
                StateContextMenuButtons(
                    currentState: displayedState,
                    hasOverride: stateOverride != nil
                ) { newState in
                    windowManager.setCLISessionState(newState, forSession: session.sessionName)
                    // A pin that lowers the pending count has no notification;
                    // push the badge down explicitly (issue #702).
                    Task {
                        await coordinator.broadcastBadgeDecreaseIfNeeded()
                    }
                }
```

(`setCLISessionState(_:forSession:)` already schedules the session-state push via `onSessionMetadataChanged`; this only adds the badge path. The same file already uses this exact `Task { await coordinator.broadcastBadgeDecreaseIfNeeded() }` shape at line ~2323.)

- [ ] **Step 2: Remote `setSessionState` command handler**

In `AppCoordinator.swift`, extend the handler (lines 3100-3103) to mirror the badge pattern used by the auto-approve handler at line 3054:

```swift
                if case let .setSessionState(spec) = command.command {
                    winManager.setCLISessionState(spec.state, forSession: spec.sessionName)
                    // A pin that lowers the pending count (pin-to-Idle, unpin)
                    // has no notification — carry the iOS badge down with it.
                    if let badge = winManager.pendingCountDecrease() {
                        await connectionManager?.broadcastBadgeUpdate(badge: badge)
                    }
                    return .success(for: command.id)
                }
```

- [ ] **Step 3: CLI `session set-state` path**

In `AppCoordinator.swift`, inside `onSessionSetState` (the `if applied > 0` block at lines 2197-2201), add the badge call after the state push:

```swift
                        if applied > 0 {
                            Task {
                                await self?.connectedViewerManager?.pushSessionStateToAll()
                                await self?.broadcastBadgeDecreaseIfNeeded()
                            }
                        }
```

- [ ] **Step 4: Run the wiring suite and build**

Via `swift-package` skill: run `ClaudeSpyServerFeatureTests` (the `pendingCountDecrease` high-water-mark behavior these paths rely on is covered there, including Task 1's new terminal-session test). Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/MainView.swift \
        ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift
git commit -m "Push the iOS badge decrease from every Set State mutation path (#702)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Full verification, spec/PR sync

**Files:**
- Modify: PR #703 description (via `gh pr edit`)
- No code files.

- [ ] **Step 1: Full test pass**

Via `swift-package` skill: run the full `ClaudeSpyNetworkingTests` and `ClaudeSpyServerFeatureTests` suites (not just filters). Expected: PASS.

- [ ] **Step 2: Full app build**

Via `xcodebuild` skill: build scheme `ClaudeSpyServer` (macOS). Expected: succeeds.

- [ ] **Step 3: Update PR #703's description**

The PR body's "Scope / assumption" section is now stale — it states a pinned plain terminal "isn't a menu-bar row and doesn't inflate the badge". Use `gh pr view 703 --json body` to fetch, rewrite that section to describe the new behavior (all sessions listed; pinned terminal-only sessions count once; badge == bell rows; badge-decrease pushes from all three Set State paths), and apply with `gh pr edit 703 --body-file <file>`. Keep the existing What/Fix/Testing sections, appending the new tests to Testing.

- [ ] **Step 4: Push**

```bash
git push
```

Expected: branch `claude/issue-702` updates PR #703. (No new PR — the pr-checklist hook only fires on `gh pr create`.)
