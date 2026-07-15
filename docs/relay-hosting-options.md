# Relay Hosting — Right-Sizing & Alternatives

Status: investigation, 2026-05-08
Owner: Gustavo

The `claudespy-relay` Vapor container is currently co-located on `hetzner1.gustavo.eng.br` (Hetzner Cloud, 2 vCPU / 7.6 GiB / 75 GB) alongside `cleancast` and the `sot` stack. This document captures the relay's actual resource footprint, evaluates cheaper hosts, and recommends a path forward.

## TL;DR

- The relay is genuinely tiny: **~17 MiB RSS, <0.05 core average, peak 17 msg/s, peak 17 WS connections.**
- It is wildly over-provisioned on a CCX13-class box. The reason `hetzner1` is sized that way is `cleancast`, not the relay.
- **Recommended:** split the relay onto its own **Hetzner CPX11 in Ashburn (~$8.23/mo)**. Same datacenter, no latency regression, no Docker rebuild, full isolation from `cleancast` OOM storms.
- The cheaper-looking CAX11 ARM (€3.79/mo) and CX22 (€4.49/mo) are **not available in any US datacenter** — EU-only (Falkenstein, Nuremberg, Helsinki). Picking one would add ~80–100 ms RTT for a Brazil-based operator and any Americas-side users.
- Down the line, if `cleancast` is tuned to <3 GB, `hetzner1` itself can collapse onto a smaller CPX/CCX class and save ~€8–10/mo.

## 1. Resource footprint (hard data, last 7 days)

| Metric | Value | Source |
|---|---|---|
| RSS (steady state) | **17 MiB** | `docker stats` |
| Image size | 409 MB virtual | `docker ps --size` |
| CPU avg | well under 0.05 core | host total ≈ 0.5 core, mostly cleancast/sot |
| Avg message rate | 0.65 msg/s | `claudespy_messages_relayed_total` |
| Peak message rate (5 m avg) | 17.3 msg/s | `claudespy_messages_relayed_total` |
| Peak active pairs | 10 | `claudespy_active_pairs` |
| Peak WS connections | 9 host + 8 viewer = 17 | `claudespy_ws_connections` |
| Peak host RX | 9.5 MB/s ≈ 76 Mbps (whole host, includes cleancast/sot) | `node_network_receive_bytes_total` |
| Peak host TX | 1.9 MB/s ≈ 15 Mbps (whole host) | `node_network_transmit_bytes_total` |

Working budget for a relay-only box: **256 MB RAM / 1 shared vCPU / ~5 GB disk** is plenty. Anything 1 GB+ is luxury and exists only to leave headroom for Caddy + node_exporter + alloy.

## 2. Current host

- **Plan:** likely **Hetzner CCX13** (2 dedicated vCPU, 8 GB, 80 GB) — confirm in Hetzner console
- **Region:** Ashburn (US East), IP `5.78.133.140`
- **Price:** ≈ **€14–16/mo** post April 2026 adjustment
- **Workload:** `claudespy-relay` + `cleancast-api-1` (5 GB cgroup) + `sot-app/db/cron/minio` (~180 MB) + `alloy` + `node_exporter`
- **Utilization:** relay is <1% of capacity; cleancast is the reason the box is this size.

## 3. Two strategies

### Strategy A — Split the relay onto its own tiny VPS (recommended)

Keep `hetzner1` as-is for cleancast/sot. Move the relay (Vapor + Caddy + alloy) to a fresh ~$8/mo instance. **Marginal cost: ~$8/mo. Benefit: ClaudeSpy becomes architecturally immune to cleancast-induced host pressure.**

#### Hetzner Cloud — region matters

Hetzner has three families and they are not all available everywhere. As of May 2026:

| Series | Arch | Availability | Notes |
|---|---|---|---|
| **CAX** (Ampere ARM) | ARM64 | **EU only** — Falkenstein, Nuremberg, Helsinki | Cheapest per spec but no US DC |
| **CX** (cost-optimized shared x86) | x86 | **EU only** — same three EU sites | Cheapest x86 but no US DC |
| **CPX** (AMD shared x86) | x86 | EU + **Ashburn US** + **Hillsboro US** + Singapore | Available globally; ~70-90% premium over CX |
| **CCX** (dedicated vCPU x86) | x86 | EU + Ashburn + Hillsboro + Singapore | Today's `hetzner1` is a CCX13 |

So if the goal is "stay in Ashburn for low Brazil latency", the floor is CPX11.

#### Plan comparison

| Provider | Plan | Arch | RAM | vCPU | Disk | Egress | Region | Price |
|---|---|---|---|---|---|---|---|---|
| **Hetzner Cloud** | **CPX11** | x86 AMD | 2 GB | 2 shared | 40 GB | 20 TB | **Ashburn US** | **~$8.23 / mo** |
| Hetzner Cloud | CAX11 | ARM64 | 4 GB | 2 ARM | 40 GB | 20 TB | EU only | €3.79 / mo (~$4) |
| Hetzner Cloud | CX22 | x86 | 4 GB | 2 shared | 40 GB | 20 TB | EU only | €4.49 / mo (~$4.85) |
| Netcup | VPS 250 G11 | x86 | 4 GB | 2 | 60 GB | unmetered | Nuremberg | €3.99 / mo |
| Vultr | Cloud Compute | x86 | 1 GB | 1 | 25 GB | 1 TB | many incl. US East | $5 / mo |
| Linode (Akamai) | Nanode 1 GB | x86 | 1 GB | 1 | 25 GB | 1 TB | many incl. US East | $5 / mo |
| DigitalOcean | Basic Droplet | x86 | 1 GB | 1 | 25 GB | 1 TB | many incl. NYC/SFO | $6 / mo |
| Vultr | IPv6-only | x86 | 512 MB | 1 | 10 GB | 0.5 TB | some | $2.50 / mo ⚠ |
| Oracle Cloud | Ampere A1 always-free | ARM64 | 24 GB | 4 ARM | 200 GB | 10 TB | Ashburn | $0 ⚠ |
| Fly.io | shared-cpu-1x always-on | x86 | 256 MB | 1 | tiny | $0.02/GB | global | ~$2/mo + $2 IPv4 + traffic |

**Recommendation: Hetzner CPX11 in Ashburn, ~$8.23/mo.**

Why:
- Same provider, same datacenter as today — no latency regression for the operator (Brazil → Ashburn is ~120 ms; Brazil → Falkenstein is ~205 ms)
- Same x86 architecture as today's Vapor image — no Dockerfile multi-arch work, no surprises with Swift on ARM
- 2 GB RAM is ~100× the relay's actual 17 MiB footprint
- 20 TB included egress vs. ~5 GB/day actual = 4 orders of magnitude headroom
- Marginal $4/mo over the cheapest EU option buys back ~80 ms of round-trip on every interactive WebSocket frame

#### When to pick CAX11 EU instead

- You don't have users in the Americas, or you don't care about ~80–100 ms extra round-trip per keystroke / frame.
- You want the absolute cheapest hosting bill (~€3.79/mo vs ~$8/mo).
- You're willing to rebuild the relay image for `linux/arm64` (official `swift:slim` is multi-arch, so this is a one-line `--platform linux/arm64` change in the build script).

The interactive UX cost is real: keystrokes use `KeystrokeDebouncer` 8 ms batching, so throughput is fine, but each forwarded char picks up the extra RTT before it reaches the Mac host and again before the screen update returns to iOS. For a Brazil-based primary user, this is a perceptible "feel" difference.

**Why not the cheaper-looking options:**

- **Vultr $2.50 IPv6-only.** Brazilian mobile carriers (and many others globally) are inconsistent on IPv6 reachability. You'd be debugging "iOS viewer can't connect" tickets that disappear on Wi-Fi. Skip.
- **Oracle Cloud always-free Ampere A1.** Tempting on paper (24 GB RAM, $0). Two real problems:
  1. Oracle reclaims instances where the 7-day P95 CPU is <20%. The relay sits near zero. It would be a textbook reclaim target unless you game the metric (busy-loop). Ugly and fragile.
  2. Documented account terminations without warning. Fine for a hobby project, not for the box your iOS users connect to.
- **Fly.io.** No real free tier since Oct 2024. Once you add a dedicated IPv4 ($2/mo), the always-on minimum (~$2/mo for 256 MB), plus per-GB traffic, you arrive at ~$5/mo for less hardware than a CAX11 — and you still need to figure out how to put a TLS-terminating reverse proxy in front of Vapor.

### Strategy B — Right-size `hetzner1` itself

Only viable if `cleancast` is tuned to fit in less than ~3 GB. Cleancast currently peaks at 5.2 GB anon-rss (cgroup-killed every ~half-day, see `host-oom-kill` alert). Until that is fixed, the box cannot drop below that ceiling without breaking cleancast.

| If cleancast peak is… | Smallest viable host | Approx. price |
|---|---|---|
| ≥ 5 GB (today) | CCX13 (current) | ~€14–16/mo |
| 3–4 GB | CPX21 (3 vCPU, 4 GB, 80 GB) | ~€8/mo |
| < 3 GB | CX22 (2 vCPU, 4 GB, 40 GB) | ~€4.49/mo |

Potential saving if cleancast tunes to <3 GB: ~€10/mo. Out of scope for ClaudeSpy — that's a `cleancast` project.

## 4. Migration sketch (Strategy A)

Rough order of operations to move the relay off `hetzner1`:

1. **Provision** Hetzner CPX11 in Ashburn, Ubuntu 24.04. Same SSH key as `hetzner1`. (No image rebuild needed — same x86 arch.)
2. **DNS:** add a second A record (e.g. `relay-new.gustavo.eng.br`) pointing at the new IP for testing. Don't repoint `relay.gallager.app` (or its legacy alias `claudespy.gustavo.eng.br`) yet.
3. **Bootstrap:** copy `/opt/claudespy/` (compose file + `.env`), `caddy/` configs, run `docker compose up -d`. Generate a fresh `METRICS_TOKEN`.
4. **Monitoring agents:** install node_exporter + alloy on the new box (re-use `monitoring/agents/install.sh`). Update Grafana dashboard `instance` filter or add the new instance label.
5. **Smoke test:** point a test iOS viewer + Mac host at `relay-new.gustavo.eng.br`. Pair, send messages, confirm push notifications fire.
6. **Cutover:** repoint `relay.gallager.app` (and the legacy `claudespy.gustavo.eng.br`) to the new IP. Caddy on the new box re-issues the certs via ACME.
7. **Decommission:** stop and remove `claudespy-relay` from `hetzner1`'s docker-compose. Remove the relay-specific Caddy site block. Stop scraping the old `instance="relay"` from the old alloy (or leave for a week as a safety net).
8. **Memory note update:** the `Relay Host Noisy Neighbor` memory becomes stale after this lands — update it.

Recurring cost change: **~+$8/mo** (CPX11) for the duration `hetzner1` continues to host cleancast.

If you instead pick CAX11 EU, add one prep step: `docker buildx build --platform linux/arm64 ...` for the relay image, plus push to the registry. Cost change: **~+€4/mo** but with the latency caveat noted above.

## 5. Decision

If you're optimizing for **fewer-incidents per dollar**, do **Strategy A now**. ~$8/mo (CPX11 in Ashburn) buys permanent isolation from whatever cleancast is doing, which has already been the cause of one production incident (May 4) and 5 OOM kills in the past 7 days.

Strategy B is a follow-up that depends on a `cleancast` change.

## Sources

- [Hetzner Cloud Pricing Calculator (May 2026)](https://costgoat.com/pricing/hetzner)
- [Hetzner April 2026 Pricing Analysis](https://agentdeals.dev/hetzner-pricing-2026)
- [Hetzner Cloud Review 2026 — Better Stack](https://betterstack.com/community/guides/web-servers/hetzner-cloud-review/)
- [Best Cheap VPS Hosting 2026](https://medium.com/@velinxs/best-cheap-vps-hosting-in-2026-under-5-month-picks-that-work-719810d47ba9)
- [DigitalOcean vs Hetzner — Better Stack](https://betterstack.com/community/guides/web-servers/digitalocean-vs-hetzner/)
- [Vultr Pricing 2026](https://www.vultr.com/pricing/)
- [Oracle Cloud Always Free Tier 2026 review](https://space-node.net/blog/oracle-vps-free-tier-review-2026)
- [Oracle Always Free idle-reclamation policy](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
- [Fly.io Pricing](https://fly.io/pricing/)
