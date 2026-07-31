import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("CLISessionState")
struct CLISessionStateTests {
    // MARK: - parse

    @Test("Canonical names and aliases parse to a set result")
    func parsesCanonicalAndAliases() {
        #expect(CLISessionState.parse("working") == .set(.working))
        #expect(CLISessionState.parse("idle") == .set(.idle))
        #expect(CLISessionState.parse("waiting") == .set(.waiting))
        #expect(CLISessionState.parse("attention") == .set(.waiting))
        #expect(CLISessionState.parse("waiting-for-input") == .set(.waiting))
    }

    @Test("clear/none parse to an explicit clear")
    func parsesClear() {
        #expect(CLISessionState.parse("clear") == .clear)
        #expect(CLISessionState.parse("none") == .clear)
    }

    @Test("Unknown values return nil")
    func unknownReturnsNil() {
        #expect(CLISessionState.parse("bogus") == nil)
        #expect(CLISessionState.parse("") == nil)
    }

    // MARK: - displayed(override:agentState:) — the "Set State" checkmark source (issue #695)

    @Test("A manual override always wins over the agent state")
    func overrideWins() {
        #expect(CLISessionState.displayed(override: .idle, agentState: .working) == .idle)
        #expect(CLISessionState.displayed(override: .waiting, agentState: .idle) == .waiting)
        #expect(CLISessionState.displayed(override: .working, agentState: nil) == .working)
    }

    @Test("Without an override the bucket is derived from the agent state")
    func derivesFromAgentState() {
        #expect(CLISessionState.displayed(override: nil, agentState: .working) == .working)
        #expect(CLISessionState.displayed(override: nil, agentState: .idle) == .idle)
        // Every needs-attention agent state maps to the .waiting bucket (the orange bell).
        #expect(CLISessionState.displayed(override: nil, agentState: .doneWorking(summary: nil)) == .waiting)
        #expect(CLISessionState.displayed(
            override: nil,
            agentState: .awaitingPermission(PermissionRequest(title: "Bash", description: "ls"), requestID: "r1")
        ) == .waiting)
        #expect(CLISessionState.displayed(
            override: nil,
            agentState: .awaitingReplies(AskUserQuestionRequest(questions: []), requestID: "r2")
        ) == .waiting)
        #expect(CLISessionState.displayed(
            override: nil,
            agentState: .awaitingPlanApproval(ApprovePlanRequest(title: "p", plan: "x"), requestID: "r3")
        ) == .waiting)
    }

    @Test("No override and no agent session is a terminal — nothing checked")
    func terminalHasNoBucket() {
        #expect(CLISessionState.displayed(override: nil, agentState: nil) == nil)
    }
}

@Suite("PaneState.displayedState")
struct PaneStateDisplayedStateTests {
    @Test("The manual Set State override wins over the agent session state")
    func overrideWins() {
        let pane = PaneState(
            paneId: "%1",
            agentSession: AgentSession(paneId: "%1", state: .idle),
            cliSessionState: .waiting
        )
        #expect(pane.displayedState == .waiting)
    }

    @Test("Without an override the bucket derives from the agent state; .waiting is the pending bell")
    func derivesFromAgent() {
        let idle = PaneState(paneId: "%1", agentSession: AgentSession(paneId: "%1", state: .idle))
        #expect(idle.displayedState == .idle)

        let attention = PaneState(
            paneId: "%2",
            agentSession: AgentSession(paneId: "%2", state: .doneWorking(summary: nil))
        )
        #expect(attention.displayedState == .waiting)
    }

    @Test("A plain terminal has no displayed state; an override alone shows but owns no agent session")
    func plainTerminalAndOverrideOnly() {
        #expect(PaneState(paneId: "%1").displayedState == nil)

        // A user can pin a plain terminal, so the override still shows — but the
        // menu bar's pending count is scoped to panes that own an agent session
        // (issue #702), so an override-only pane never inflates that count.
        let overriddenTerminal = PaneState(paneId: "%2", cliSessionState: .waiting)
        #expect(overriddenTerminal.displayedState == .waiting)
        #expect(overriddenTerminal.agentSession == nil)
    }
}

@Suite("SetSessionStateCommand")
struct SetSessionStateCommandTests {
    @Test("commandType wraps the spec")
    func commandTypeWrapsSpec() {
        let spec = SetSessionState(sessionName: "web", state: .working)
        #expect(spec.commandType == .setSessionState(spec))
    }

    @Test("Round-trips through Codable via CommandType, including a clear")
    func codableRoundTrip() throws {
        let commands: [CommandType] = [
            .setSessionState(SetSessionState(sessionName: "web", state: .working)),
            .setSessionState(SetSessionState(sessionName: "web", state: .waiting)),
            .setSessionState(SetSessionState(sessionName: "web", state: nil)),
        ]
        for command in commands {
            let decoded = try JSONDecoder().decode(
                CommandType.self, from: JSONEncoder().encode(command)
            )
            #expect(decoded == command)
        }
    }
}
