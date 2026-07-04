# Collapsible Usage Overview Cell (iOS + macOS)

**Date:** 2026-07-04
**Status:** Approved

## Problem

The cross-session usage rollup (issue #598) renders differently per platform:

- **iOS** (`SessionListView.swift`) shows the full `UsageOverviewView` — Today
  line + Projects ranking + Recent days trend — which makes the cell very tall
  and pushes sessions below the fold.
- **macOS** (`MainView.swift`, local sidebar section) shows only the one-line
  `UsageOverviewHeader`, with no way to see projects/days at all.

Both platforms should show just the compact "Today" line by default, with a
disclosure chevron that expands the cell in place to the full details and
contracts it again.

## Decision

Make the shared `UsageOverviewView`
(`ClaudeSpyPackage/Sources/ClaudeSpyCommon/UI/UsageOverviewViews.swift`)
collapsible, and use it on both platforms.

### Behavior

- `UsageOverviewView` owns `@State private var isExpanded = false`. The state
  is transient: every launch (and each host cell on iOS independently) starts
  collapsed. No persistence.
- Collapsed, the view renders exactly the existing `UsageOverviewHeader` row
  (icon + **Today** + `tokens · cost · sessions`) plus a trailing
  `chevron.right` in secondary caption styling.
- The whole header row is the tap target (plain button style). Tapping toggles
  `isExpanded` inside `withAnimation`; the chevron rotates 90° (pointing down)
  and the Projects + Recent days sections animate in below, unchanged from the
  current full layout.
- Accessibility: the header keeps its combined element, the
  `usage-overview-header` identifier, and the "Today's usage: …" label; it
  gains button traits so VoiceOver announces tappability.

### Call sites

- **macOS** `MainView.localSessionsSection` swaps `UsageOverviewHeader` →
  `UsageOverviewView`. `coordinator.usageOverview` already carries the full
  projects/days data, so nothing upstream changes.
- **iOS** `SessionListView.HostSessionsSection` keeps `UsageOverviewView`,
  which now defaults collapsed.
- `UsageOverviewHeader` remains public (used as the row content); no other
  consumers exist.

### Rejected alternatives

- **Native `DisclosureGroup`** — platform-specific disclosure chrome
  (sidebar-style on mac, tinted trailing chevron on iOS) fights the compact
  caption layout; overriding it costs more than a custom chevron.
- **Platform-specific expansion** — duplicates logic and leaves the two
  platforms diverging, which the shared module exists to prevent.

## Testing

- **E2E (one paired scenario, both platforms):** convert
  `OTELUsageOverviewScenario` from `macos-only` to a paired scenario by
  composing `FreshPairingScenario.scenario` up front (the pattern used by
  `TerminalTitleMacToIOSScenario`) in place of the mac-only setup — its
  existing session binding + synthetic OTLP posts already produce everything
  iOS needs, since the overview rides the `SessionStateMessage` to the viewer.
  - **macOS leg (existing, extended):** keep the collapsed-state wait
    (`.anyTextMatches("Today's usage")`) and screenshot; add click the header
    row → wait for the "Projects" section label → screenshot expanded → click
    again and verify it contracts.
  - **iOS leg (new):** verify the collapsed Today line renders on the iOS
    session list (screenshot), tap to expand, verify "Projects" appears
    (screenshot), tap to collapse again.
  - The changed/new baselines are removed locally (`git rm`) and regenerated
    by CI per repo policy.
- **Previews:** collapsed and expanded variants of `UsageOverviewView`.
