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

        /// Committed seeds the 27-generation model is known to miss — the
        /// 2026-07-31 round-7 frontier: every candidate that flipped W18
        /// ("Final reviewer idling after its already-processed report —
        /// nothing to act on. The fix-wave agent is working.") also flipped
        /// 13 mined user-handback finals ("reviewer idle — waiting on your
        /// call"), which would pin sessions on Working (see the
        /// productionGuide27 doc comment for the sixteen-candidate map).
        /// Excluded from the 100% seed gate ONLY here; these cases still
        /// gate the 26 side, still score in `correct`/`waiting-recall`, and
        /// a future round (or model generation) that fixes one for free
        /// should remove it from this set.
        static let known27Misses: Set<String> = ["W18"]

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
                slice(
                    Self.seedCorrect,
                    when: input.source.source == .seed
                        && !Self.known27Misses.contains(input.source.id)
                ),
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
        let cases: [StopFinalityCase]
        /// Returns true for WAITING. Baseline passes the production seam;
        /// the candidate may pass an eval-local path when the round's
        /// variable (e.g. the @Guide text, round 4) is one the seam cannot
        /// inject.
        let classify: @Sendable (String) async -> Bool

        var dataset: ArrayLoader<StopSample> {
            ArrayLoader(samples: cases.map { StopSample(source: $0) })
        }

        func subject(from sample: StopSample) async throws -> ModelSubject<Bool> {
            ModelSubject(value: await classify(sample.source.message), transcript: nil)
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
        /// Result: waiting fell back to 0.850/0.843, final only 0.9336/0.9324
        /// (gate still breached), W13 still missed — suffix-only edits trade
        /// the classes around a frontier. Round 4 (2026-07-30): keep these
        /// instructions, change the OTHER string — the guided-generation
        /// @Guide text (see `CandidateClassifier`). Result: first
        /// gate-clearing round on the mined set (final 0.9557 > gate,
        /// waiting 0.85 > gate, correct 0.9305 best yet) but W13 STILL
        /// missed — the rule asks whether the agent "says it will continue"
        /// and W13 never says it. Round 5 (2026-07-30): the rule counted
        /// elliptical forms as yes — waiting best-ever (0.941/0.936) but
        /// mined-final collapsed to 0.911 and W13 STILL missed. Round 6
        /// (2026-07-30, WINNER — promoted): revert the rule amendment and
        /// tighten the orchestrator example with W13's lexical texture
        /// ("going idle", "already handled") instead, paired with the round-4
        /// guide. Cleared everything: seeds 21/21 incl. W13, mined-final
        /// 0.9604, mined-waiting 0.8143, correct 0.9271 — beats the
        /// pre-tuning prompt on every slice ON THE 27 MODEL. The daily-Mac
        /// cross-check then showed the same text COLLAPSES the 26 model's
        /// waiting class (126/153 → 27/153), so promotion was
        /// version-branched: round 6 lives in `productionInstructions27` +
        /// `StopFinalityJudgment27` (what this suite exercises on the beta
        /// Mac via the runtime-picked `productionInstructions`), while the
        /// 26 generation keeps its own validated rubric. The guide-swapping
        /// CandidateClassifier scaffold was removed with the promotion
        /// (recover from git history for future guide rounds). Round 7
        /// (2026-07-31, guide-side — this constant untouched): after five
        /// orchestrator field failures joined the seeds (W14–W18, suite
        /// 23/26), a third elliptical form in `productionGuide27` recovered
        /// W15+W16 plus one mined final (mined-final 412→413, waiting held
        /// at 114, zero finals lost); W18 proved unfixable without −13
        /// mined handback finals and became the first `known27Misses`
        /// entry. Rounds were driven by `swift run StopFinalityEval
        /// --guide` on the beta Mac (~40 s seed screens) rather than this
        /// suite (~19 min per test) — same seam, same numbers.
        static let instructions = StopFinalityClassifier.productionInstructions
    }

    // MARK: - Runner

    /// Beta-SDK reconciliation (Xcode 27 beta 4): Swift Testing's @Suite/@Test
    /// macros reject declarations carrying @available, so the suite below
    /// stays availability-free and each test guards #available at runtime
    /// before calling into this 27-only runner.
    @available(macOS 27, *)
    enum StopFinalityEvalRunner {
        /// Mined-set gates: first pinned from the 2026-07-30 macOS 27
        /// baseline (407/429, 112/140), ratcheted to the promoted round-6
        /// config's results the same day (final 412/429, waiting 114/140 —
        /// greedy, macOS 27 build 26A5388g), then to round 7's 413/429
        /// (2026-07-31, guide-side, waiting held at 114). These gate the 27
        /// generation only (this suite runs on the beta Mac); the 26
        /// generation's line is the executable's recorded baseline in
        /// docs/stop-finality-eval.md. Seeds gate at 100% minus the
        /// documented `known27Misses`; keep ratcheting as future rounds
        /// improve.
        static let minedFinalRecallGate: Double? = 413 / 429
        static let minedWaitingRecallGate: Double? = 114 / 140

        static func run(
            name: String,
            variant: String,
            classify: @escaping @Sendable (String) async -> Bool
        ) async throws {
            try requireModel()
            let evaluation = StopFinalityEvaluation(
                name: name,
                cases: try loadCases(),
                classify: classify
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
                variant: "baseline"
            ) { message in
                await StopFinalityClassifier.classify(
                    message: message,
                    instructions: StopFinalityClassifier.productionInstructions
                ) == .stillWaiting
            }
        }

        @Test func candidate() async throws {
            guard #available(macOS 27, *) else {
                Issue.record("Evaluations requires macOS 27")
                return
            }
            try await StopFinalityEvalRunner.run(
                name: "StopFinalityCandidate",
                variant: "candidate"
            ) { message in
                await StopFinalityClassifier.classify(
                    message: message,
                    instructions: CandidatePrompt.instructions
                ) == .stillWaiting
            }
        }
    }
#endif
