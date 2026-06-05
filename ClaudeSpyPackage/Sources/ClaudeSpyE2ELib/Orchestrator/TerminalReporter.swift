import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Rich terminal output for E2E test progress using ANSI escape sequences.
/// Falls back to plain text when stderr is not a terminal.
final public class TerminalReporter: TestProgressReporter, @unchecked Sendable {
    private let isTTY: Bool
    private let stream: UnsafeMutablePointer<FILE>

    public init() {
        self.stream = stderr
        self.isTTY = isatty(fileno(stderr)) != 0
    }

    // MARK: - ANSI Helpers

    private enum Style: String {
        case reset = "\u{1b}[0m"
        case bold = "\u{1b}[1m"
        case dim = "\u{1b}[2m"
        case red = "\u{1b}[31m"
        case green = "\u{1b}[32m"
        case yellow = "\u{1b}[33m"
        case cyan = "\u{1b}[36m"
        case clearLine = "\u{1b}[2K"
    }

    private func styled(_ text: String, _ styles: Style...) -> String {
        guard isTTY else { return text }
        let prefix = styles.map(\.rawValue).joined()
        return "\(prefix)\(text)\(Style.reset.rawValue)"
    }

    private func write(_ text: String) {
        fputs(text, stream)
        fflush(stream)
    }

    private func writeln(_ text: String = "") {
        fputs(text + "\n", stream)
        fflush(stream)
    }

    private func clearCurrentLine() {
        guard isTTY else { return }
        write("\r\(Style.clearLine.rawValue)")
    }

    /// Current terminal width in columns, or `nil` when not connected to a TTY
    /// or the ioctl fails. Used to truncate progress lines so they fit on a
    /// single physical row — wrapped lines can't be reclaimed by `\r` + clear,
    /// which only erases the row the cursor is on.
    private func terminalColumns() -> Int? {
        guard isTTY else { return nil }
        var w = winsize()
        guard ioctl(fileno(stream), UInt(TIOCGWINSZ), &w) == 0, w.ws_col > 0 else {
            return nil
        }
        return Int(w.ws_col)
    }

    /// Trim `text` to at most `width` columns, appending an ellipsis when
    /// truncated. Assumes ASCII/monospaced content (true for `String(describing:)`
    /// output of test steps).
    private func truncate(_ text: String, toColumns width: Int) -> String {
        guard width > 0 else { return "" }
        guard text.count > width else { return text }
        let ellipsis = "…"
        let keep = max(0, width - ellipsis.count)
        return String(text.prefix(keep)) + ellipsis
    }

    // MARK: - TestProgressReporter

    public func scenarioStarted(_ name: String, totalSteps: Int) async {
        writeln()
        let arrow = styled(">>>", .cyan, .bold)
        let scenarioName = styled(name, .bold)
        let stepCount = styled("(\(totalSteps) steps)", .dim)
        writeln("\(arrow) \(scenarioName) \(stepCount)")
    }

    public func stepStarted(_ stepNumber: Int, totalSteps: Int, description: String) async {
        clearCurrentLine()
        let plainPrefix = "  [\(stepNumber)/\(totalSteps)] "
        // Cap the description so the whole line stays on one row. Leave a 1-col
        // margin so a description that exactly fills the terminal width can't
        // push the cursor onto the next row (some terminals auto-wrap on the
        // trailing column, others don't — leaving a gap is universal).
        let visibleDescription: String
        if let cols = terminalColumns() {
            let budget = max(10, cols - plainPrefix.count - 1)
            visibleDescription = truncate(description, toColumns: budget)
        } else {
            visibleDescription = description
        }
        let progress = styled("  [\(stepNumber)/\(totalSteps)]", .dim)
        let desc = styled(visibleDescription, .dim)
        write("\(progress) \(desc)")
    }

    public func stepCompleted(_ stepNumber: Int, screenshot: TestOrchestrator.ScreenshotResult?) async {
        clearCurrentLine()
    }

    public func stepFailed(
        _ stepNumber: Int,
        error: String,
        screenshot: TestOrchestrator.ScreenshotResult?,
        failureScreenshots: [TestOrchestrator.FailureScreenshot]
    ) async {
        clearCurrentLine()
        if let ss = screenshot {
            let camera = styled("  [screenshot]", .dim)
            let detail: String
            if let diff = ss.diffPercentage {
                detail = styled(String(format: "%.2f%% diff - MISMATCH", diff), .red)
            } else {
                detail = styled("MISMATCH", .red)
            }
            writeln("\(camera) \(ss.label): \(detail)")
        }
        let marker = styled("  FAIL", .red, .bold)
        let stepInfo = styled("step \(stepNumber)", .dim)
        writeln("\(marker) \(stepInfo)")
        let errorText = styled("       \(error)", .red)
        writeln(errorText)
        for capture in failureScreenshots {
            let camera = styled("  [failure screenshot]", .dim)
            let target = styled(capture.target, .yellow)
            let path = styled(capture.path, .dim)
            writeln("\(camera) \(target): \(path)")
        }
    }

    public func scenarioCompleted(_ result: TestOrchestrator.ScenarioResult) async {
        clearCurrentLine()
        let duration = styled(String(format: "%.1fs", result.duration), .dim)
        if result.success {
            let check = styled("  PASS", .green, .bold)
            writeln("\(check) \(duration)")
        } else {
            // Error details already printed by stepFailed
            let cross = styled("  FAIL", .red, .bold)
            writeln("\(cross) \(duration)")
        }
    }

    public func printSummary(_ results: [TestOrchestrator.ScenarioResult]) async {
        writeln()

        let passed = results.filter(\.success).count
        let failed = results.count - passed

        // Find column widths
        let nameWidth = max(results.map(\.scenarioName.count).max() ?? 20, 20)
        let resultWidth = 6
        let durationWidth = 8

        let hLine = String(repeating: "\u{2500}", count: nameWidth + 2)
        let hResult = String(repeating: "\u{2500}", count: resultWidth + 2)
        let hDuration = String(repeating: "\u{2500}", count: durationWidth + 2)

        writeln("\u{250c}\(hLine)\u{252c}\(hResult)\u{252c}\(hDuration)\u{2510}")
        let headerName = " Scenario".padding(toLength: nameWidth + 1, withPad: " ", startingAt: 0)
        let headerResult = " Result".padding(toLength: resultWidth + 1, withPad: " ", startingAt: 0)
        let headerDur = " Duration".padding(toLength: durationWidth + 1, withPad: " ", startingAt: 0)
        writeln("\u{2502}\(headerName) \u{2502}\(headerResult) \u{2502}\(headerDur) \u{2502}")
        writeln("\u{251c}\(hLine)\u{253c}\(hResult)\u{253c}\(hDuration)\u{2524}")

        for result in results {
            let name = " \(result.scenarioName)".padding(toLength: nameWidth + 1, withPad: " ", startingAt: 0)
            let duration = String(format: "%.1fs", result.duration)
            let durPadded = " \(duration)".padding(toLength: durationWidth + 1, withPad: " ", startingAt: 0)

            let status: String
            if result.success {
                status = styled(" PASS ".padding(toLength: resultWidth + 1, withPad: " ", startingAt: 0), .green, .bold)
            } else {
                status = styled(" FAIL ".padding(toLength: resultWidth + 1, withPad: " ", startingAt: 0), .red, .bold)
            }

            writeln("\u{2502}\(name) \u{2502}\(status) \u{2502}\(durPadded) \u{2502}")
        }

        writeln("\u{2514}\(hLine)\u{2534}\(hResult)\u{2534}\(hDuration)\u{2518}")
        writeln()

        if failed == 0 {
            writeln(styled(" \(passed)/\(results.count) passed", .green, .bold))
        } else {
            let summary = " \(passed)/\(results.count) passed, \(failed) failed"
            writeln(styled(summary, .red, .bold))
        }
        writeln()
    }
}
