# Trial-status toolbar badge + trial-starts-on-pairing (design)

- **Date:** 2026-07-15
- **Status:** Approved (design); pending implementation plan
- **Feature area:** Hosted-relay licensing (#392)
- **Related:** `docs/superpowers/specs/2026-07-13-hosted-relay-monetization-design.md`

## Summary

Two coordinated changes to the hosted-relay trial experience:

- **Part A (relay):** Start a host's free-trial clock only when a **viewer actually
  completes pairing**, not when the host generates a pairing code (register) or
  connects. Today the clock starts on first touch of `checkEntitlement`, which
  fires at register and at host WebSocket connect (including the pending, pre-pair
  window). We move the start to the `complete` endpoint.
- **Part B (Mac UI):** Add a trial-status badge to the panes-window toolbar, just
  left of the Disconnect capsule, shown only when the host has a paired viewer and
  is on a trial (or has an expired trial). Clicking it opens a popover that
  explains the trial and lets the user buy a license or enter a license key.

The two parts dovetail: a `.trial` status only exists *after* a viewer pairs, so
the badge and the trial start together, and both are gated on the host being
paired.

## Motivation

- Generating a pairing code that no viewer ever uses should not burn trial days.
  The trial should represent time spent with a working paired setup.
- Hosts on a trial have no in-app affordance surfacing "you're on a trial, N days
  left — buy/activate" outside the Settings → Remote Access License section. A
  toolbar badge makes the trial state and the upgrade path visible where the user
  is already working.

---

## Part A — Relay: trial starts on viewer pairing

### Current behavior

- `LicensingService.checkEntitlement(hostDeviceId:)`
  (`ClaudeSpyExternalServerLib/Services/LicensingService.swift:143`) auto-starts a
  trial on first sight of a device via `trialEntitlement(...)`
  (`:172`), which creates the `TrialRecord` and increments the `trialStarts`
  metric as a side effect of the check.
- `checkEntitlement` is called at three gates:
  - **register** — `PairingController.registerPairingCode`
    (`Routes/PairingController.swift:24`), when the Mac *generates* a pairing code.
  - **host WS connect** — `WebSocketController` (`Routes/WebSocketController.swift:146`).
  - **sweep** — `sweepBlockedHosts` (hourly, from `configure.swift`).
- `PairingService.isValidPair(pairId:)` (`Services/PairingService.swift:156`) also
  accepts **pending** registrations, so a host WS can connect (and, today, start
  the trial) during the pending window before any viewer completes.

Net: the clock starts at "generate a code," which can be well before — or entirely
without — a viewer pairing.

### Change

Separate *starting* a trial from *checking* entitlement.

1. **`checkEntitlement(hostDeviceId:)` becomes side-effect-free.** It only evaluates
   existing state. A device with no activation and no trial returns a new
   entitlement case `.preTrial` whose `isAllowed == true`. Existing-trial and
   activation logic is unchanged (active → `.trial`/`.licensed`; expired →
   `.blocked`).

2. **New `startTrialIfNeeded(hostDeviceId:)`.** If licensing is enabled, the device
   has no activation, and no `TrialRecord` exists, create the record, persist, and
   increment the `trialStarts` metric. Idempotent (no-op if a trial or activation
   already exists, or if licensing is disabled). The metric increment moves here
   from `trialEntitlement`.

3. **Call `startTrialIfNeeded` from `completePairing`**
   (`PairingController.completePairing`, `Routes/PairingController.swift:46`): after
   `pairingService.completePairing(...)` returns `.paired(pairId:…)`, resolve the
   host via `pairingService.getPair(pairId:)?.hostDeviceId` and call
   `startTrialIfNeeded(hostDeviceId:)`. This is the **only** place the clock starts.

The `Entitlement` enum (`LicensingService.swift:40`) gains:

```swift
enum Entitlement: Equatable {
    case unrestricted
    case preTrial          // NEW: licensing on, no trial yet, no activation → allowed
    case trial(expiresAt: Date)
    case licensed
    case blocked(reason: BlockReason)

    var isAllowed: Bool {
        if case .blocked = self { return false }
        return true
    }
}
```

`status(deviceId:)` (`LicensingService.swift:188`) is unchanged — it is already
read-only and returns `.none` for a pre-trial device, `.trial`/`.expired` once a
trial exists.

### Resulting semantics

Keyed by host `deviceId`; anti-abuse behavior preserved (trial is sticky per
device once used).

| Host state | register / host WS connect gate | trial clock |
|---|---|---|
| never paired (`.preTrial`) | allowed | not started |
| viewer completes pairing (`complete`) | — | **starts here** |
| trial active | allowed | running |
| trial expired | **blocked** (`SUBSCRIPTION_REQUIRED`) | stays expired per deviceId |
| licensed (active) | allowed | — |
| license expired / disabled / grace-expired | blocked | — |

A host may generate pairing codes freely until a viewer actually pairs. Once the
trial is used up it stays expired even if the host deletes the pair and re-pairs
(the `TrialRecord` persists per `deviceId`).

### Non-goals

- **No WS-connect safety-net start.** We deliberately do *not* also start the trial
  at host WS connect. Every active (completed) pair already went through
  `complete`, so the only gap is "a pairing completed while licensing was disabled,
  then licensing was enabled later" — an operational edge case not worth the added
  branch (WS connect would have to distinguish active vs pending pairs, since
  `isValidPair` accepts both). If it ever matters, it can be added later.

### Test impact (relay)

Several tests assume first-touch auto-start and must be restructured to arm the
trial via `complete`:

- `LicenseEndpointTests.registerStartsTrial` → becomes "register does **not** start
  a trial" (register succeeds, `status` stays `.none`) **plus** a new
  "complete starts the trial" (after a viewer completes, host `status` is `.trial`).
- `LicenseEndpointTests.registerBlockedAfterTrial` (`TRIAL_DAYS=0`) → a fresh host is
  now `.preTrial` and may register; restructure to first complete a pairing (which
  starts an immediately-expired trial) and then assert a subsequent register is
  blocked.
- `LicenseEnforcementWebSocketTests.expiredTrialHostRejected` /
  `viewerToldHostSubscriptionInactive` (`TRIAL_DAYS=0`) → the `makePair` helper must
  drive (or simulate) `complete` so the host has an expired trial before the WS
  connect gate is exercised; otherwise a pre-trial host would be *allowed*.
- Audit `LicensingServiceTests` (actor-level) for any test that relies on
  `checkEntitlement` creating a trial; move those to `startTrialIfNeeded`.

New/updated relay unit coverage:

- `checkEntitlement` returns `.preTrial` (allowed) for a fresh device and does **not**
  create a `TrialRecord` or increment `trialStarts`.
- `startTrialIfNeeded` creates exactly one trial (idempotent on repeat), no-ops when
  an activation exists, and no-ops when licensing is disabled.
- `completePairing` starts the host's trial; a second completion for the same host
  does not restart it.
- Expired trial blocks register, host WS connect, and is swept.

---

## Part B — Mac UI: trial-status toolbar badge

### Component

New view `TrialStatusToolbarItem`
(`ClaudeSpyServerFeature/Views/TrialStatusToolbarItem.swift`).

Dependencies:

- `@Environment(LicenseManager.self) private var licenseManager`
- `@Environment(AppSettings.self) private var settings` (for `isPaired`)
- `@Dependency(URLOpener.self) private var urlOpener`
- `@State private var showingPopover = false`

A pure, unit-testable helper maps license state to appearance:

```swift
enum TrialBadgeAppearance: Equatable {
    case trial(text: String, urgent: Bool)   // urgent → orange, else secondary
    case expired                             // red "Subscription required"
}

func trialBadgeAppearance(
    state: LicenseStatus.State?, trialDaysLeft: Int?
) -> TrialBadgeAppearance?   // nil → render nothing
```

The `isPaired` gate lives in the view (it is app state, not license state): the
badge renders only when `settings.isPaired && appearance != nil`.

### Appearance & visibility

| Condition | Badge | Tint |
|---|---|---|
| not paired (any state) | hidden | — |
| paired · `.trial`, > 2 days left | ⏳ "N days left" | secondary (grey) |
| paired · `.trial`, ≤ 2 days left | ⏳ "N days left" | orange |
| paired · `.expired` | ⚠️ "Subscription required" | red |
| paired · `.active` / `.none` / `.notRequired` / nil | hidden | — |

- Day count uses `licenseManager.trialDaysLeft` (already ceil-of-remaining; nil
  unless the status is an unexpired trial).
- Rendered as a borderless capsule `Button` (`controlSize(.small)`) matching the
  toolbar pill idiom, label = icon + text.
- Icons: trial uses a new `Symbols` case (`hourglass` = `"hourglass"`, to be added
  to `ClaudeSpyCommon/UI/Symbols.swift`); expired reuses the existing
  `Symbols.exclamationmarkTriangle`.

### Popover

`.popover(isPresented: $showingPopover, arrowEdge: .bottom)`, width ~320 to match
the existing Disconnect popover. Content (a `VStack`, all logic via the existing
`LicenseManager` — no duplicated licensing logic):

- **Headline** — trial: "Free trial — N days left"; expired: "Your trial has ended".
- **Body** — one or two lines: the hosted relay needs a subscription after the
  7-day trial; for expired, note that remote access is paused until they subscribe.
- **"Buy a License…"** button → `urlOpener.openInDefaultBrowser(LicensingLinks.checkout)`.
- Divider labelled "or enter a license key".
- **License key** `TextField` bound to `$licenseManager.licenseKeyField` +
  **"Activate"** button → `Task { await licenseManager.activate() }`. Activate is
  disabled while `licenseManager.actionState == .working`; an inline error line
  shows when `actionState == .error(message)`.
- On successful activation, `LicenseManager.onActivationSuccess` already handles
  reconnect and `status` refreshes to `.active` → the badge auto-hides; the popover
  dismisses.

### Placement

Add a new `ToolbarItem(placement: .automatic)` **before** the existing
`connectionStatusView` item in `MainView.toolbarContent`
(`ClaudeSpyServerFeature/Views/MainView.swift:1767`). Same-placement toolbar items
render in declaration order, so declaring the badge first puts it to the left of
the wifi + Disconnect capsule.

### Wiring

- Inject the license manager into the panes window: add
  `.environment(coordinator.licenseManager)` to the `Window("Panes", id: "panes")`
  scene in `ClaudeSpyServer/ClaudeSpyServerApp.swift` (~line 390). It is currently
  injected only into the Settings scene (`:548`); `MainView` (in the panes window)
  cannot resolve it today.
- Status is already kept fresh app-wide by `AppCoordinator.startLicenseMonitoring()`
  (called at launch, `AppCoordinator.swift:429`; refreshes on start and every
  30 min), so the badge has data without opening Settings.
- **Refresh on pairing completion:** when the Mac observes that a viewer has
  completed pairing, call `licenseManager.refreshStatus()` so the badge appears
  promptly (the server started the trial at `complete`) rather than waiting for the
  next 30-min poll. Wire this at the Mac-side pairing-completion handler.

### Test impact (Mac)

- Unit-test the pure `trialBadgeAppearance(state:trialDaysLeft:)` mapping:
  visibility per state, orange at ≤ 2 days, red for expired, nil for hidden states.
- **E2E scenario** proving the feature: with a paired host on a trial, assert the
  badge is visible with the countdown; open the popover; assert the Buy button,
  license-key field, and Activate button are present; assert the badge is hidden
  when not paired. Driving the Mac's `LicenseManager.status` into `.trial`/`.expired`
  needs a DEBUG/E2E-only injection hook (e.g. an E2E method on `LicenseManager` or
  `AppCoordinator` that sets a `LicenseStatus` directly) rather than standing up a
  licensing-enabled relay with a real trial; the exact hook is an implementation
  detail for the plan.

### Accessibility identifiers (for E2E)

- Badge button: `trial-status-badge`
- Popover Buy button: `trial-popover-buy`
- Popover license-key field: `trial-popover-license-key`
- Popover Activate button: `trial-popover-activate`

---

## Interfaces & data model

- `LicenseStatus` (`ClaudeSpyNetworking/Models/LicenseModels.swift`) — **unchanged**.
- `LicensingService.Entitlement` — gains `.preTrial`.
- `LicensingService` — `checkEntitlement` loses its trial-creating side effect;
  new `startTrialIfNeeded(hostDeviceId:)`.
- No wire-format change → no `VersionCompatibility` bump required. Relay and Mac can
  deploy independently; an old Mac against a new relay simply starts the trial later
  (at pairing) and shows no badge, which is acceptable.

## Affected files

Relay:
- `ClaudeSpyExternalServerLib/Services/LicensingService.swift` — split
  check/start, add `.preTrial`.
- `ClaudeSpyExternalServerLib/Routes/PairingController.swift` — `startTrialIfNeeded`
  on `complete`.
- Tests: `LicenseEndpointTests.swift`, `LicenseEnforcementWebSocketTests.swift`,
  `LicensingServiceTests` (audit).

Mac:
- `ClaudeSpyServerFeature/Views/TrialStatusToolbarItem.swift` — new.
- `ClaudeSpyServerFeature/Views/MainView.swift` — add toolbar item.
- `ClaudeSpyServer/ClaudeSpyServerApp.swift` — inject `licenseManager` into panes
  window.
- `ClaudeSpyCommon/UI/Symbols.swift` — add `hourglass`.
- Mac-side pairing-completion handler — trigger `licenseManager.refreshStatus()`.
- Tests: new unit test for `trialBadgeAppearance`; new E2E scenario + DEBUG status
  hook.

## Risks

- **Test churn** on the relay side is the largest surface; the behavior change is
  intentional and the restructured tests document the new semantics.
- **Existing paired hosts** (pre-change) already have a `TrialRecord` from the old
  first-touch start, so no migration is needed — they keep their current trial/
  expiry. New pairs start at `complete`.
- **Badge latency** after pairing is bounded by the pairing-completion refresh; if
  that hook is missed, the badge still appears within one 30-min poll.
