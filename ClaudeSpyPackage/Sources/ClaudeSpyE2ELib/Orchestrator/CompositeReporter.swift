import Foundation

/// Fans out all TestProgressReporter calls to multiple reporters.
public final class CompositeReporter: TestProgressReporter, @unchecked Sendable {
    private let reporters: [any TestProgressReporter]

    public init(_ reporters: [any TestProgressReporter]) {
        self.reporters = reporters
    }

    public func scenarioStarted(_ name: String, totalSteps: Int) async {
        for r in reporters { await r.scenarioStarted(name, totalSteps: totalSteps) }
    }

    public func stepStarted(_ stepNumber: Int, totalSteps: Int, description: String) async {
        for r in reporters { await r.stepStarted(stepNumber, totalSteps: totalSteps, description: description) }
    }

    public func stepCompleted(_ stepNumber: Int, screenshot: TestOrchestrator.ScreenshotResult?) async {
        for r in reporters { await r.stepCompleted(stepNumber, screenshot: screenshot) }
    }

    public func stepFailed(_ stepNumber: Int, error: String, screenshot: TestOrchestrator.ScreenshotResult?) async {
        for r in reporters { await r.stepFailed(stepNumber, error: error, screenshot: screenshot) }
    }

    public func scenarioCompleted(_ result: TestOrchestrator.ScenarioResult) async {
        for r in reporters { await r.scenarioCompleted(result) }
    }

    public func printSummary(_ results: [TestOrchestrator.ScenarioResult]) async {
        for r in reporters { await r.printSummary(results) }
    }
}
