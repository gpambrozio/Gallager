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
- `StopFinalityEval` executable — the macOS 26 harness: scores the same
  dataset on this machine's model, and A/Bs candidates against it
  (`--instructions <file>`, `--guide <file>`, `--seeds-only`, `--sample N`,
  `--out <file>`, `--dump-prompt [--generation 26|27]`, `--concurrency N`).
  Baseline and candidate runs share one code path — the
  `classify(message:instructions:guide:)` seam — and every run prints a
  SHA fingerprint of the two prompt strings, so a tally that moved without
  a fingerprint moving is a bug, not a model. A `--guide` candidate builds
  its schema at runtime; `candidateSchemaMatchesShippedSchema` pins that
  schema as identical to the shipped `@Generable` one.
- `StopFinalityEvaluations` test target — the real eval (Apple Evaluations
  framework). Compiles everywhere; RUNS only on a macOS 27 beta Mac with
  Apple Intelligence (`swift test --filter StopFinalityEvaluations`, or via
  Xcode 27 for the evaluation report / comparison view).

## Hill-climb protocol (one round)

Which harness depends on which generation you are tuning. **A round only
ever changes one generation's constants** — the two rubrics and the two
`@Guide` texts are independent literals, so a 26 edit cannot move the 27
side and needs no beta-Mac re-run (and vice versa). Prove it when in doubt:
`--dump-prompt --generation 27` before and after must be identical.

### 27 generation (beta Mac)

1. Edit ONLY `CandidatePrompt.instructions` in
   `Tests/StopFinalityEvaluations/StopFinalityEvaluations.swift`.
2. `swift test --filter StopFinalityEvaluations` — compare candidate vs
   baseline (`~/.gallager/eval/results/*.json`, or Xcode's comparison view).
3. Promotion: copy the winning text into `productionInstructions27` (guide
   changes go to `productionGuide27`), reset CandidatePrompt to
   `= productionInstructions`, re-run the suite (both tests green, seeds
   100%, mined ≥ gates).
4. Ratchet: if the round improved mined recalls, raise the pinned gates in
   `StopFinalityEvalRunner` to the new values.

### 26 generation (daily Mac)

`StopFinalityEval` is the A/B driver — no editing production between
rounds. A full 590-case run is ~6 min; the seed screen is ~8 s.

1. `swift run StopFinalityEval --dump-prompt --generation 26` → save the
   instructions and guide to files; edit ONE of them.
2. Screen: `--seeds-only --instructions cand.txt` (or `--guide cand.txt`).
   A candidate that breaks a committed seed is dead — stop there.
3. Full run: same flags without `--seeds-only`, plus
   `--out runs/<round>.json`. Compare against the recorded 26 baseline
   above; `--sample N` is the middle screen when a round looks expensive.
4. Promotion: paste the winning text into `productionInstructions26` /
   `productionGuide26`, rebuild, and confirm
   `--dump-prompt --generation 26` prints the SAME fingerprint the winning
   run reported. Fingerprints make this exact — no confirmation re-run
   needed, since greedy sampling is deterministic and identical text is
   identical behavior.

Keep or revert; one change per round. Failed rounds are data — note them
in the constant's doc comment.

Cold-start note: `--verdicts` mode rides the production 10 s fail-open
deadline, so the first inference after a model load can time out and report
`final`. Scoring runs use the eval seam directly (no deadline) and are
immune, but a first-run outlier is still worth a warm re-run.

## Recorded baselines (per-generation cross-check reference)

- **macOS 26.5 model** (2026-07-30, 21 seeds + 569 mined, 56 contested rows
  human-labeled, rubric = `productionInstructions26` after the 26-side
  round-1 promotion): overall 549/590, final-recall 420/437, waiting-recall
  129/153, seed 21/21, mined 528/569 — instructions fingerprint `5179bc1d`,
  guide `b96be60a`. Promotions touching the 26 side must keep these tallies
  at or above this line.
  The pre-climb line was overall 542/590, final 416/437, waiting 126/153,
  seed 20/21 (sole failure: W13, now fixed).
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
