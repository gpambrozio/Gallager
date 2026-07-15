# Staging relay (maintainers)

A second, fully isolated copy of the **hosted** relay running beside production on
the **same box**, so the hosted-relay monetization (Lemon Squeezy licensing) — and
any other relay change — can be tested against real host + viewer clients without
interrupting the live service.

This is maintainer tooling for the official relay. It is unrelated to
[self-hosting](self-hosting.md) (running your own free relay).

## How it stays isolated

```
staging.gallager.gustavo.eng.br  →  Caddy  →  127.0.0.1:8081  →  claudespy-relay-staging   (its own ./data + .env, licensing ON)
claudespy.gustavo.eng.br         →  Caddy  →  127.0.0.1:8080  →  claudespy-relay           (production, licensing OFF, untouched)
```

| Concern | Production | Staging |
| --- | --- | --- |
| Deploy dir | `/opt/claudespy` | `/opt/claudespy-staging` |
| Compose project | `claudespy` | `claudespy-staging` |
| Container | `claudespy-relay` | `claudespy-relay-staging` |
| Host port (behind Caddy) | `8080` | `8081` |
| Hostname | `claudespy.gustavo.eng.br` | `staging.gallager.gustavo.eng.br` |
| `./data` (pairings, `licensing.json`) | separate | separate |
| `.env` / `secrets/` | prod's | staging's (licensing test-mode) |

Staging state (pairings, trial timers, license activations) lives in its own
`./data`, so nothing you do on staging can touch a production user.

## Why this works off any branch

The staging container is built from whatever source you run `deploy.sh staging`
from — so to exercise licensing, deploy from a checkout that has the licensing
code (the `monetization-392` branch, or `main` once it merges). The relay reads
`LEMONSQUEEZY_*` from its process environment, and the base compose's
`env_file: .env` injects the staging `.env` verbatim — so the ids reach the relay
regardless of which branch's compose you use.

## One-time setup

1. **DNS** — add an A record `staging.gallager.gustavo.eng.br` → the server's IP.
   Caddy issues a separate Let's Encrypt cert on first request.

2. **Lemon Squeezy test mode** — in the Lemon Squeezy dashboard, toggle **Test
   mode**, then note the numeric **store id** (Settings → Stores) and
   **product id** (the subscription product's page). Test-mode license keys
   validate against the same `api.lemonsqueezy.com` — no API base override.

3. **Server files** (kept on the server; the deploy deliberately never rsyncs
   them, so they survive redeploys and a prod deploy can't overwrite them):

   ```sh
   ssh root@<server> 'mkdir -p /opt/claudespy-staging/secrets'
   scp ClaudeSpyPackage/.env.staging.example root@<server>:/opt/claudespy-staging/.env
   # edit /opt/claudespy-staging/.env: set LEMONSQUEEZY_STORE_ID / _PRODUCT_ID to the
   # test-mode ids, and copy the APNS_* values from your prod .env.
   scp ClaudeSpyPackage/secrets/AuthKey.p8 root@<server>:/opt/claudespy-staging/secrets/AuthKey.p8
   ```

   Set `APNS_ENVIRONMENT` to match the test build you point at staging
   (`development` for an Xcode debug build, `production` for TestFlight), or pushes
   silently no-op.

## Deploy

From a checkout with the code you want on staging (e.g. `monetization-392`):

```sh
export DEPLOY_HOST=<server-ip-or-hostname>   # same target as prod
./scripts/deploy.sh staging
```

This runs the same local release build + server tests as a prod deploy, rsyncs
the package to `/opt/claudespy-staging` (excluding `.env`, `secrets`, `data`),
installs the staging Caddy block, builds and starts `claudespy-relay-staging` on
`127.0.0.1:8081`, reloads Caddy, and health-checks
`https://staging.gallager.gustavo.eng.br/health`. Production is never touched.

To shorten the trial for expiry testing, set `TRIAL_DAYS=1` (or lower) in the
staging `.env` and redeploy / restart.

## Point test clients at staging

On a **throwaway** host Mac and viewer, set **Remote Access → Server URL** to:

```
wss://staging.gallager.gustavo.eng.br
```

No rebuild needed — the URL is an editable field. Your everyday devices stay on
`wss://claudespy.gustavo.eng.br`.

## Operate

```sh
./scripts/deploy.sh staging-status   # container status + recent logs
./scripts/deploy.sh staging-logs     # follow logs
./scripts/deploy.sh staging-stop     # stop staging (prod untouched)
```

## Teardown

```sh
./scripts/deploy.sh staging-stop
ssh root@<server> 'rm -rf /opt/claudespy-staging && rm -f /etc/caddy/conf.d/claudespy-staging.caddy && systemctl reload caddy'
# optional: remove the staging.gallager.gustavo.eng.br DNS record
```

## Notes

- **Resource pressure** — the box already runs prod plus co-resident services and
  has been OOM-tight. The relay is light, but watch memory while staging is up.
- **Monitoring** — the prod Alloy agent only scrapes prod's port, so staging
  metrics aren't collected. `curl` `/metrics` directly if you need them (set a
  `METRICS_TOKEN` in the staging `.env`).
- **Env vars** — `STAGING_REMOTE_DIR`, `STAGING_PROJECT`, and `STAGING_HEALTH_URL`
  override the defaults in `scripts/deploy.sh` if you want a different layout.
