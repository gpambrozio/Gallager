import Foundation
import Testing
@testable import ClaudeSpyNetworking

@Suite("AgentState")
struct AgentStateTests {
    @Test("needsAttention is true only for awaiting* and doneWorking")
    func needsAttentionDerivation() {
        #expect(AgentState.working.needsAttention == false)
        #expect(AgentState.idle.needsAttention == false)
        #expect(AgentState.doneWorking(summary: nil).needsAttention == true)
        #expect(AgentState.awaitingPermission(
            PermissionRequest(title: "Bash", description: "ls"), requestID: "r1"
        ).needsAttention == true)
        #expect(AgentState.awaitingReplies(
            AskUserQuestionRequest(questions: []), requestID: "r1"
        ).needsAttention == true)
        #expect(AgentState.awaitingPlanApproval(
            ApprovePlanRequest(title: "Plan", plan: "do it"), requestID: "r1"
        ).needsAttention == true)
    }

    @Test("isActiveWorking is true only for .working")
    func isActiveWorkingDerivation() {
        #expect(AgentState.working.isActiveWorking == true)
        #expect(AgentState.idle.isActiveWorking == false)
        #expect(AgentState.doneWorking(summary: "done").isActiveWorking == false)
    }

    @Test("openForm returns the matching request + id for awaiting*; nil otherwise")
    func openFormDerivation() {
        let perm = PermissionRequest(title: "Bash", description: "ls")
        #expect(AgentState.awaitingPermission(perm, requestID: "r1").openForm?.request == .permission(perm))
        #expect(AgentState.awaitingPermission(perm, requestID: "r1").openForm?.requestID == "r1")

        let q = AskUserQuestionRequest(questions: [])
        #expect(AgentState.awaitingReplies(q, requestID: "r2").openForm?.request == .askUserQuestion(q))

        let plan = ApprovePlanRequest(title: "p", plan: "x")
        #expect(AgentState.awaitingPlanApproval(plan, requestID: "r3").openForm?.request == .approvePlan(plan))

        #expect(AgentState.working.openForm == nil)
        #expect(AgentState.doneWorking(summary: nil).openForm == nil)
        #expect(AgentState.idle.openForm == nil)
    }

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        let states: [AgentState] = [
            .working, .idle, .doneWorking(summary: "bye"),
            .awaitingPermission(PermissionRequest(title: "t", description: "d"), requestID: "r1"),
            .awaitingReplies(AskUserQuestionRequest(questions: []), requestID: "r2"),
            .awaitingPlanApproval(ApprovePlanRequest(title: "p", plan: "x"), requestID: "r3"),
        ]
        for state in states {
            let decoded = try JSONDecoder().decode(
                AgentState.self, from: JSONEncoder().encode(state)
            )
            #expect(decoded == state)
        }
    }
}
