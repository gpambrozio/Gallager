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

    /// Instructions are eval-tuned against real agent messages (see
    /// `docs/stop-finality-eval.md`): FINISHED must explicitly cover
    /// error reports, questions, and user-directed next steps, and must
    /// say that naming builds/tests/commands is not waiting — the
    /// earlier, softer rubric misclassified all of those. WAITING keeps
    /// a FINISHED default (a systematic false WAITING pins the session
    /// on "Working" while a false FINISHED is just the pre-#644
    /// behavior) but must also cover elliptical forms — a second field
    /// failure showed orchestrator summaries like "Task 2 reviewer
    /// dispatched. Awaiting the verdict" read as finished when WAITING
    /// demanded a first-person "I'll wait".
    ///
    /// The macOS 26-GENERATION rubric, validated ONLY on the 26 model: the
    /// 2026-07-30 hill-climb's winning 27 text collapses this generation's
    /// waiting class (waiting-recall 126/153 → 27/153 on the same dataset),
    /// so each model generation ships its own rubric — never edit one from
    /// the other generation's eval results.
    ///
    /// The WAITING sentences past "…does not make the turn finished" are the
    /// 26-side climb (2026-07-30/31, `swift run StopFinalityEval`, greedy).
    /// Round 1, the "one piece done while ANOTHER is still running" sentence:
    /// overall 542→549 (of 590), final 416→420, waiting 126→129, seeds
    /// 20/21→21/21 — it fixed W13, the orchestrator field failure. Round 2,
    /// the bare-dispatch sentence: overall 549→560, waiting 129→142, final
    /// 420→418, seeds still 21/21. Round 4 (2026-07-31, after five fresh
    /// orchestrator field failures joined the seeds as W14–W18): the
    /// contingent-plan sentence ("after it commits, I'll re-review") and the
    /// idle-reviewer tail sentence: overall 561→568 (of 595), waiting
    /// 142→152, final 419→416, seeds 21/26→26/26, zero waiting-side
    /// regressions. Rounds 2 and 4 are non-Pareto and were taken
    /// deliberately: each recovers real field false-stops (the whole point
    /// of #644) for a small final-recall dip, and round 4's three lost
    /// finals are two user-handbacks ("Standing by for your direction",
    /// "waiting on your call") plus one release-notes document — the same
    /// boundary families round 3 proved cost 3-7 finals to protect from the
    /// instructions side.
    ///
    /// Lessons for the next 26 round, all the OPPOSITE of the 27 climb's:
    /// - The @Guide text is inert on this generation for WIDENING waiting
    ///   (the elliptical clause left W13 missing), and actively destructive
    ///   for widening FINISHED: quoting the round-4 handbacks in the guide's
    ///   user clause collapsed the waiting side (W13/W14/W18 + two bare
    ///   dispatches flipped in one screen). Every gain here came from the
    ///   instructions.
    /// - Worked `Examples:` blocks REGRESS this model. The 27 round-6
    ///   examples scored seeds 18/21 (W1 and W5 flip to final) — the same
    ///   allergy that collapsed the round-6 text to waiting-recall 27/153.
    ///
    /// Placement is a real variable, not prose polish: the bare-dispatch idea
    /// scored seeds 20/21 (W13 relapsed) both when folded into the dispatch
    /// sentence and when appended to the terse-forms list, and 21/21 only as
    /// its own trailing sentence — same claim, three positions, one survivor.
    /// Append; do not splice into a sentence that already earns its keep.
    /// Round 4 sharpened this: a sentence appended AFTER the bare-dispatch
    /// sentence silently flipped four mined bare dispatches ("Task 5
    /// reviewer dispatched.") to final — invisible to the seed screen, which
    /// has no bare-dispatch case — while the same sentence placed beside its
    /// thematic neighbor (the dispatch-and-await sentence) cost nothing. And
    /// a "still running does state waiting" clarifier appended to the
    /// closing default paragraph looked like the round's winner on seeds
    /// (26/26) but swallowed user-handback finals on the full run; the
    /// idle-reviewer sentence at the WAITING paragraph's tail covered the
    /// same seeds without it.
    public static let productionInstructions26 = """
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
    past tense does not make the turn finished. A dispatch followed by a plan \
    for after the work finishes — "after it commits, I'll re-review" — is \
    WAITING, not a finished turn. Reporting that one piece of work is done while \
    ANOTHER is still running — "nothing to do until it reports" — is WAITING \
    too: the finished part does not end the turn. A bare dispatch announcement — \
    "Task 3 reviewer dispatched." — is WAITING as well. A reviewer idling after \
    its already-processed report — "nothing to act on. The next implementer is \
    running" — is the same WAITING shape.

    Background work can stay registered after a turn genuinely finishes (tasks \
    pending cleanup), so decide only from what the message says. If the message \
    does not clearly state the agent is waiting to continue, it is FINISHED.
    """

    /// The macOS 27-generation rubric, validated ONLY on the 27 model
    /// (2026-07-30, 590 cases, greedy): correct 0.9119→0.9271, final-recall
    /// 0.9497→0.9611, waiting-recall 0.8039→0.8301, seeds 21/21 including
    /// W13 — the field failure the round-6 hill-climb fixed. Paired with
    /// `productionGuide27`.
    ///
    /// Historically this was spelled `productionInstructions26 + suffix`,
    /// which silently rewrote the 27 rubric on every 26 edit and forced a
    /// beta-Mac re-validation of a generation nobody had touched. The two
    /// are standalone literals now: they START from a shared ancestor (this
    /// text is that ancestor plus the round-6 decision rule and examples)
    /// but they are tuned against different models and are expected to
    /// drift apart. Editing one NEVER changes the other — and each is
    /// validated only by its own generation's eval.
    public static let productionInstructions27 = """
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

    Decision rule: ask one question — does the message say the agent \
    itself will automatically continue when still-running WORK (a build, \
    test, deploy, job, task, or subagent) completes? Only then is it \
    WAITING. Everything else is FINISHED, including: asking the user to \
    act or answer ("please do X, then I'll…" — the agent resumes on the \
    USER, not on work), waiting for the user's decision or input in any \
    phrasing ("waiting on your call", "standing by"), and mentions of \
    work someone else owns (CI, cron) that the agent does not promise to \
    pick up.

    Examples:
    - "Task B reviewer dispatched. Awaiting the verdict." → WAITING
    - "Just task A's checker going idle after posting its results — \
    already handled. Task B is still running; nothing to do until it \
    reports." → WAITING (the awaited work is still running — a subagent \
    going idle or a report being saved does not end the turn while \
    another task runs)
    - "I've launched the deploy in the background — it takes about ten \
    minutes. I'll pick this up and summarize once it completes." → WAITING
    """

    /// The rubric for THIS machine's model generation — what production
    /// ships and what the eval suite A/Bs candidates against via
    /// `classify(message:instructions:)` (spec docs/superpowers/specs/
    /// 2026-07-30-stop-finality-evaluations-design.md). A winning candidate
    /// is promoted into the matching per-generation constant, after
    /// cross-checking the OTHER generation (docs/stop-finality-eval.md).
    public static var productionInstructions: String {
        if #available(macOS 27, iOS 27, *) {
            productionInstructions27
        } else {
            productionInstructions26
        }
    }

    /// The `@Guide` description on the 26-generation judgment schema — the
    /// string closest to the model's actual decision, and the highest-leverage
    /// variable the 2026-07-30 hill-climb found. Named (rather than inlined in
    /// `@Guide`) so the eval can dump it, A/B a candidate against it
    /// (`classify(message:instructions:guide:)`), and assert the candidate seam
    /// builds a schema identical to the shipped one.
    ///
    /// Real agent summaries are long and full of action words ("run the
    /// preflight", "the build is pushed"), which an earlier, softer wording
    /// misread as waiting — including plain error reports and questions. Keep
    /// the "default to false" clause; removing it regresses the eval.
    ///
    /// The "next move belongs to the user" clause is the 26-side climb's
    /// round 3 (overall 560→561, final 418→419, waiting held at 142, seeds
    /// 21/21) — the round's whole point being WHERE it landed. The identical
    /// carve-out written into `productionInstructions26` cost 3-7 finals
    /// every way it was phrased and placed (411-415, all under the pre-climb
    /// floor of 416), because on the instructions side widening FINISHED
    /// drags waiting-recall with it. In the guide the same idea is free.
    public static let productionGuide26 = """
    True ONLY when the message clearly states the agent is pausing and will \
    continue when background work finishes. False for summaries of completed \
    work, results, error reports, questions, and messages whose next move \
    belongs to the user — even when they mention builds, tests, commands, or \
    jobs. Default to false when unsure.
    """

    /// The 27-generation guide: rewritten by the 2026-07-30 hill-climb in
    /// lockstep with the decision-rule suffix in `productionInstructions27`.
    /// Validated only on the 27 model — like the rubrics, the two generations'
    /// guides are independent strings (see the divergence note above).
    public static let productionGuide27 = """
    True ONLY when the message states the agent itself will automatically \
    continue when still-running work (a build, test, deploy, job, task, or \
    subagent) completes — including elliptical forms like "Awaiting its \
    report" or "another task is still working; nothing to do until it \
    reports". False for everything else: summaries of completed work, \
    results, error reports, questions, requests for the user to act or \
    answer (resuming after the USER does something is false), waiting on \
    the user's decision in any phrasing, and mentions of work someone else \
    owns that the agent does not promise to pick up. Default to false \
    when unsure.
    """

    /// The guide for THIS machine's model generation — the twin of
    /// `productionInstructions`, and what a `nil` `guide:` argument to the
    /// eval seam resolves to.
    public static var productionGuide: String {
        if #available(macOS 27, iOS 27, *) {
            productionGuide27
        } else {
            productionGuide26
        }
    }

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
    /// 26-generation schema; see `StopFinalityJudgment27` for the 27 twin and
    /// the divergence note on `productionInstructions26`. The guide text lives
    /// in `StopFinalityClassifier.productionGuide26` (eval-tuned — see there).
    @available(macOS 26, iOS 26, *)
    @Generable
    private struct StopFinalityJudgment {
        @Guide(description: StopFinalityClassifier.productionGuide26)
        var isWaitingForBackgroundWork: Bool
    }

    /// 27-generation twin of `StopFinalityJudgment`, carrying
    /// `productionGuide27`.
    @available(macOS 27, iOS 27, *)
    @Generable
    private struct StopFinalityJudgment27 {
        @Guide(description: StopFinalityClassifier.productionGuide27)
        var isWaitingForBackgroundWork: Bool
    }

    /// The one property both judgment schemas expose — shared by the shipped
    /// `@Generable` structs and the eval's runtime-guide twin.
    private let judgmentProperty = "isWaitingForBackgroundWork"

    @available(macOS 26, iOS 26, *)
    extension StopFinalityClassifier {
        /// The on-device model's context window is small (~4k tokens), and the
        /// waiting/finished signal lives at the end of the message ("I'll check
        /// back when the build finishes"), so keep the tail.
        private static let maxMessageLength = 4_000

        /// Eval seam: production classification with injectable instructions
        /// and, for guide-text rounds, an injectable `@Guide` description.
        /// `liveValue` passes `productionInstructions` and no guide; the eval
        /// passes candidates. Guided generation (per-generation schema),
        /// greedy sampling, and tail truncation stay in lockstep so the eval
        /// measures exactly what ships.
        ///
        /// `guide: nil` runs the shipped `@Generable` schema verbatim. A
        /// non-nil guide swaps ONLY that description, via a dynamic schema
        /// built to match the shipped one exactly (same type name, same
        /// property, same bool) — `stopFinalityCandidateSchemaMatchesShipped`
        /// in StopFinalityTests pins that equivalence, so a guide round
        /// measures the changed words and nothing else.
        public static func classify(
            message: String,
            instructions: String,
            guide: String? = nil
        ) async -> StopFinalityVerdict {
            guard case .available = SystemLanguageModel.default.availability else {
                return .final
            }
            let session = LanguageModelSession(instructions: instructions)
            let prompt = """
            Agent message:
            \(message.suffix(maxMessageLength))
            """
            do {
                let isWaiting: Bool = if let guide {
                    try await session.respond(
                        to: prompt,
                        schema: candidateJudgmentSchema(guide: guide),
                        options: GenerationOptions(sampling: .greedy)
                    ).content.value(Bool.self, forProperty: judgmentProperty)
                } else if #available(macOS 27, iOS 27, *) {
                    try await session.respond(
                        to: prompt,
                        generating: StopFinalityJudgment27.self,
                        options: GenerationOptions(sampling: .greedy)
                    ).content.isWaitingForBackgroundWork
                } else {
                    try await session.respond(
                        to: prompt,
                        generating: StopFinalityJudgment.self,
                        options: GenerationOptions(sampling: .greedy)
                    ).content.isWaitingForBackgroundWork
                }
                return isWaiting ? .stillWaiting : .final
            } catch {
                // Guardrail refusals, context overflow, cancellation — all fail
                // open to the pre-#644 behavior.
                return .final
            }
        }

        /// The runtime-guide twin of this generation's `@Generable` judgment.
        /// The schema's type name is part of what the model sees, so it must
        /// match the generation's shipped struct name — otherwise a guide
        /// round would be changing two strings at once.
        static func candidateJudgmentSchema(guide: String) throws -> GenerationSchema {
            let typeName = if #available(macOS 27, iOS 27, *) {
                "StopFinalityJudgment27"
            } else {
                "StopFinalityJudgment"
            }
            return try GenerationSchema(
                root: DynamicGenerationSchema(
                    name: typeName,
                    properties: [
                        DynamicGenerationSchema.Property(
                            name: judgmentProperty,
                            description: guide,
                            schema: DynamicGenerationSchema(type: Bool.self)
                        ),
                    ]
                ),
                dependencies: []
            )
        }

        /// Debug dumps of the shipped schemas, so the equivalence test can
        /// compare them against `candidateJudgmentSchema` without making the
        /// `@Generable` types themselves public.
        static var shippedJudgmentSchemaDescription: String {
            if #available(macOS 27, iOS 27, *) {
                StopFinalityJudgment27.generationSchema.debugDescription
            } else {
                StopFinalityJudgment.generationSchema.debugDescription
            }
        }

        fileprivate static func appleIntelligenceVerdict(
            message: String
        ) async -> StopFinalityVerdict {
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
            await classify(message: message, instructions: productionInstructions)
        }
    }
#endif
