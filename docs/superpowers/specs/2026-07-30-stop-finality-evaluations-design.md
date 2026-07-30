# Stop-Finality Classifier Evaluation (Apple Evaluations Framework)

**Date:** 2026-07-30
**Status:** Approved design
**Related:** issue #644 (stop-finality classifier), WWDC26 session 335 ("Improve your prompts by hill-climbing with Evaluations"), session 298 ("Meet the Evaluations framework")

## Problem

`StopFinalityClassifier` (Apple Intelligence on-device model, `ClaudeCodePluginCore/StopFinalityClassifier.swift`) judges whether a Claude Code `Stop` hook's `last_assistant_message` is a real finish (FINAL) or a pause while background work runs (WAITING). It still produces false FINAL verdicts on messages that clearly say the agent is waiting — latest field failure (2026-07-30): an orchestrator message ending "Task 2's implementer is still working; nothing to do until it reports" fired a premature "Session Idle" notification.

The prompt has been tuned twice already, each round driven by manual screenshot archaeology and the hand-rolled `StopFinalityEval` executable (20 hardcoded cases, overall pass count only). The existing case W12 is nearly identical to the new failure, so either the on-device model version drifted or the real message's extra content falls outside the tuned shapes — the current eval can't tell us which, and can't compare prompt variants.

## Goal

A repeatable evaluation on Apple's Evaluations framework that:

1. Reproduces real failures from a dataset grown out of real session transcripts.
2. Compares a baseline prompt against a candidate prompt in one run (hill-climbing, one variable at a time).
3. Gates promotion of a new prompt on per-class metrics, not vibes.
4. Ends its first iteration with the 2026-07-30 failure classified WAITING with zero regressions.

## Non-goals / deferred

- **In-app capture log** of live classifications (opt-in JSONL) — deferred; revisit if transcript mining under-covers.
- **Synthetic sample generation** (`SampleGenerator`) — deferred.
- Judge-alignment machinery (Cohen's kappa) — not needed: labels are binary ground truth, the evaluator is exact match, no model-as-judge.

## Constraints

- The Evaluations framework requires **macOS 27.0+ beta / Xcode 27 beta**. Evals run on a **second Apple-silicon Mac** on the beta; this (daily) Mac stays on macOS 26.x. Apple Intelligence does not run in VMs, so a VM can only compile-check the target.
- The package must keep compiling on macOS 26 hosts and CI (no Apple Intelligence there at all).
- Mined dataset content is verbatim excerpts from the user's real sessions and must **never be committed** (repo is heading public).

## Architecture

- New test target **`StopFinalityEvaluations`** in `ClaudeSpyPackage`, depending on `ClaudeCodePluginCore`. All framework code guarded by `#if canImport(Evaluations)` + `@available(macOS 27, *)`; on older SDKs the target compiles to an empty/skipped suite.
- Run via Xcode 27 on the beta Mac to get the evaluation report, per-sample assistant view, and baseline-vs-candidate comparison view. `#expect` gates come from Swift Testing integration (`EvaluationTrait`).
- **Production seam (only production-code change):** extract the instruction text into `StopFinalityClassifier.productionInstructions` and add a package-visible `classify(message:instructions:)` path. `liveValue` calls it with `productionInstructions` — behavior unchanged; the eval calls it with variants. The seam preserves the production configuration (guided `StopFinalityJudgment` generation, greedy sampling, 4k-char tail truncation) so the eval measures exactly what ships.

## Dataset

One JSON schema for all samples:

```json
{ "id": "W12", "message": "…", "expected": "waiting" | "final", "source": "seed" | "mined", "notes": "optional provenance" }
```

- **Seeds (committed):** the existing 20 cases move out of `StopFinalityEval/main.swift` into a bundled JSON resource, plus the 2026-07-30 failure verbatim (full text recovered from the transcript by the mining script). Seeds encode past field failures — they are the regression suite.
- **Mined (never committed):** stored at `~/.gallager/eval/stop-finality-mined.json` (overridable via `STOP_FINALITY_MINED_DATASET`), synced manually to the beta Mac; the eval reads seeds from the bundle and mined data from that path, skipping the mined portion with a loud notice when the file is absent.

## Mining + labeling pipeline

Runs entirely on the daily Mac (no beta required). A Python script under `scripts/`:

1. Walks `~/.claude/projects/*/*.jsonl`, extracts **turn-final assistant text messages** (next non-meta entry is a user turn or EOF), excludes sidechains, dedupes by content hash.
2. Keyword-enriches WAITING-shaped candidates (await/waiting/monitor/report back/dispatched/…) while keeping a random sample of the rest for FINAL coverage; caps the set at a few hundred.
3. Pre-labels every candidate with `claude -p` (label + confidence), and records the current on-device classifier's verdict (macOS 26 model works on this Mac).
4. Emits a review file of **contested rows only** — Claude-vs-on-device disagreements and low-confidence labels — for human labeling; merges reviewed labels into the mined dataset file.

## The evaluation

- **Sample:** custom `SampleProtocol` type (message + expected bool). **Subject:** `subject(from:)` calls the classifier seam. **Evaluator:** exact match emitting three metrics — `correct` (all samples), `final-recall` (`.ignore()` on WAITING samples), `waiting-recall` (`.ignore()` on FINAL samples); `computeMean` of each yields accuracy and per-class recall. Aggregation also groups seed vs mined.
- **Two evaluations, control vs experimental:** `Baseline` (uses `productionInstructions`) and `Candidate` (the variant under trial, a string in the eval target). Hill-climb loop: edit only the candidate → run suite → Xcode comparison view → promote the winner into `productionInstructions`, which becomes the next baseline.
- **Expectation gates:** seeds must score 100% on both classes (greedy sampling is deterministic per model version). Mined-set thresholds are pinned **after the first baseline run** and recorded in the eval source; costs are asymmetric (false WAITING pins a session on "Working" — worse than a premature idle), so `final-recall` gates at least as strictly as `waiting-recall`.

## Model-version skew

The beta Mac evaluates the macOS 27 model; production runs 26.x. Mitigation: the existing `StopFinalityEval` executable stays, repointed at the same JSON dataset (seeds + mined path), as the macOS 26 cross-check. **Run it on the daily Mac before promoting any prompt.**

## Error handling

- Model unavailable on the eval machine → the suite fails loudly (as the executable does today), never silently passes.
- The eval exercises the production deadline/fail-open path only implicitly; unit tests for that behavior already exist and are unchanged.
- Mining script: unparseable transcript lines are skipped with a count reported, never silently dropped wholesale.

## Testing

- Dataset schema decode + seed-resource loading get unit tests that compile and run everywhere (no framework/model needed).
- The evaluation suite itself is the test on the beta Mac.
- Mining script correctness is validated by its review artifacts (counts, spot checks) rather than a test harness.

## Definition of done (first iteration)

1. Suite runs on the beta Mac; baseline numbers recorded; mined-set gates pinned.
2. A candidate prompt classifies the 2026-07-30 failure WAITING, keeps seeds at 100%, and is at-or-above baseline on the mined set for both classes (few-shot examples in the instructions are the first thing to try, per the WWDC session).
3. The winning prompt is promoted to `productionInstructions` and cross-checked with the macOS 26 executable on the daily Mac.
