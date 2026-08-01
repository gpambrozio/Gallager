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

    @Test("Conflicting sibling pins resolve by (window, pane) order, matching the sidebar")
    func conflictingSiblingPinsResolveInPaneOrder() {
        // Per-pane CLI pins can leave siblings disagreeing; the winner must be
        // the first pinned pane by (windowIndex, paneIndex) — the same scan
        // order as TmuxSession.cliSessionState — regardless of input order.
        let panes = [
            PaneState(paneId: "%2", sessionName: "s", windowIndex: 1, paneIndex: 0, cliSessionState: .waiting),
            PaneState(paneId: "%1", sessionName: "s", windowIndex: 0, paneIndex: 0, cliSessionState: .idle),
        ]
        #expect(panes.terminalOnlySessions().first?.displayedState == .idle)
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
