import Foundation

/// Sends test progress events to the Marvin Dashboard CI endpoint.
///
/// Reporter methods return immediately — events are placed on an internal
/// async queue and drained serially by a background task. The drain task
/// is fully fire-and-forget: network errors are silently ignored.
final public class DashboardReporter: TestProgressReporter, @unchecked Sendable {
    private let dashboardURL: URL
    private let prNumber: Int?
    private let prTitle: String?
    private var currentScenarioName = ""

    private let continuation: AsyncStream<[String: Any]>.Continuation
    private let drainTask: Task<Void, Never>

    public init(dashboardURL: URL, prNumber: Int? = nil, prTitle: String? = nil) {
        self.dashboardURL = dashboardURL
        self.prNumber = prNumber
        self.prTitle = prTitle

        let (stream, continuation) = AsyncStream<[String: Any]>.makeStream()
        self.continuation = continuation

        let url = dashboardURL
        self.drainTask = Task.detached(priority: .utility) {
            for await body in stream {
                await DashboardReporter.send(body, to: url)
            }
        }
    }

    deinit {
        continuation.finish()
        drainTask.cancel()
    }

    // MARK: - Run lifecycle

    public func sendRunStarted(totalScenarios: Int) async {
        var body: [String: Any] = ["type": "e2e", "event": "run-started", "totalScenarios": totalScenarios]
        if let n = prNumber { body["prNumber"] = n }
        if let t = prTitle { body["prTitle"] = t }
        enqueue(body)
    }

    // MARK: - TestProgressReporter

    public func scenarioStarted(_ name: String, totalSteps: Int) async {
        currentScenarioName = name
        enqueue(["type": "e2e", "event": "scenario-started", "scenario": name, "totalSteps": totalSteps])
    }

    public func stepStarted(_ stepNumber: Int, totalSteps: Int, description: String) async {
        enqueue([
            "type": "e2e", "event": "step-started",
            "scenario": currentScenarioName,
            "stepNumber": stepNumber, "totalSteps": totalSteps,
            "description": description,
        ])
    }

    public func stepCompleted(_ stepNumber: Int, screenshot: TestOrchestrator.ScreenshotResult?) async {
        enqueue(["type": "e2e", "event": "step-completed", "scenario": currentScenarioName, "stepNumber": stepNumber])
    }

    public func stepFailed(
        _ stepNumber: Int,
        error: String,
        screenshot: TestOrchestrator.ScreenshotResult?,
        failureScreenshots: [TestOrchestrator.FailureScreenshot]
    ) async {
        enqueue(["type": "e2e", "event": "step-failed", "scenario": currentScenarioName, "stepNumber": stepNumber, "error": error])
    }

    public func scenarioCompleted(_ result: TestOrchestrator.ScenarioResult) async {
        enqueue([
            "type": "e2e", "event": "scenario-completed",
            "scenario": result.scenarioName,
            "status": result.success ? "passed" : "failed",
            "error": result.error ?? "",
        ])
    }

    public func printSummary(_ results: [TestOrchestrator.ScenarioResult]) async {
        enqueue(["type": "e2e", "event": "run-completed"])
    }

    // MARK: - Private

    private func enqueue(_ body: sending [String: Any]) {
        continuation.yield(body)
    }

    private static func send(_ body: [String: Any], to dashboardURL: URL) async {
        let endpoint = dashboardURL.appendingPathComponent("api/ci/update")
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        _ = try? await URLSession.shared.data(for: request)
    }
}
