#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration via environment variables (with defaults)
# Set these before running the script or export them in your shell
DEPLOY_USER="${DEPLOY_USER:-root}"
REMOTE_DIR="${REMOTE_DIR:-/opt/claudespy}"
CADDY_CONF_D="${CADDY_CONF_D:-/etc/caddy/conf.d}"
HCLOUD_SERVER_NAME="${HCLOUD_SERVER_NAME:-cleancast}"
PROD_CADDY_FILE="claudespy.caddy"
UPDATES_CADDY_FILE="updates.caddy"
PROD_COMPOSE="docker compose"
HEALTH_URL="${HEALTH_CHECK_URL:-https://relay.gallager.app/health}"

# Isolated-test configuration (used by the `test` command). These intentionally
# differ from the prod dir/port/container so a test run never touches the running
# server.
TEST_REMOTE_DIR="${TEST_REMOTE_DIR:-/opt/claudespy-test}"
TEST_PORT="${TEST_PORT:-8099}"
TEST_IMAGE="${TEST_IMAGE:-claudespy-relay:test}"
TEST_CONTAINER="${TEST_CONTAINER:-claudespy-relay-test}"

# Staging configuration (used by the `staging*` commands). A second, fully
# isolated relay on the SAME box behind staging.gallager.app →
# 127.0.0.1:8081, with Lemon Squeezy licensing ENABLED via its own on-server
# .env. Prod (/opt/claudespy, :8080, licensing off) is never touched.
STAGING_REMOTE_DIR="${STAGING_REMOTE_DIR:-/opt/claudespy-staging}"
STAGING_PROJECT="${STAGING_PROJECT:-claudespy-staging}"
STAGING_CADDY_FILE="${STAGING_CADDY_FILE:-claudespy-staging.caddy}"
STAGING_HEALTH_URL="${STAGING_HEALTH_URL:-https://staging.gallager.app/health}"
# Compose invocation that layers the staging override and names the project so it
# can't collide with prod's container/network. Relative -f paths resolve after a
# `cd $STAGING_REMOTE_DIR`.
STAGING_COMPOSE="docker compose -f docker-compose.yml -f docker-compose.staging.yml -p ${STAGING_PROJECT}"

# Website configuration (used by the `website` command). Static marketing site
# (gallager.app) built locally with Astro from website/ and served by Caddy as
# plain files — no container involved.
WEBSITE_REMOTE_DIR="${WEBSITE_REMOTE_DIR:-/opt/gallager-website}"
WEBSITE_CADDY_FILE="website.caddy"
WEBSITE_URL="${WEBSITE_URL:-https://gallager.app}"

# Print colored output
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Get server IP/hostname
get_server_host() {
    # Priority: DEPLOY_HOST env var > hcloud (if available)
    if [ -n "$DEPLOY_HOST" ]; then
        echo "$DEPLOY_HOST"
        return
    fi

    # Fallback to hcloud if configured (for backwards compatibility)
    if [ -n "$HCLOUD_SERVER_NAME" ] && command -v hcloud &> /dev/null; then
        hcloud server ip "$HCLOUD_SERVER_NAME" 2>/dev/null
        return
    fi

    # No host configured
    echo ""
}

# Resolve the deploy target into $SERVER_HOST / $REMOTE_HOST, or exit.
resolve_remote_host() {
    SERVER_HOST=$(get_server_host)
    if [ -z "$SERVER_HOST" ]; then
        error "Could not determine server host"
        exit 1
    fi
    REMOTE_HOST="$DEPLOY_USER@$SERVER_HOST"
}

# Run a command on the server over a quiet SSH connection.
remote() { ssh -o LogLevel=ERROR "$REMOTE_HOST" "$@"; }

# Absolute path to ClaudeSpyPackage (rsync source / swift --package-path).
package_dir() { cd "$(dirname "$0")/../ClaudeSpyPackage" && pwd; }

# Strip Ubuntu MOTD noise + blank lines from captured remote output (stdin).
strip_motd() {
    grep -v -E '(^Welcome to|Documentation:|Management:|Support:|System (information|load)|Usage of|Memory usage|Swap usage|Processes:|Users logged|IPv[46] address|Expanded Security|update.*applied|additional updates|additional security|Learn more about|ubuntu\.com|help\.ubuntu)' | grep -v '^[[:space:]]*$'
}

# rsync the local package to a remote dir. Extra args (e.g. --exclude) pass through.
sync_package() {
    local dest="$1"; shift
    rsync -az --delete \
        --exclude='.build' \
        --exclude='.git' \
        --exclude='*.xcodeproj' \
        --exclude='*.xcworkspace' \
        --exclude='Tests' \
        --exclude='data' \
        "$@" \
        -e ssh \
        "$(package_dir)/" \
        "$REMOTE_HOST:$dest/"
}

# Install a Caddy site file (from $remote_dir/caddy/) into the server's conf.d,
# if that directory exists on the server.
install_caddy() {
    local remote_dir="$1" caddy_file="$2"
    info "Checking for Caddy configuration..."
    if remote "test -d $CADDY_CONF_D" 2>/dev/null; then
        if [ -f "$(package_dir)/caddy/$caddy_file" ]; then
            info "Installing Caddy configuration ($caddy_file)..."
            remote "cp $remote_dir/caddy/$caddy_file $CADDY_CONF_D/"
        fi
    else
        info "Caddy conf.d directory not found, skipping Caddy config installation."
        info "You may need to configure your reverse proxy manually."
    fi
}

# Build the image and (re)start the container on the server for a given deploy
# dir + compose invocation. Echoes filtered build + status output for the caller
# to inspect; emits the sentinel DEPLOY_BUILD_FAILED (and exits nonzero) if the
# image build fails.
remote_compose_up() {
    local remote_dir="$1" compose="$2"
    ssh -T -o LogLevel=ERROR "$REMOTE_HOST" << REMOTE_SCRIPT 2>&1
        cd $remote_dir
        set -eo pipefail

        # Build the image with BuildKit enabled for cache mounts (incremental Swift builds).
        echo "Building Docker image with BuildKit..."
        BUILD_LOG=\$(mktemp)
        if ! DOCKER_BUILDKIT=1 $compose build --progress=plain 2>&1 | tee "\$BUILD_LOG"; then
            echo "DEPLOY_BUILD_FAILED"
            grep -E '(error:|ERROR|failed)' "\$BUILD_LOG" | head -20
            rm -f "\$BUILD_LOG"
            exit 1
        fi

        # Show filtered build output.
        grep -E '(^#[0-9]+ \[|CACHED|DONE|ERROR|error:|Build of product|exporting to image|naming to)' "\$BUILD_LOG" | head -50
        rm -f "\$BUILD_LOG"

        # Restart the container.
        $compose down 2>/dev/null || true
        echo "Starting container..."
        $compose up -d 2>&1 | grep -v "^\$"

        # Reload Caddy if it's running.
        if systemctl is-active --quiet caddy 2>/dev/null; then
            echo "Reloading Caddy..."
            systemctl reload caddy
        fi

        echo ""
        echo "Container status:"
        $compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || $compose ps
REMOTE_SCRIPT
}

# curl a health URL; succeeds if the body reports "status":"ok".
check_health() { curl -s "$1" 2>/dev/null | grep -q '"status":"ok"'; }

# Check prerequisites
check_prerequisites() {
    local server_host
    server_host=$(get_server_host)

    if [ -z "$server_host" ]; then
        error "No deploy target configured."
        echo ""
        echo "Set one of these environment variables:"
        echo "  export DEPLOY_HOST=your-server-ip-or-hostname"
        echo ""
        echo "Or for Hetzner Cloud:"
        echo "  export HCLOUD_SERVER_NAME=your-server-name"
        echo ""
        exit 1
    fi

    # Verify SSH connectivity
    if ! ssh -q -o BatchMode=yes -o ConnectTimeout=5 "${DEPLOY_USER}@${server_host}" exit 2>/dev/null; then
        warn "Cannot connect to ${DEPLOY_USER}@${server_host}"
        warn "Make sure SSH key authentication is configured."
    fi
}

# Pre-deploy checks: compile and test locally before deploying
pre_deploy_checks() {
    info "Running pre-deploy checks..."

    local pkg
    pkg="$(package_dir)"

    # Build in release mode to catch cross-module optimization issues
    info "Building server in release mode..."
    if ! swift build -c release --product ClaudeSpyExternalServer --package-path "$pkg" 2>&1; then
        error "Release build failed! Fix compilation errors before deploying."
        exit 1
    fi
    info "Release build successful."

    # Build the full package test bundle, then run just the server tests.
    #
    # This must build ALL test targets (`--build-tests`), not a single target:
    # SPM links ONE .xctest bundle per package, so `swift build --target
    # ClaudeSpyExternalServerTests` compiles that target's objects but never
    # produces ClaudeSpyPackagePackageTests.xctest — and `swift test --skip-build`
    # then fails with "xctest doesn't exist" on a clean .build (it only appeared
    # to work when a stale bundle happened to be present). Building the whole
    # bundle costs a one-time compile of the other test targets (incl. SwiftTerm)
    # but makes the gate correct regardless of build-cache state.
    info "Building test bundle..."
    if ! swift build --package-path "$pkg" --build-tests 2>&1; then
        error "Server test build failed! Fix compilation errors before deploying."
        exit 1
    fi
    info "Running server tests..."
    if ! swift test --package-path "$pkg" --skip-build --filter ClaudeSpyExternalServerTests 2>&1; then
        error "Server tests failed! Fix test failures before deploying."
        exit 1
    fi
    info "All tests passed."

    echo ""
    info "Pre-deploy checks completed successfully."
    echo ""
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

# Main deployment
deploy() {
    # Run pre-deploy checks first
    pre_deploy_checks

    info "Starting ClaudeSpy relay server deployment..."
    resolve_remote_host
    info "Deploying to server: $SERVER_HOST"

    # Create remote directory if it doesn't exist
    info "Setting up remote directory..."
    remote "mkdir -p $REMOTE_DIR"

    info "Syncing files to server..."
    sync_package "$REMOTE_DIR"

    install_caddy "$REMOTE_DIR" "$PROD_CADDY_FILE"
    # Update hosting (updates.gallager.app → /opt/claudespy-updates, issue #664)
    # rides along so edits to its site file reach the server on every deploy.
    install_caddy "$REMOTE_DIR" "$UPDATES_CADDY_FILE"

    # Ensure data directory exists with correct permissions
    info "Ensuring data directory permissions..."
    remote "mkdir -p $REMOTE_DIR/data && chmod 777 $REMOTE_DIR/data"

    # Build and start the container
    info "Building and starting container..."
    BUILD_OUTPUT=$(remote_compose_up "$REMOTE_DIR" "$PROD_COMPOSE")
    BUILD_EXIT_CODE=$?

    echo "$BUILD_OUTPUT" | strip_motd

    if [ $BUILD_EXIT_CODE -ne 0 ] || echo "$BUILD_OUTPUT" | grep -q "DEPLOY_BUILD_FAILED"; then
        error "Docker build failed on server! Deployment aborted."
        exit 1
    fi

    # Wait for health check
    info "Waiting for server to be healthy..."
    sleep 5

    info "Testing deployment..."
    if check_health "$HEALTH_URL"; then
        info "Deployment successful! Server is healthy."
        echo ""
        echo -e "${GREEN}ClaudeSpy relay server is now running.${NC}"
        echo ""
        echo "Health check: $HEALTH_URL"
        echo ""
        echo "Endpoints:"
        echo "  GET  /health                    - Health check"
        echo "  POST /api/pairing/register      - Register pairing code (Mac)"
        echo "  POST /api/pairing/complete      - Complete pairing (iOS)"
        echo "  WS   /api/ws                    - WebSocket connection"
    else
        warn "Health check failed or server is still starting."
        echo "Check manually: curl $HEALTH_URL"
        echo ""
        echo "If using a reverse proxy, check: curl https://your-domain.com/health"
    fi
}

# Staging deployment: a second, isolated relay on the SAME box behind
# staging.gallager.app → 127.0.0.1:8081, with Lemon Squeezy licensing
# ENABLED. Prod (/opt/claudespy, :8080) is never touched.
#
# Unlike `deploy`, this EXCLUDES .env and secrets/ from the rsync: staging keeps
# its own licensing-enabled .env (test mode) and APNs key resident on the server,
# so deploys never clobber them and a prod deploy can't leak into staging. Those
# two files must therefore be created on the server once (this fails loud with
# setup steps if the .env is missing).
deploy_staging() {
    # Same local release build + server tests as prod — it's the same codebase.
    pre_deploy_checks

    info "Starting Gallager STAGING relay deployment..."
    resolve_remote_host
    info "Deploying STAGING to: $SERVER_HOST (dir: $STAGING_REMOTE_DIR, project: $STAGING_PROJECT)"

    # Preflight: the staging .env must already exist on the server, because we
    # deliberately don't rsync it. Fail loud with first-time setup steps.
    if ! remote "test -f $STAGING_REMOTE_DIR/.env" 2>/dev/null; then
        error "Missing $STAGING_REMOTE_DIR/.env on the server."
        echo ""
        echo "First-time staging setup (run once):"
        echo "  1. DNS: point staging.gallager.app at this server's IP."
        echo "  2. ssh $REMOTE_HOST 'mkdir -p $STAGING_REMOTE_DIR/secrets'"
        echo "  3. scp ClaudeSpyPackage/.env.staging.example $REMOTE_HOST:$STAGING_REMOTE_DIR/.env"
        echo "     then edit it: set LEMONSQUEEZY_* to your Lemon Squeezy TEST-mode ids + APNS_* values."
        echo "  4. scp ClaudeSpyPackage/secrets/AuthKey.p8 $REMOTE_HOST:$STAGING_REMOTE_DIR/secrets/AuthKey.p8"
        echo ""
        echo "Then re-run: $0 staging"
        exit 1
    fi

    info "Syncing files to $STAGING_REMOTE_DIR (excluding .env, secrets, data)..."
    remote "mkdir -p $STAGING_REMOTE_DIR"
    sync_package "$STAGING_REMOTE_DIR" --exclude='.env' --exclude='secrets'

    install_caddy "$STAGING_REMOTE_DIR" "$STAGING_CADDY_FILE"

    info "Ensuring data directory permissions..."
    remote "mkdir -p $STAGING_REMOTE_DIR/data && chmod 777 $STAGING_REMOTE_DIR/data"

    info "Building and starting the staging container..."
    BUILD_OUTPUT=$(remote_compose_up "$STAGING_REMOTE_DIR" "$STAGING_COMPOSE")
    BUILD_EXIT_CODE=$?

    echo "$BUILD_OUTPUT" | strip_motd

    if [ $BUILD_EXIT_CODE -ne 0 ] || echo "$BUILD_OUTPUT" | grep -q "DEPLOY_BUILD_FAILED"; then
        error "Staging Docker build failed! Deployment aborted (prod untouched)."
        exit 1
    fi

    info "Waiting for staging server to be healthy..."
    sleep 5

    info "Testing staging deployment..."
    if check_health "$STAGING_HEALTH_URL"; then
        info "Staging deployment successful! Server is healthy."
        echo ""
        echo -e "${GREEN}Gallager STAGING relay is now running.${NC}"
        echo ""
        echo "Health check: $STAGING_HEALTH_URL"
        echo ""
        echo "Point a TEST host Mac + viewer at (Remote Access → Server URL):"
        echo "  wss://staging.gallager.app"
        echo "Your everyday devices stay on wss://relay.gallager.app."
    else
        warn "Staging health check failed or server is still starting."
        echo "Check manually: curl $STAGING_HEALTH_URL"
        echo "Container logs: $0 staging-logs"
    fi
}

# Isolated dry-run: rsync to a throwaway dir, build the image, boot the relay on a
# spare port with throwaway data, hit /health, then tear everything down — all
# WITHOUT touching the running production container, port, or data. Use this to
# validate a build (e.g. a Swift toolchain or dependency bump) before `deploy`.
test_deploy() {
    info "Starting isolated relay test (no impact on the running server)..."
    resolve_remote_host
    info "Testing on server: $SERVER_HOST (dir: $TEST_REMOTE_DIR, port: $TEST_PORT)"

    # Sync the package to an ISOLATED dir so prod ($REMOTE_DIR) is untouched.
    info "Syncing files to $TEST_REMOTE_DIR..."
    remote "mkdir -p $TEST_REMOTE_DIR"
    sync_package "$TEST_REMOTE_DIR"

    info "Building and smoke-testing on the server..."
    TEST_OUTPUT=$(ssh -T -o LogLevel=ERROR "$REMOTE_HOST" << REMOTE_SCRIPT 2>&1
        cd $TEST_REMOTE_DIR
        set -eo pipefail

        # Clean up anything left over from a previous test run.
        docker rm -f $TEST_CONTAINER >/dev/null 2>&1 || true

        build_image() { DOCKER_BUILDKIT=1 docker build -t $TEST_IMAGE . 2>&1; }

        echo "Building test image..."
        BUILD_LOG=\$(mktemp)
        if ! build_image | tee "\$BUILD_LOG"; then
            # A Swift dependency/toolchain bump can deadlock against a stale
            # checkout cached in the BuildKit cache mount ("declares no traits").
            # Detect that, clear the build cache, and retry once from scratch.
            if grep -qiE 'declares no traits|enables traits' "\$BUILD_LOG"; then
                echo "TEST_CACHE_PRUNED"
                echo "Stale build cache detected — pruning and rebuilding clean..."
                docker builder prune -af >/dev/null 2>&1 || true
                if ! build_image | tee "\$BUILD_LOG"; then
                    echo "TEST_BUILD_FAILED"
                    grep -E '(error:|ERROR|failed)' "\$BUILD_LOG" | head -20
                    rm -f "\$BUILD_LOG"; exit 1
                fi
            else
                echo "TEST_BUILD_FAILED"
                grep -E '(error:|ERROR|failed)' "\$BUILD_LOG" | head -20
                rm -f "\$BUILD_LOG"; exit 1
            fi
        fi
        rm -f "\$BUILD_LOG"
        echo "Build OK."

        # Boot the relay on an isolated port with throwaway data (no secrets —
        # this validates build + boot + /health, not APNs push delivery).
        docker run -d --name $TEST_CONTAINER \
            -p 127.0.0.1:$TEST_PORT:8080 \
            -e DATA_DIRECTORY=/data \
            $TEST_IMAGE >/dev/null

        echo "Waiting for /health on port $TEST_PORT..."
        HEALTHY=""
        for _ in \$(seq 1 15); do
            if curl -fs "http://localhost:$TEST_PORT/health" 2>/dev/null | grep -q '"status":"ok"'; then
                HEALTHY=1; break
            fi
            sleep 2
        done

        echo ""
        echo "Container logs (tail):"
        docker logs --tail=20 $TEST_CONTAINER 2>&1 || true

        # Tear down the container + image (the synced dir is kept for fast re-runs).
        docker rm -f $TEST_CONTAINER >/dev/null 2>&1 || true
        docker rmi $TEST_IMAGE >/dev/null 2>&1 || true

        if [ -n "\$HEALTHY" ]; then echo "TEST_HEALTHY"; else echo "TEST_UNHEALTHY"; exit 1; fi
REMOTE_SCRIPT
    ) || true
    # `|| true` above: a non-zero remote exit must not trip `set -e` before we
    # print the captured diagnostics; pass/fail is decided from the sentinels.

    echo "$TEST_OUTPUT" | strip_motd

    echo ""
    if echo "$TEST_OUTPUT" | grep -q "TEST_HEALTHY"; then
        info "Test passed: the image builds and the relay reports healthy on $SERVER_HOST."
        if echo "$TEST_OUTPUT" | grep -q "TEST_CACHE_PRUNED"; then
            warn "A stale build cache was pruned during this run; the next 'deploy' build repopulates it (slower once, then cached)."
        fi
        info "The running production server was NOT touched. Run '$0 deploy' to roll it out."
    else
        error "Test failed — do NOT deploy yet. Review the build/container logs above."
        exit 1
    fi
}

# docker compose lifecycle helpers, shared by prod + staging.
compose_down() {
    local dir="$1" compose="$2" label="$3"
    resolve_remote_host
    info "Stopping $label..."
    remote "cd $dir && $compose down"
    info "$label stopped."
}

compose_restart() {
    local dir="$1" compose="$2" label="$3"
    resolve_remote_host
    info "Restarting $label..."
    remote "cd $dir && $compose restart"
    info "$label restarted."
}

compose_status() {
    local dir="$1" compose="$2" label="$3"
    resolve_remote_host
    info "Checking $label status on $SERVER_HOST..."
    remote "cd $dir && $compose ps && echo '' && $compose logs --tail=10"
}

# Follow staging logs.
staging_logs() {
    resolve_remote_host
    info "Fetching STAGING logs from $SERVER_HOST..."
    remote "cd $STAGING_REMOTE_DIR && $STAGING_COMPOSE logs -f --tail=200"
}

staging_status() { compose_status "$STAGING_REMOTE_DIR" "$STAGING_COMPOSE" "Gallager STAGING relay"; }
staging_stop()   { compose_down   "$STAGING_REMOTE_DIR" "$STAGING_COMPOSE" "Gallager STAGING relay"; }

# Deploy the static marketing website (gallager.app). Builds the Astro site
# locally (needs node/npm), rsyncs website/dist/ to the server, installs the
# Caddy vhost and reloads Caddy. One-time prerequisite: DNS for gallager.app
# and www.gallager.app must point at the server (see website/README.md).
deploy_website() {
    local website_dir
    website_dir="$(cd "$(dirname "$0")/../website" && pwd)"

    info "Building website..."
    (cd "$website_dir" && npm ci && npm run build)

    if [ ! -f "$website_dir/dist/index.html" ]; then
        error "Build produced no dist/index.html — aborting."
        exit 1
    fi

    resolve_remote_host
    info "Deploying website to $SERVER_HOST:$WEBSITE_REMOTE_DIR..."
    remote "mkdir -p $WEBSITE_REMOTE_DIR"
    rsync -az --delete -e ssh "$website_dir/dist/" "$REMOTE_HOST:$WEBSITE_REMOTE_DIR/"

    if remote "test -d $CADDY_CONF_D" 2>/dev/null; then
        info "Installing Caddy configuration ($WEBSITE_CADDY_FILE)..."
        rsync -az -e ssh "$(package_dir)/caddy/$WEBSITE_CADDY_FILE" "$REMOTE_HOST:$CADDY_CONF_D/"
        remote "systemctl reload caddy"
    else
        warn "Caddy conf.d not found on server; configure your web server manually."
    fi

    info "Verifying deployment..."
    if curl -sf -o /dev/null "$WEBSITE_URL"; then
        info "Website deployed: $WEBSITE_URL"
    else
        warn "Could not fetch $WEBSITE_URL — if this is the first deploy, check DNS for gallager.app."
    fi
}

# Show prod logs (warnings and errors only by default)
logs() {
    resolve_remote_host

    local mode="${1:-}"

    case "$mode" in
        all|info)
            info "Fetching all logs from $SERVER_HOST..."
            remote "cd $REMOTE_DIR && $PROD_COMPOSE logs -f --tail=100"
            ;;
        debug)
            info "Restarting container with debug logging..."
            remote "cd $REMOTE_DIR && LOG_LEVEL=debug $PROD_COMPOSE up -d && $PROD_COMPOSE logs -f --tail=100"
            warn "Note: Container is now running with debug logging. Run 'deploy.sh restart' to restore normal logging."
            ;;
        *)
            info "Fetching warnings and errors from $SERVER_HOST..."
            remote "cd $REMOTE_DIR && $PROD_COMPOSE logs -f --tail=500 2>&1 | grep -E '\[ (WARNING|ERROR|CRITICAL) \]|error|Error|ERROR|warning|Warning|WARNING'"
            ;;
    esac
}

stop()    { compose_down    "$REMOTE_DIR" "$PROD_COMPOSE" "ClaudeSpy relay server"; }
restart() { compose_restart "$REMOTE_DIR" "$PROD_COMPOSE" "ClaudeSpy relay server"; }
status()  { compose_status  "$REMOTE_DIR" "$PROD_COMPOSE" "ClaudeSpy relay server"; }

# Show help
usage() {
    echo "ClaudeSpy Relay Server Deployment"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  deploy          Deploy or update the PROD server (default)"
    echo "  test            Build + boot + health-check in isolation on the server (no prod impact)"
    echo "  staging         Deploy the isolated STAGING relay (licensing ON, staging.gallager.app)"
    echo "  staging-logs    Follow staging container logs"
    echo "  staging-status  Show staging container status + recent logs"
    echo "  staging-stop    Stop the staging relay (prod untouched)"
    echo "  website         Build the Astro site and deploy it to gallager.app"
    echo "  logs          Show warnings and errors only (follow mode)"
    echo "  logs all      Show all logs including info level"
    echo "  logs debug    Restart with debug logging (use 'restart' to restore)"
    echo "  stop          Stop the server"
    echo "  restart       Restart the server"
    echo "  status        Show container status and recent logs"
    echo "  help          Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  DEPLOY_HOST       Server IP or hostname (required)"
    echo "  DEPLOY_USER       SSH user (default: root)"
    echo "  REMOTE_DIR        Installation directory (default: /opt/claudespy)"
    echo "  HEALTH_CHECK_URL  URL for health check (default: https://relay.gallager.app/health)"
    echo "  TEST_REMOTE_DIR   Isolated dir for 'test' (default: /opt/claudespy-test)"
    echo "  TEST_PORT         Host port for the 'test' container (default: 8099)"
    echo ""
    echo "  # Staging (second isolated relay on the same box):"
    echo "  STAGING_REMOTE_DIR  Staging install dir (default: /opt/claudespy-staging)"
    echo "  STAGING_PROJECT     Compose project name (default: claudespy-staging)"
    echo "  STAGING_HEALTH_URL  Staging health URL (default: https://staging.gallager.app/health)"
    echo ""
    echo "  # Website (gallager.app static site):"
    echo "  WEBSITE_REMOTE_DIR  Website install dir (default: /opt/gallager-website)"
    echo "  WEBSITE_URL         Post-deploy check URL (default: https://gallager.app)"
    echo ""
    echo "  # Legacy Hetzner Cloud support:"
    echo "  HCLOUD_SERVER_NAME  Hetzner server name (alternative to DEPLOY_HOST)"
    echo ""
    echo "Example:"
    echo "  export DEPLOY_HOST=192.168.1.100"
    echo "  $0 deploy"
}

# Main
check_prerequisites

case "${1:-deploy}" in
    deploy)
        deploy
        ;;
    test)
        test_deploy
        ;;
    staging)
        deploy_staging
        ;;
    staging-logs)
        staging_logs
        ;;
    staging-status)
        staging_status
        ;;
    staging-stop)
        staging_stop
        ;;
    website)
        deploy_website
        ;;
    logs)
        logs "$2"
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        error "Unknown command: $1"
        usage
        exit 1
        ;;
esac
