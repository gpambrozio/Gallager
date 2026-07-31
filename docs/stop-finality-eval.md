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
rounds. A full 595-case run is ~7 min; the seed screen is ~12 s.

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

What the 2026-07-30 26-side climb learned about the harness itself:

- **The seed screen is the cheap gate and it is honest.** W13 sits right on
  this model's decision boundary, so nearly any FINISHED-leaning text flips
  it — 8 s of screening killed a dozen candidates that would each have cost
  a 6-minute run.
- **A frontier-weighted subset CANNOT certify final-recall.** A 171-case
  screen set (every case any run had missed + 120 strided passes) rated
  i-K4 at +0 finals; the full run showed −4, because the finals that flip
  are stable-looking ones outside the subset. Use a subset to rank
  waiting-side gains or catch a collapse, never to clear a promotion.
- **Placement is a variable, not prose.** The same sentence scored 21/21 or
  20/21 depending only on which paragraph it landed in. Sweep positions
  before concluding an idea does not work.
- **`--concurrency 4` is bit-identical to serial** (0/192 verdicts differed)
  but only ~1.25× faster — the model daemon serializes anyway. Not worth
  the determinism risk as a default; the flag stays opt-in.

Cold-start note: `--verdicts` mode rides the production 10 s fail-open
deadline, so the first inference after a model load can time out and report
`final`. Scoring runs use the eval seam directly (no deadline) and are
immune, but a first-run outlier is still worth a warm re-run.

## Recorded baselines (per-generation cross-check reference)

- **macOS 26.5 model** (2026-07-31, 26 seeds + 569 mined, rubric =
  `productionInstructions26` after the 26-side round-4 promotion): overall
  568/595, final-recall 416/437, waiting-recall 152/158, seed 26/26, mined
  542/569 — instructions fingerprint `74dc10fa`, guide `1eafda2e`.
  Promotions touching the 26 side must keep these tallies at or above this
  line.
  Round history: pre-climb 542/590 (final 416, waiting 126, seed 20/21 —
  sole failure W13); round 1 549/590 (420/129, W13 fixed, Pareto); round 2
  560/590 (418/142) — non-Pareto by 2 finals, taken deliberately for +13
  net waiting recall; round 3 561/590 (419/142, Pareto, guide-side);
  round 4 (2026-07-31, after five fresh orchestrator false-stops from the
  field became seeds W14–W18, dataset now 595) 568/595 (416/152, seed
  26/26) — non-Pareto by 3 finals, taken for +10 waiting fixes with ZERO
  waiting-side regressions. The three lost finals are two user-handbacks
  ("Standing by for your direction", "waiting on your call about the doc
  updates") and one release-notes document — the same families the round-3
  carve-out attempts showed cost 3-7 finals to protect from the
  instructions side (best full runs 562/415/147 and 562/414/148). Above
  this point the two recalls trade close to 1:1 on this model; a further
  gain likely needs more labeled data in the disputed shapes (handbacks
  phrased with waiting verbs, changelog/document dumps), not more rubric
  text.
  Round-4 harness lessons: a sentence appended AFTER the bare-dispatch
  sentence silently flipped four mined bare dispatches ("Task 5 reviewer
  dispatched.") to final — invisible to the seed screen, which has no bare
  form — while the same sentence beside its thematic neighbor (the
  dispatch-and-await sentence) cost nothing. A "still running does state
  waiting" clarifier on the closing default paragraph scored 26/26 on
  seeds but swallowed user-handback finals on the full run. Quoting the
  handbacks in the guide's user clause collapsed the waiting side
  (W13/W14/W18 plus two bare dispatches in one screen) — the guide is
  inert for widening WAITING but destructive for widening FINISHED. A
  scratchpad `STOP_FINALITY_MINED_DATASET` file holding just the previous
  candidate's full-run flips makes a cheap second screen (seeds + known
  frontier) before paying for a full run.
- **macOS 27.0 model** (2026-07-30, 26A5388g, 21 seeds + 569 mined, rubric =
  `productionInstructions27` after the round-6 promotion): correct 0.9271,
  final-recall 0.9611, waiting-recall 0.8301, seeds 21/21 (W13 fixed),
  mined-final 412/429, mined-waiting 114/140 — the suite's pinned gates.
  NEEDS A BETA-MAC RE-RUN: seeds W14–W18 (2026-07-31) postdate this
  baseline, and the suite gates on seeds == 100%. The 27 round-6 examples
  cover the idle-reviewer shape, so they plausibly pass, but that is
  unverified — re-run `swift test --filter StopFinalityEvaluations` on the
  beta Mac before trusting the 27 gates.
- History: the pre-tuning 27 baseline was correct 0.9119 / final 0.9497 /
  waiting 0.8039 / seeds 19/21 (W2+W13). Round-by-round numbers live in the
  `CandidatePrompt` doc comment.

## Growing the dataset

New field failure → find the message (`mine` + grep the candidates file),
add it to `seed-cases.json` with the next W/F id + a dated note, bump the
count in `StopFinalityDatasetTests`. Re-run `mine`/`prelabel`/`review`/
`finalize` occasionally to refresh the mined set; sync ~/.gallager/eval/stop-finality-mined.json to the beta Mac (scp) when they change.
