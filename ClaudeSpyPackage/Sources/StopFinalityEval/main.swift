import ClaudeCodePluginCore
import Foundation

// Eval harness for the stop-finality judge (issue #644). Drives the REAL
// production classifier — `StopFinalityClassifier.liveValue` — over a fixed
// case set of realistic final and waiting messages, so prompt changes in
// `StopFinalityClassifier.swift` are measurable instead of vibes-based.
//
// Run on a Mac with Apple Intelligence enabled (macOS 26+):
//     swift run StopFinalityEval
// Exits non-zero when any case misclassifies (or the model is unavailable),
// and prints a per-case table. CI never runs this — its VMs have no Apple
// Intelligence — but the target compiles everywhere.
//
// Case provenance: F1 is the real merge summary that pinned a session on
// "Working" (misclassified by the pre-tuning prompt); the other FINAL cases
// cover the shapes that prompt also failed on (error reports, questions,
// user-directed next steps). Sampling is greedy, so results are stable for a
// given model version.

struct EvalCase {
    let name: String
    let message: String
    let expectWaiting: Bool
}

let cases: [EvalCase] = [
    // ── FINAL messages (expect .final) ──
    EvalCase(name: "F1 full merge summary (real-world failure)", message: """
    Merged and pushed. Summary:
    - Updated local `main` from the remote, then merged it into the feature branch — \
    a clean merge with no conflicts, bringing exactly the one checklist commit.
    - One housekeeping step first: the working tree still carried your uncommitted \
    edit (identical to what the merge was bringing in), which would have blocked the \
    merge. I discarded the local copy and let the merge supply the same content.
    - Build verified clean and the branch is pushed, so the working tree is fully \
    clean and the checklist note (run the e2e preflight, don't skip on assumptions) \
    is active on this branch too.
    """, expectWaiting: false),
    EvalCase(name: "F2 blunt done", message: """
    All done. I fixed the bug and all 1189 tests pass.
    """, expectWaiting: false),
    EvalCase(name: "F3 error report + question", message: """
    The build failed with 3 errors in StopFinalityClassifier.swift — the first is a \
    missing argument for parameter 'availability'. I can add the parameter to the \
    eight test stubs or introduce a helper. How would you like to proceed?
    """, expectWaiting: false),
    EvalCase(name: "F4 completed background work", message: """
    The e2e run finished: 1/1 passed (21s). Baselines were regenerated and the \
    screenshots verified visually — the row stays "Working" after the paused stop \
    and flips to "Done" after the final one. Pushed as a107aff3.
    """, expectWaiting: false),
    EvalCase(name: "F5 user-directed imperatives", message: """
    Done — pushed as 70c05ccf. To try it locally, run ./scripts/dev-install.sh and \
    restart Gallager; the toggle is under Settings → Agents → Claude Code. Watch the \
    sidecar log while you test to see the classifier verdicts.
    """, expectWaiting: false),
    EvalCase(name: "F6 mentions ongoing external work", message: """
    Fixed. Note the nightly backup cron stays registered — it fires at 2am and \
    doesn't affect this feature. Let me know if you want it disabled.
    """, expectWaiting: false),
    EvalCase(name: "F7 question ending", message: """
    I found two approaches: (a) race inference against a deadline, or (b) cancel \
    and poll the session. Which do you prefer?
    """, expectWaiting: false),
    EvalCase(name: "F8 long summary with offer", message: """
    Done — the settings row now reflects availability. What was added:
    - A new `availability` endpoint on the existing dependency, probed on form load.
    - Pre-macOS 26 and Apple-Intelligence-off render the toggle disabled with a \
    caption; a still-downloading model keeps it editable with a transient note.
    - Two tests pin the presentation mapping; the e2e run compares clean.
    - CI machines vary, so under --e2e-test the probe always reports available.
    Verification: 1189 tests pass, the Agents Settings Tab scenario passed, and the \
    build is clean. Want me to also surface the caption on iOS?
    """, expectWaiting: false),

    // ── WAITING messages (expect .stillWaiting) ──
    EvalCase(name: "W1 explicit report-back", message: """
    The build is running; I'll report back when it finishes.
    """, expectWaiting: true),
    EvalCase(name: "W2 background suite started", message: """
    I've started the full e2e suite in the background — it takes about 10 minutes. \
    I'll pick this up and summarize the results once it completes.
    """, expectWaiting: true),
    EvalCase(name: "W3 monitoring", message: """
    Monitoring the deploy; will update you once it's healthy.
    """, expectWaiting: true),
    EvalCase(name: "W4 waiting on CI", message: """
    Waiting on CI to go green before merging — the required checks are still running.
    """, expectWaiting: true),
    EvalCase(name: "W5 long status then wait", message: """
    Progress so far:
    - The decode hardening is done and unit-tested (4 new tests).
    - The deadline race is in with both outcomes covered.
    - The settings toggle is wired and renders correctly.
    The remaining scenario is still running; I'll verify the screenshots and report \
    back when it finishes.
    """, expectWaiting: true),
    EvalCase(name: "W6 nothing to do until done", message: """
    Kicked off the release build — it takes about 40 minutes. Nothing more to do \
    until it completes; I'll resume then.
    """, expectWaiting: true),
]

let classifier = StopFinalityClassifier.liveValue

guard classifier.availability() == .available else {
    print("Apple Intelligence unavailable (\(classifier.availability())) — cannot eval.")
    print("Enable it in System Settings on a macOS 26+ machine and re-run.")
    exit(1)
}

// The neutral descriptor the core passes in production
// (`StopBody.pendingBackgroundWorkSummary`).
let pendingWork = ["1 background task"]

var failures = 0
for c in cases {
    let verdict = await classifier.classify(message: c.message, pendingWork: pendingWork)
    let waiting = verdict == .stillWaiting
    let ok = waiting == c.expectWaiting
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL")  \(c.name) → \(waiting ? "WAITING" : "FINISHED")")
}

print("\(cases.count - failures)/\(cases.count) passed")
exit(failures == 0 ? 0 : 2)
