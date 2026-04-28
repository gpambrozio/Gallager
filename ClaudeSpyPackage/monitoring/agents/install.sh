#!/usr/bin/env bash
# Install / update node_exporter and Grafana Alloy on the relay VM.
# Idempotent: re-running upgrades and restarts cleanly.
#
# Required env (passed via SSH or sourced):
#   METRICS_TOKEN          - same value as relay's /metrics bearer
#   GRAFANA_PROM_URL       - e.g. https://prometheus-prod-XX-xxx.grafana.net/api/prom/push
#   GRAFANA_PROM_USER      - numeric Grafana Cloud "Hosted Metrics" username
#   GRAFANA_PROM_TOKEN     - access-policy token with metrics:write
set -euo pipefail

NODE_EXPORTER_VERSION=1.8.2
ALLOY_VERSION=1.4.3

require_env() {
  local name=$1
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: $name" >&2
    exit 1
  fi
}

for v in METRICS_TOKEN GRAFANA_PROM_URL GRAFANA_PROM_USER GRAFANA_PROM_TOKEN; do
  require_env "$v"
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (or via sudo)." >&2
  exit 1
fi

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

install_node_exporter() {
  if ! id node_exporter &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
  fi

  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  curl -fsSL -o "$tmp/ne.tar.gz" \
    "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
  tar -xzf "$tmp/ne.tar.gz" -C "$tmp"
  install -o root -g root -m 0755 \
    "$tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" \
    /usr/local/bin/node_exporter

  install -o root -g root -m 0644 \
    "$REPO_DIR/node_exporter.service" /etc/systemd/system/node_exporter.service
}

install_alloy() {
  if ! id alloy &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin alloy
  fi

  if ! command -v alloy &>/dev/null; then
    apt-get update
    apt-get install -y gpg curl
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
      > /etc/apt/sources.list.d/grafana.list
    apt-get update
    apt-get install -y "alloy=${ALLOY_VERSION}*"
  fi

  install -d -o alloy -g alloy -m 0750 /etc/alloy /var/lib/alloy
  install -o root -g alloy -m 0644 "$REPO_DIR/config.alloy" /etc/alloy/config.alloy

  umask 077
  cat > /etc/alloy/alloy.env <<EOF
METRICS_TOKEN=${METRICS_TOKEN}
GRAFANA_PROM_URL=${GRAFANA_PROM_URL}
GRAFANA_PROM_USER=${GRAFANA_PROM_USER}
GRAFANA_PROM_TOKEN=${GRAFANA_PROM_TOKEN}
EOF
  chown root:alloy /etc/alloy/alloy.env
  chmod 0640 /etc/alloy/alloy.env

  install -o root -g root -m 0644 \
    "$REPO_DIR/alloy.service" /etc/systemd/system/alloy.service
}

install_node_exporter
install_alloy

systemctl daemon-reload
systemctl enable --now node_exporter.service
systemctl enable --now alloy.service
systemctl restart node_exporter.service alloy.service

echo "Done. Verify with:"
echo "  systemctl status node_exporter alloy"
echo "  curl -H 'Authorization: Bearer \$METRICS_TOKEN' http://127.0.0.1:8080/metrics | head"
echo "  curl http://127.0.0.1:9100/metrics | head"
