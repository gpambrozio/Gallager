import Foundation

/// Drives the Gallager sidebar progress bar and session color on the calling
/// pane via `gallager set-progress` / `gallager set-color`. The bar advances
/// by `(completed / total)` percent as scenarios finish; the session is
/// painted green at run start and switches to red on the first failure.
///
/// Silently no-ops when not launched from a Gallager-managed tmux pane
/// (i.e. `$TMUX_PANE` is unset) or when the `gallager` CLI is not on PATH.
final public class GallagerProgressReporter: TestProgressReporter, @unchecked Sendable {
    private let totalScenarios: Int
    private let gallagerPath: String?
    private let hasPane: Bool
    private var completed = 0
    private var sawFailure = false

    public init(totalScenarios: Int) {
        self.totalScenarios = totalScenarios
        let env = ProcessInfo.processInfo.environment
        self.hasPane = env["TMUX_PANE"]?.isEmpty == false
        self.gallagerPath = Self.resolveGallager()
    }

    // MARK: - TestProgressReporter

    public func scenarioStarted(_ name: String, totalSteps: Int) async {
        if completed == 0 {
            setProgress("0")
            setColor("green")
        }
    }

    public func stepStarted(_ stepNumber: Int, totalSteps: Int, description: String) async { }
    public func stepCompleted(_ stepNumber: Int, screenshot: TestOrchestrator.ScreenshotResult?) async { }
    public func stepFailed(
        _ stepNumber: Int,
        error: String,
        screenshot: TestOrchestrator.ScreenshotResult?,
        failureScreenshots: [TestOrchestrator.FailureScreenshot]
    ) async { }

    public func scenarioCompleted(_ result: TestOrchestrator.ScenarioResult) async {
        completed += 1
        if !result.success, !sawFailure {
            sawFailure = true
            setColor("red")
        }
        guard totalScenarios > 0 else { return }
        let pct = min(100, max(0, (completed * 100) / totalScenarios))
        setProgress(String(pct))
    }

    public func printSummary(_ results: [TestOrchestrator.ScenarioResult]) async {
        setProgress("clear")
    }

    // MARK: - Private

    private func setProgress(_ value: String) {
        runGallager(["set-progress", value])
    }

    private func setColor(_ value: String) {
        runGallager(["set-color", value])
    }

    private func runGallager(_ arguments: [String]) {
        guard hasPane, let path = gallagerPath else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // Failures here are non-fatal — the sidebar updates are best-effort.
        }
    }

    private static func resolveGallager() -> String? {
        let candidates = ["/usr/local/bin/gallager", "/opt/homebrew/bin/gallager"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
