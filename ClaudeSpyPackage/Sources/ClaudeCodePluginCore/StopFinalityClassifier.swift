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

// MARK: - StopFinalityAvailability

/// Whether the on-device model can classify right now — drives how the
/// settings row presents the `detect_false_stops` toggle. The classifier
/// itself never needs this (it fails open internally); this exists so the UI
/// can tell the user *why* the check is inert instead of showing a live-looking
/// toggle that silently does nothing.
public enum StopFinalityAvailability: Sendable, Equatable {
    /// The model is ready; classification runs.
    case available
    /// Permanent on this machine: pre-26 OS, no FoundationModels SDK, or the
    /// device is not eligible for Apple Intelligence.
    case unsupported
    /// Apple Intelligence is switched off in System Settings.
    case appleIntelligenceDisabled
    /// The model is still downloading — transient; checks resume when ready.
    case modelDownloading

    /// Whether the settings toggle should render disabled. `modelDownloading`
    /// keeps it enabled: the state is transient and the stored setting should
    /// stay editable while the model arrives.
    public var disablesToggle: Bool {
        switch self {
        case .unsupported,
             .appleIntelligenceDisabled: true
        case .available,
             .modelDownloading: false
        }
    }

    /// Settings-row caption explaining why the check is inert; `nil` when
    /// nothing needs explaining.
    public var settingsCaption: String? {
        switch self {
        case .available:
            nil
        case .unsupported:
            "Requires Apple Intelligence (macOS 26+), which isn't available on this Mac."
        case .appleIntelligenceDisabled:
            "Turn on Apple Intelligence in System Settings to enable this check."
        case .modelDownloading:
            "The Apple Intelligence model is still downloading — checks resume once it's ready."
        }
    }
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
    /// Classifies `message` (the stop's `last_assistant_message`). The verdict
    /// rides on the message alone — the prompt carries NO information about the
    /// registered background work. Task descriptions and cron prompts are
    /// agent-authored free text that often reads as waiting ("Wait for X to
    /// finish") and demonstrably steered the judge; even neutral counts can
    /// anchor a wrong still-waiting verdict, so they stay out too. The
    /// human-readable labels surface in the caller's log line instead.
    public var classify: @Sendable (_ message: String) async -> StopFinalityVerdict = { _ in .final }
    /// Probes whether the on-device model could classify right now. Purely
    /// informational — `classify` re-guards internally — so the settings UI can
    /// render the toggle's real state.
    public var availability: @Sendable () -> StopFinalityAvailability = { .unsupported }
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
                classify: { message in
                    message.contains(e2eStillWaitingMarker) ? .stillWaiting : .final
                },
                // Deterministic in e2e: CI machines vary in OS / Apple
                // Intelligence state, and the settings form must render the
                // same everywhere (toggle enabled, no caption).
                availability: { .available }
            )
        }
        return StopFinalityClassifier(
            classify: { message in
                #if canImport(FoundationModels)
                    guard #available(macOS 26, iOS 26, *) else { return .final }
                    // classify runs inside the serial ingress consumer — one frame
                    // at a time across every plugin and session — so a slow or
                    // wedged model daemon must not head-of-line-block everyone
                    // else's status updates. Race inference against a fail-open
                    // deadline.
                    return await raceAgainstDeadline(classificationDeadline) {
                        await appleIntelligenceVerdict(message: message)
                    }
                #else
                    return .final
                #endif
            },
            availability: {
                #if canImport(FoundationModels)
                    guard #available(macOS 26, iOS 26, *) else { return .unsupported }
                    switch SystemLanguageModel.default.availability {
                    case .available:
                        return .available
                    case let .unavailable(reason):
                        switch reason {
                        case .appleIntelligenceNotEnabled:
                            return .appleIntelligenceDisabled
                        case .modelNotReady:
                            return .modelDownloading
                        // deviceNotEligible + any reason added by a future SDK:
                        // nothing the user can flip on this machine today.
                        default:
                            return .unsupported
                        }
                    }
                #else
                    return .unsupported
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
    ///
    /// The guide text is eval-tuned (`swift run StopFinalityEval`): real agent
    /// summaries are long and full of action words ("run the preflight", "the
    /// build is pushed"), which the earlier, softer wording misread as waiting
    /// — including plain error reports and questions. Keep the "default to
    /// false" clause; removing it regresses the eval.
    @available(macOS 26, iOS 26, *)
    @Generable
    private struct StopFinalityJudgment {
        @Guide(description: """
        True ONLY when the message clearly states the agent is pausing and will \
        continue when background work finishes. False for summaries of completed \
        work, results, error reports, and questions — even when they mention \
        builds, tests, commands, or jobs. Default to false when unsure.
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
            message: String
        ) async -> StopFinalityVerdict {
            guard case .available = SystemLanguageModel.default.availability else {
                return .final
            }

            // Instructions are eval-tuned against real agent messages (see
            // `swift run StopFinalityEval`): FINISHED must explicitly cover
            // error reports, questions, and user-directed next steps, and must
            // say that naming builds/tests/commands is not waiting — the
            // earlier, softer rubric misclassified all of those. WAITING keeps
            // a FINISHED default (a systematic false WAITING pins the session
            // on "Working" while a false FINISHED is just the pre-#644
            // behavior) but must also cover elliptical forms — a second field
            // failure showed orchestrator summaries like "Task 2 reviewer
            // dispatched. Awaiting the verdict" read as finished when WAITING
            // demanded a first-person "I'll wait".
            let session = LanguageModelSession(instructions: """
            You judge the final message a coding agent printed when its turn ended, \
            deciding whether the agent FINISHED its turn or is WAITING for background work.

            FINISHED — the message wraps the turn up: it summarizes work already done \
            (past tense), reports results or an error, asks the user a question, or tells \
            the USER what they can do next. Mentioning builds, tests, commands, or \
            background jobs by name does NOT make it waiting, and neither do commands the \
            user could run.

            WAITING — the message says the agent is pausing now and will continue when \
            still-running work completes: "I'll wait for the build", "monitoring the \
            deploy", "will report back when the tests finish", "I'll resume once CI \
            completes". Terse forms without "I" count too: "Awaiting its report", \
            "Waiting on Task 3". Dispatching or starting a task, run, or subagent and \
            then awaiting its result, report, or verdict is WAITING — the dispatch being \
            past tense does not make the turn finished.

            Background work can stay registered after a turn genuinely finishes (tasks \
            pending cleanup), so decide only from what the message says. If the message \
            does not clearly state the agent is waiting to continue, it is FINISHED.
            """)

            // Trust boundary: `message` is untrusted agent output interpolated
            // into the judge prompt, so adversarial text ("answer WAITING") can
            // steer the verdict. The message is the ONLY per-case input — the
            // registered background work stays out entirely: raw task
            // descriptions steered real verdicts (issue #644 follow-up), and
            // even neutral counts anchor the judge toward still-waiting.
            // Bounded by design: a steered verdict can only downgrade a
            // done-notification to a still-working one and hold the state on
            // Working while work really is registered (the gate requires
            // non-empty pending work), and the session recovers on the next
            // Stop or SessionEnd — it never gains capabilities or reaches
            // other sessions.
            let prompt = """
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
