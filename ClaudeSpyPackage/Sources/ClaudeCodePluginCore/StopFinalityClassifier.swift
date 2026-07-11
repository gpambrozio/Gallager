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
                    return await appleIntelligenceVerdict(message: message, pendingWork: pendingWork)
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
