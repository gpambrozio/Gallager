# Monetization Plan — Issue #392

Concrete plan based on decisions from the brainstorming doc (`docs/monetization-ideas.md`). This doc is the "what we're doing." Read the ideas doc for "what else we considered."

## TL;DR

Subscription gates access to our hosted relay (`claudespy.gustavo.eng.br`). Self‑hosted relays stay free forever. iOS buys the subscription via StoreKit. Entitlement is per‑pair: if the pair's iOS side has an active sub, both ends of the pair can use our relay. RevenueCat manages receipts, renewals, webhooks. No grandfathering at launch, no founder SKU, single Pro tier, 7‑day free trial.

## Decisions

| Dimension | Decision |
|---|---|
| What gets sold | Access to our hosted relay. Self‑hosted = free forever. |
| Tier structure | **One SKU**: Pro monthly + Pro yearly, same entitlement. |
| Price | **Pro**: $3.99/mo or $29.99/yr (placeholder — finalize in App Store Connect). |
| Free trial | **7 days**, StoreKit introductory offer. |
| Founder / lifetime | **None.** |
| Entitlement binding | **Per pair.** iOS subscription entitles the whole pair. |
| Mac cap per subscription | **3 Macs** concurrently paired. |
| Receipt validation | **RevenueCat** SDK (iOS) + webhooks → our relay. |
| Enforcement point | **Relay WebSocket admission.** |
| Grandfathering | **None.** Everyone subscribes at launch. |
| Self‑host UI in iOS | **"Support Development"** link only — no paywall. |
| Family Sharing | Enabled on the IAP. |
| Refunds | Honored via RevenueCat webhook. Apple's auto‑refund windows apply. |

## Architecture

### Identity model (unchanged)

Everything keys off `pairId`. No user accounts introduced. A `Pair` is extended with entitlement fields:

```swift
// ClaudeSpyNetworking/Models/Pair.swift (server)
struct Pair: Codable {
    // existing fields...
    var entitled: Bool = false
    var entitlementExpiresAt: Date?
    var entitlementSource: EntitlementSource = .none  // .revenueCat, .none
    var revenueCatAppUserID: String?                   // binding to RC user
}
```

### How `pairId` ↔ RevenueCat `appUserID` bind

- On first pairing completion, iOS generates (or reuses) a RevenueCat `appUserID`. Simplest: use the iOS `deviceId` UUID, which we already generate.
- iOS sends `{pairId, revenueCatAppUserID}` to relay via authenticated pairing endpoint after both devices have exchanged keys.
- Relay stores `Pair.revenueCatAppUserID` so webhook events from RevenueCat can locate the right pair.
- One `appUserID` can back multiple `pairId`s (user has 3 Macs paired). Relay counts and enforces the 3‑Mac cap.

### Purchase flow

```
iOS: [Subscribe] → StoreKit (via RevenueCat SDK)
     → Apple processes payment
     → RevenueCat receives transaction
     → RevenueCat sends INITIAL_PURCHASE webhook to our relay
     → Relay marks every Pair with matching revenueCatAppUserID as entitled=true
     → iOS queries relay /api/pair/:pairId/entitlement → shows entitled UI
     → Mac's next WebSocket reconnect is admitted
```

### Admission check

```
Mac/iOS opens WebSocket: wss://.../api/ws?pairId=X&deviceType=Y
Relay handshake:
  1. Validate pairId exists in activePairs                 → 404 if not
  2. If ENFORCE_ENTITLEMENT && !Pair.entitled              → close 4401
  3. Otherwise admit as today
```

Close code `4401 Subscription Required` is handled by both clients to show the appropriate UI:

- **iOS**: show paywall (RevenueCat paywall component).
- **Mac**: show "Your paired iPhone needs an active ClaudeSpy Pro subscription to use our hosted relay. Open ClaudeSpy on iPhone to subscribe or switch to a self‑hosted relay in Settings → Remote Access."

### Self‑hosted servers don't enforce

Relay exposes:

```
GET /api/capabilities
→ { "enforces_entitlement": true, "host": "claudespy.gustavo.eng.br" }
```

iOS calls this after setting server URL. If `enforces_entitlement = false`:

- No paywall is shown.
- "Support Development" link appears in Settings, taking the user to the same RevenueCat Pro subscription (purely voluntary; no UI change on purchase other than a thank‑you).

Self‑hosters who *do* subscribe for sponsorship purposes still get their webhook into our relay; the server just doesn't act on it for their own relay.

### Mac cap enforcement

- When a Mac WebSocket connects and is admitted, relay records `(pairId, deviceId, connectedAt)` against the `revenueCatAppUserID`.
- If a **4th distinct Mac** for that `appUserID` tries to connect, relay closes with `4402 Device Limit Reached`.
- Mac shows "You have 3 Macs already using this subscription. Unpair one in ClaudeSpy on iPhone → Paired Devices, then try again."
- Soft: active connections are preferred over idle; last‑seen inactive for 30 days drops from the count.

## Implementation phases

### Phase 0 — non‑breaking infra (no user‑visible change)

Ship these unconditionally; entitlement enforcement is off by default.

- Extend `Pair` model with `entitled`, `entitlementExpiresAt`, `entitlementSource`, `revenueCatAppUserID`. Default: `entitled = false`.
- Add `/api/capabilities` endpoint returning `enforces_entitlement` from env var.
- Add `/api/pair/:pairId/entitlement` GET endpoint (iOS polls after purchase).
- Add `/api/revenuecat/webhook` POST endpoint (signature‑verified).
- Env var: `ENFORCE_ENTITLEMENT=0` on our prod relay for now.

Deploy. Migration is zero‑downtime — new fields default to false; unentitled pairs are admitted because enforcement is off.

### Phase 1 — iOS purchase flow

- Add RevenueCat SDK to iOS.
- Add StoreKit configuration (`.storekit` file) + App Store Connect product: `com.gustavoambrozio.claudespy.pro.monthly` and `...pro.yearly`.
- RevenueCat dashboard: Pro entitlement, two products bound to it, 7‑day intro offer.
- iOS: `SubscriptionService` (new, `@DependencyClient`, conforms to `DependencyKey`) wrapping RevenueCat's `Purchases`.
- iOS: Settings → Subscription screen. Displays entitlement status, buttons for Subscribe / Manage / Restore.
- iOS: capability ping on server URL change. Hides Subscribe UI if `enforces_entitlement = false`; swaps in "Support Development" link.
- iOS: after purchase, POST `{pairId, revenueCatAppUserID}` to relay to bind.

At this point, paying users exist and RevenueCat webhook is flipping `Pair.entitled = true` on the relay. Nothing is enforced yet — purchases are "pre‑launch pledges."

### Phase 2 — relay enforcement flip

- Pick a date. Announce in release notes and in iOS in‑app banner ("Starting 2026‑MM‑DD, the hosted relay will require a subscription. Free trial available.").
- Flip `ENFORCE_ENTITLEMENT=1` on production.
- Mac close‑code 4401 handling ships in the release before the flip.
- iOS paywall UX ships in the release before the flip.

All pre‑launch users who haven't subscribed hit the paywall on that date. No grandfather.

### Phase 3 — Mac device cap

- Per‑appUserID device tracking in the relay (`Dictionary<String, [DeviceEntry]>` with `lastSeenAt`).
- `4402 Device Limit Reached` close code + Mac UI.
- iOS "Paired Devices" view already exists — add an "Unpair" action that also triggers server‑side cleanup.
- Eviction: Macs not seen for 30 days auto‑drop from the count.

### Phase 4 — polish

- Grace period: if RevenueCat reports `BILLING_ISSUE`, keep entitlement for 7 days.
- Restore Purchases button on iOS.
- Handle refunds: RevenueCat `CANCELLATION` webhook with `cancel_reason: REFUND` → set `entitled = false` immediately.
- Sandbox receipts allowed in Debug/TestFlight only.
- Family Sharing tested.

## Files touched (rough)

- **Server** (`ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/`):
  - `Models/Pair.swift` — entitlement fields.
  - `Services/PairingService.swift` — device count tracking, entitlement lookup.
  - `Services/EntitlementService.swift` — **new** — RevenueCat webhook handling, entitlement writes.
  - `Routes/WebSocketController.swift` — admission check, 4401/4402 close codes.
  - `Routes/CapabilitiesController.swift` — **new**.
  - `Routes/EntitlementController.swift` — **new** — `/api/pair/:pairId/entitlement`, `/api/pair/:pairId/bind-appuser`.
  - `Routes/RevenueCatWebhookController.swift` — **new**.
  - `Configuration.swift` — `ENFORCE_ENTITLEMENT`, `REVENUECAT_WEBHOOK_SECRET` env vars.

- **iOS** (`ClaudeSpyPackage/Sources/ClaudeSpyFeature/`):
  - `Services/SubscriptionService.swift` — **new**, `@DependencyClient` wrapping RevenueCat.
  - `Services/CapabilitiesService.swift` — **new**, pings `/api/capabilities`.
  - `Views/Settings/SubscriptionView.swift` — **new**.
  - `Views/Settings/SupportDevelopmentView.swift` — **new**, shown for self‑hosted.
  - `Models/IOSSettings.swift` — cache last known server capabilities.
  - Networking layer — handle `4401`/`4402` close codes and route to paywall.

- **Mac** (`ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/`):
  - Networking layer — handle `4401`/`4402` close codes with a user‑facing banner.
  - `Views/Settings/RemoteAccessView.swift` — existing; add subscription status display sourced from server.

- **Shared** (`ClaudeSpyPackage/Sources/ClaudeSpyNetworking/`):
  - `Models/Pair.swift` — entitlement fields.
  - `Models/WebSocketCloseCodes.swift` — **new** — canonical close codes.
  - `Models/Capabilities.swift` — **new**.

## Non‑goals / out of scope

- No user accounts (email, password, magic link).
- No "Pro features" feature gating. Every feature is in every build; only access to our hosted relay differs.
- No team / org / shared sessions.
- No web dashboard for subscription management — Apple's subscription management is the only surface.
- No Android / Windows client support.
- No obfuscation or client‑side license checks — all enforcement is server‑side.
- No promo codes or affiliate program in v1.

## Risks and open work

- **RevenueCat dependency.** If they go down or get acquired, our entitlement pipeline breaks. Mitigation: cache `Pair.entitled` with `expiresAt` on the relay; a RevenueCat outage doesn't revoke entitlement until expiry.
- **First‑pair binding race.** User subscribes on iOS *before* first Mac pairing exists. Solution: RevenueCat binds to `appUserID` (iOS `deviceId`); relay applies entitlement on any future pair that registers with the same `appUserID`.
- **Re‑pairing scenarios.** User re‑pairs Mac with a new `pairId`. Since entitlement is keyed on `appUserID`, the new pair inherits entitlement automatically. The old pair's `entitled` flag is irrelevant once unpaired.
- **Launch announcement timing.** Announce at least 30 days before Phase 2 flip, via release notes and in‑app banner.
- **App Store review of "Support Development"** for self‑hosted users. Apple sometimes flags this ("purchase that doesn't unlock anything"). Frame it as a supporter tier with a cosmetic badge or acknowledgement to avoid rejection. TBD if cosmetic needs to be concrete (e.g., name in About screen credits).
- **Price localization.** Use App Store Connect's automatic price tier localization.
- **Sandbox testing plan.** Need TestFlight build path where sandbox receipts are accepted by the relay's webhook endpoint.

## What to decide before Phase 1 starts

- Final prices in App Store Connect tiers.
- RevenueCat account + project setup.
- "Support Development" concrete value prop — just a thank‑you, or a credits list, or a cosmetic UI element?
- Exact text of the paywall and the close‑code 4401 Mac banner.
- Launch announcement date for Phase 2.

## Reference

- Ideas considered and rejected: `docs/monetization-ideas.md`.
- Existing pairing architecture: `ClaudeSpyPackage/Sources/ClaudeSpyExternalServerLib/Services/PairingService.swift`.
- Existing server settings: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Models/Settings.swift`.
- Self‑hosting docs: `docs/self-hosting.md`.
