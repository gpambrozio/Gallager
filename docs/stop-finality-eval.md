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
