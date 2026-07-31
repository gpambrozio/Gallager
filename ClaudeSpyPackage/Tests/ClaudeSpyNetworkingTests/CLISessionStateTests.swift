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
