import Testing
@testable import ClaudeSpyServerFeature

struct LocalTmuxSessionTests {
    /// Builds a bare window fixture. The selection logic only reads `id` and
    /// `isWindowActive`, so panes are intentionally empty.
    private static func makeWindow(
        index: Int,
        active: Bool,
        session: String = "work"
    ) -> LocalTmuxWindow {
        LocalTmuxWindow(
            id: "\(session):\(index)",
            sessionName: session,
            windowIndex: index,
            windowName: "win\(index)",
            windowLayout: "d0c6,80x24",
            isWindowActive: active,
            panes: []
        )
    }

    private static func makeSession(_ windows: [LocalTmuxWindow], name: String = "work") -> LocalTmuxSession {
        LocalTmuxSession(sessionName: name, windows: windows)
    }

    // MARK: - activeWindow

    @Test("activeWindow returns the window flagged active by tmux")
    func activeWindowPrefersActiveFlag() {
        let session = Self.makeSession([
            Self.makeWindow(index: 1, active: false),
            Self.makeWindow(index: 2, active: true),
        ])
        #expect(session.activeWindow?.windowIndex == 2)
    }

    @Test("activeWindow falls back to the first window when none is active")
    func activeWindowFallsBackToFirst() {
        let session = Self.makeSession([
            Self.makeWindow(index: 1, active: false),
            Self.makeWindow(index: 2, active: false),
        ])
        #expect(session.activeWindow?.windowIndex == 1)
    }

    // MARK: - leftPaneWindow (issue #653)

    @Test("Opening a session lands on tmux's active window, not the first window (issue #653)")
    func picksTmuxActiveWindowOnOpen() {
        // The reported bug: a session whose second window is the tmux-active
        // one opened on the first window. The selection must follow the active
        // flag so the freshly opened session shows window 2.
        let session = Self.makeSession([
            Self.makeWindow(index: 1, active: false),
            Self.makeWindow(index: 2, active: true),
        ])
        #expect(session.leftPaneWindow(excludingRightSide: [])?.windowIndex == 2)
    }

    @Test("A first-window-active session still opens on the first window")
    func picksFirstWindowWhenItIsActive() {
        let session = Self.makeSession([
            Self.makeWindow(index: 1, active: true),
            Self.makeWindow(index: 2, active: false),
        ])
        #expect(session.leftPaneWindow(excludingRightSide: [])?.windowIndex == 1)
    }

    @Test("With no active window, falls back to the first left-side window")
    func fallsBackToFirstWhenNoneActive() {
        let session = Self.makeSession([
            Self.makeWindow(index: 1, active: false),
            Self.makeWindow(index: 2, active: false),
        ])
        #expect(session.leftPaneWindow(excludingRightSide: [])?.windowIndex == 1)
    }

    @Test("A tmux-active window parked on the right side is skipped for the left pane")
    func skipsActiveWindowParkedOnRight() {
        // If the active window is already shown on the right side of a split,
        // picking it for the left too would render the same terminal twice.
        let active = Self.makeWindow(index: 2, active: true)
        let session = Self.makeSession([
            Self.makeWindow(index: 1, active: false),
            active,
        ])
        let pick = session.leftPaneWindow(excludingRightSide: [active.id])
        #expect(pick?.windowIndex == 1)
    }

    @Test("When every window is parked on the right, falls back to the active window")
    func fallsBackToActiveWhenAllParkedRight() {
        let win1 = Self.makeWindow(index: 1, active: false)
        let win2 = Self.makeWindow(index: 2, active: true)
        let session = Self.makeSession([win1, win2])
        // Both windows are on the right — there is no left candidate, so the
        // final fallback (the session's active window) wins.
        let pick = session.leftPaneWindow(excludingRightSide: [win1.id, win2.id])
        #expect(pick?.windowIndex == 2)
    }
}
