#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    @Suite("SessionSortData.forLocalSession")
    struct SessionSortDataForLocalSessionTests {
        private let sidebarFields: [SidebarField] = [.customDescription, .projectName, .sessionName]
        private let terminalFields: [SidebarField] = [.customDescription, .currentPath, .sessionName]

        private func makePane(
            _ paneId: String, session: String, window: Int = 0, pane: Int = 0
        ) -> PaneInfo {
            PaneInfo(
                paneId: paneId, target: "\(session):\(window).\(pane)", sessionName: session,
                windowIndex: window, paneIndex: pane, command: "zsh", currentPath: "/tmp/dir",
                width: 80, height: 24, isActive: true
            )
        }

        private func makeSession(_ panes: [PaneInfo]) -> LocalTmuxSession {
            LocalTmuxSession.groupWindows(LocalTmuxWindow.groupPanes(panes))[0]
        }

        @Test("An agent session uses the agent sidebar fields and carries its status priority")
        func agentSession() {
            let session = makeSession([makePane("%1", session: "work")])
            var paneState = PaneState(paneId: "%1", sessionName: "work")
            paneState.agentSession = AgentSession(
                paneId: "%1",
                detectedProjectPath: "/Users/me/Dev/Gallager",
                state: .doneWorking(summary: nil)
            )
            let data = SessionSortData.forLocalSession(
                session,
                paneStates: ["%1": paneState],
                lastActivity: { _ in nil },
                sidebarFields: sidebarFields,
                sidebarTerminalFields: terminalFields
            )
            #expect(data.hasClaude)
            #expect(data.primaryLabel == "Gallager")
            #expect(data.statusPriority == 0)
        }

        @Test("A terminal session uses the terminal fields; recency is the max across panes")
        func terminalSession() {
            let panes = [
                makePane("%1", session: "scratch", window: 0),
                makePane("%2", session: "scratch", window: 1),
            ]
            let session = makeSession(panes)
            let older = Date(timeIntervalSince1970: 100)
            let newer = Date(timeIntervalSince1970: 200)
            let activity = ["%1": older, "%2": newer]
            let data = SessionSortData.forLocalSession(
                session,
                paneStates: [
                    "%1": PaneState(paneId: "%1", sessionName: "scratch"),
                    "%2": PaneState(paneId: "%2", sessionName: "scratch"),
                ],
                lastActivity: { activity[$0] },
                sidebarFields: sidebarFields,
                sidebarTerminalFields: terminalFields
            )
            #expect(!data.hasClaude)
            #expect(data.primaryLabel == "/tmp/dir")
            #expect(data.statusPriority == 3)
            #expect(data.latestEventTimestamp == newer)
        }
    }
#endif
