import ClaudeSpyCommon
import Clocks
import ConcurrencyExtras
import Dependencies
import Foundation
import Testing
@testable import ClaudeSpyServerFeature

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("Timeout terminates a long-running process when the deadline passes")
    func timeoutTerminatesProcess() async throws {
        let clock = TestClock()
        try await withDependencies {
            $0.continuousClock = clock
        } operation: {
            let runner = ProcessRunner.liveValue
            // /bin/sleep would normally hold the call open for 60 seconds;
            // the test clock makes the timeout fire after a virtual 1s.
            async let result = runner.run("/bin/sleep", ["60"], nil, 1)

            // Wait until the runner's timeout task has actually registered a
            // sleeper on the test clock. `process.run()` is real-time work
            // (OS spawn) that yields can't wait for, so we poll
            // `checkSuspension()` until it reports an active sleep — capped
            // at a few real-time seconds so a regression fails fast rather
            // than hanging.
            try await waitForSleeperToRegister(on: clock)

            // Cross the virtual deadline: the timeout task fires
            // `process.terminate()`, the OS kills /bin/sleep, and the runner
            // surfaces the kill as `ProcessRunnerError.timeout` (not a generic
            // non-zero result) so callers can tell a timeout apart from a real
            // failure.
            await clock.advance(by: .seconds(2))

            do {
                _ = try await result
                Issue.record("expected ProcessRunnerError.timeout to be thrown")
            } catch let error as ProcessRunnerError {
                guard case .timeout = error else {
                    Issue.record("expected .timeout, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected ProcessRunnerError.timeout, got \(error)")
            }
        }
    }

    @Test("No timeout lets the process complete naturally")
    func noTimeoutLetsProcessComplete() async throws {
        // No `withDependencies` wrapper — without a timeout the runner never
        // touches the clock, so there is nothing to fake.
        let runner = ProcessRunner.liveValue
        let result = try await runner.run("/bin/echo", ["hello"], nil, nil)
        #expect(result.isSuccess)
        #expect(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    /// Polls until the runner's timeout task has registered a sleeper on `clock`.
    /// `TestClock.checkSuspension()` throws when there are active sleeps, so we
    /// loop until it throws. The cap is generous (10 real-time seconds) because
    /// `process.run()` is real OS work that yields can't replace — we have to
    /// wait for the spawn + the task hop in real time before the virtual clock
    /// has anything to advance against. Anything within seconds of the cap is
    /// almost certainly a regression rather than a slow CI runner.
    private func waitForSleeperToRegister(on clock: TestClock<Duration>) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            do {
                try await clock.checkSuspension()
                // No active suspensions yet — the runner Task has not reached
                // its `clock.sleep` await point. Wait a moment and retry.
                // Sanctioned exception to the "no Task.sleep in tests" rule:
                // OS process spawn is real-time work the TestClock can't replace.
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return
            }
        }
        Issue.record("Timeout task never registered a sleeper on the TestClock")
    }
}
