import Testing
@testable import ClaudeSpyE2ELib

@Suite("ScenarioBuilder Tests")
struct ScenarioBuilderTests {
    @Test("Basic scenario construction")
    func basicScenario() {
        let s = scenario("Test Scenario", tags: ["smoke"]) {
            TestStep.log("Starting")
            TestStep.wait(seconds: 1)
            TestStep.log("Done")
        }

        #expect(s.name == "Test Scenario")
        #expect(s.tags == ["smoke"])
        #expect(s.steps.count == 3)
    }

    @Test("Scenario with server steps")
    func serverSteps() {
        let s = scenario("Server Test") {
            TestStep.startServer
            TestStep.verifyServerHealth
            TestStep.verifyServerHasPairings(count: 0)
            TestStep.stopServer
        }

        #expect(s.steps.count == 4)
    }

    @Test("Scenario with variable substitution steps")
    func variableSubstitution() {
        let ctx = ExecutionContext()
        ctx.set("code", value: "ABC123")

        let resolved = ctx.resolve("Enter ${code} here")
        #expect(resolved == "Enter ABC123 here")
    }

    @Test("ExecutionContext resolves multiple variables")
    func multipleVariables() {
        let ctx = ExecutionContext()
        ctx.set("host", value: "Mac")
        ctx.set("viewer", value: "iPhone")

        let resolved = ctx.resolve("${host} paired with ${viewer}")
        #expect(resolved == "Mac paired with iPhone")
    }

    @Test("ExecutionContext clear removes all values")
    func clearContext() {
        let ctx = ExecutionContext()
        ctx.set("key", value: "value")
        ctx.clear()
        #expect(ctx.get("key") == nil)
    }
}
