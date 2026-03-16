import Foundation

/// Sends test progress events to the Marvin Dashboard CI endpoint.
/// All network errors are caught and ignored (fail-silent).
public final class DashboardReporter: TestProgressReporter, @unchecked Sendable {
    private let dashboardURL: URL
    private let prNumber: Int?
    private let prTitle: String?
    private var currentScenarioName: String = ""

    public init(dashboardURL: URL, prNumber: Int? = nil, prTitle: String? = nil) {
        self.dashboardURL = dashboardURL
        self.prNumber = prNumber
        self.prTitle = prTitle
    }

    // MARK: - Run lifecycle

    public func sendRunStarted() async {
        var body: [String: Any] = ["type": "e2e", "event": "run-started"]
        if let n = prNumber { body["prNumber"] = n }
        if let t = prTitle { body["prTitle"] = t }
        await post(body)
    }

    // MARK: - TestProgressReporter

    public func scenarioStarted(_ name: String, totalSteps: Int) async {
        currentScenarioName = name
        await post([
            "type": "e2e",
            "event": "scenario-started",
            "scenario": name,
            "totalSteps": totalSteps
        ])
    }

    public func stepStarted(_ stepNumber: Int, totalSteps: Int, description: String) async {
        await post([
            "type": "e2e",
            "event": "step-started",
            "scenario": currentScenarioName,
            "stepNumber": stepNumber,
            "totalSteps": totalSteps,
            "description": description
        ])
    }

    public func stepCompleted(_ stepNumber: Int, screenshot: TestOrchestrator.ScreenshotResult?) async {
        await post([
            "type": "e2e",
            "event": "step-completed",
            "scenario": currentScenarioName,
            "stepNumber": stepNumber
        ])
    }

    public func stepFailed(_ stepNumber: Int, error: String, screenshot: TestOrchestrator.ScreenshotResult?) async {
        await post([
            "type": "e2e",
            "event": "step-failed",
            "scenario": currentScenarioName,
            "stepNumber": stepNumber,
            "error": error
        ])
    }

    public func scenarioCompleted(_ result: TestOrchestrator.ScenarioResult) async {
        await post([
            "type": "e2e",
            "event": "scenario-completed",
            "scenario": result.scenarioName,
            "status": result.success ? "passed" : "failed",
            "error": result.error ?? ""
        ])
    }

    public func printSummary(_ results: [TestOrchestrator.ScenarioResult]) async {
        await post([
            "type": "e2e",
            "event": "run-completed"
        ])
    }

    // MARK: - Private

    private func post(_ body: [String: Any]) async {
        let endpoint = dashboardURL.appendingPathComponent("api/ci/update")
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3

        _ = try? await URLSession.shared.data(for: request)
    }
}
