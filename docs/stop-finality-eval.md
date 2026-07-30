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
   Cold-start note: the executable rides the production 10 s fail-open deadline, so the first inference after a model load can time out and report `final`; if early rows look wrong, re-run once the model is warm before trusting the tallies.
5. Ratchet: if the round improved mined recalls, raise the pinned gates in
   `StopFinalityEvalRunner` to the new values.

## Recorded baselines (daily-Mac cross-check reference)

- 2026-07-30, macOS 26.5 model, dataset = 21 seeds + 569 mined (56 contested
  rows human-labeled): overall 542/590, final-recall 416/437,
  waiting-recall 126/153, seed 20/21 (sole failure: W13), mined 522/569.
  Promotions must keep the daily-Mac tallies at or above this line.

## Growing the dataset

New field failure → find the message (`mine` + grep the candidates file),
add it to `seed-cases.json` with the next W/F id + a dated note, bump the
count in `StopFinalityDatasetTests`. Re-run `mine`/`prelabel`/`review`/
`finalize` occasionally to refresh the mined set; sync ~/.gallager/eval/stop-finality-mined.json to the beta Mac (scp) when they change.
