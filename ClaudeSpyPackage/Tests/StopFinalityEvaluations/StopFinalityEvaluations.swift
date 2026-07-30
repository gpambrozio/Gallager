// Beta-SDK note for the implementer: this file is written against the macOS
// 27 beta Evaluations API as documented at developer.apple.com/documentation/
// evaluations (fetchable via sosumi). It cannot compile on this machine
// (macOS 26 SDK — canImport(Evaluations) is false, so the file is empty here
// and CI-safe). If spellings drifted in a newer beta, fix them in this file
// only, on the beta Mac, against its local SDK — the shapes to preserve: one
// exact-match evaluator emitting per-class/per-source metrics, and baseline +
// candidate evaluations over the identical dataset. If an EvaluationTrait
// initializer is available (@Test(.evaluation(...)) form), prefer it — it
// feeds Xcode's evaluation report and comparison view — and read the result
// via EvaluationContext.current.result; the run(info:) form below is the
// documented fallback and produces the same numbers.

#if canImport(Evaluations) && canImport(FoundationModels)
    import ClaudeCodePluginCore
    import Evaluations
    import Foundation
    import FoundationModels
    import StopFinalityDataset
    import Testing

    // MARK: - Sample

    @available(macOS 27, *)
    struct StopSample: SampleProtocol {
        let source: StopFinalityCase
        var input: String { source.message }
        /// true = WAITING. Optional per SampleProtocol; always present here.
        var expected: Bool? { source.expected == .waiting }
    }

    // MARK: - Evaluator

    /// Exact match against ground truth, fanned into per-class and per-source
    /// metrics via `.ignore()` (an ignored metric drops out of that sample's
    /// aggregation, so each mean is computed over exactly its slice).
    @available(macOS 27, *)
    struct StopFinalityExactMatchEvaluator: EvaluatorProtocol {
        static let correct = Metric("correct")
        static let finalRecall = Metric("final-recall")
        static let waitingRecall = Metric("waiting-recall")
        static let seedCorrect = Metric("seed-correct")
        static let minedFinalRecall = Metric("mined-final-recall")
        static let minedWaitingRecall = Metric("mined-waiting-recall")
        static let allMetrics = [
            correct, finalRecall, waitingRecall,
            seedCorrect, minedFinalRecall, minedWaitingRecall,
        ]

        func metrics(subject: ModelSubject<Bool>, input: StopSample) async throws -> [Metric] {
            let expectedWaiting = input.source.expected == .waiting
            let mined = input.source.source == .mined
            let ok = subject.value == expectedWaiting
            let rationale = "\(input.source.id): expected \(input.source.expected.rawValue), "
                + "got \(subject.value ? "waiting" : "final")"

            func slice(_ metric: Metric, when relevant: Bool) -> Metric {
                guard relevant else { return metric.ignore(rationale: nil) }
                return ok ? metric.passing(rationale: nil) : metric.failing(rationale: rationale)
            }

            return [
                slice(Self.correct, when: true),
                slice(Self.finalRecall, when: !expectedWaiting),
                slice(Self.waitingRecall, when: expectedWaiting),
                slice(Self.seedCorrect, when: input.source.source == .seed),
                slice(Self.minedFinalRecall, when: mined && !expectedWaiting),
                slice(Self.minedWaitingRecall, when: mined && expectedWaiting),
            ]
        }
    }

    // MARK: - Evaluation

    @available(macOS 27, *)
    struct StopFinalityEvaluation: Evaluation {
        /// "StopFinalityBaseline" or "StopFinalityCandidate" — distinguishes
        /// the two runs in reports and saved result JSON.
        let name: String
        let instructions: String
        let cases: [StopFinalityCase]

        var dataset: ArrayLoader<StopSample> {
            ArrayLoader(samples: cases.map { StopSample(source: $0) })
        }

        func subject(from sample: StopSample) async throws -> ModelSubject<Bool> {
            let verdict = await StopFinalityClassifier.classify(
                message: sample.source.message,
                instructions: instructions
            )
            return ModelSubject(value: verdict == .stillWaiting, transcript: nil)
        }

        var evaluators: Evaluators {
            StopFinalityExactMatchEvaluator()
        }

        func aggregateMetrics(using aggregator: inout MetricsAggregator) {
            for metric in StopFinalityExactMatchEvaluator.allMetrics {
                aggregator.computeMean(of: metric)
            }
        }
    }

    // MARK: - Candidate prompt (the experimental variable)

    @available(macOS 27, *)
    enum CandidatePrompt {
        /// The ONLY thing a hill-climb round edits (one variable at a time —
        /// WWDC26 session 335). Starts identical to production so run 1 is an
        /// aligned baseline; a winning candidate is promoted by copying this
        /// text into `StopFinalityClassifier.productionInstructions` and
        /// resetting this back to `productionInstructions`.
        ///
        /// Round 1 (2026-07-30): few-shot examples alone. Fixed both seed
        /// misses (W13 orchestrator shape, W2 background start) and lifted
        /// waiting-recall 0.804→0.869, but flipped 9 mined FINAL cases to
        /// WAITING — all "awaiting the USER" shapes — breaching the
        /// mined-final gate (0.9487→0.9277). Round 2: user-wait/work-wait
        /// clause + FINISHED contrast examples — waiting side climbed to
        /// 0.908/0.907 but W13 relapsed (its FINISHED twin example
        /// pattern-matched the opening) and mined-final stayed 0.9277.
        /// Round 3 (2026-07-30): one change — replace the suffix with an
        /// explicit decision rule and only the 3 WAITING examples (drop the
        /// W13-twin and the extra FINISHED examples; fewer examples per the
        /// WWDC overfit warning, discriminator stated as a question).
        static let instructions = StopFinalityClassifier.productionInstructions + """


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
        - "That's just task A's helper finishing — already handled. Task B's \
        implementer is still working; nothing to do until it reports." → WAITING \
        (the awaited work is still running, even though this event needed no \
        action)
        - "I've launched the deploy in the background — it takes about ten \
        minutes. I'll pick this up and summarize once it completes." → WAITING
        """
    }

    // MARK: - Runner

    /// Beta-SDK reconciliation (Xcode 27 beta 4): Swift Testing's @Suite/@Test
    /// macros reject declarations carrying @available, so the suite below
    /// stays availability-free and each test guards #available at runtime
    /// before calling into this 27-only runner.
    @available(macOS 27, *)
    enum StopFinalityEvalRunner {
        /// Mined-set gates, pinned from the first baseline run on the beta
        /// Mac (2026-07-30, macOS 27.0 26A5388g, greedy — exact values from
        /// results/baseline.json: mined-final-recall 407/429, mined-waiting-
        /// recall 112/140). Seeds always gate at 100%; ratchet these up as
        /// hill-climb rounds improve them.
        static let minedFinalRecallGate: Double? = 407 / 429
        static let minedWaitingRecallGate: Double? = 112 / 140

        static func run(name: String, instructions: String, variant: String) async throws {
            try requireModel()
            let evaluation = StopFinalityEvaluation(
                name: name,
                instructions: instructions,
                cases: try loadCases()
            )
            let result = try await evaluation.run(info: ["variant": variant])
            print(result.groupedSummary)
            try saveResult(result, label: variant)
            assertGates(result)
        }

        static func loadCases() throws -> [StopFinalityCase] {
            let seeds = try StopFinalityDataset.seeds()
            guard let mined = try StopFinalityDataset.mined() else {
                print("WARNING: no mined dataset at \(StopFinalityDataset.minedURL.path) — seeds only")
                return seeds
            }
            return seeds + mined
        }

        static func requireModel() throws {
            guard case .available = SystemLanguageModel.default.availability else {
                Issue.record("""
                Apple Intelligence unavailable (\(SystemLanguageModel.default.availability)) \
                — the eval must run on the macOS 27 beta Mac with Apple Intelligence enabled.
                """)
                throw CancellationError()
            }
        }

        static func assertGates(_ result: EvaluationResult) {
            let seed = result.aggregateValue(
                .mean(of: StopFinalityExactMatchEvaluator.seedCorrect))
            #expect(seed == 1, "seed regression — every committed case must pass")
            if let gate = minedFinalRecallGate {
                let value = result.aggregateValue(
                    .mean(of: StopFinalityExactMatchEvaluator.minedFinalRecall))
                #expect(value >= gate, "mined final-recall fell below the pinned gate")
            }
            if let gate = minedWaitingRecallGate {
                let value = result.aggregateValue(
                    .mean(of: StopFinalityExactMatchEvaluator.minedWaitingRecall))
                #expect(value >= gate, "mined waiting-recall fell below the pinned gate")
            }
        }

        static func saveResult(_ result: EvaluationResult, label: String) throws {
            let dir = StopFinalityDataset.minedURL
                .deletingLastPathComponent()
                .appendingPathComponent("results")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = try result.saveJSON(
                to: dir.appendingPathComponent("\(label).json"),
                includeReportMetadata: true
            )
            print("saved \(label) result → \(url.path)")
        }

    }

    // MARK: - Suite

    @Suite("Stop-finality hill-climb", .serialized)
    struct StopFinalityEvaluationSuite {
        @Test func baseline() async throws {
            guard #available(macOS 27, *) else {
                Issue.record("Evaluations requires macOS 27")
                return
            }
            try await StopFinalityEvalRunner.run(
                name: "StopFinalityBaseline",
                instructions: StopFinalityClassifier.productionInstructions,
                variant: "baseline"
            )
        }

        @Test func candidate() async throws {
            guard #available(macOS 27, *) else {
                Issue.record("Evaluations requires macOS 27")
                return
            }
            try await StopFinalityEvalRunner.run(
                name: "StopFinalityCandidate",
                instructions: CandidatePrompt.instructions,
                variant: "candidate"
            )
        }
    }
#endif
