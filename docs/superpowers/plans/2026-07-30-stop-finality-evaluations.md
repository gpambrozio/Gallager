# Stop-Finality Classifier Evaluation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a hill-climbing evaluation for the stop-finality judge on Apple's Evaluations framework, fed by a transcript-mined dataset, and use it to fix the 2026-07-30 false "Session Idle" failure.

**Architecture:** A shared `StopFinalityDataset` library (schema + committed seeds + gitignored mined data) feeds three consumers: the existing `StopFinalityEval` executable (macOS 26 cross-check + labeling helper), a new `StopFinalityEvaluations` test target on the Evaluations framework (runs only on a macOS 27 beta Mac), and a Python mining/labeling pipeline. The only production change is an instruction-injection seam on `StopFinalityClassifier`.

**Tech Stack:** Swift 6.3 / SPM, Swift Testing, FoundationModels, Evaluations framework (macOS 27 beta), Python 3 + `claude` CLI.

**Spec:** `docs/superpowers/specs/2026-07-30-stop-finality-evaluations-design.md`

## Global Constraints

- Package platform floors are `.iOS(.v18), .macOS(.v15)` — all model code stays behind `#if canImport(FoundationModels)` + `@available(macOS 26, iOS 26, *)`; all Evaluations code behind `#if canImport(Evaluations)` + `@available(macOS 27, *)`. CI has no Apple Intelligence and must keep compiling everything.
- Mined data is verbatim excerpts from the user's real sessions and must **never be committed** (repo is heading public). It lives at `~/.gallager/eval/stop-finality-mined.json`, override env var `STOP_FINALITY_MINED_DATASET`.
- Production classifier behavior must not change: guided `StopFinalityJudgment` generation, `GenerationOptions(sampling: .greedy)`, 4 000-char tail truncation, fail-open to `.final`, 10 s deadline race — all preserved.
- Build/test through the XcodeBuildTools skills (`swift-package` for `swift build` / `swift test` / `swift run`); the sandbox wrappers handle DerivedData/SPM isolation.
- A `PostToolUse` swiftformat hook formats Swift edits automatically — don't run formatters manually.
- Tasks 8–9 require the second Mac on macOS 27 beta with Apple Intelligence enabled; everything else runs on the daily (macOS 26) Mac.
- Working branch: `stop-finality-evaluations` (already created off `main`; spec is committed there).

---

### Task 1: `StopFinalityDataset` module with committed seed cases

**Files:**
- Modify: `ClaudeSpyPackage/Package.swift` (Target.Dependency helper extension at line ~63, targets array near line 477)
- Create: `ClaudeSpyPackage/Sources/StopFinalityDataset/StopFinalityDataset.swift`
- Create: `ClaudeSpyPackage/Sources/StopFinalityDataset/Resources/seed-cases.json`
- Test: `ClaudeSpyPackage/Tests/StopFinalityDatasetTests/StopFinalityDatasetTests.swift`

**Interfaces:**
- Consumes: nothing (leaf module, Foundation only).
- Produces (later tasks depend on these exact names):
  - `struct StopFinalityCase: Codable, Sendable, Equatable, Identifiable` with `id: String`, `message: String`, `expected: Expected` (`enum Expected: String { case waiting, final }`), `source: Source` (`enum Source: String { case seed, mined }`), `notes: String?`, and a public memberwise `init(id:message:expected:source:notes:)` (notes defaulted `nil`).
  - `enum StopFinalityDataset` with `static let minedPathEnvVar = "STOP_FINALITY_MINED_DATASET"`, `static var minedURL: URL`, `static func seeds() throws -> [StopFinalityCase]`, `static func mined() throws -> [StopFinalityCase]?` (nil when the file is absent).

- [ ] **Step 1: Declare the module in Package.swift**

In the `extension Target.Dependency` block (near the `claudeCodePluginCore` helper at line ~162), add:

```swift
    static var stopFinalityDataset: Self {
        "StopFinalityDataset"
    }
```

In the targets array, directly above the `StopFinalityEval` executable target (line ~477), add:

```swift
    // Shared dataset for the stop-finality eval (spec
    // docs/superpowers/specs/2026-07-30-stop-finality-evaluations-design.md):
    // committed seed cases (past field failures — the regression suite) ride
    // as a bundled resource; mined cases load from ~/.gallager/eval and are
    // never committed (verbatim excerpts from real sessions).
    .target(
        name: "StopFinalityDataset",
        resources: [.copy("Resources/seed-cases.json")]
    ),
```

And in the test-target section (near `ClaudeCodePluginCoreTests`, line ~494):

```swift
    .testTarget(
        name: "StopFinalityDatasetTests",
        dependencies: [.stopFinalityDataset]
    ),
```

- [ ] **Step 2: Write the failing tests**

`ClaudeSpyPackage/Tests/StopFinalityDatasetTests/StopFinalityDatasetTests.swift`:

```swift
import Foundation
import Testing
@testable import StopFinalityDataset

@Suite("StopFinalityDataset")
struct StopFinalityDatasetTests {
    @Test func decodesSchema() throws {
        let json = """
        [{"id": "X1", "message": "All done.", "expected": "final", "source": "seed", "notes": "smoke"}]
        """
        let cases = try JSONDecoder().decode([StopFinalityCase].self, from: Data(json.utf8))
        #expect(cases == [
            StopFinalityCase(id: "X1", message: "All done.", expected: .final, source: .seed, notes: "smoke"),
        ])
    }

    @Test func notesIsOptional() throws {
        let json = """
        [{"id": "X2", "message": "Waiting on CI.", "expected": "waiting", "source": "mined"}]
        """
        let cases = try JSONDecoder().decode([StopFinalityCase].self, from: Data(json.utf8))
        #expect(cases.first?.notes == nil)
    }

    @Test func seedsLoadFromBundle() throws {
        let seeds = try StopFinalityDataset.seeds()
        #expect(seeds.count == 20)
        #expect(seeds.allSatisfy { $0.source == .seed })
        #expect(Set(seeds.map(\.id)).count == seeds.count)
        let f1 = try #require(seeds.first { $0.id == "F1" })
        #expect(f1.expected == .final)
        #expect(f1.message.contains("Merged and pushed"))
        let w12 = try #require(seeds.first { $0.id == "W12" })
        #expect(w12.expected == .waiting)
    }

    @Test func minedURLHonorsEnvOverride() {
        // Can't mutate the process env safely in tests (see memory:
        // setenv breaks posix_spawn) — just pin the default path shape.
        #expect(StopFinalityDataset.minedURL.path.hasSuffix(".gallager/eval/stop-finality-mined.json"))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run (XcodeBuildTools swift-package skill): `swift test --filter StopFinalityDatasetTests` in `ClaudeSpyPackage/`
Expected: build failure — module `StopFinalityDataset` has no sources yet.

- [ ] **Step 4: Implement the module**

`ClaudeSpyPackage/Sources/StopFinalityDataset/StopFinalityDataset.swift`:

```swift
import Foundation

// MARK: - StopFinalityCase

/// One labeled stop-finality example: the `last_assistant_message` of a real
/// (or realistic) Claude Code `Stop` hook plus its ground-truth verdict.
public struct StopFinalityCase: Codable, Sendable, Equatable, Identifiable {
    public enum Expected: String, Codable, Sendable {
        case waiting
        case final
    }

    public enum Source: String, Codable, Sendable {
        /// Committed regression case (past field failures + tuned shapes).
        case seed
        /// Harvested from local session transcripts; never committed.
        case mined
    }

    public let id: String
    public let message: String
    public let expected: Expected
    public let source: Source
    public let notes: String?

    public init(
        id: String,
        message: String,
        expected: Expected,
        source: Source,
        notes: String? = nil
    ) {
        self.id = id
        self.message = message
        self.expected = expected
        self.source = source
        self.notes = notes
    }
}

// MARK: - StopFinalityDataset

/// Loads the two dataset halves: committed seeds (bundled resource) and the
/// local, never-committed mined set (spec 2026-07-30 — the repo is heading
/// public and mined messages are verbatim session excerpts).
public enum StopFinalityDataset {
    /// Absolute-path override for the mined dataset location.
    public static let minedPathEnvVar = "STOP_FINALITY_MINED_DATASET"

    public static var minedURL: URL {
        if let override = ProcessInfo.processInfo.environment[minedPathEnvVar] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gallager/eval/stop-finality-mined.json")
    }

    public static func seeds() throws -> [StopFinalityCase] {
        guard let url = Bundle.module.url(forResource: "seed-cases", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "seed-cases.json missing from StopFinalityDataset bundle",
            ])
        }
        return try JSONDecoder().decode([StopFinalityCase].self, from: Data(contentsOf: url))
    }

    /// `nil` when the mined file is absent — callers announce the skip loudly
    /// instead of silently scoring seeds only.
    public static func mined() throws -> [StopFinalityCase]? {
        let url = minedURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([StopFinalityCase].self, from: Data(contentsOf: url))
    }
}
```

- [ ] **Step 5: Create the seed resource by porting the 20 existing cases**

Create `ClaudeSpyPackage/Sources/StopFinalityDataset/Resources/seed-cases.json`. Port every case from `ClaudeSpyPackage/Sources/StopFinalityEval/main.swift` lines 29–133 **verbatim** (message text unchanged — these are tuned regression cases; the Swift `\` line-continuations join with a space, so materialize the joined string). The `name` field maps: leading token becomes `id`, remainder becomes `notes`. Full id/expected inventory (all 20 must be present, `source` is `"seed"` for every row):

| id | expected | notes |
|----|----------|-------|
| F1 | final | full merge summary (real-world failure) |
| F2 | final | blunt done |
| F3 | final | error report + question |
| F4 | final | completed background work |
| F5 | final | user-directed imperatives |
| F6 | final | mentions ongoing external work |
| F7 | final | question ending |
| F8 | final | long summary with offer |
| W1 | waiting | explicit report-back |
| W2 | waiting | background suite started |
| W3 | waiting | monitoring |
| W4 | waiting | waiting on CI |
| W5 | waiting | long status then wait |
| W6 | waiting | nothing to do until done |
| W7 | waiting | dispatch + awaiting report |
| W8 | waiting | dispatch + awaiting verdict |
| W9 | waiting | dispatch + awaiting re-run |
| W10 | waiting | dispatch + awaiting report (parenthetical) |
| W11 | waiting | fix dispatched + awaiting then re-review |
| W12 | waiting | no action, waiting on other task |

Shape (first two rows shown fully; the F1 message below is the exact joined text of the Swift literal):

```json
[
  {
    "id": "F1",
    "message": "Merged and pushed. Summary:\n- Updated local `main` from the remote, then merged it into the feature branch — a clean merge with no conflicts, bringing exactly the one checklist commit.\n- One housekeeping step first: the working tree still carried your uncommitted edit (identical to what the merge was bringing in), which would have blocked the merge. I discarded the local copy and let the merge supply the same content.\n- Build verified clean and the branch is pushed, so the working tree is fully clean and the checklist note (run the e2e preflight, don't skip on assumptions) is active on this branch too.",
    "expected": "final",
    "source": "seed",
    "notes": "full merge summary (real-world failure)"
  },
  {
    "id": "F2",
    "message": "All done. I fixed the bug and all 1189 tests pass.",
    "expected": "final",
    "source": "seed",
    "notes": "blunt done"
  }
]
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter StopFinalityDatasetTests`
Expected: 4 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add ClaudeSpyPackage/Package.swift ClaudeSpyPackage/Sources/StopFinalityDataset ClaudeSpyPackage/Tests/StopFinalityDatasetTests
git commit -m "Add StopFinalityDataset module: schema + committed seed cases

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Instruction-injection seam on `StopFinalityClassifier`

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/StopFinalityClassifier.swift:248-269` (instructions move) and `:230-301` (seam)
- Test: `ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/StopFinalityTests.swift` (append one test)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `StopFinalityClassifier.productionInstructions: String` — public static let, available unconditionally (plain string; Tasks 6 and 9 reference it).
  - `StopFinalityClassifier.classify(message:instructions:) async -> StopFinalityVerdict` — public static, inside `#if canImport(FoundationModels)`, `@available(macOS 26, iOS 26, *)` (Tasks 6's subject calls it).
- Production behavior byte-identical: `liveValue` routes through the seam with `productionInstructions`.

- [ ] **Step 1: Write the failing test**

Append to the `StopFinalityTests` suite in `ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/StopFinalityTests.swift`:

```swift
    // The eval suite (StopFinalityEvaluations) hill-climbs candidate
    // instructions against this exact constant — pin the rubric anchors so a
    // refactor can't silently swap in an empty/placeholder string.
    @Test
    func productionInstructionsCarryTunedRubric() {
        let instructions = StopFinalityClassifier.productionInstructions
        #expect(instructions.contains("FINISHED"))
        #expect(instructions.contains("WAITING"))
        #expect(instructions.contains("Awaiting its report"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StopFinalityTests`
Expected: build failure — `productionInstructions` doesn't exist yet.

- [ ] **Step 3: Implement the seam**

In `StopFinalityClassifier.swift`:

1. In the unguarded `extension StopFinalityClassifier` (the one holding `e2eStillWaitingMarker`, `liveValue`, etc.), add the instructions as a constant. Move the existing rubric comment ("Instructions are eval-tuned against real agent messages…", lines ~237-247) to sit above it, and move the instruction text **verbatim** from the `LanguageModelSession(instructions:)` call:

```swift
    /// The production judge instructions — the single string hill-climbing
    /// tunes (spec docs/superpowers/specs/2026-07-30-stop-finality-
    /// evaluations-design.md). The StopFinalityEvaluations suite compares
    /// candidate variants against this exact text via
    /// `classify(message:instructions:)`; a winning candidate is promoted by
    /// replacing this constant.
    public static let productionInstructions = """
    You judge the final message a coding agent printed when its turn ended, \
    deciding whether the agent FINISHED its turn or is WAITING for background work.
    …(existing text from lines 248-269, unchanged)…
    """
```

2. In the `@available(macOS 26, iOS 26, *)` extension inside `#if canImport(FoundationModels)`, replace `appleIntelligenceVerdict(message:)`'s body with the injectable seam (keep the existing trust-boundary comment block on the seam — it still holds; `maxMessageLength` and its comment stay):

```swift
        /// Eval seam: production classification with injectable instructions.
        /// `liveValue` passes `productionInstructions`; the eval suite passes
        /// candidates. Guided generation, greedy sampling, and tail
        /// truncation stay in lockstep so the eval measures exactly what
        /// ships.
        public static func classify(
            message: String,
            instructions: String
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

        fileprivate static func appleIntelligenceVerdict(
            message: String
        ) async -> StopFinalityVerdict {
            await classify(message: message, instructions: productionInstructions)
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StopFinalityTests`
Expected: all suite tests PASS (existing behavior tests plus the new rubric test).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeCodePluginCore/StopFinalityClassifier.swift ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/StopFinalityTests.swift
git commit -m "Extract productionInstructions + classify(message:instructions:) eval seam

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Repoint `StopFinalityEval` at the dataset; add `--verdicts` mode

**Files:**
- Modify: `ClaudeSpyPackage/Sources/StopFinalityEval/main.swift` (full rewrite)
- Modify: `ClaudeSpyPackage/Package.swift:477-480` (add dataset dependency, refresh comment)

**Interfaces:**
- Consumes: `StopFinalityDataset.seeds()/mined()/minedURL/minedPathEnvVar`, `StopFinalityClassifier.liveValue`.
- Produces: CLI contract used by Task 5's pipeline — `swift run StopFinalityEval --verdicts <in.jsonl> <out.jsonl>` reads `{"id","message"}` JSONL and writes `{"id","onDevice":"waiting"|"final"}` JSONL. Default invocation scores seeds+mined with per-class/per-source tallies; exit 0 all-pass, 2 failures, 1 model unavailable.

- [ ] **Step 1: Update the Package.swift target**

```swift
    // macOS-26 cross-check + labeling helper for the stop-finality judge
    // (spec docs/superpowers/specs/2026-07-30-stop-finality-evaluations-
    // design.md). Scores the SAME dataset as the StopFinalityEvaluations
    // suite against THIS machine's model — run on the daily (macOS 26) Mac
    // before promoting a prompt tuned on the 27-beta model. Run manually on
    // a Mac with Apple Intelligence (`swift run StopFinalityEval`); CI only
    // compiles it.
    .executableTarget(
        name: "StopFinalityEval",
        dependencies: [.claudeCodePluginCore, .stopFinalityDataset]
    ),
```

- [ ] **Step 2: Rewrite main.swift**

Replace the whole file with:

```swift
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
        outputLines.append(String(decoding: data, as: UTF8.self))
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
```

- [ ] **Step 3: Verify the scoring mode runs against the real model**

Run: `swift run StopFinalityEval` in `ClaudeSpyPackage/` (Apple Intelligence is available on the daily Mac; first inference loads the model, allow a few minutes total).
Expected: 20 seed rows print with the summary block; "no mined dataset" NOTE appears. Some FAILs are acceptable at this point (pre-tuning state — record which). Exit code 0 or 2, not 1.

- [ ] **Step 4: Verify --verdicts mode**

```bash
mkdir -p ~/.gallager/eval
printf '%s\n%s\n' \
  '{"id":"t1","message":"All done. Tests pass."}' \
  '{"id":"t2","message":"Kicked off the build; I will report back when it finishes."}' \
  > ~/.gallager/eval/verdicts-smoke-in.jsonl
swift run StopFinalityEval --verdicts ~/.gallager/eval/verdicts-smoke-in.jsonl ~/.gallager/eval/verdicts-smoke-out.jsonl
cat ~/.gallager/eval/verdicts-smoke-out.jsonl
```

Expected: two JSONL rows, `t1 → final`, `t2 → waiting` (if t2 comes back `final`, the tool still worked — it's a model verdict, not a harness bug).

- [ ] **Step 5: Run the package test suite for regressions**

Run: `swift test --filter 'StopFinalityDatasetTests|StopFinalityTests'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Package.swift ClaudeSpyPackage/Sources/StopFinalityEval/main.swift
git commit -m "Repoint StopFinalityEval at the shared dataset; add --verdicts labeling mode

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Transcript mining (`mine` subcommand) + recover the 2026-07-30 failure as seed W13

**Files:**
- Create: `scripts/stop-finality-dataset.py`
- Modify: `ClaudeSpyPackage/Sources/StopFinalityDataset/Resources/seed-cases.json` (append W13)
- Modify: `ClaudeSpyPackage/Tests/StopFinalityDatasetTests/StopFinalityDatasetTests.swift` (seed count 20 → 21, W13 assertions)

**Interfaces:**
- Consumes: `~/.claude/projects/*/*.jsonl` transcript layout (verified 2026-07-30): each line is JSON with a `type` field; conversation turns are `assistant`/`user`; metadata types observed: `last-prompt`, `mode`, `permission-mode`, `attachment`, `ai-title`, `file-history-snapshot`, `file-history-delta`, plus `summary`/`system` in older files. Assistant entries: `isSidechain: Bool`, `timestamp`, `message.content` = list of blocks (`thinking`/`text`/`tool_use`). User entries: `message.content` is a string (real turn) or a list (real turn if it contains a `text` block; tool_result-only lists are machine turns).
- Produces: `~/.gallager/eval/stop-finality-candidates.jsonl`, rows `{"id": "m<sha10>", "message": str, "project": str, "session": str, "timestamp": str}` (Task 5 extends these rows in place).

- [ ] **Step 1: Write the script with the `mine` subcommand**

`scripts/stop-finality-dataset.py` (executable, `chmod +x`):

```python
#!/usr/bin/env python3
"""Stop-finality eval dataset pipeline (spec 2026-07-30).

Subcommands, run in order:
  mine      harvest turn-final assistant messages from ~/.claude/projects
  prelabel  Claude pre-labels candidates via `claude -p`   (added in Task 5)
  review    emit contested rows for human labeling         (added in Task 5)
  finalize  write ~/.gallager/eval/stop-finality-mined.json (added in Task 5)

All working files live under ~/.gallager/eval/ and are NEVER committed —
they contain verbatim excerpts from real sessions.
"""

import argparse
import hashlib
import json
import random
import re
import sys
from pathlib import Path

EVAL_DIR = Path.home() / ".gallager" / "eval"
CANDIDATES = EVAL_DIR / "stop-finality-candidates.jsonl"
PROJECTS = Path.home() / ".claude" / "projects"

# Entry types that are transcript metadata, not conversation turns.
META_TYPES = {
    "last-prompt", "mode", "permission-mode", "attachment", "ai-title",
    "file-history-snapshot", "file-history-delta", "summary", "system",
}

# Enrichment filter: shapes that might be WAITING. Everything matching is
# kept; non-matches are randomly sampled to fill the cap so FINAL coverage
# stays representative.
WAITING_HINTS = re.compile(
    r"await|waiting|wait for|monitor|report back|check back|dispatched"
    r"|kicked off|in the background|once it (completes|finishes)"
    r"|still running|will (update|resume|pick|summarize|verify)"
    r"|nothing (more )?to do until",
    re.IGNORECASE,
)

CAP = 300
MIN_LENGTH = 5


def is_real_user_turn(obj):
    content = (obj.get("message") or {}).get("content")
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        return any(block.get("type") == "text" for block in content
                   if isinstance(block, dict))
    return False


def assistant_text(obj):
    content = (obj.get("message") or {}).get("content")
    if not isinstance(content, list):
        return None
    texts = [block.get("text", "") for block in content
             if isinstance(block, dict) and block.get("type") == "text"]
    joined = "\n\n".join(t for t in texts if t.strip()).strip()
    return joined or None


def mine(args):
    files = sorted(PROJECTS.glob("*/*.jsonl"))
    parse_errors = 0
    seen_hashes = set()
    hint_rows, other_rows = [], []

    for path in files:
        entries = []
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    parse_errors += 1
                    continue
                if obj.get("type") in META_TYPES:
                    continue
                entries.append(obj)

        for index, obj in enumerate(entries):
            if obj.get("type") != "assistant" or obj.get("isSidechain"):
                continue
            text = assistant_text(obj)
            if not text or len(text) < MIN_LENGTH:
                continue
            # Turn-final: next conversation entry is a real user turn, or EOF.
            nxt = entries[index + 1] if index + 1 < len(entries) else None
            if nxt is not None and not (nxt.get("type") == "user"
                                        and is_real_user_turn(nxt)):
                continue
            digest = hashlib.sha256(text.encode()).hexdigest()[:10]
            if digest in seen_hashes:
                continue
            seen_hashes.add(digest)
            row = {
                "id": f"m{digest}",
                "message": text,
                "project": path.parent.name,
                "session": path.stem,
                "timestamp": obj.get("timestamp", ""),
            }
            (hint_rows if WAITING_HINTS.search(text) else other_rows).append(row)

    random.seed(42)
    fill = max(0, CAP - len(hint_rows))
    sampled = random.sample(other_rows, min(fill, len(other_rows)))
    rows = hint_rows + sampled

    EVAL_DIR.mkdir(parents=True, exist_ok=True)
    with open(CANDIDATES, "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    print(f"scanned {len(files)} transcripts "
          f"({parse_errors} unparseable lines skipped)")
    print(f"turn-final messages: {len(hint_rows) + len(other_rows)} unique "
          f"({len(hint_rows)} waiting-shaped, kept all; "
          f"{len(sampled)}/{len(other_rows)} others sampled)")
    print(f"wrote {len(rows)} candidates → {CANDIDATES}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("mine", help="harvest turn-final messages").set_defaults(fn=mine)
    args = parser.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it against the real transcripts**

Run: `python3 scripts/stop-finality-dataset.py mine`
Expected: counts print; `~/.gallager/eval/stop-finality-candidates.jsonl` exists with up to 300 rows. Sanity-check three rows by eye (`head -3 ~/.gallager/eval/stop-finality-candidates.jsonl | python3 -m json.tool` on one line) — messages must be assistant prose, not tool output or user text.

- [ ] **Step 3: Recover the 2026-07-30 failure message**

```bash
python3 - <<'EOF'
import json
from pathlib import Path
hits = []
for line in open(Path.home() / ".gallager/eval/stop-finality-candidates.jsonl"):
    row = json.loads(line)
    if "implementer is still working" in row["message"]:
        hits.append(row)
for row in hits:
    print(row["id"], "|", row["project"], "|", row["message"][:200])
EOF
```

Take the full `message` of the matching row (the one ending "nothing to do until it reports"). **Fallback if no hit** (transcript may have been cleaned up): use the screenshot text verbatim: `That's just Task 1's reviewer going idle after saving its report — already handled. Task 2's implementer is still working; nothing to do until it reports.`

- [ ] **Step 4: Append W13 to the seeds and tighten the tests**

Append to `seed-cases.json`:

```json
  {
    "id": "W13",
    "message": "<recovered full text from Step 3>",
    "expected": "waiting",
    "source": "seed",
    "notes": "2026-07-30 field failure: Session Idle fired while orchestrating subagents"
  }
```

In `StopFinalityDatasetTests.seedsLoadFromBundle`, change `#expect(seeds.count == 20)` to `21` and add:

```swift
        let w13 = try #require(seeds.first { $0.id == "W13" })
        #expect(w13.expected == .waiting)
        #expect(w13.message.contains("still working"))
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter StopFinalityDatasetTests`
Expected: PASS.

- [ ] **Step 6: Reproduce the failure on the macOS 26 model**

Run: `swift run StopFinalityEval`
Expected: W13 prints — most likely `FAIL [seed] W13 expected waiting → got final`, reproducing the bug on-device. If it PASSES here, note that in the commit message (the 27-beta model run in Task 8 becomes the deciding reproduction; the eval is still worth having either way).

- [ ] **Step 7: Commit**

```bash
git add scripts/stop-finality-dataset.py ClaudeSpyPackage/Sources/StopFinalityDataset/Resources/seed-cases.json ClaudeSpyPackage/Tests/StopFinalityDatasetTests/StopFinalityDatasetTests.swift
git commit -m "Add transcript mining pipeline; capture 2026-07-30 field failure as seed W13

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Prelabel / review / finalize subcommands — produce the labeled mined dataset

**Files:**
- Modify: `scripts/stop-finality-dataset.py` (three subcommands)

**Interfaces:**
- Consumes: `stop-finality-candidates.jsonl` (Task 4), `swift run StopFinalityEval --verdicts` (Task 3), the `claude` CLI.
- Produces: `~/.gallager/eval/stop-finality-mined.json` — a JSON **array** of `StopFinalityCase` objects (`source: "mined"`), decodable by `StopFinalityDataset.mined()`. Also intermediates: candidates rows gain `claudeLabel`/`claudeConfidence`; `stop-finality-contested.json` for human review.

- [ ] **Step 1: Add the `prelabel` subcommand**

Append to `scripts/stop-finality-dataset.py` (register in `main()` like `mine`):

```python
VERDICTS = EVAL_DIR / "stop-finality-verdicts.jsonl"
CONTESTED = EVAL_DIR / "stop-finality-contested.json"
MINED = EVAL_DIR / "stop-finality-mined.json"
BATCH = 20
CONFIDENCE_FLOOR = 0.8

PRELABEL_PROMPT = """\
You label coding-agent turn-final messages for a binary classifier eval.
For each message decide: did the agent FINISH its turn ("final") or is it
PAUSING while background work it depends on completes ("waiting")?

"waiting" requires the message to state the agent will continue when
still-running work completes: "I'll report back", "Awaiting its report",
"Waiting on Task 3", "nothing to do until it reports". Summaries of
completed work, error reports, and questions to the user are "final" even
when they mention builds, tests, commands, or background jobs.

Reply with ONLY a JSON array, no prose, no code fences:
[{"id": "...", "label": "waiting" or "final", "confidence": 0.0-1.0}, ...]

Messages:
"""


def load_candidates():
    return [json.loads(line) for line in open(CANDIDATES, encoding="utf-8")]


def save_candidates(rows):
    with open(CANDIDATES, "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def prelabel(args):
    import subprocess
    rows = load_candidates()
    pending = [r for r in rows if "claudeLabel" not in r]
    print(f"{len(pending)} rows to label ({len(rows) - len(pending)} already done)")
    for start in range(0, len(pending), BATCH):
        batch = pending[start:start + BATCH]
        payload = json.dumps(
            [{"id": r["id"], "message": r["message"]} for r in batch],
            ensure_ascii=False,
        )
        proc = subprocess.run(
            ["claude", "-p", PRELABEL_PROMPT + payload],
            capture_output=True, text=True, timeout=600,
        )
        if proc.returncode != 0:
            sys.exit(f"claude -p failed: {proc.stderr[:500]}")
        text = proc.stdout.strip()
        if text.startswith("```"):
            text = text.strip("`").lstrip("json").strip()
        labels = {item["id"]: item for item in json.loads(text)}
        for row in batch:
            got = labels.get(row["id"])
            if got is None or got["label"] not in ("waiting", "final"):
                sys.exit(f"bad label response for {row['id']}: {text[:300]}")
            row["claudeLabel"] = got["label"]
            row["claudeConfidence"] = float(got.get("confidence", 0.5))
        save_candidates(rows)  # checkpoint per batch — rerun-safe
        print(f"labeled {start + len(batch)}/{len(pending)}")
```

- [ ] **Step 2: Add the `review` and `finalize` subcommands**

```python
def review(args):
    rows = load_candidates()
    unlabeled = [r["id"] for r in rows if "claudeLabel" not in r]
    if unlabeled:
        sys.exit(f"run prelabel first — {len(unlabeled)} rows unlabeled")
    if not VERDICTS.exists():
        sys.exit(
            "missing on-device verdicts — run:\n  cd ClaudeSpyPackage && "
            f"swift run StopFinalityEval --verdicts {CANDIDATES} {VERDICTS}"
        )
    verdicts = {json.loads(l)["id"]: json.loads(l)["onDevice"]
                for l in open(VERDICTS, encoding="utf-8") if l.strip()}
    contested = []
    for row in rows:
        on_device = verdicts.get(row["id"])
        if (on_device != row["claudeLabel"]
                or row["claudeConfidence"] < CONFIDENCE_FLOOR):
            contested.append({
                "id": row["id"],
                "message": row["message"],
                "claudeLabel": row["claudeLabel"],
                "claudeConfidence": row["claudeConfidence"],
                "onDevice": on_device,
                "label": None,  # ← human fills "waiting" or "final"
            })
    CONTESTED.write_text(
        json.dumps(contested, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"{len(contested)} contested rows → {CONTESTED}")
    print('fill each "label" field with "waiting" or "final", then run finalize')


def finalize(args):
    rows = load_candidates()
    overrides = {}
    if CONTESTED.exists():
        contested = json.loads(CONTESTED.read_text(encoding="utf-8"))
        missing = [c["id"] for c in contested if c["label"] not in ("waiting", "final")]
        if missing:
            sys.exit(f"contested rows still unlabeled: {missing}")
        overrides = {c["id"]: c["label"] for c in contested}
    dataset = [{
        "id": row["id"],
        "message": row["message"],
        "expected": overrides.get(row["id"], row["claudeLabel"]),
        "source": "mined",
        "notes": f"{row['project']}/{row['session']} {row['timestamp']}",
    } for row in rows]
    MINED.write_text(
        json.dumps(dataset, indent=2, ensure_ascii=False), encoding="utf-8")
    waiting = sum(1 for d in dataset if d["expected"] == "waiting")
    print(f"wrote {len(dataset)} cases ({waiting} waiting, "
          f"{len(dataset) - waiting} final) → {MINED}")
```

Register both in `main()`:

```python
    sub.add_parser("prelabel", help="Claude pre-labels candidates").set_defaults(fn=prelabel)
    sub.add_parser("review", help="emit contested rows").set_defaults(fn=review)
    sub.add_parser("finalize", help="write the mined dataset").set_defaults(fn=finalize)
```

- [ ] **Step 3: Run the pipeline end-to-end on the real candidates**

```bash
python3 scripts/stop-finality-dataset.py prelabel
cd ClaudeSpyPackage && swift run StopFinalityEval --verdicts ~/.gallager/eval/stop-finality-candidates.jsonl ~/.gallager/eval/stop-finality-verdicts.jsonl && cd ..
python3 scripts/stop-finality-dataset.py review
```

Expected: prelabel completes all batches (claude CLI is on PATH); verdicts run prints one line per candidate; review reports a contested count (typically a few dozen).

- [ ] **Step 4: USER GATE — human labels the contested rows**

Stop and hand `~/.gallager/eval/stop-finality-contested.json` to the user: they fill each `"label"` (present the rows conversationally if that's faster). **Do not guess these labels — contested rows are exactly where Claude and the on-device model disagree, and they steer the hill-climb.**

- [ ] **Step 5: Finalize and validate against the Swift loader**

```bash
python3 scripts/stop-finality-dataset.py finalize
cd ClaudeSpyPackage && swift run StopFinalityEval
```

Expected: finalize prints class counts; the eval now scores seeds **and** mined rows and prints all four tallies. Record the printed tallies — this is the daily-Mac (macOS 26 model) baseline used by the Task 9 cross-check.

- [ ] **Step 6: Commit (script only — data stays local)**

```bash
git status   # confirm nothing under ~/.gallager leaked into the repo
git add scripts/stop-finality-dataset.py
git commit -m "Add prelabel/review/finalize labeling pipeline for the mined dataset

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: `StopFinalityEvaluations` test target on the Evaluations framework

**Files:**
- Modify: `ClaudeSpyPackage/Package.swift` (test-target section)
- Create: `ClaudeSpyPackage/Tests/StopFinalityEvaluations/StopFinalityEvaluations.swift`

**Interfaces:**
- Consumes: `StopFinalityClassifier.productionInstructions`, `StopFinalityClassifier.classify(message:instructions:)` (Task 2), `StopFinalityDataset` (Task 1), Evaluations framework (`Evaluation`, `ArrayLoader`, `SampleProtocol`, `ModelSubject`, `EvaluatorProtocol`, `Metric`, `MetricsAggregator`, `EvaluationResult.run(info:)/aggregateValue/groupedSummary/saveJSON`).
- Produces: the two evaluations Task 8 runs and the gate constants Task 8 pins (`StopFinalityEvaluationSuite.minedFinalRecallGate` / `minedWaitingRecallGate`), result JSONs under `~/.gallager/eval/results/`.

- [ ] **Step 1: Add the test target to Package.swift**

In the test-target section:

```swift
    // Hill-climbing eval for the stop-finality judge on Apple's Evaluations
    // framework (WWDC26 session 335; spec docs/superpowers/specs/
    // 2026-07-30-stop-finality-evaluations-design.md). Compiles to an empty
    // suite on pre-macOS-27 SDKs and CI (#if canImport(Evaluations)); RUNS
    // only on a macOS 27 beta Mac with Apple Intelligence enabled.
    .testTarget(
        name: "StopFinalityEvaluations",
        dependencies: [
            .claudeCodePluginCore,
            .stopFinalityDataset,
        ]
    ),
```

- [ ] **Step 2: Write the evaluation suite**

`ClaudeSpyPackage/Tests/StopFinalityEvaluations/StopFinalityEvaluations.swift`.

> **Beta-SDK note for the implementer:** this file is written against the macOS 27 beta Evaluations API as documented at `developer.apple.com/documentation/evaluations` (fetchable via sosumi). It cannot compile on this machine (macOS 26 SDK — `canImport(Evaluations)` is false, so the file is empty here and CI-safe). If spellings drifted in a newer beta, fix them **in this file only, on the beta Mac, against its local SDK** — the shapes to preserve: one exact-match evaluator emitting per-class/per-source metrics, and baseline + candidate evaluations over the identical dataset. If an `EvaluationTrait` initializer is available (`@Test(.evaluation(...))` form), prefer it — it feeds Xcode's evaluation report and comparison view — and read the result via `EvaluationContext.current.result`; the `run(info:)` form below is the documented fallback and produces the same numbers.

```swift
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
        static let instructions = StopFinalityClassifier.productionInstructions
    }

    // MARK: - Suite

    @available(macOS 27, *)
    @Suite("Stop-finality hill-climb", .serialized)
    struct StopFinalityEvaluationSuite {
        /// Mined-set gates, pinned from the FIRST baseline run on the beta
        /// Mac (Task 8 records the numbers here; nil skips the gate so the
        /// suite is runnable before pinning). Seeds always gate at 100%.
        static let minedFinalRecallGate: Double? = nil
        static let minedWaitingRecallGate: Double? = nil

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
            #expect(seed == 1.0, "seed regression — every committed case must pass")
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

        @Test func baseline() async throws {
            try Self.requireModel()
            let evaluation = StopFinalityEvaluation(
                name: "StopFinalityBaseline",
                instructions: StopFinalityClassifier.productionInstructions,
                cases: try Self.loadCases()
            )
            let result = try await evaluation.run(info: ["variant": "baseline"])
            print(result.groupedSummary)
            try Self.saveResult(result, label: "baseline")
            Self.assertGates(result)
        }

        @Test func candidate() async throws {
            try Self.requireModel()
            let evaluation = StopFinalityEvaluation(
                name: "StopFinalityCandidate",
                instructions: CandidatePrompt.instructions,
                cases: try Self.loadCases()
            )
            let result = try await evaluation.run(info: ["variant": "candidate"])
            print(result.groupedSummary)
            try Self.saveResult(result, label: "candidate")
            Self.assertGates(result)
        }
    }
#endif
```

- [ ] **Step 3: Verify it compiles (empty) on this machine and CI stays green**

Run: `swift build --build-tests` in `ClaudeSpyPackage/`
Expected: builds clean — on the macOS 26 SDK the whole file is compiled out.

Run: `swift test --filter StopFinalityEvaluations`
Expected: zero tests matched, exit 0.

- [ ] **Step 4: Run the neighboring suites for regressions**

Run: `swift test --filter 'StopFinalityDatasetTests|StopFinalityTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Package.swift ClaudeSpyPackage/Tests/StopFinalityEvaluations
git commit -m "Add StopFinalityEvaluations suite on Apple's Evaluations framework (macOS 27 beta)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Workflow documentation

**Files:**
- Create: `docs/stop-finality-eval.md`
- Modify: `CLAUDE.md` (Reference Docs list)

**Interfaces:** none — documentation of Tasks 1–6 outputs and the Task 8–9 runbook.

- [ ] **Step 1: Write `docs/stop-finality-eval.md`**

Content (write it fully, structured exactly like this):

```markdown
# Stop-Finality Eval (hill-climbing the false-stop judge)

Spec: `docs/superpowers/specs/2026-07-30-stop-finality-evaluations-design.md`.
Improves `StopFinalityClassifier.productionInstructions` (issue #644) with the
methodology from WWDC26 session 335: baseline vs candidate prompt over one
dataset, one variable per round, per-class gates.

## Pieces

- `StopFinalityDataset` (SPM target) — schema + committed seeds
  (`Resources/seed-cases.json`, past field failures; the regression suite).
  Mined cases: `~/.gallager/eval/stop-finality-mined.json` (env override
  `STOP_FINALITY_MINED_DATASET`). NEVER commit mined data — verbatim
  session excerpts.
- `scripts/stop-finality-dataset.py` — `mine` → `prelabel` (claude CLI) →
  `review` (label the contested file by hand) → `finalize`.
  On-device verdicts for `review` come from
  `swift run StopFinalityEval --verdicts <candidates> <out>`.
- `StopFinalityEval` executable — macOS 26 cross-check: scores the same
  dataset on this machine's model. Run before every prompt promotion.
- `StopFinalityEvaluations` test target — the real eval (Apple Evaluations
  framework). Compiles everywhere; RUNS only on a macOS 27 beta Mac with
  Apple Intelligence (`swift test --filter StopFinalityEvaluations`, or via
  Xcode 27 for the evaluation report / comparison view).

## Hill-climb protocol (one round)

1. Beta Mac: edit ONLY `CandidatePrompt.instructions` in
   `Tests/StopFinalityEvaluations/StopFinalityEvaluations.swift`.
2. `swift test --filter StopFinalityEvaluations` — compare candidate vs
   baseline (`~/.gallager/eval/results/*.json`, or Xcode's comparison view).
3. Keep or revert; one change per round. Failed rounds are data — note them.
4. Promotion: copy the winning text into
   `StopFinalityClassifier.productionInstructions`, reset CandidatePrompt to
   `= productionInstructions`, re-run the suite (both tests green, seeds
   100%, mined ≥ gates), then on the daily Mac run
   `swift run StopFinalityEval` (macOS 26 model cross-check) before pushing.
5. Ratchet: if the round improved mined recalls, raise the pinned gates in
   `StopFinalityEvaluationSuite` to the new values.

## Growing the dataset

New field failure → find the message (`mine` + grep the candidates file),
add it to `seed-cases.json` with the next W/F id + a dated note, bump the
count in `StopFinalityDatasetTests`. Re-run `mine`/`prelabel`/`review`/
`finalize` occasionally to refresh the mined set; sync the two
`~/.gallager/eval` files to the beta Mac (scp) when they change.
```

- [ ] **Step 2: Add the CLAUDE.md reference line**

In the CLAUDE.md "Reference Docs" list, after the E2E-testing bullet, add:

```markdown
- **Stop-finality eval (#644):** `docs/stop-finality-eval.md` - Hill-climbing eval for the false-stop judge on Apple's Evaluations framework (macOS 27 beta Mac) + transcript-mining/labeling pipeline (`scripts/stop-finality-dataset.py`) + macOS 26 cross-check (`swift run StopFinalityEval`). Mined dataset lives in `~/.gallager/eval/`, never committed.
```

- [ ] **Step 3: Commit**

```bash
git add docs/stop-finality-eval.md CLAUDE.md
git commit -m "Document the stop-finality eval workflow

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Beta-Mac bring-up, baseline run, gate pinning — **REQUIRES THE SECOND MAC (macOS 27 beta)**

**Files:**
- Modify: `ClaudeSpyPackage/Tests/StopFinalityEvaluations/StopFinalityEvaluations.swift` (pin gates; fix any beta-SDK API drift — this file only)

**Interfaces:** consumes everything above; produces pinned `minedFinalRecallGate`/`minedWaitingRecallGate` values and recorded baseline numbers (commit message + `~/.gallager/eval/results/baseline.json`).

- [ ] **Step 1: Prepare the beta Mac**

Checklist: macOS 27 beta + Xcode 27 beta installed; Apple Intelligence enabled in System Settings and model downloaded; repo cloned at branch `stop-finality-evaluations`; copy the dataset over:

```bash
scp ~/.gallager/eval/stop-finality-mined.json <beta-mac>:.gallager/eval/
```

- [ ] **Step 2: Build; reconcile beta-SDK drift if any**

On the beta Mac: `swift build --build-tests` in `ClaudeSpyPackage/`.
If the Evaluations API spellings drifted from the file as written, fix `StopFinalityEvaluations.swift` only (see the beta-SDK note in Task 6) — consult the local SDK headers/docs. If `EvaluationTrait` offers a `@Test(.evaluation(...))` form, adopt it here for the Xcode report and read results via `EvaluationContext.current.result`.

- [ ] **Step 3: Run the baseline**

On the beta Mac: `swift test --filter StopFinalityEvaluations` (or run the suite in Xcode 27 for the evaluation report UI).
Expected: both tests execute (baseline == candidate at this point). **The seed gate very likely FAILS on W13 — that is the reproduced bug and the point of the exercise.** Record from `groupedSummary` / `results/baseline.json`: correct, final-recall, waiting-recall, seed-correct, mined-final-recall, mined-waiting-recall.

- [ ] **Step 4: Pin the mined gates**

Set the two constants in `StopFinalityEvaluationSuite` to the exact baseline values (greedy sampling is deterministic per model version):

```swift
        static let minedFinalRecallGate: Double? = <baseline mined-final-recall>
        static let minedWaitingRecallGate: Double? = <baseline mined-waiting-recall>
```

- [ ] **Step 5: Re-run to confirm gates hold**

`swift test --filter StopFinalityEvaluations`
Expected: mined gates pass at exactly the pinned values; seed gate still red on W13 (carried into Task 9).

- [ ] **Step 6: Commit (from the beta Mac, or copy the diff back and commit here)**

```bash
git add ClaudeSpyPackage/Tests/StopFinalityEvaluations/StopFinalityEvaluations.swift
git commit -m "Pin mined-set gates from the macOS 27 baseline run

Baseline (macOS 27 beta model, greedy): <paste the six recorded numbers>

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 9: Hill-climb round 1 — fix W13, promote, cross-check — **REQUIRES THE SECOND MAC + daily Mac**

**Files:**
- Modify: `ClaudeSpyPackage/Tests/StopFinalityEvaluations/StopFinalityEvaluations.swift` (candidate text per round)
- Modify: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/StopFinalityClassifier.swift` (promotion)

**Interfaces:** consumes the Task 8 baseline; produces the new `productionInstructions`.

- [ ] **Step 1: First candidate — add few-shot examples (the WWDC session's highest-leverage move)**

On the beta Mac, set `CandidatePrompt.instructions` to the production text **plus** an examples block appended after the "Background work can stay registered…" paragraph. Use the failure's *shape*, not W13 verbatim — quoting the eval case verbatim overfits (session 335's warning):

```
Examples:
- "Task B reviewer dispatched. Awaiting the verdict." → WAITING
- "That's just task A's helper finishing — already handled. Task B's \
implementer is still working; nothing to do until it reports." → WAITING \
(work the agent depends on is still running, even though this event needed \
no action)
- "Done — pushed as 70c05ccf. To try it locally, run the install script." \
→ FINISHED
- "The build failed with 3 errors. How would you like to proceed?" → FINISHED
```

- [ ] **Step 2: Run and compare**

`swift test --filter StopFinalityEvaluations`
Compare candidate vs baseline across all six numbers (result JSONs or Xcode comparison view). Success for the round: candidate seed-correct == 1.0 (W13 now WAITING) **and** both mined recalls ≥ the pinned gates.

- [ ] **Step 3: Iterate if needed — one variable per round**

If W13 still fails or a mined recall regressed, revert or refine **one** thing per run. Ordered move list (from the session + prior tuning history): (a) reword the examples; (b) sharpen the WAITING definition with "another task/subagent still running counts as background work even when the agent says the current event needed no action"; (c) sharpen the FINISHED default clause. Keep notes on failed rounds in the eventual commit message — failed experiments are data.

- [ ] **Step 4: Promote the winner**

Copy the winning candidate text into `StopFinalityClassifier.productionInstructions` (update its eval-tuned rubric comment: add a third bullet dated 2026-07-30 describing the orchestrator-idle failure and the examples block). Reset `CandidatePrompt.instructions = StopFinalityClassifier.productionInstructions`. Re-run: `swift test --filter StopFinalityEvaluations` — both tests green.

- [ ] **Step 5: Daily-Mac cross-check (macOS 26 model) — REQUIRED before pushing**

Pull the branch on the daily Mac and run: `swift run StopFinalityEval`
Expected: all 21 seeds PASS (W13 included) and the mined tallies are at or above the Task 5 Step 5 recorded numbers. If the 26 model regresses, return to Step 3 — the prompt must win on **both** model versions.

Also run: `swift test --filter StopFinalityTests` (production-path regressions).

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeCodePluginCore/StopFinalityClassifier.swift ClaudeSpyPackage/Tests/StopFinalityEvaluations/StopFinalityEvaluations.swift
git commit -m "Tune stop-finality prompt via Evaluations hill-climb: fix orchestrator false idle

macOS 27 baseline → candidate: <paste before/after numbers>
macOS 26 cross-check: <paste StopFinalityEval tallies>

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review (completed)

- **Spec coverage:** dataset module + seeds (Task 1), seam (Task 2), macOS 26 cross-check + verdicts helper (Task 3), mining (Task 4), prelabel/review/finalize + user gate (Task 5), Evaluations suite with per-class metrics and baseline/candidate split (Task 6), docs (Task 7), beta bring-up + gate pinning after first baseline (Task 8), first hill-climb + promotion + cross-check = definition of done (Task 9). Loud mined-file-absent behavior: Task 3 Step 2 and Task 6's `loadCases`. Loud parse-skip counts: Task 4 `mine`.
- **Placeholder scan:** the `<recovered full text>` (Task 4) and `<baseline numbers>` (Tasks 8–9) are run-time measurements with explicit recovery/recording steps and fallbacks — not authoring placeholders.
- **Type consistency:** `StopFinalityCase` fields, `StopFinalityDataset.seeds()/mined()/minedURL/minedPathEnvVar`, `classify(message:instructions:)`, `productionInstructions`, metric names, and the `--verdicts` JSONL contract are used with identical spellings across Tasks 1–9.
