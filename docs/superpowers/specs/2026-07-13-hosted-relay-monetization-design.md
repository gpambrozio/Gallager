# Hosted Relay Monetization — Design

**Date:** 2026-07-13
**Issue:** #392 (Figure out a good way to monetize)
**Status:** Approved design, pending implementation plan

## Summary

Gallager stays free — the Mac app, the iOS app, viewers, and self-hosting the relay.
The paid feature is a **host Mac using the hosted relay**. A host needs an active
subscription (or trial) before the hosted relay will register pairing codes or accept
its WebSocket connections. Viewers always connect free.

Because hosts are always Macs (never iOS), **all payments go through a web checkout**
— no Apple in-app purchase, no App Store cut, no cross-provider entitlement sync. The
iOS app remains a free client with no purchase UI at all.

## Decisions

| Decision | Choice |
|---|---|
| Goal | Meaningful side income (worth a proper checkout + trial funnel, not worth heavy ops) |
| Entitlement holder | The host Mac (keyed by host `deviceId`) |
| Payment provider | Lemon Squeezy — merchant of record (handles global VAT/sales tax), native license keys |
| Licensing mechanism | License key, entered in the Mac app's Remote Access settings |
| Activations per key | 3 Macs (Lemon Squeezy enforces the limit) |
| Pricing | $5/month or $50/year (configurable in LS without code changes) |
| Free experience | 7-day full-featured trial, no card, auto-started per host device |
| Early testers | 100%-off-forever Lemon Squeezy discount codes (capped redemptions) — testers flow through the normal checkout → key → activate path. No relay-side comp keys. |
| Enforcement architecture | Relay validates keys against Lemon Squeezy with caching (Approach 1). No webhooks, no separate licensing service. |
| Self-hosting | Unaffected: licensing is disabled unless env vars are set (default off) |

## Entitlement model

A new `LicensingService` actor on the relay computes an entitlement per host
`deviceId`. States:

1. **Unrestricted** — licensing env vars absent. Every check short-circuits to
   allowed. This is the state for self-hosted relays, E2E, and local dev. Provably
   zero behavior change from today.
2. **Trial** — starts automatically the first time a host `deviceId` touches the
   hosted relay (pairing register or host WS connect). Lasts `TRIAL_DAYS` (7).
   Stored relay-side; no card, no LS involvement.
3. **Licensed** — the Mac app activated a license key. The relay revalidates the key
   against LS lazily, at most every `LICENSE_REVALIDATE_HOURS` (24), caching verdicts.
4. **Blocked** — trial expired with no valid key, or the key's verdict is
   `expired`/`disabled`, or LS has been unreachable past the grace window.

Resolution: if an activation exists, its verdict decides — valid → licensed,
invalid (`expired`/`disabled`) → blocked, with **no fallback to trial** once a key
has ever been activated for that device. With no activation: unexpired trial →
trial, otherwise blocked.

**Grace semantics:** a hard verdict from LS (`expired`, `disabled`) blocks
immediately — LS's own dunning/retry already gives payment-failure leeway. An
*unreachable* LS keeps a previously-valid key valid for `LICENSE_GRACE_DAYS` (7)
from the last successful validation, then blocks.

**Blocked ≠ deleted:** pairs are never removed for entitlement reasons. A lapsed
subscriber who resubscribes resumes with all existing pairs intact — no re-pairing.

**Trial-reset abuse:** a wiped host `deviceId` gets a fresh trial. Accepted at this
scale; revisit only if it shows up in metrics.

## Relay changes (`ClaudeSpyExternalServerLib`)

### LicensingService (new actor, `Services/LicensingService.swift`)

Follows the `PairingService` pattern: JSON file persistence (`licensing.json` next to
`pairs.json`), synchronous load in init, `save` after mutations.

API:
- `checkEntitlement(hostDeviceId:) async -> Entitlement` — the single call both
  enforcement points use. Auto-starts trials. Triggers lazy revalidation when a
  cached verdict is older than 24h.
- `activate(licenseKey:deviceId:deviceName:) async -> LicenseStatus` — calls LS
  `POST /v1/licenses/activate` (instance name = device name), verifies the response's
  `store_id` and `product_id` against configuration, stores the activation.
- `deactivate(deviceId:) async throws` — calls LS `POST /v1/licenses/deactivate`,
  frees one of the 3 slots, removes the local activation.
- `status(deviceId:) async -> LicenseStatus` — for the Mac app UI (state + expiry).
- Daily sweep: revalidates connected hosts' entitlements and disconnects hosts that
  became blocked mid-connection (typed error to host, `hostSubscriptionInactive`
  notification to the pair's viewers).

Outbound HTTP goes through a small injected client protocol (backed by Vapor's
`app.client` in production) so tests stub LS without a network.

**Security check that matters:** LS's license endpoints answer for *any* store's
keys. Every activate/validate response MUST match the configured
`LEMONSQUEEZY_STORE_ID` and `LEMONSQUEEZY_PRODUCT_ID`, else treat the key as invalid
— otherwise any key from any LS store would unlock the relay.

**No secrets on the relay:** LS's `/v1/licenses/*` endpoints are public (keyed by the
license key itself); the store/product IDs are identifiers, not credentials.

### Endpoints (new `Routes/LicenseController.swift`)

```
POST   /api/license/activate    { licenseKey, deviceId, deviceName } → LicenseStatus
DELETE /api/license/activation?deviceId=x                            → 204
GET    /api/license/status?deviceId=x                                → LicenseStatus
```

These return billing state only (never session data) and are keyed by `deviceId` —
the same trust model as pairing registration today. `GET /status` is read-only: it
never starts a trial (only the two enforcement points do), so opening Settings on a
fresh install reports `none` without burning trial days.

### Enforcement points (two, plus the sweep)

1. `PairingController.registerPairingCode` — checks
   `checkEntitlement(hostDeviceId:)`; blocked hosts get a typed `subscriptionRequired`
   error in `PairingResponse` instead of a registration.
2. `WebSocketController.handleWebSocketUpgrade`, `deviceType == .host` — after the
   existing pair validation, checks entitlement; blocked hosts receive
   `WebSocketMessage.error(.subscriptionRequired)` and are closed (mirrors the
   existing `.invalidPair()` flow).
3. Daily sweep (above) for lapses during long-lived connections.

Viewer connections are never gated. E2EE and message relaying are untouched; the
relay learns only `deviceId ↔ license key` and trial timestamps.

### Configuration (env, fail-loud like `METRICS_TOKEN`)

| Variable | Default | Meaning |
|---|---|---|
| `LEMONSQUEEZY_STORE_ID` | unset | Both set → licensing enabled. Both unset → unrestricted. Exactly one set → `fatalError` at boot. |
| `LEMONSQUEEZY_PRODUCT_ID` | unset | (see above) |
| `TRIAL_DAYS` | 7 | Trial length |
| `LICENSE_REVALIDATE_HOURS` | 24 | Max verdict cache age before lazy revalidation |
| `LICENSE_GRACE_DAYS` | 7 | How long a previously-valid key survives LS being unreachable |

### Storage (`licensing.json`)

```json
{
  "trials":      { "<deviceId>": { "startedAt": "…" } },
  "activations": { "<deviceId>": { "licenseKey": "…", "instanceId": "…",
                                    "verdict": "active", "lastValidatedAt": "…",
                                    "expiresAt": "…" } }
}
```

### Metrics

New counters on `MetricsService`: trial starts, activations, deactivations,
validation failures (by reason), blocked pairing attempts, blocked/swept
connections. Surfaces the conversion funnel on the existing Grafana dashboard.

## Wire protocol changes (`ClaudeSpyNetworking`)

- `LicenseStatus` model: `state` (`trial(expiresAt)` / `active(expiresAt?)` /
  `expired` / `none`) plus activation info for UI.
- New error code `subscriptionRequired` (pairing response + host WS error).
- New message `hostSubscriptionInactive` sent to viewers of a blocked host so the
  iOS/viewer UI can explain the disconnect. Carries no session content.
- All new fields optional / `decodeIfPresent` for cross-host version skew (paired
  Macs on different builds).

## Mac app changes (`ClaudeSpyServerFeature`)

- **`LicensingClient`** `@DependencyClient` wrapping the three relay endpoints;
  `inMemory()` test value. License key + instance id stored in Keychain alongside
  the existing E2EE material.
- **`RemoteAccessSettingsView` License section:**
  - Status line: "Trial — 5 days left" / "Active" / "Expired".
  - License key field + **Activate** button (surfaces LS activation-limit errors:
    "All 3 Macs used — deactivate one or manage your subscription").
  - **Buy** — opens the LS hosted checkout in the browser (no marketing site needed
    at launch).
  - **Manage subscription** — LS customer billing portal (card changes, cancel; LS
    emails the customer a magic link).
  - Both URLs are constants in the Mac app (they change rarely; an app update is an
    acceptable cost to change them).
  - **Deactivate this Mac** — frees an activation slot for Mac migration.
- **Typed-error UX:** `subscriptionRequired` renders a clear banner with a Subscribe
  button instead of a generic connection error.
- **Trial expiry alerts:** when `LicenseStatus` is `trial`, the app schedules local
  checks against `expiresAt` and fires a desktop notification at **48h remaining**
  and **24h remaining** — each once (flags persisted keyed to the trial's
  `expiresAt`, so relaunches don't re-alert). A threshold crossed while the app was
  closed fires on next launch. Clicking opens Remote Access settings. Uses the
  existing desktop-notification infrastructure.

## iOS app changes (`ClaudeSpyFeature`)

Deliberately minimal: render `hostSubscriptionInactive` as "Host's subscription
expired" on the affected host row instead of a mute disconnect. No purchase UI, no
checkout links, no pricing anywhere — the iOS app stays a free client with nothing
for App Store review to object to.

## Lemon Squeezy setup (manual, dashboard)

1. Store + one subscription product, two variants: $5/month, $50/year.
2. Enable license keys on the product: activation limit 3, key expires with the
   subscription.
3. Create capped 100%-off-forever discount codes for early testers.
4. Full dry run in LS **test mode**: test-card purchase → key email → activate →
   validate → cancel → key expires. Verify a 100%-off subscription checkout skips
   card entry and still creates the subscription + key (LS changed this behavior
   historically — verify before distributing tester codes).

## Rollout (each step independently safe)

1. **Deploy relay** with licensing code, env unset → no behavior change (verify:
   existing E2E suite green against it).
2. **Ship the app update** (Mac + iOS) that understands `LicenseStatus`, the license
   UI, and the typed errors. `decodeIfPresent` keeps old/new peers compatible.
3. **Enable licensing** on the hosted relay (set the two LS env vars) and bump
   `VersionCompatibility`'s minimum so stale hosts get the existing upgrade prompt
   rather than opaque errors. Every active user starts their 7-day trial at first
   post-enable connect — de facto notice period.

## Testing

- **`LicensingServiceTests`** (stubbed LS client): trial auto-start and expiry; 24h
  revalidation cadence; 7-day unreachable grace; immediate block on
  `expired`/`disabled`; store/product mismatch rejection; activation-limit error
  mapping; licensed-beats-trial resolution; persistence round-trip.
- **Controller tests** for the three endpoints and both enforcement points
  (blocked host → typed errors; viewer unaffected).
- **E2E:** existing suite runs with licensing disabled — must stay green untouched.
  One new scenario via the e2e-for-feature skill during implementation: licensing
  enabled against a stub LS server — trial banner → trial expired → blocked pairing
  with the subscribe banner → activate → connected.
- **Manual:** the LS test-mode dry run above, plus one real production purchase +
  refund before launch.

## Docs to update during implementation

- `self-hosting.md`: note that licensing is disabled by default and self-hosts need
  no configuration.
- `monitoring.md`: new metrics.
- `CLAUDE.md` reference entry per the PR checklist.

## Out of scope (explicitly)

- Apple in-app purchase, user accounts, teams/seats, webhooks-driven entitlement,
  relay-side comp keys, a marketing website, per-viewer pricing, usage-based limits.
