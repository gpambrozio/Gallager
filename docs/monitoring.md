# Monitoring Runbook

## Stack
- **Source:** Vapor `/metrics` (token-protected) + `node_exporter` on the VM
- **Collector:** Grafana Alloy (systemd) on the VM, push to Grafana Cloud Prometheus
- **Storage / UI:** Grafana Cloud free tier (`<your-stack>.grafana.net`)
- **Alerts:** Discord webhook → `#claudespy-alerts`
- **Config-as-code:** `ClaudeSpyPackage/monitoring/grizzly/` applied via `grr apply`

## Initial Setup

See the implementation plan at `docs/superpowers/plans/2026-04-27-relay-server-monitoring.md`, Phases 3–5, for the one-time bootstrap (Grafana Cloud account, service-account token, Discord webhook, agent install on VM).

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
