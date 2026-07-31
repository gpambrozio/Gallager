# Stop-Finality Eval (hill-climbing the false-stop judge)

Spec: `docs/superpowers/specs/2026-07-30-stop-finality-evaluations-design.md`.
Improves the stop-finality rubric (issue #644) with the methodology from
WWDC26 session 335: baseline vs candidate prompt over one dataset, one
variable per round, per-class gates.

**The rubric is version-branched** (2026-07-30 finding): the 26- and
27-generation on-device models respond to the same text in opposite
directions — the round-6 winner is a Pareto improvement on the 27 model and
collapses the 26 model's waiting class (126/153 → 27/153). Production picks
`productionInstructions26`/`27` + `StopFinalityJudgment`/`27` (guide) at
runtime; **each generation's rubric is validated only by its own eval** —
never promote to one from the other's numbers. The beta-Mac suite gates the
27 side; the daily-Mac executable gates the 26 side.

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
4. Promotion: copy the winning text into the matching per-generation
   constant (`productionInstructions27` today; guide changes go to the
   matching `StopFinalityJudgment*`), reset CandidatePrompt to
   `= productionInstructions`, re-run the suite (both tests green, seeds
   100%, mined ≥ gates), then on the daily Mac run
   `swift run StopFinalityEval` — the other generation's tallies must stay
   at or above its recorded line before pushing.
   Cold-start note: the executable rides the production 10 s fail-open deadline, so the first inference after a model load can time out and report `final`; if early rows look wrong, re-run once the model is warm before trusting the tallies.
5. Ratchet: if the round improved mined recalls, raise the pinned gates in
   `StopFinalityEvalRunner` to the new values.

## Recorded baselines (per-generation cross-check reference)

- **macOS 26.5 model** (2026-07-30, 21 seeds + 569 mined, 56 contested rows
  human-labeled, rubric = `productionInstructions26`): overall 542/590,
  final-recall 416/437, waiting-recall 126/153, seed 20/21 (sole failure:
  W13), mined 522/569. Promotions touching the 26 side must keep these
  tallies at or above this line. Known open: W13 misses on this generation.
- **macOS 27.0 model** (2026-07-30, 26A5388g, same dataset, rubric =
  `productionInstructions27` after the round-6 promotion): correct 0.9271,
  final-recall 0.9611, waiting-recall 0.8301, seeds 21/21 (W13 fixed),
  mined-final 412/429, mined-waiting 114/140 — the suite's pinned gates.
- History: the pre-tuning 27 baseline was correct 0.9119 / final 0.9497 /
  waiting 0.8039 / seeds 19/21 (W2+W13). Round-by-round numbers live in the
  `CandidatePrompt` doc comment.

## Growing the dataset

New field failure → find the message (`mine` + grep the candidates file),
add it to `seed-cases.json` with the next W/F id + a dated note, bump the
count in `StopFinalityDatasetTests`. Re-run `mine`/`prelabel`/`review`/
`finalize` occasionally to refresh the mined set; sync ~/.gallager/eval/stop-finality-mined.json to the beta Mac (scp) when they change.
