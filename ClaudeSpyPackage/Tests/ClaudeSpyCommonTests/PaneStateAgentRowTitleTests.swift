import ClaudeSpyNetworking
import Foundation
import Testing
@testable import ClaudeSpyCommon

@Suite("PaneState.agentRowTitle")
struct PaneStateAgentRowTitleTests {
    @Test("A session description replaces the agent's project-derived name")
    func descriptionWins() {
        let pane = PaneState(
            paneId: "%1",
            customDescription: "My feature work",
            agentSession: AgentSession(paneId: "%1", detectedProjectPath: "/Users/me/Dev/Gallager")
        )
        #expect(pane.agentRowTitle == "My feature work")
    }

    @Test("Without a description the agent displayName is used; empty counts as unset")
    func fallsBackToDisplayName() {
        let project = PaneState(
            paneId: "%1",
            customDescription: "",
            agentSession: AgentSession(paneId: "%1", detectedProjectPath: "/Users/me/Dev/Gallager")
        )
        #expect(project.agentRowTitle == "Gallager")

        let bare = PaneState(paneId: "%2", agentSession: AgentSession(paneId: "%2"))
        #expect(bare.agentRowTitle == "%2")
    }

    @Test("A pane without an agent session has no agent row title")
    func nilWithoutAgent() {
        #expect(PaneState(paneId: "%1", customDescription: "desc").agentRowTitle == nil)
    }
}
