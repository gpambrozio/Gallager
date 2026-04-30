import Foundation

/// Protocol for reporting test progress to the terminal or other outputs.
/// The orchestrator calls these methods as it executes scenarios and steps.
public protocol TestProgressReporter: Sendable {
    func scenarioStarted(_ name: String, totalSteps: Int) async
    func stepStarted(_ stepNumber: Int, totalSteps: Int, description: String) async
    func stepCompleted(_ stepNumber: Int, screenshot: TestOrchestrator.ScreenshotResult?) async
    func stepFailed(
        _ stepNumber: Int,
        error: String,
        screenshot: TestOrchestrator.ScreenshotResult?,
        failureScreenshots: [TestOrchestrator.FailureScreenshot]
    ) async
    func scenarioCompleted(_ result: TestOrchestrator.ScenarioResult) async
    func printSummary(_ results: [TestOrchestrator.ScenarioResult]) async
}
