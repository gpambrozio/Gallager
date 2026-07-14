# Self-Hosting the ClaudeSpy Relay Server

This guide explains how to deploy your own ClaudeSpy relay server for private use.

## Overview

The ClaudeSpy relay server is a lightweight Vapor (Swift) application that:
- Facilitates device pairing between Mac and iOS apps
- Relays WebSocket messages between paired devices
- Sends push notifications when iOS is disconnected (optional)

All communication is end-to-end encrypted. The server only relays encrypted blobs—it cannot read your session data.

Self-hosted relays are free and require no license configuration: the hosted-relay
licensing gate is entirely disabled unless `LEMONSQUEEZY_STORE_ID` and
`LEMONSQUEEZY_PRODUCT_ID` are set in the environment. Leave them unset (the
default) and the relay behaves exactly as before licensing existed. Once licensing is enabled, a malformed (non-integer) value in any licensing variable fails the boot rather
than silently falling back; with both ids unset, the other licensing variables are ignored.

## Requirements

### Server Requirements
- Linux server (Ubuntu 22.04+ recommended)
- Docker and Docker Compose
- 1 CPU core, 512MB RAM minimum (1GB recommended)
- A domain name with DNS configured

### Optional Requirements (for push notifications)
- Apple Developer account ($99/year)
- APNs authentication key (.p8 file)

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/your-username/ClaudeSpy.git
cd ClaudeSpy/ClaudeSpyPackage
```

### 2. Configure Environment

```bash
# Copy the example environment file
cp .env.example .env

# Edit with your settings (see Configuration section below)
nano .env
```

### 3. Deploy

```bash
# Build and start the server
docker compose up -d

# Verify it's running
curl http://localhost:8080/health
# Should return: {"status":"ok"}
```

### 4. Set Up Reverse Proxy (Required)

The server must be accessible via HTTPS for WebSocket connections. See [Reverse Proxy Setup](#reverse-proxy-setup).

### 5. Configure Your Apps

Update the server URL in both apps:
- **Mac app**: Settings → Remote Access → Server URL
- **iOS app**: Will use the same server after pairing

## Configuration

### Environment Variables

Create a `.env` file based on `.env.example`:

```bash
# Server settings
LOG_LEVEL=warning              # debug, info, notice, warning, error, critical
PAIRING_CODE_EXPIRY_SECONDS=300  # How long pairing codes are valid

# Licensing (leave unset for self-hosting — see docs above)
LEMONSQUEEZY_STORE_ID=         # From Lemon Squeezy dashboard
LEMONSQUEEZY_PRODUCT_ID=       # From Lemon Squeezy dashboard
TRIAL_DAYS=7                   # Trial length (default 7)
LICENSE_REVALIDATE_HOURS=24    # Recheck license validity (default 24)
LICENSE_GRACE_DAYS=7           # Grace period if Lemon Squeezy unreachable (default 7)

# Required for push notifications (optional feature)
APNS_KEY_PATH=/secrets/AuthKey.p8
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=XXXXXXXXXX
APNS_BUNDLE_ID=com.yourcompany.ClaudeSpy
APNS_ENVIRONMENT=development
```

### Push Notifications (Optional)

Push notifications allow the iOS app to receive alerts when not connected via WebSocket. To enable:

1. **Create an APNs Key** in [Apple Developer Portal](https://developer.apple.com/account/resources/authkeys/list):
   - Go to Certificates, Identifiers & Profiles → Keys
   - Create a new key with APNs capability
   - Download the `.p8` file (you can only download it once!)
   - Note the Key ID

2. **Place the key file**:
   ```bash
   mkdir -p secrets
   cp ~/Downloads/AuthKey_XXXXXXXXXX.p8 secrets/AuthKey.p8
   chmod 600 secrets/AuthKey.p8
   ```

3. **Configure environment variables**:
   ```bash
   APNS_KEY_PATH=/secrets/AuthKey.p8
   APNS_KEY_ID=XXXXXXXXXX        # From step 1
   APNS_TEAM_ID=XXXXXXXXXX       # From Apple Developer Portal → Membership
   APNS_BUNDLE_ID=com.yourcompany.ClaudeSpy  # Your iOS app bundle ID
   APNS_ENVIRONMENT=development  # Use "production" for App Store builds
   ```

If you skip APNs configuration, the server runs without push notifications—devices communicate only when both are actively connected.

## Reverse Proxy Setup

The relay server needs HTTPS for secure WebSocket connections. Choose one option:

### Option A: Caddy (Recommended)

Caddy automatically handles TLS certificates via Let's Encrypt.

1. **Install Caddy**:
   ```bash
   sudo apt install -y caddy
   ```

2. **Create Caddy configuration**:
   ```bash
   sudo nano /etc/caddy/Caddyfile
   ```

   Add:
   ```caddyfile
   your-domain.com {
       reverse_proxy localhost:8080

       log {
           output file /var/log/caddy/claudespy-access.log
           format json
       }

       header {
           X-Frame-Options "DENY"
           X-Content-Type-Options "nosniff"
           X-XSS-Protection "1; mode=block"
       }
   }
   ```

3. **Reload Caddy**:
   ```bash
   sudo systemctl reload caddy
   ```

### Option B: nginx with Certbot

1. **Install nginx and Certbot**:
   ```bash
   sudo apt install -y nginx certbot python3-certbot-nginx
   ```

2. **Create nginx configuration**:
   ```bash
   sudo nano /etc/nginx/sites-available/claudespy
   ```

   Add:
   ```nginx
   server {
       listen 80;
       server_name your-domain.com;

       location / {
           proxy_pass http://localhost:8080;
           proxy_http_version 1.1;
           proxy_set_header Upgrade $http_upgrade;
           proxy_set_header Connection "upgrade";
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;

           # WebSocket timeouts
           proxy_read_timeout 86400;
           proxy_send_timeout 86400;
       }
   }
   ```

3. **Enable the site and get certificates**:
   ```bash
   sudo ln -s /etc/nginx/sites-available/claudespy /etc/nginx/sites-enabled/
   sudo nginx -t
   sudo systemctl reload nginx
   sudo certbot --nginx -d your-domain.com
   ```

### Option C: Traefik (Docker-native)

If you're already using Traefik, add labels to `docker-compose.yml`:

```yaml
services:
  relay:
    # ... existing configuration ...
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.claudespy.rule=Host(`your-domain.com`)"
      - "traefik.http.routers.claudespy.entrypoints=websecure"
      - "traefik.http.routers.claudespy.tls.certresolver=letsencrypt"
      - "traefik.http.services.claudespy.loadbalancer.server.port=8080"
```

## Deployment Script

For automated deployments, use `deploy.sh`:

```bash
# Set required environment variables
export DEPLOY_HOST=your-server-ip-or-hostname
export DEPLOY_USER=root  # or your SSH user

# Dry-run first: build + boot + health-check in isolation on the server
# (separate dir/port/container — does NOT touch the running deployment).
# Recommended before a Swift toolchain or dependency bump.
./deploy.sh test

# Deploy
./deploy.sh deploy

# Other commands
./deploy.sh logs          # View warnings and errors
./deploy.sh logs all      # View all logs
./deploy.sh logs debug    # Restart with debug logging
./deploy.sh stop          # Stop the server
./deploy.sh restart       # Restart the server
```

`test` builds the image and boots the relay on `TEST_PORT` (default `8099`) under
`TEST_REMOTE_DIR` (default `/opt/claudespy-test`), curls `/health`, then tears the
container and image down. If a dependency bump deadlocks against a stale build
cache (`declares no traits`), it prunes the BuildKit cache and retries once
automatically. The production container keeps running throughout.

### Environment Variables for deploy.sh

| Variable | Default | Description |
|----------|---------|-------------|
| `DEPLOY_HOST` | (required) | Server IP or hostname |
| `DEPLOY_USER` | `root` | SSH username |
| `REMOTE_DIR` | `/opt/claudespy` | Installation directory on server |
| `HEALTH_CHECK_URL` | `http://localhost:8080/health` | URL to check after deployment |
| `TEST_REMOTE_DIR` | `/opt/claudespy-test` | Isolated directory used by `test` |
| `TEST_PORT` | `8099` | Host port the `test` container binds to |

## API Reference

### Health Check
```
GET /health
Response: {"status":"ok"}
```

### Pairing Endpoints
```
POST /api/pairing/register    # Mac registers pairing code
POST /api/pairing/complete    # iOS completes pairing
GET  /api/pairing/:pairId/status  # Check pairing status
DELETE /api/pairing/:pairId   # Remove pairing
```

### WebSocket
```
WS /api/ws?pairId=xxx&deviceType=mac|ios&deviceId=xxx
```

### Metrics (Optional)
```
GET /metrics    # Prometheus text exposition, requires Bearer METRICS_TOKEN
```

## Monitoring (Optional)

The relay can push metrics to Grafana Cloud (free tier) for dashboards and Discord alerts. See [docs/monitoring.md](monitoring.md) for the full setup. Quick summary:

1. Set `METRICS_TOKEN` in `.env` (generate with `openssl rand -hex 32`).
2. Sign up for Grafana Cloud and grab a metrics-write token.
3. Run `monitoring/agents/install.sh` on the VM (installs `node_exporter` + Grafana Alloy as systemd services).
4. Apply the dashboards/alerts from `monitoring/grizzly/` with `grr apply`.

The `/metrics` endpoint is gated by a bearer token (`METRICS_TOKEN`). In the default Docker deployment the relay's port is published only on `127.0.0.1:8080:8080`, so `/metrics` is not externally reachable; if you build and run the binary directly without Docker, restrict access via firewall or reverse proxy in addition to the token.

## Security Considerations

### Data Privacy
- All session data is end-to-end encrypted between Mac and iOS
- The server cannot decrypt any message content
- Pairing codes expire after 5 minutes (configurable)

### Network Security
- Always use HTTPS/WSS in production
- Consider firewall rules to restrict access to port 8080 (only allow reverse proxy)
- The Docker container runs as a non-root user

### Server Hardening
```bash
# Recommended: Only allow reverse proxy to access the container
sudo ufw allow from 127.0.0.1 to any port 8080
sudo ufw enable
```

## Troubleshooting

### Server won't start
```bash
# Check container logs
docker compose logs -f

# Verify the image built successfully
docker compose build --progress=plain
```

### WebSocket connections fail
- Ensure your reverse proxy supports WebSocket upgrades
- Check that the `Upgrade` and `Connection` headers are being forwarded
- Verify TLS/HTTPS is working: `curl -v https://your-domain.com/health`

### Push notifications not working
- Verify APNs configuration: check logs for "APNs client initialized"
- Ensure the `.p8` key file is readable
- Use `APNS_ENVIRONMENT=development` for Xcode builds
- Use `APNS_ENVIRONMENT=production` for TestFlight/App Store builds

### Pairing fails
- Ensure both devices can reach the server
- Check that the pairing code hasn't expired (5 minutes by default)
- Verify the Mac app is connected: `GET /api/pairing/:pairId/status`

### View server logs
```bash
# Warnings and errors only
docker compose logs -f | grep -E '\[ (WARNING|ERROR|CRITICAL) \]'

# All logs
docker compose logs -f

# Debug mode (restart required)
LOG_LEVEL=debug docker compose up -d
docker compose logs -f
```

## Updating

To update to a new version:

```bash
cd ClaudeSpy/ClaudeSpyPackage

# Pull latest changes
git pull

# Rebuild and restart
docker compose down
docker compose build
docker compose up -d
```

## Hosting Provider Examples

### DigitalOcean
- Create a Droplet (Ubuntu 22.04, $6/month Droplet is sufficient)
- Point your domain to the Droplet's IP
- Follow the Quick Start instructions above

### AWS
- Launch an EC2 instance (t3.micro is sufficient)
- Configure Security Group to allow ports 80, 443
- Use Elastic IP for a stable address
- Follow the Quick Start instructions above

### Hetzner
- Create a CX11 server (cheapest option works fine)
- Point your domain to the server IP
- Follow the Quick Start instructions above

### Raspberry Pi (Local Network)
For local-only use without internet access:
```bash
# Skip reverse proxy, use direct HTTP
docker compose up -d

# Configure Mac app to use: http://raspberrypi.local:8080
```
Note: iOS requires HTTPS for WebSocket, so this is Mac-only without extra setup.

## Building from Source

If you prefer to build without Docker:

```bash
# Requires Swift 6.3+ (swift-dependencies declares its package traits only in its Swift 6.3 manifest)
cd ClaudeSpyPackage
swift build -c release --product ClaudeSpyExternalServer

# Run the server
.build/release/ClaudeSpyExternalServer serve --env production --hostname 0.0.0.0 --port 8080
```

---

*"Here I am, brain the size of a planet, and they ask me to relay WebSocket messages. But at least they're encrypted, so I don't have to know what pointless tasks the humans are doing."* — Your Server
