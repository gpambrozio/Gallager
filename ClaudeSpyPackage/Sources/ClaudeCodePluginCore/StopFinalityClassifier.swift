import Dependencies
import DependenciesMacros
import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

// MARK: - StopFinalityVerdict

/// The classifier's judgment of a `Stop` hook's last assistant message
/// (issue #644).
public enum StopFinalityVerdict: Sendable, Equatable {
    /// The message reads as a completed turn — apply the stop normally.
    case final
    /// The message reads like the agent paused while background work finishes
    /// and will resume — the stop must not flip the session to done.
    case stillWaiting
}

// MARK: - StopFinalityClassifier

/// Judges whether a `Stop` hook's last assistant message is a real finish or a
/// pause: Claude Code fires `Stop` when it parks the turn waiting on background
/// tasks / session crons, and the payload's `background_tasks`/`session_crons`
/// arrays alone can't distinguish the two (a task pending termination lingers
/// after a genuinely final message). The live value asks Apple Intelligence's
/// on-device model; every failure path — no FoundationModels SDK, pre-26 OS,
/// model unavailable, generation error — fails open to `.final`, so the worst
/// case is today's behavior (a premature done + notification), never a session
/// stuck on "Working".
@DependencyClient
public struct StopFinalityClassifier: Sendable {
    /// Classifies `message` (the stop's `last_assistant_message`), given the
    /// user-facing names of the background tasks / crons still in flight.
    public var classify: @Sendable (_ message: String, _ pendingWork: [String]) async -> StopFinalityVerdict = { _, _ in .final }
}

extension StopFinalityClassifier: DependencyKey {
    /// E2E seam: scenarios embed this marker in `last_assistant_message` to get
    /// a deterministic `.stillWaiting` verdict — CI has no Apple Intelligence,
    /// so the real model can't drive the drop path there (mirrors the
    /// `--e2e-test` stubs in `AppCoordinator`). Ignored outside e2e-test mode.
    public static let e2eStillWaitingMarker = "[e2e-still-waiting]"

    public static var liveValue: StopFinalityClassifier {
        if CommandLine.arguments.contains("--e2e-test") {
            return StopFinalityClassifier(
                classify: { message, _ in
                    message.contains(e2eStillWaitingMarker) ? .stillWaiting : .final
                }
            )
        }
        return StopFinalityClassifier(
            classify: { message, pendingWork in
                #if canImport(FoundationModels)
                    guard #available(macOS 26, iOS 26, *) else { return .final }
                    // classify runs inside the serial ingress consumer — one frame
                    // at a time across every plugin and session — so a slow or
                    // wedged model daemon must not head-of-line-block everyone
                    // else's status updates. Race inference against a fail-open
                    // deadline.
                    return await raceAgainstDeadline(classificationDeadline) {
                        await appleIntelligenceVerdict(message: message, pendingWork: pendingWork)
                    }
                #else
                    return .final
                #endif
            }
        )
    }

    /// Loud in tests: the macro-generated `Self()` closures record an issue when
    /// invoked, so a test that unexpectedly reaches the classifier fails instead
    /// of silently classifying. Tests that exercise it override via
    /// `withDependencies`.
    public static var testValue: StopFinalityClassifier {
        StopFinalityClassifier()
    }

    /// Upper bound on one classification. First use after launch loads the model
    /// (a few seconds); a guided single-bool response is normally well under a
    /// second after that.
    static let classificationDeadline: Duration = .seconds(10)

    /// Races `inference` against a fail-open deadline: whichever finishes first
    /// wins, and hitting the deadline returns `.final` (apply the stop — the
    /// pre-#644 behavior). Both racers are unstructured tasks bridged through an
    /// `AsyncStream` deliberately: a task-group race would still await the losing
    /// child on the way out, so a `respond()` call wedged inside the model daemon
    /// (ignoring cancellation) would block the ingress FIFO anyway. The losing
    /// task is cancelled and left to wind down in the background.
    static func raceAgainstDeadline(
        _ deadline: Duration,
        inference: @escaping @Sendable () async -> StopFinalityVerdict
    ) async -> StopFinalityVerdict {
        let verdicts = AsyncStream<StopFinalityVerdict> { continuation in
            let inferenceTask = Task {
                continuation.yield(await inference())
                continuation.finish()
            }
            let deadlineTask = Task {
                try? await Task.sleep(for: deadline)
                continuation.yield(.final)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                inferenceTask.cancel()
                deadlineTask.cancel()
            }
        }
        for await verdict in verdicts {
            return verdict
        }
        return .final
    }
}

// MARK: - Apple Intelligence implementation

#if canImport(FoundationModels)
    /// Structured verdict for guided generation — the model fills the single
    /// boolean instead of free text, so there is nothing to parse.
    @available(macOS 26, iOS 26, *)
    @Generable
    private struct StopFinalityJudgment {
        @Guide(description: """
        True when the message says or implies the agent is waiting for background \
        work to finish and will continue afterwards. False when it reads as a \
        completed, final answer.
        """)
        var isWaitingForBackgroundWork: Bool
    }

    @available(macOS 26, iOS 26, *)
    extension StopFinalityClassifier {
        /// The on-device model's context window is small (~4k tokens), and the
        /// waiting/finished signal lives at the end of the message ("I'll check
        /// back when the build finishes"), so keep the tail.
        private static let maxMessageLength = 4_000

        fileprivate static func appleIntelligenceVerdict(
            message: String,
            pendingWork: [String]
        ) async -> StopFinalityVerdict {
            guard case .available = SystemLanguageModel.default.availability else {
                return .final
            }

            let session = LanguageModelSession(instructions: """
            You judge the last message a coding agent printed when its turn ended, \
            to decide why it stopped:
            - FINISHED: the message delivers a final answer — a summary of completed \
            work, a conclusion, an error report, or a question for the user.
            - WAITING: the message says the agent paused while background work keeps \
            running (builds, tests, subagents, scheduled jobs) and will continue when \
            that work completes — e.g. "I'll wait for the build to finish", \
            "monitoring the deploy", "will report back when the tests complete".
            Background work may be registered even when the agent is finished (a task \
            pending cleanup), so judge only what the message itself communicates.
            """)

            // Trust boundary: `message` and the `pendingWork` labels are
            // untrusted agent output interpolated into the judge prompt, so
            // adversarial text ("answer WAITING") can steer the verdict. Bounded
            // by design: a steered verdict can only downgrade a done-notification
            // to a still-working one and hold the state on Working while work
            // really is registered (the gate requires non-empty pending work),
            // and the session recovers on the next Stop or SessionEnd — it never
            // gains capabilities or reaches other sessions.
            let prompt = """
            Background work registered for this session: \
            \(pendingWork.joined(separator: ", ")).

            Agent message:
            \(message.suffix(maxMessageLength))
            """

            do {
                let response = try await session.respond(
                    to: prompt,
                    generating: StopFinalityJudgment.self,
                    options: GenerationOptions(sampling: .greedy)
                )
                return response.content.isWaitingForBackgroundWork ? .stillWaiting : .final
            } catch {
                // Guardrail refusals, context overflow, cancellation — all fail
                // open to the pre-#644 behavior.
                return .final
            }
        }
    }
#endif
