# Monitoring Runbook

## Stack
- **Source:** Vapor `/metrics` (token-protected) + `node_exporter` on the VM
- **Collector:** Grafana Alloy (systemd) on the VM, push to Grafana Cloud Prometheus
- **Storage / UI:** Grafana Cloud free tier (`gpambrozio.grafana.net`)
- **Alerts:** Discord webhook → `#claudespy-alerts`
- **Config-as-code:** `ClaudeSpyPackage/monitoring/grizzly/` applied via `grr apply`

## Initial Setup

One-time bootstrap. Detailed steps in the plan at `docs/superpowers/plans/2026-04-27-relay-server-monitoring.md` (Phases 3–5). Track progress here:

### Grafana Cloud (Phase 3)
- [x] Sign up at <https://grafana.com/auth/sign-up/create-user>; create stack `claudespy` in a region near Hetzner.
- [x] From "Send Metrics" → "Hosted Prometheus": save `GRAFANA_PROM_URL` and `GRAFANA_PROM_USER`.
- [x] Create access policy `claudespy-alloy-write` with scope `metrics:write`; save the token as `GRAFANA_PROM_TOKEN`.
- [x] Save the stack's Grafana URL as `GRAFANA_URL`.
- [x] Create service account `grizzly` (Admin role); save its token as `GRAFANA_SA_TOKEN` (= `GRAFANA_TOKEN` in `.env`).
- [x] Generate `METRICS_TOKEN` with `openssl rand -hex 32`; add it to `/opt/claudespy/.env` on the Hetzner VM and redeploy the relay.
- [x] Verify `/metrics` from inside the VM: `curl -H "Authorization: Bearer $METRICS_TOKEN" http://127.0.0.1:8080/metrics | head`.
- [x] Verify external port is closed: `curl http://$DEPLOY_HOST:8080/metrics` should refuse connection (not 401).
- [x] `scp -r ClaudeSpyPackage/monitoring/agents root@$DEPLOY_HOST:/opt/claudespy-monitoring`.
- [x] Run installer with all four env vars: `ssh root@$DEPLOY_HOST METRICS_TOKEN=… GRAFANA_PROM_URL=… GRAFANA_PROM_USER=… GRAFANA_PROM_TOKEN=… bash /opt/claudespy-monitoring/install.sh`.
- [x] Confirm both services active: `systemctl is-active node_exporter alloy`.
- [ ] In Grafana Explore, query `claudespy_active_pairs` and `node_filesystem_avail_bytes` to confirm data is flowing.

### Discord (Phase 4)
- [x] Create private channel `#claudespy-alerts` on a Discord server you control.
- [x] Add webhook named `Grafana`; save URL as `DISCORD_WEBHOOK_URL`.
- [x] Smoke-test: `curl -X POST -H 'Content-Type: application/json' -d '{"content":"hello"}' "$DISCORD_WEBHOOK_URL"`.

### grizzly config-as-code (Phase 5)
- [x] `brew install grafana/grafana/grizzly` (installed v0.7.1 via `brew install grizzly`).
- [x] `cd ClaudeSpyPackage/monitoring/grizzly && cp .env.example .env`; fill in `GRAFANA_URL`, `GRAFANA_TOKEN`, `DISCORD_WEBHOOK_URL`.
- [x] Pull current state to discover the Prometheus datasource UID (`grafanacloud-prom`); updated all alert YAMLs and `.env`.
- [x] Applied contact point (`discord-alerts`) and notification policy via `grr apply`. Alert rules applied via Grafana provisioning API (grr 0.7.1 has a bug with AlertRuleGroup).
- [ ] In Grafana UI → Alerting → Contact points → `discord-alerts` → Test. Verify message in `#claudespy-alerts`.
- [ ] Build the Relay Overview dashboard in the Grafana UI (panel queries listed in the plan, Task 23).
- [ ] `mkdir -p pulled && grr pull -t Dashboard -d ./pulled && mv ./pulled/dashboards/*.json dashboards/relay.json && rm -rf pulled`. Commit `dashboards/relay.json`.
- [ ] `make apply` again — should report `unchanged` for the dashboard (round-trip works).

### Smoke test (Phase 6 / Task 24)
- [ ] `ssh root@$DEPLOY_HOST 'docker stop claudespy-relay'`. Wait 3 min. Expect a Discord alert.
- [ ] `ssh root@$DEPLOY_HOST 'docker start claudespy-relay'`. Wait 1–2 min. Expect a Discord "resolved" message.

## Daily life

### Re-apply after editing alerts/dashboards
```bash
cd ClaudeSpyPackage/monitoring/grizzly
set -a; . ./.env; set +a
make diff   # see what would change
make apply  # actually apply
```

### Pull current state from Grafana
```bash
make pull
ls pulled/
```
Use this if you've edited something in the UI and want to bring it into git.

## Troubleshooting

### Alloy is not pushing metrics
```bash
ssh root@$DEPLOY_HOST 'systemctl status alloy'
ssh root@$DEPLOY_HOST 'journalctl -u alloy -n 100 --no-pager'
```
Common causes: bad `GRAFANA_PROM_TOKEN`, expired access policy, network egress blocked.

### `/metrics` returns 401 from Alloy
The token in `/etc/alloy/alloy.env` does not match `METRICS_TOKEN` in `/opt/claudespy/.env`. Re-run `install.sh` with the correct value.

### node_exporter shows no data
```bash
ssh root@$DEPLOY_HOST 'curl -fsS http://127.0.0.1:9100/metrics | head'
```
If empty, the binary may have failed — check `journalctl -u node_exporter`.

### Discord notifications stopped arriving
Test the contact point in Grafana UI (Alerting → Contact points → `discord-alerts` → Test). If that fails, regenerate the webhook in Discord and update `DISCORD_WEBHOOK_URL`, then `make apply`.

### A new metric I added isn't visible
1. Confirm the relay actually exposes it: `curl -H "Authorization: Bearer $METRICS_TOKEN" http://127.0.0.1:8080/metrics | grep <name>`
2. Wait one scrape interval (30s).
3. Query in Grafana Explore: `<metric_name>` against the Prometheus datasource.

## Rotating the metrics token

1. Generate a new value: `openssl rand -hex 32`.
2. Update `/opt/claudespy/.env` on the VM and restart relay: `docker compose up -d relay`.
3. Update `/etc/alloy/alloy.env` and restart Alloy: `systemctl restart alloy`.

## Free-tier limits

Grafana Cloud free: 10k active series, 14-day retention, 1 user. Current usage: ~50 series. Plenty of headroom unless we add per-pair labels (which we deliberately avoided).

## Metrics emitted

| Metric | Type | Description |
|--------|------|-------------|
| `claudespy_messages_relayed_total` | counter | Encrypted messages relayed since process start |
| `claudespy_push_notifications_total` | counter | Push notifications sent to APNs since process start |
| `claudespy_active_pairs` | gauge | Currently-paired devices |
| `claudespy_ws_connections{device_type="host\|viewer"}` | gauge | Active WebSocket connections per device type |
| `claudespy_uptime_seconds` | gauge | Process uptime |
| `claudespy_build_info{version="..."}` | gauge | Always 1; the `version` label carries the build identifier |

Plus the standard `node_exporter` metrics for host CPU/RAM/disk/net.
