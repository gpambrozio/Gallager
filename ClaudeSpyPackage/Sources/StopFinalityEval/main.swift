import ClaudeCodePluginCore
import CryptoKit
import Foundation
import StopFinalityDataset

// macOS-26 cross-check, hill-climb driver, and labeling helper for the
// stop-finality judge (spec docs/superpowers/specs/
// 2026-07-30-stop-finality-evaluations-design.md). The Evaluations-framework
// eval (StopFinalityEvaluations test target) only runs on a macOS 27 beta Mac
// and therefore only ever tunes the 27-generation rubric; this executable
// drives the SAME dataset through the SAME classifier seam on this machine's
// model, so the 26 generation can be hill-climbed here (docs/
// stop-finality-eval.md).
//
//     swift run StopFinalityEval                            # score seeds + mined
//     swift run StopFinalityEval --instructions cand.txt    # A/B a rubric
//     swift run StopFinalityEval --guide cand-guide.txt     # A/B the @Guide text
//     swift run StopFinalityEval --seeds-only               # 21-case screen (~30 s)
//     swift run StopFinalityEval --sample 120 --out r.json  # mid-cost screen
//     swift run StopFinalityEval --dump-prompt              # emit today's strings
//     swift run StopFinalityEval --verdicts in.jsonl out.jsonl
//
// Baseline and candidate runs share one code path — both call
// `StopFinalityClassifier.classify(message:instructions:guide:)`, defaulting to
// the production strings — so a round's only difference is the file it was
// handed. `--out` writes per-case verdicts for diffing rounds; every run prints
// the config fingerprint, because greedy sampling is exactly deterministic and
// any tally drift therefore means the config moved, not the model.
//
// --verdicts serves scripts/stop-finality-dataset.py: classifies each
// {"id","message"} line and writes {"id","onDevice"} lines, so the labeling
// pipeline can surface Claude-vs-on-device disagreements for human review. It
// deliberately keeps the *production* dependency path (deadline race included)
// — it is labeling what ships, not scoring a candidate.

let classifier = StopFinalityClassifier.liveValue
let arguments = CommandLine.arguments

func fail(_ message: String, code: Int32 = 64) -> Never {
    print(message)
    exit(code)
}

func value(for flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard index + 1 < arguments.count else { fail("\(flag) needs a value") }
    return arguments[index + 1]
}

func text(atPathFor flag: String) -> String? {
    guard let path = value(for: flag) else { return nil }
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("cannot read \(flag) file: \(path)", code: 66)
    }
    // Trailing newlines are an artifact of editing a prompt in a file; the
    // shipped constants have none, and a stray one would make an otherwise
    // identical candidate look like a different config.
    return contents.trimmingCharacters(in: .newlines)
}

/// Short digest of a prompt string — printed with every run so a surprising
/// tally can be traced to the exact text that produced it.
func fingerprint(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).prefix(4)
        .map { String(format: "%02x", $0) }.joined()
}

let candidateInstructions = text(atPathFor: "--instructions")
let candidateGuide = text(atPathFor: "--guide")
let instructions = candidateInstructions ?? StopFinalityClassifier.productionInstructions
let label = value(for: "--label")
    ?? (candidateInstructions == nil && candidateGuide == nil ? "baseline" : "candidate")

// MARK: - --dump-prompt mode

// Seeds a hill-climb round: dump today's strings, edit the copy, feed it back
// via --instructions/--guide. `--generation` reaches the OTHER generation's
// rubric from this machine (the rubrics are independent literals — see
// StopFinalityClassifier — so reading the 27 text on a 26 Mac needs the
// explicit pick).
if arguments.contains("--dump-prompt") {
    let dumped: (instructions: String, guide: String) = switch value(for: "--generation") {
    case "26": (StopFinalityClassifier.productionInstructions26, StopFinalityClassifier.productionGuide26)
    case "27": (StopFinalityClassifier.productionInstructions27, StopFinalityClassifier.productionGuide27)
    case let other?: fail("--generation takes 26 or 27, got \(other)")
    case nil: (instructions, candidateGuide ?? StopFinalityClassifier.productionGuide)
    }
    if arguments.contains("--guide-only") {
        print(dumped.guide)
    } else if arguments.contains("--instructions-only") {
        print(dumped.instructions)
    } else {
        print("=== instructions (\(fingerprint(dumped.instructions))) ===")
        print(dumped.instructions)
        print("\n=== guide (\(fingerprint(dumped.guide))) ===")
        print(dumped.guide)
    }
    exit(0)
}

guard classifier.availability() == .available else {
    print("Apple Intelligence unavailable (\(classifier.availability())) — cannot eval.")
    print("Enable it in System Settings on a macOS 26+ machine and re-run.")
    exit(1)
}

// MARK: - --verdicts mode

struct VerdictInput: Codable {
    let id: String
    let message: String
}

struct VerdictOutput: Codable {
    let id: String
    let onDevice: String
}

if let flagIndex = arguments.firstIndex(of: "--verdicts") {
    guard arguments.count >= flagIndex + 3 else {
        fail("usage: StopFinalityEval --verdicts <in.jsonl> <out.jsonl>")
    }
    let inputURL = URL(fileURLWithPath: arguments[flagIndex + 1])
    let outputURL = URL(fileURLWithPath: arguments[flagIndex + 2])
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    var outputLines: [String] = []
    let lines = try String(contentsOf: inputURL, encoding: .utf8)
        .split(separator: "\n").filter { !$0.isEmpty }
    for (index, line) in lines.enumerated() {
        let row = try decoder.decode(VerdictInput.self, from: Data(line.utf8))
        let verdict = await classifier.classify(message: row.message)
        let onDevice = verdict == .stillWaiting ? "waiting" : "final"
        let data = try encoder.encode(VerdictOutput(id: row.id, onDevice: onDevice))
        guard let encoded = String(bytes: data, encoding: .utf8) else {
            fail("non-UTF8 JSON for \(row.id) — aborting", code: 70)
        }
        outputLines.append(encoded)
        print("[\(index + 1)/\(lines.count)] \(row.id) → \(onDevice)")
    }
    try (outputLines.joined(separator: "\n") + "\n")
        .write(to: outputURL, atomically: true, encoding: .utf8)
    exit(0)
}

// MARK: - Scoring mode

let seeds = try StopFinalityDataset.seeds()
let mined = try StopFinalityDataset.mined()
if mined == nil {
    print("NOTE: no mined dataset at \(StopFinalityDataset.minedURL.path) — scoring seeds only.")
    print("      (override the path via \(StopFinalityDataset.minedPathEnvVar))")
}

/// Cheap screens for a hill-climb round: `--seeds-only` answers "does this
/// candidate fix the field failure and break no committed case?" in ~30 s, and
/// `--sample N` strides the mined set for an early read on whether the majority
/// FINAL class collapsed. Neither replaces the full run a promotion needs — the
/// recorded per-generation baseline is over all 590 cases.
func selectedCases() -> [StopFinalityCase] {
    guard let mined, !arguments.contains("--seeds-only") else { return seeds }
    guard let requested = value(for: "--sample").flatMap(Int.init), requested < mined.count else {
        return seeds + mined
    }
    let stride = max(1, mined.count / requested)
    return seeds + mined.enumerated()
        .filter { $0.offset.isMultiple(of: stride) }
        .map(\.element)
}

let cases = selectedCases()
// Serial by default: one classification at a time is how the recorded
// baselines were produced, and the model daemon is the shared resource either
// way. Raising it shortens a round; validate a new value by diffing an --out
// against a serial run before trusting its tallies.
let concurrency = max(1, value(for: "--concurrency").flatMap(Int.init) ?? 1)

print("""
run:            \(label)
instructions:   \(fingerprint(instructions))\(candidateInstructions == nil ? " (production)" : " (candidate)")
guide:          \(fingerprint(candidateGuide ?? StopFinalityClassifier.productionGuide))\
\(candidateGuide == nil ? " (production)" : " (candidate)")
cases:          \(cases.count)
concurrency:    \(concurrency)

""")

struct Tally {
    var passed = 0
    var total = 0
    var display: String { "\(passed)/\(total)" }
}

struct CaseResult: Codable {
    let id: String
    let source: String
    let expected: String
    let got: String
    var ok: Bool { expected == got }
}

/// Classifies every case, keeping at most `concurrency` in flight and
/// returning verdicts in dataset order (the printed log is a round's primary
/// diff surface, so it must not reorder with concurrency).
@available(macOS 26, *)
func classifyAll(
    _ cases: [StopFinalityCase],
    instructions: String,
    guide: String?,
    concurrency: Int
) async -> [CaseResult] {
    var results: [CaseResult?] = Array(repeating: nil, count: cases.count)
    await withTaskGroup(of: (Int, StopFinalityVerdict).self) { group in
        var next = 0
        func submit() {
            guard next < cases.count else { return }
            let index = next
            let message = cases[index].message
            next += 1
            group.addTask {
                (index, await StopFinalityClassifier.classify(
                    message: message,
                    instructions: instructions,
                    guide: guide
                ))
            }
        }
        for _ in 0 ..< min(concurrency, cases.count) { submit() }
        for await (index, verdict) in group {
            let c = cases[index]
            let got: StopFinalityCase.Expected = verdict == .stillWaiting ? .waiting : .final
            results[index] = CaseResult(
                id: c.id,
                source: c.source.rawValue,
                expected: c.expected.rawValue,
                got: got.rawValue
            )
            submit()
        }
    }
    return results.compactMap { $0 }
}

let started = Date()
let results: [CaseResult]
// Unreachable in practice — the availability probe above already exited on
// anything older — but availability can't be narrowed across top-level
// statements, so the seam call needs the `if` around it.
if #available(macOS 26, *) {
    results = await classifyAll(
        cases,
        instructions: instructions,
        guide: candidateGuide,
        concurrency: concurrency
    )
} else {
    fail("scoring needs the FoundationModels classifier seam (macOS 26+)", code: 1)
}
guard results.count == cases.count else {
    fail("classified \(results.count) of \(cases.count) cases", code: 70)
}

var byClass: [StopFinalityCase.Expected: Tally] = [:]
var bySource: [StopFinalityCase.Source: Tally] = [:]
var failures = 0
var completed: [CaseResult] = []

for (c, result) in zip(cases, results) {
    completed.append(result)
    if !result.ok { failures += 1 }
    byClass[c.expected, default: Tally()].total += 1
    bySource[c.source, default: Tally()].total += 1
    if result.ok {
        byClass[c.expected, default: Tally()].passed += 1
        bySource[c.source, default: Tally()].passed += 1
    }
    print("\(result.ok ? "PASS" : "FAIL")  [\(c.source.rawValue)] \(c.id) expected \(c.expected.rawValue) → got \(result.got)  (\(c.notes ?? ""))")
}

if let path = value(for: "--out") {
    struct RunReport: Codable {
        let label: String
        let instructionsFingerprint: String
        let guideFingerprint: String
        let caseCount: Int
        let concurrency: Int
        let overall: String
        let finalRecall: String
        let waitingRecall: String
        let seed: String
        let mined: String
        let cases: [CaseResult]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let report = RunReport(
        label: label,
        instructionsFingerprint: fingerprint(instructions),
        guideFingerprint: fingerprint(candidateGuide ?? StopFinalityClassifier.productionGuide),
        caseCount: cases.count,
        concurrency: concurrency,
        overall: "\(cases.count - failures)/\(cases.count)",
        finalRecall: byClass[.final, default: Tally()].display,
        waitingRecall: byClass[.waiting, default: Tally()].display,
        seed: bySource[.seed, default: Tally()].display,
        mined: bySource[.mined, default: Tally()].display,
        cases: completed
    )
    try encoder.encode(report).write(to: URL(fileURLWithPath: path))
    print("\nwrote per-case results → \(path)")
}

print("""

run:            \(label)  [instructions \(fingerprint(instructions)), \
guide \(fingerprint(candidateGuide ?? StopFinalityClassifier.productionGuide))]
overall:        \(cases.count - failures)/\(cases.count)
final-recall:   \(byClass[.final, default: Tally()].display)
waiting-recall: \(byClass[.waiting, default: Tally()].display)
seed:           \(bySource[.seed, default: Tally()].display)
mined:          \(bySource[.mined, default: Tally()].display)
elapsed:        \(Int(Date().timeIntervalSince(started)))s
""")
exit(failures == 0 ? 0 : 2)
