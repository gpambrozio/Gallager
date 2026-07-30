import ClaudeCodePluginCore
import Foundation
import StopFinalityDataset

// macOS-26 cross-check + labeling helper for the stop-finality judge (spec
// docs/superpowers/specs/2026-07-30-stop-finality-evaluations-design.md).
// The hill-climbing eval proper lives in the StopFinalityEvaluations test
// target (macOS 27 beta only); this executable drives the SAME dataset
// through the production classifier on this machine's model.
//
//     swift run StopFinalityEval                          # score seeds + mined
//     swift run StopFinalityEval --verdicts in.jsonl out.jsonl
//
// --verdicts serves scripts/stop-finality-dataset.py: classifies each
// {"id","message"} line and writes {"id","onDevice"} lines, so the labeling
// pipeline can surface Claude-vs-on-device disagreements for human review.

let classifier = StopFinalityClassifier.liveValue

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

let arguments = CommandLine.arguments
if let flagIndex = arguments.firstIndex(of: "--verdicts") {
    guard arguments.count >= flagIndex + 3 else {
        print("usage: StopFinalityEval --verdicts <in.jsonl> <out.jsonl>")
        exit(64)
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
        let label = verdict == .stillWaiting ? "waiting" : "final"
        let data = try encoder.encode(VerdictOutput(id: row.id, onDevice: label))
        guard let encoded = String(bytes: data, encoding: .utf8) else {
            print("non-UTF8 JSON for \(row.id) — aborting")
            exit(70)
        }
        outputLines.append(encoded)
        print("[\(index + 1)/\(lines.count)] \(row.id) → \(label)")
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
let cases = seeds + (mined ?? [])

struct Tally {
    var passed = 0
    var total = 0
    var display: String { "\(passed)/\(total)" }
}

var byClass: [StopFinalityCase.Expected: Tally] = [:]
var bySource: [StopFinalityCase.Source: Tally] = [:]
var failures = 0

for c in cases {
    let verdict = await classifier.classify(message: c.message)
    let got: StopFinalityCase.Expected = verdict == .stillWaiting ? .waiting : .final
    let ok = got == c.expected
    if !ok { failures += 1 }
    byClass[c.expected, default: Tally()].total += 1
    bySource[c.source, default: Tally()].total += 1
    if ok {
        byClass[c.expected, default: Tally()].passed += 1
        bySource[c.source, default: Tally()].passed += 1
    }
    print("\(ok ? "PASS" : "FAIL")  [\(c.source.rawValue)] \(c.id) expected \(c.expected.rawValue) → got \(got.rawValue)  (\(c.notes ?? ""))")
}

print("""

overall:        \(cases.count - failures)/\(cases.count)
final-recall:   \(byClass[.final, default: Tally()].display)
waiting-recall: \(byClass[.waiting, default: Tally()].display)
seed:           \(bySource[.seed, default: Tally()].display)
mined:          \(bySource[.mined, default: Tally()].display)
""")
exit(failures == 0 ? 0 : 2)
