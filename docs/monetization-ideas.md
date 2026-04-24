# Monetization Ideas — Issue #392

Brainstorming document. No decisions here, just possibilities and trade-offs.

## The problem

From issue #392:

1. Keep everything free by default.
2. **Our hosted relay** (claudespy.gustavo.eng.br) should require a subscription when used from iOS.
3. Ideally, the **Mac app** should also require a subscription when connecting to any **remote** (non‑self‑hosted) server.
4. The Mac app is **not on the App Store**, so purchases must happen via iOS IAP.
5. We need some way for the Mac app to verify a user has a valid iOS subscription.

## What exists today (grounding)

- **No accounts.** Identity is `pairId` + `deviceId`. A `Pair` links one Mac to one iOS device.
- **No DB.** `PairingService` persists to `pairs.json` in `DATA_DIRECTORY`.
- **No auth.** Mac and iOS connect to the relay with query‑params (`pairId`, `deviceType`, `deviceId`). If the `pairId` exists in `activePairs`, the WebSocket is admitted.
- **Configurable server URL** on both platforms. Self‑hosting is fully supported and documented.
- **No StoreKit anywhere.** Greenfield.
- **E2EE already in place.** Public keys are exchanged during pairing — useful for signing.

Implication: the cheapest monetization surface is the **relay itself**. We already own it, it already knows every `Pair`, and we can gate WebSocket admission on an entitlement check without touching the clients' trust model.

---

## Dimension 1 — What are we actually selling?

Before picking a mechanism, the "what" matters more than the "how."

### 1A. Access to our hosted relay
"Pay to not run your own server." This is the purest version and aligns with running costs. Self‑hosted stays free forever.
- **Pro:** No artificial feature gating. Price tracks real cost.
- **Pro:** Self‑hosters — who are saving us money — get everything.
- **Con:** Power users will run their own relay; easy bypass for the technical crowd.

### 1B. Access to our hosted relay + "premium" features
Same as 1A but gate some features behind the subscription regardless of server (e.g., push notifications, multi‑device, file browser, history/replay).
- **Pro:** Reduces self‑host bypass incentive.
- **Con:** Penalizes the "run your own infra" crowd, who are the exact audience that will evangelize the product.
- **Con:** Every feature gate adds branching in `ClaudeSpyFeature` and `ClaudeSpyServerFeature`.

### 1C. Freemium on the relay — limits, not features
Free tier on the hosted relay: 1 pair, N minutes/day, no push. Subscription lifts limits.
- **Pro:** People can try the full UX without friction.
- **Con:** Needs quota tracking in the relay (new infra).
- **Con:** "Time‑limited" feels user‑hostile for what is essentially a monitoring tool.

### 1D. Tip‑jar / optional support
Keep everything free, accept "Support Development" subscriptions with no behavioral change.
- **Pro:** Zero friction, zero bypass.
- **Con:** Almost certainly doesn't pay for server costs.
- **Con:** Doesn't address "how to fund the hosted relay" at all.

### 1E. Pay‑once "founder" license + subscription later
First 500 (or N) users get lifetime access at a flat price. New users subscribe.
- **Pro:** Good early‑adopter signal; fundraises a cushion.
- **Con:** SaaS cost base grows; a few thousand founders is permanent liability.
- **Best combined** with another approach (e.g., founder = 3 years, then subscribe).

### 1F. Hybrid — subscription for hosted relay, one‑time for "Pro features"
Hosted relay is a subscription (ongoing cost). Feature unlocks (file browser, history, themes) are one‑time purchases on iOS.
- **Pro:** Matches value to cost model (service = recurring, software = one‑time).
- **Con:** More SKUs, more surface area.

### 1G. Usage‑based pricing
Per‑device‑pair/month, per‑hour‑of‑connected‑time, per‑session.
- **Pro:** Fair.
- **Con:** Awful UX for a consumer tool. Don't.

**My lean:** 1A with an optional 1F layer once there's traction. Keep ideology consistent: "you pay because we host your relay, not because we locked off code."

---

## Dimension 2 — How does the Mac verify iOS entitlement?

This is the thorny part. Four fundamentally different shapes.

### 2.1. Server‑side entitlement keyed by `pairId` ⭐
- iOS buys subscription via StoreKit 2.
- iOS sends `JWSTransaction` (signed by Apple) to our relay.
- Relay verifies with Apple's App Store Server API.
- Relay writes `entitled: true` (+ expiry) onto the `Pair` record in `pairs.json`.
- On WebSocket connect, relay checks `Pair.entitled` for the `pairId`. If false, reject or downgrade.
- **Mac does nothing.** It just gets a clean "not entitled" close code from the server.

Pros:
- Works with existing pair‑based identity — no accounts needed.
- The server (our single source of truth about who's paid) is also the enforcer.
- Bypass impossible without breaking Apple receipt signing.
- Offline flow is fine: Apple verifies once, server caches entitlement until expiry.

Cons:
- Adds server‑side Apple verification (App Store Server API client).
- Need App Store Server Notifications (v2) webhooks for refunds/cancellations/renewals.
- Per‑pair model means "I re‑paired my Mac" should carry the subscription over. See §3.

This is the path that matches the existing architecture most naturally.

### 2.2. Signed JWT issued by server, forwarded through pairing
- Same purchase flow as 2.1, but server issues a short‑lived JWT with the entitlement claim.
- iOS forwards the JWT to the Mac over the E2EE pairing channel.
- Mac sends JWT on WebSocket connect (or verifies it locally against server's public key to show UI state).
- Server re‑validates on every connect anyway.

Pros:
- Lets the Mac *display* entitlement state (greyed‑out feature badges, "Subscribed via user@example.com", etc.) without a separate API round‑trip.
- Re‑uses the existing E2EE channel for the handoff.

Cons:
- JWT rotation/refresh adds complexity over 2.1.
- Mostly a UI nicety — the server still has to enforce on connect.

Probably a v2 layer over 2.1, not an alternative.

### 2.3. Add accounts (email + magic link)
- User creates account on iOS, buys subscription, links account to all paired Macs.
- Mac app signs in via magic link to email.
- Entitlement lives on the account, not the pair.

Pros:
- Familiar model ("my subscription follows me").
- Handles device replacement cleanly.
- Useful for future team/org features.

Cons:
- Large architectural change: introduces user accounts to a system that has carefully avoided them.
- Requires email infra (SMTP, deliverability, bounce handling) or a third‑party (Resend, Postmark).
- E2EE key management suddenly has to consider "two Macs on one account" semantics.
- Not required for the stated problem.

Only worth it if accounts are coming anyway for other reasons (teams, shared sessions).

### 2.4. RevenueCat (or Glassfy) as a middleware
- iOS uses RevenueCat SDK for StoreKit.
- RevenueCat webhooks push entitlement changes to our server.
- Server stores entitlement, exposes "is `pairId` entitled?" endpoint.

Pros:
- RC handles receipt validation, renewal, grace periods, family sharing, refunds, analytics.
- Cross‑platform ready if we ever ship Android / Windows.
- Free below 2.5k MTR.
- Significantly less code to write.

Cons:
- Dependency on a third‑party service (SPOF, privacy surface).
- Their cut above the threshold.
- Still need to bind RC `appUserID` to our `pairId`.

**Real lean:** Start with RevenueCat (option 2.4) unless there's a reason not to. Reduces time‑to‑first‑dollar and handles the boring receipt‑validation edge cases that eat weeks.

---

## Dimension 3 — The "subscription follows what?" question

A subscription is a logical thing. It needs to attach to a physical thing.

### 3.1. Per‑pair
One subscription = one Mac↔iOS pair. Re‑pairing re‑binds.
- Simple. Matches existing architecture.
- Penalizes users who re‑pair often (new Mac = lose subscription unless we handle transfer).
- Needs explicit "transfer subscription" UI.

### 3.2. Per‑Apple‑ID (implicit via StoreKit)
StoreKit transaction is tied to the Apple ID that bought it. As long as that Apple ID is signed in on iOS, IAP works. New iPhone = same Apple ID = sub restored via "Restore Purchases."
- Natural for iOS.
- For Mac: Mac doesn't have the Apple ID directly. So we still need to bridge Mac→iOS entitlement somehow (back to §2).

### 3.3. Per‑Mac (i.e., `deviceId`)
Subscription grants N Mac `deviceId`s. Allows power users with multiple Macs.
- Needs a claim/release UI (similar to Spotify device management).
- Easy to game unless we cap.

### 3.4. "As many Macs as you want, as long as they pair with this iOS"
Subscription belongs to the iOS account; any Mac paired with that iOS inherits entitlement for the lifetime of the pairing.
- Simple model to explain.
- "Free" for users with many Macs.
- Might be too generous, but is the cleanest UX.

**My lean:** 3.4, capped softly at some large number (e.g., 5 concurrent paired Macs). Most users have 1–2 Macs; enforcing "one" is fighting reality. Spotify‑style device swap if we ever hit the cap.

---

## Dimension 4 — Enforcement point and degradation mode

Where does the "nope, subscribe" signal happen?

### 4.1. At WebSocket admission
Server rejects the connection with a specific close code/reason. Mac shows a "Subscribe on iPhone" sheet.
- Cleanest. Can't be bypassed by client patching because the *server* controls it.
- But "can't connect at all" is the hardest stop — consider UX.

### 4.2. At a feature boundary (soft gate)
Connection succeeds but, say, remote keystrokes or file browser payloads are dropped server‑side for unentitled pairs.
- Lets the user see their terminal — good "free trial of the core UX."
- More gate points = more code.

### 4.3. Read‑only / time‑limited
Unentitled connects get 15 minutes/day of interactive use, unlimited read‑only.
- Generous free tier. Great for word‑of‑mouth.
- Quota tracking infra required.

### 4.4. Grace periods and expiry handling
- Lapsed subscription: 7 days of full access with in‑app nag.
- Billing retry: Apple handles automatically for auto‑renewing subs.
- Cancellation: user keeps access until period end (App Store default).

**Lean:** 4.1 for iOS (app‑level check before even connecting) + 4.2 selectively on the relay for defense in depth.

---

## Dimension 5 — Self‑hosting stays free. Period.

The issue's spirit and the project's identity demand this. Implications:

- Self‑hosters run the full `ClaudeSpyExternalServer` Docker image with **no entitlement check**.
- Official hosted server has the entitlement gate compiled in (or enabled via env var `ENTITLEMENT_CHECK=1`).
- Same codebase, feature flag.
- iOS app detects "is server URL ours?" via either (a) a hardcoded list of official hostnames or (b) server capability ping (`GET /api/capabilities` returns `{"enforces_entitlement": true}`).
- If the server doesn't enforce entitlement, iOS doesn't bother offering the subscription.

This also neatly handles "Mac connecting to remote server" from the issue: if it's our server, the server gates. If it's self‑hosted, user already owns it.

---

## Dimension 6 — Pricing sketches

(All wildly speculative — would need real user research.)

### 6.1. Simple
- **Free:** self‑hosted.
- **Pro:** $3.99/mo or $29.99/yr — unlimited use of hosted relay, unlimited paired Macs.
- **Founder:** $79 lifetime (first 500 users, limited window).

### 6.2. Tiered
- **Free:** self‑hosted.
- **Lite:** $1.99/mo — hosted relay, 1 Mac, no push.
- **Pro:** $4.99/mo — everything.

### 6.3. Yearly‑only
- **Free:** self‑hosted.
- **Pro:** $24/yr. No monthly. Reduces churn infra and "forgot I was paying" bad PR.

### 6.4. "Pay what you can"
Three price points ($1.99, $3.99, $7.99) for the same entitlement. Works for indie devs (Overcast‑style).

**Family Sharing** should be enabled (Apple setting on the IAP) — low cost, good will.

---

## Dimension 7 — Anti‑abuse and bypass surface

Honest about the attack surface:

- **Mac app is open source.** Any "is subscribed" check on the Mac can be patched out. Don't bother — put enforcement on the server.
- **Sharing pair codes** on social media: someone pairs, subscribes, posts their `pairId`. Others pair‑and‑replace? → re‑pairing flow must invalidate the old pair's entitlement, not duplicate it.
- **Refund abuse:** Apple receipts include refund info; server must honor refund webhooks and revoke.
- **Sandboxed receipts / TestFlight:** Server must accept sandbox receipts in Debug builds, reject in Release. Apple documents both environments.

None of these are blockers; just TODO items on whichever path is picked.

---

## Dimension 8 — Implementation phases (if we pick path A)

If we go with "relay gate + per‑pair entitlement + RevenueCat" (a plausible winner), rough phasing:

### Phase 0 — non‑breaking infrastructure
- Add `entitled: Bool` and `entitlementExpiresAt: Date?` to `Pair` model.
- Add `/api/capabilities` endpoint returning `{ enforces_entitlement, hosts }`.
- Default: `enforces_entitlement = false` in config. Behavior unchanged.

### Phase 1 — iOS purchase flow
- StoreKit 2 + RevenueCat SDK.
- "Subscribe" screen visible only when connected to a server that `enforces_entitlement`.
- On purchase, iOS sends `transactionID` + `pairId` to server.
- Server verifies with Apple (via RevenueCat webhooks) and sets `Pair.entitled`.

### Phase 2 — relay enforcement
- Flip `ENTITLEMENT_CHECK=1` on our production relay.
- WebSocket admission checks `Pair.entitled`. Unentitled connections close with code `4401 Subscription Required`.
- iOS shows paywall on 4401. Mac shows "Subscribe on iPhone to use this relay."

### Phase 3 — restore / transfer
- "Restore Purchases" on iOS (StoreKit standard).
- Re‑pairing carries entitlement if the same iOS device (Apple ID) is re‑pairing.
- Multiple Mac support (5 paired Macs per subscription) already works because the sub is on the Apple ID side.

### Phase 4 — optional: founder pricing, annual, family sharing
- Add additional SKUs, promo codes.
- Introductory offer / free trial via StoreKit configuration.

---

## Open questions that need opinions

1. **Must Mac also require subscription to connect to our relay, or only iOS?** The issue says "ideally." If the relay enforces per‑pair entitlement, then *if the iOS side of the pair is subscribed*, the Mac side automatically gets access — i.e., it's free‑rider‑free without extra logic. Does that satisfy "Mac requires sub for remote server"?
2. **Cap on paired Macs per subscription?** Pick a number and move on. Suggest 5.
3. **What happens to existing pairs when we ship this?** Grandfather everyone who paired before date X? Or free trial until date Y? Or just turn it on?
4. **Self‑hoster messaging:** how visible is "subscribe" in the iOS UI when connected to a self‑hosted server? Probably invisible. Confirm.
5. **Refunds — full or prorated?** Apple auto‑refund windows are short; match them.
6. **Free trial?** 7 days is standard. Requires StoreKit offer configuration.
7. **Pricing model 6.1 vs 6.2 vs 6.3?** Need to pick a floor/ceiling to even talk to App Store Connect.
8. **Is RevenueCat acceptable as a dependency?** Alternative is rolling our own receipt validator (more code, fewer webhooks).
9. **Where do we stand on "lifetime founder" SKUs?** Fun for early traction, dangerous for long‑term cost base. Time‑boxed lifetime ("unlimited for 3 years") is a middle ground.

---

## Non‑ideas / explicitly rejected

- **Obfuscating or license‑checking the Mac app.** Open source; bypass is trivial; don't waste effort.
- **Per‑session micropayments.** UX disaster for a monitoring tool.
- **Ad‑supported tier.** Inappropriate for a dev‑facing utility.
- **Selling user data.** Obviously no, but worth stating.
- **Forking into "Pro" and "Open Source" builds.** One codebase, flag‑gated behavior.

---

## Suggested path forward

If forced to pick one direction for follow‑up discussion, in order of preference:

1. **Dim 1A × Dim 2.4 (RevenueCat) × Dim 3.4 (one sub, many Macs) × Dim 4.1 (relay admission) + Dim 5 (self‑host always free).**
2. Same, but Dim 2.1 (roll our own Apple receipt check) instead of RevenueCat if third‑party dependency is a dealbreaker.
3. Hybrid 1F (subscription for relay + one‑time for niche "Pro" features) once there's baseline traction.

But again: this doc is a map of possibilities, not a decision. Read, push back, narrow.
