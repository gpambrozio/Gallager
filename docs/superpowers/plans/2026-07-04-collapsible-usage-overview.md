# Collapsible Usage Overview Cell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Both iOS and macOS show the usage rollup as a compact one-line "Today" cell that expands in place (disclosure chevron) to the full Projects + Recent days details, proven by one paired mac+iOS E2E scenario.

**Architecture:** The shared `UsageOverviewView` in `ClaudeSpyCommon` gains a transient `@State` `isExpanded` (always starts collapsed) and renders its header as a tappable plain-style button with a rotating chevron. macOS swaps its header-only call site for the full view; iOS's call site is unchanged. `OTELUsageOverviewScenario` converts from `macos-only` to a paired scenario (composing `FreshPairingScenario`) and exercises expand/contract on both platforms.

**Tech Stack:** Swift 6.3+, SwiftUI (MV pattern), ClaudeSpyE2ELib scenario DSL.

**Spec:** `docs/superpowers/specs/2026-07-04-collapsible-usage-overview-design.md`

## Global Constraints

- Swift 6.3+, SwiftUI MV pattern — no ViewModels; `@State` for view state.
- Targets: macOS 15.0+, iOS 17.0+.
- SF Symbols only via the `Symbols` enum (`Symbols.chevronRight` already exists — do NOT add a string literal).
- Expanded state is transient `@State`, default collapsed — NO persistence (no `@AppStorage`).
- Shared UI lives in `ClaudeSpyPackage/Sources/ClaudeSpyCommon/`.
- All builds/tests go through XcodeBuildTools skills (`xcodebuild`, `swift-package`) — never raw `xcodebuild`/`swift` commands. macOS scheme: `ClaudeSpyServer`; iOS scheme: `ClaudeSpy`.
- E2E work (Task 3, 4) requires invoking the repo `e2e-testing` skill first.
- E2E screenshot baselines are CI-generated: never commit locally-captured baselines; `git rm` the affected dir and let CI capture them.
- Run the E2E scenario locally 2–3 times and visually verify ALL screenshots before pushing.
- Never `--no-verify`; a swiftformat PostToolUse hook formats edits automatically.

---

### Task 1: Make the shared `UsageOverviewView` collapsible

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyCommon/UI/UsageOverviewViews.swift:37-83` (the `UsageOverviewView` struct) and `:181-191` (previews)

**Interfaces:**
- Consumes: existing `UsageOverviewHeader` (unchanged), `UsageProjectRow`, `UsageDayRow`, `Symbols.chevronRight`.
- Produces: `UsageOverviewView.init(overview: UsageOverview, initiallyExpanded: Bool = false)` — the default-argument init keeps the existing iOS call site `UsageOverviewView(overview: overview)` source-compatible. Task 2 uses the same one-argument form. The header button exposes accessibility label `"Today's usage: …"` (via the embedded header), identifier `usage-overview-toggle`, and accessibility value `"expanded"`/`"collapsed"` — Task 3's queries depend on the label text.

- [ ] **Step 1: Replace the `UsageOverviewView` struct**

In `ClaudeSpyPackage/Sources/ClaudeSpyCommon/UI/UsageOverviewViews.swift`, replace the entire `UsageOverviewView` struct (lines 39–83, including its doc comment) with:

```swift
/// The full cross-session overview (issue #598): a compact "Today" header row
/// that expands in place — via the trailing disclosure chevron — to the
/// per-project ranking over the recent window and the per-day trend. Starts
/// collapsed on every appearance (transient state, no persistence). Shared by
/// both platforms: the iOS session list and the Mac sidebar.
public struct UsageOverviewView: View {
    private let overview: UsageOverview

    @State private var isExpanded: Bool

    public init(overview: UsageOverview, initiallyExpanded: Bool = false) {
        self.overview = overview
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var trendDays: [DayUsage] {
        overview.days.filter { $0.costUSD > 0 || $0.tokens > 0 }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    UsageOverviewHeader(overview: overview)
                    Symbols.chevronRight.image
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("usage-overview-toggle")
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")

            if isExpanded {
                if !overview.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionLabel("Projects", symbol: .folder)
                        ForEach(overview.projects) { project in
                            UsageProjectRow(project: project)
                        }
                    }
                }

                if !trendDays.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionLabel("Recent days", symbol: .calendar)
                        ForEach(trendDays) { day in
                            UsageDayRow(day: day)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("usage-overview")
    }

    private func sectionLabel(_ title: String, symbol: Symbols) -> some View {
        Label(title, symbol: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
```

Notes on why this shape:
- `UsageOverviewHeader` is reused unchanged inside the button label, so its
  combined accessibility element, `usage-overview-header` identifier, and
  `"Today's usage: …"` label propagate to the button (the E2E queries in Task 3
  match on that label — on macOS it surfaces as the button's AXDescription).
- The header's internal `Spacer(minLength: 0)` pushes the chevron to the
  trailing edge; `.contentShape(Rectangle())` makes the full row width
  tappable even over the spacer.
- `chevron.right` rotated 90° points down when expanded — standard disclosure.
- `initiallyExpanded` exists ONLY so the expanded preview below can render; the
  default keeps both production call sites collapsed-on-appear.

- [ ] **Step 2: Replace the "Overview full" preview with collapsed + expanded variants**

At the bottom of the same file, replace:

```swift
#Preview("Overview full") {
    UsageOverviewView(overview: previewOverview)
        .padding()
        .frame(width: 320)
}
```

with:

```swift
#Preview("Overview collapsed") {
    UsageOverviewView(overview: previewOverview)
        .padding()
        .frame(width: 320)
}

#Preview("Overview expanded") {
    UsageOverviewView(overview: previewOverview, initiallyExpanded: true)
        .padding()
        .frame(width: 320)
}
```

- [ ] **Step 3: Build both platforms**

Use the XcodeBuildTools `xcodebuild` skill:
1. Scheme `ClaudeSpyServer` (macOS destination). Expected: BUILD SUCCEEDED.
2. Scheme `ClaudeSpy` (iOS Simulator destination). Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyCommon/UI/UsageOverviewViews.swift
git commit -m "Make UsageOverviewView collapsible with disclosure chevron"
```

---

### Task 2: macOS sidebar uses the collapsible view

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/MainView.swift:489-493`

**Interfaces:**
- Consumes: `UsageOverviewView(overview:)` from Task 1 (one-argument form, defaults collapsed).
- Produces: the mac sidebar's local section renders the collapsible cell with the existing `usage-overview-header-local` identifier on the container (unchanged, in case anything references it).

- [ ] **Step 1: Swap the header for the full collapsible view**

In `MainView.swift`, `localSessionsSection`, replace:

```swift
            // Host's own cross-session usage rollup (issue #598).
            if let overview = coordinator.usageOverview, !overview.isEmpty {
                UsageOverviewHeader(overview: overview)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("usage-overview-header-local")
            }
```

with:

```swift
            // Host's own cross-session usage rollup (issue #598), collapsed to
            // the "Today" line until the disclosure chevron expands it.
            if let overview = coordinator.usageOverview, !overview.isEmpty {
                UsageOverviewView(overview: overview)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("usage-overview-header-local")
            }
```

- [ ] **Step 2: Build macOS**

Use the XcodeBuildTools `xcodebuild` skill: scheme `ClaudeSpyServer` (macOS destination). Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/MainView.swift
git commit -m "Show collapsible usage overview in mac sidebar"
```

---

### Task 3: Convert `OTELUsageOverviewScenario` to a paired mac+iOS scenario with expand/contract legs

**Invoke the repo `e2e-testing` skill before starting this task.**

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/OTELUsageOverviewScenario.swift` (whole file)

**Interfaces:**
- Consumes: `FreshPairingScenario.scenario` (starts server, launches mac + iOS, pairs them; leaves iOS on the Sessions list and mac Settings open), `Shortcut.openPanesWindow()`, the view from Tasks 1–2 whose header button carries label `"Today's usage: …"`.
- Produces: scenario tagged `["telemetry", "otel"]` (dropping `macos-only` makes the runner require `--ios-app-path`, i.e. the iOS leg runs). Baseline dir `E2ETests/otel-usage-overview/` will regenerate with new screenshot labels: pairing shots (`ios-pairing-view`, `mac-code-generated`, `ios-paired`, `mac-connected`) plus `mac-usage-overview`, `mac-usage-overview-expanded`, `ios-usage-overview`, `ios-usage-overview-expanded`.

Background the implementer needs:
- The host folds OTLP into `UsageAggregationStore` and pushes a
  `SessionStateMessage` (which carries `usageOverview`) to all viewers on a
  ~1 s trailing throttle (`AppCoordinator.handleTelemetry`), so iOS sees the
  overview within a couple of seconds of the curl.
- Composed scenarios flatten: `FreshPairingScenario.scenario`'s screenshots
  land in this scenario's baseline dir with sequence-number prefixes (see
  `E2ETests/terminal-title-mac-to-ios/` for the pattern).
- `${otlpEndpoint}` is set by the orchestrator when mac instance 0 launches —
  it works identically in paired scenarios.
- On macOS, `macClickButton(titled:)` does an AXPress on the first element
  whose title/label/value contains the string (`anyTextMatches`). The header
  button's AXDescription is `"Today's usage: …"`. If AXPress turns out not to
  toggle the SwiftUI button inside the sidebar List, fall back to
  `TestStep.macCGClickElement(query: .anyTextMatches("Today's usage"))` (real
  mouse click).
- The waits on "Projects" are unambiguous: the project name in this scenario
  is `OverviewProject`, which contains "Project" but not "Projects", so only
  the section label matches.

- [ ] **Step 1: Rewrite the scenario file**

Replace the entire contents of `OTELUsageOverviewScenario.swift` with:

```swift
import Foundation

/// E2E scenario: the cross-session cost/usage overview renders as a collapsed
/// "Today" line on the macOS sidebar AND the iOS session list, and expands /
/// contracts in place via the disclosure chevron (issue #598, part B +
/// collapsible cell).
///
/// Proves the receive → accumulate → durable-store → overview → render pipeline
/// without a live Claude, building on the #597 OTEL channel — plus the
/// cross-device path: the overview rides `SessionStateMessage` to the paired
/// iOS viewer.
/// 1. Mac host + iOS viewer pair via `FreshPairingScenario`.
/// 2. A tmux session is created and bound to a Claude `session.id` via a
///    synthetic `SessionStart` hook, then a `UserPromptSubmit` carrying a
///    `permission_mode` + project path so the pane has a `detectedProjectPath`
///    (the aggregation key the usage store attributes spend to).
/// 3. Synthetic OTLP/JSON `api_request` + `commit.count` are POSTed to the
///    Mac-local receiver from the pane's own shell (addressed by the instance's
///    `${otlpEndpoint}`, like the render scenario).
/// 4. The mac sidebar shows the collapsed "Today" total; clicking it expands
///    to Projects + Recent days; clicking again contracts it.
/// 5. The iOS session list shows the same collapsed line (the overview rode
///    the session-state push); tapping expands and contracts it.
public enum OTELUsageOverviewScenario {
    /// `api_request` log: 30 000 input + 1 000 output tokens, $1.23, opus-4.8.
    /// → today total "31k · $1.23 · 1 session". Real wire shape (bare `event.name`
    /// attribute + fully-qualified body), matching the render scenario.
    private static let apiRequestCurl =
        #"curl -s -o /dev/null -X POST ${otlpEndpoint}/v1/logs -H 'Content-Type: application/json' -d '{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"body":{"stringValue":"claude_code.api_request"},"attributes":[{"key":"event.name","value":{"stringValue":"api_request"}},{"key":"session.id","value":{"stringValue":"e2e-usage-session"}},{"key":"input_tokens","value":{"intValue":"30000"}},{"key":"output_tokens","value":{"intValue":"1000"}},{"key":"cost_usd","value":{"doubleValue":1.23}},{"key":"duration_ms","value":{"intValue":"1500"}},{"key":"model","value":{"stringValue":"claude-opus-4-8"}}]}]}]}]}'"#

    /// `commit.count` metric (cumulative 2) → carried onto the snapshot and into
    /// the store's per-project commit total (issue #598).
    private static let commitMetricCurl =
        #"curl -s -o /dev/null -X POST ${otlpEndpoint}/v1/metrics -H 'Content-Type: application/json' -d '{"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.commit.count","sum":{"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":"e2e-usage-session"}}],"asInt":"2"}]}}]}]}]}'"#

    public static let scenario = ClaudeSpyE2ELib.scenario(
        "OTEL Usage Overview",
        tags: ["telemetry", "otel"]
    ) {
        // 1. Pair the mac host with the iOS simulator (starts the relay and
        //    launches both apps), then open the Panes window on the host.
        FreshPairingScenario.scenario
        Shortcut.openPanesWindow()
        TestStep.macResizeWindow(width: 1_200, height: 700)
        TestStep.macSetSidebarWidth(280)

        // 2. Create a session and bind it to a known Claude session id with a
        //    project path (the usage store's aggregation key).
        TestStep.tmuxCreateSession(name: "usage-session", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "usage-session:0.0", storeAs: "usagePane")
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-usage-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${usagePane}",
            projectPath: "/Users/test/OverviewProject"
        )
        // A UserPromptSubmit carrying the project path so the pane's
        // `detectedProjectPath` is set before telemetry arrives — otherwise the
        // store can't attribute the spend and the overview stays empty.
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "e2e-usage-session",
                "permission_mode": "default",
                "prompt": "hello",
                "timestamp": "2026-02-14T10:00:03.000000Z"
            }
            """,
            tmuxPane: "${usagePane}",
            projectPath: "/Users/test/OverviewProject"
        )
        TestStep.wait(seconds: 2)

        // 3. POST synthetic telemetry to the loopback receiver from the pane.
        Shortcut.tmuxRunCommand(target: "usage-session:0.0", command: apiRequestCurl)
        Shortcut.tmuxRunCommand(target: "usage-session:0.0", command: commitMetricCurl)
        TestStep.wait(seconds: 2)

        // 4. macOS: the local sidebar section shows the collapsed "Today"
        //    overview cell. Match on its accessibility label (SwiftUI
        //    identifiers don't reliably surface as AXIdentifier on macOS, but
        //    labels do — the header's label is the button's AXDescription).
        TestStep.macWaitForElementQuery(.anyTextMatches("Today's usage"), timeout: 10)
        TestStep.macScreenshot(label: "mac-usage-overview")

        //    Expand: click the header row, the Projects section appears.
        TestStep.macClickButton(titled: "Today's usage")
        TestStep.macWaitForElement(titled: "Projects", timeout: 10)
        TestStep.macScreenshot(label: "mac-usage-overview-expanded")

        //    Contract: click again, the details disappear.
        TestStep.macClickButton(titled: "Today's usage")
        TestStep.macWaitForElementToDisappear(titled: "Projects", timeout: 10)

        // 5. iOS: the overview rode the session-state push to the viewer.
        //    The host throttles telemetry pushes to ~1/s, so allow a little
        //    slack for the collapsed line to appear.
        TestStep.iosWaitForElement(.labelContains("Today's usage"), timeout: 20)
        TestStep.iosScreenshot(label: "ios-usage-overview")

        //    Expand: tap the header row, the Projects section appears.
        TestStep.iosTap(.labelContains("Today's usage"))
        TestStep.iosWaitForElement(.labelContains("Projects"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-usage-overview-expanded")

        //    Contract: tap again, the details disappear.
        TestStep.iosTap(.labelContains("Today's usage"))
        TestStep.iosWaitForElementToDisappear(.labelContains("Projects"), timeout: 10)
    }
}
```

- [ ] **Step 2: Verify the scenario still registers and the suite builds**

Run: `./scripts/e2e-test.sh --list-scenarios`
Expected: build succeeds and the list includes `OTEL Usage Overview` (no `macos-only` tag shown for it).

- [ ] **Step 3: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/OTELUsageOverviewScenario.swift
git commit -m "Extend OTEL usage overview E2E to paired mac+iOS with expand/contract"
```

---

### Task 4: Run the scenario locally, verify screenshots, reset baselines

**Invoke the repo `e2e-testing` skill before starting this task (if not already active from Task 3).**

**Files:**
- Delete (from git): `E2ETests/otel-usage-overview/` (stale mac-only baseline; CI regenerates)

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: a locally-verified green scenario and a commit that removes the stale baseline dir.

- [ ] **Step 1: Clear the stale local baseline**

The old `01-mac-usage-overview.png` was captured under the mac-only setup and can't match the paired run. Remove the dir from disk so run 1 captures fresh local baselines:

```bash
rm -rf E2ETests/otel-usage-overview
```

- [ ] **Step 2: First run (captures local baselines)**

Run: `./scripts/e2e-test.sh --scenario "OTEL Usage Overview"`
Expected: PASS. Every screenshot step saves a new local baseline and passes.

If the mac expand click doesn't toggle (wait for "Projects" times out): switch the two `macClickButton(titled: "Today's usage")` steps to `TestStep.macCGClickElement(query: .anyTextMatches("Today's usage"))` and re-run. If the iOS tap can't find the row, use `TestStep.iosLogUI` to inspect the actual labels (per the e2e-manual-debugging skill).

- [ ] **Step 3: Two more runs (stability check, per repo policy)**

Run the same command twice more.
Expected: PASS both times — screenshots now compare against run-1 baselines, proving the flow is deterministic.

- [ ] **Step 4: Visually verify EVERY screenshot**

Read each PNG in `E2ETests/otel-usage-overview/` with the Read tool and confirm:
- `*-mac-usage-overview.png`: sidebar shows ONE compact line — chart icon, "Today", totals (`31k · $1.23 · 1 session`), right-pointing chevron. NO Projects/Recent days rows.
- `*-mac-usage-overview-expanded.png`: same cell now also shows "Projects" with `OverviewProject … 31k · $1.23 · 2 commits` and "Recent days" with `02-14 … 31k · $1.23`; chevron points down.
- `*-ios-usage-overview.png`: iOS host section shows the same single collapsed line above the `usage-session` row.
- `*-ios-usage-overview-expanded.png`: iOS cell expanded with Projects + Recent days; chevron points down.
- Pairing screenshots (`ios-pairing-view`, `mac-code-generated`, `ios-paired`, `mac-connected`) look like their counterparts in `E2ETests/terminal-title-mac-to-ios/`.

Copy the verified screenshots to the session scratchpad as review copies (per repo policy) before the next step deletes them.

- [ ] **Step 5: Remove local baselines from the working tree and commit the deletion**

CI owns baselines. Delete the locally-captured ones and commit the removal of the tracked stale file:

```bash
git rm -r E2ETests/otel-usage-overview
git commit -m "Remove stale OTEL usage overview baselines; CI regenerates for paired scenario"
```

(`git rm` removes both the tracked `01-mac-usage-overview.png` and stages the deletion; locally-captured untracked PNGs in that dir are deleted from disk by the same command. If any remain untracked, `rm -rf E2ETests/otel-usage-overview` before committing.)
