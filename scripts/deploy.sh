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

# Isolated-test configuration (used by the `test` command). These intentionally
# differ from the prod dir/port/container so a test run never touches the running
# server.
TEST_REMOTE_DIR="${TEST_REMOTE_DIR:-/opt/claudespy-test}"
TEST_PORT="${TEST_PORT:-8099}"
TEST_IMAGE="${TEST_IMAGE:-claudespy-relay:test}"
TEST_CONTAINER="${TEST_CONTAINER:-claudespy-relay-test}"

# Staging configuration (used by the `staging*` commands). A second, fully
# isolated relay on the SAME box behind staging.gallager.gustavo.eng.br →
# 127.0.0.1:8081, with Lemon Squeezy licensing ENABLED via its own on-server
# .env. Prod (/opt/claudespy, :8080, licensing off) is never touched.
STAGING_REMOTE_DIR="${STAGING_REMOTE_DIR:-/opt/claudespy-staging}"
STAGING_PROJECT="${STAGING_PROJECT:-claudespy-staging}"
STAGING_CADDY_FILE="${STAGING_CADDY_FILE:-claudespy-staging.caddy}"
STAGING_HEALTH_URL="${STAGING_HEALTH_URL:-https://staging.gallager.gustavo.eng.br/health}"
# Compose invocation that layers the staging override and names the project so it
# can't collide with prod's container/network. Relative -f paths resolve after a
# `cd $STAGING_REMOTE_DIR`.
STAGING_COMPOSE="docker compose -f docker-compose.yml -f docker-compose.staging.yml -p ${STAGING_PROJECT}"

# Print colored output
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

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

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    PACKAGE_DIR="$(cd "$SCRIPT_DIR/../ClaudeSpyPackage" && pwd)"

    # Build in release mode to catch cross-module optimization issues
    info "Building server in release mode..."
    if ! swift build -c release --product ClaudeSpyExternalServer --package-path "$PACKAGE_DIR" 2>&1; then
        error "Release build failed! Fix compilation errors before deploying."
        exit 1
    fi
    info "Release build successful."

    # Build and run server tests (build target separately to avoid compiling unrelated targets like SwiftTerm)
    info "Building server tests..."
    if ! swift build --package-path "$PACKAGE_DIR" --target ClaudeSpyExternalServerTests 2>&1; then
        error "Server test build failed! Fix compilation errors before deploying."
        exit 1
    fi
    info "Running server tests..."
    if ! swift test --package-path "$PACKAGE_DIR" --skip-build --filter ClaudeSpyExternalServerTests 2>&1; then
        error "Server tests failed! Fix test failures before deploying."
        exit 1
    fi
    info "All tests passed."

    echo ""
    info "Pre-deploy checks completed successfully."
    echo ""
}

# Main deployment
deploy() {
    # Run pre-deploy checks first
    pre_deploy_checks

    info "Starting ClaudeSpy relay server deployment..."

    # Get server host
    SERVER_HOST=$(get_server_host)
    if [ -z "$SERVER_HOST" ]; then
        error "Could not determine server host"
        exit 1
    fi
    info "Deploying to server: $SERVER_HOST"

    REMOTE_HOST="$DEPLOY_USER@$SERVER_HOST"

    # Create remote directory if it doesn't exist
    info "Setting up remote directory..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "mkdir -p $REMOTE_DIR"

    # Sync files to server (only the package directory)
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    PACKAGE_DIR="$(cd "$SCRIPT_DIR/../ClaudeSpyPackage" && pwd)"

    info "Syncing files to server..."
    rsync -az --delete \
        --exclude='.build' \
        --exclude='.git' \
        --exclude='*.xcodeproj' \
        --exclude='*.xcworkspace' \
        --exclude='Tests' \
        --exclude='data' \
        -e ssh \
        "$PACKAGE_DIR/" \
        "$REMOTE_HOST:$REMOTE_DIR/"

    # Copy Caddy config if directory exists on server
    info "Checking for Caddy configuration..."
    if ssh -o LogLevel=ERROR "$REMOTE_HOST" "test -d $CADDY_CONF_D" 2>/dev/null; then
        if [ -f "$PACKAGE_DIR/caddy/claudespy.caddy" ]; then
            info "Installing Caddy configuration..."
            ssh -o LogLevel=ERROR "$REMOTE_HOST" "cp $REMOTE_DIR/caddy/claudespy.caddy $CADDY_CONF_D/"
        fi
    else
        info "Caddy conf.d directory not found, skipping Caddy config installation."
        info "You may need to configure your reverse proxy manually."
    fi

    # Ensure data directory exists with correct permissions
    info "Ensuring data directory permissions..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "mkdir -p $REMOTE_DIR/data && chmod 777 $REMOTE_DIR/data"

    # Build and start the container
    info "Building and starting container..."

    # Run remote commands and capture exit code
    BUILD_OUTPUT=$(ssh -T -o LogLevel=ERROR "$REMOTE_HOST" << REMOTE_SCRIPT 2>&1
        cd $REMOTE_DIR
        set -eo pipefail

        # Build the image with BuildKit enabled for cache mounts (incremental Swift builds)
        echo "Building Docker image with BuildKit..."
        BUILD_LOG=\$(mktemp)
        if ! DOCKER_BUILDKIT=1 docker compose build --progress=plain 2>&1 | tee "\$BUILD_LOG"; then
            echo "DEPLOY_BUILD_FAILED"
            cat "\$BUILD_LOG" | grep -E '(error:|ERROR|failed)' | head -20
            rm -f "\$BUILD_LOG"
            exit 1
        fi

        # Show filtered build output
        cat "\$BUILD_LOG" | grep -E '(^#[0-9]+ \[|CACHED|DONE|ERROR|error:|Build of product|exporting to image|naming to)' | head -50
        rm -f "\$BUILD_LOG"

        # Stop existing container if running
        docker compose down 2>/dev/null || true

        # Start the new container
        echo "Starting container..."
        docker compose up -d 2>&1 | grep -v "^\$"

        # Reload Caddy if it's running
        if systemctl is-active --quiet caddy 2>/dev/null; then
            echo "Reloading Caddy..."
            systemctl reload caddy
        fi

        # Show container status
        echo ""
        echo "Container status:"
        docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || docker compose ps
REMOTE_SCRIPT
    )
    BUILD_EXIT_CODE=$?

    # Filter out Ubuntu MOTD noise and display output
    echo "$BUILD_OUTPUT" | grep -v -E '(^Welcome to|Documentation:|Management:|Support:|System (information|load)|Usage of|Memory usage|Swap usage|Processes:|Users logged|IPv[46] address|Expanded Security|update.*applied|additional updates|additional security|Learn more about|ubuntu\.com|help\.ubuntu)' | grep -v '^[[:space:]]*$'

    # Check if build failed
    if [ $BUILD_EXIT_CODE -ne 0 ] || echo "$BUILD_OUTPUT" | grep -q "DEPLOY_BUILD_FAILED"; then
        error "Docker build failed on server! Deployment aborted."
        exit 1
    fi

    # Wait for health check
    info "Waiting for server to be healthy..."
    sleep 5

    # Test the deployment
    info "Testing deployment..."

    # Determine health check URL
    HEALTH_URL="${HEALTH_CHECK_URL:-https://gallager.gustavo.eng.br/health}"
    HEALTH_CHECK=$(curl -s "$HEALTH_URL" 2>/dev/null || echo "failed")

    if echo "$HEALTH_CHECK" | grep -q '"status":"ok"'; then
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

# Isolated dry-run: rsync to a throwaway dir, build the image, boot the relay on a
# spare port with throwaway data, hit /health, then tear everything down — all
# WITHOUT touching the running production container, port, or data. Use this to
# validate a build (e.g. a Swift toolchain or dependency bump) before `deploy`.
test_deploy() {
    info "Starting isolated relay test (no impact on the running server)..."

    SERVER_HOST=$(get_server_host)
    if [ -z "$SERVER_HOST" ]; then
        error "Could not determine server host"
        exit 1
    fi
    info "Testing on server: $SERVER_HOST (dir: $TEST_REMOTE_DIR, port: $TEST_PORT)"
    REMOTE_HOST="$DEPLOY_USER@$SERVER_HOST"

    # Sync the package to an ISOLATED dir so prod ($REMOTE_DIR) is untouched.
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    PACKAGE_DIR="$(cd "$SCRIPT_DIR/../ClaudeSpyPackage" && pwd)"

    info "Syncing files to $TEST_REMOTE_DIR..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "mkdir -p $TEST_REMOTE_DIR"
    rsync -az --delete \
        --exclude='.build' \
        --exclude='.git' \
        --exclude='*.xcodeproj' \
        --exclude='*.xcworkspace' \
        --exclude='Tests' \
        --exclude='data' \
        -e ssh \
        "$PACKAGE_DIR/" \
        "$REMOTE_HOST:$TEST_REMOTE_DIR/"

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

    # Filter out Ubuntu MOTD noise and display output.
    echo "$TEST_OUTPUT" | grep -v -E '(^Welcome to|Documentation:|Management:|Support:|System (information|load)|Usage of|Memory usage|Swap usage|Processes:|Users logged|IPv[46] address|Expanded Security|update.*applied|additional updates|additional security|Learn more about|ubuntu\.com|help\.ubuntu)' | grep -v '^[[:space:]]*$'

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

# Staging deployment: a second, isolated relay on the SAME box behind
# staging.gallager.gustavo.eng.br → 127.0.0.1:8081, with Lemon Squeezy licensing
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

    SERVER_HOST=$(get_server_host)
    if [ -z "$SERVER_HOST" ]; then
        error "Could not determine server host"
        exit 1
    fi
    info "Deploying STAGING to: $SERVER_HOST (dir: $STAGING_REMOTE_DIR, project: $STAGING_PROJECT)"
    REMOTE_HOST="$DEPLOY_USER@$SERVER_HOST"

    # Preflight: the staging .env must already exist on the server, because we
    # deliberately don't rsync it. Fail loud with first-time setup steps.
    if ! ssh -o LogLevel=ERROR "$REMOTE_HOST" "test -f $STAGING_REMOTE_DIR/.env" 2>/dev/null; then
        error "Missing $STAGING_REMOTE_DIR/.env on the server."
        echo ""
        echo "First-time staging setup (run once):"
        echo "  1. DNS: point staging.gallager.gustavo.eng.br at this server's IP."
        echo "  2. ssh $REMOTE_HOST 'mkdir -p $STAGING_REMOTE_DIR/secrets'"
        echo "  3. scp ClaudeSpyPackage/.env.staging.example $REMOTE_HOST:$STAGING_REMOTE_DIR/.env"
        echo "     then edit it: set LEMONSQUEEZY_* to your Lemon Squeezy TEST-mode ids + APNS_* values."
        echo "  4. scp ClaudeSpyPackage/secrets/AuthKey.p8 $REMOTE_HOST:$STAGING_REMOTE_DIR/secrets/AuthKey.p8"
        echo ""
        echo "Then re-run: $0 staging"
        exit 1
    fi

    # Sync the package to the ISOLATED staging dir, EXCLUDING .env + secrets
    # (managed on-server) and data (persistent state).
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    PACKAGE_DIR="$(cd "$SCRIPT_DIR/../ClaudeSpyPackage" && pwd)"

    info "Syncing files to $STAGING_REMOTE_DIR (excluding .env, secrets, data)..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "mkdir -p $STAGING_REMOTE_DIR"
    rsync -az --delete \
        --exclude='.build' \
        --exclude='.git' \
        --exclude='*.xcodeproj' \
        --exclude='*.xcworkspace' \
        --exclude='Tests' \
        --exclude='data' \
        --exclude='.env' \
        --exclude='secrets' \
        -e ssh \
        "$PACKAGE_DIR/" \
        "$REMOTE_HOST:$STAGING_REMOTE_DIR/"

    # Install the staging Caddy site block (separate hostname + port from prod).
    info "Checking for Caddy configuration..."
    if ssh -o LogLevel=ERROR "$REMOTE_HOST" "test -d $CADDY_CONF_D" 2>/dev/null; then
        if [ -f "$PACKAGE_DIR/caddy/$STAGING_CADDY_FILE" ]; then
            info "Installing staging Caddy configuration ($STAGING_CADDY_FILE)..."
            ssh -o LogLevel=ERROR "$REMOTE_HOST" "cp $STAGING_REMOTE_DIR/caddy/$STAGING_CADDY_FILE $CADDY_CONF_D/"
        fi
    else
        info "Caddy conf.d directory not found, skipping Caddy config installation."
        info "You may need to configure your reverse proxy manually."
    fi

    # Ensure the staging data directory exists with correct permissions.
    info "Ensuring data directory permissions..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "mkdir -p $STAGING_REMOTE_DIR/data && chmod 777 $STAGING_REMOTE_DIR/data"

    info "Building and starting the staging container..."
    BUILD_OUTPUT=$(ssh -T -o LogLevel=ERROR "$REMOTE_HOST" << REMOTE_SCRIPT 2>&1
        cd $STAGING_REMOTE_DIR
        set -eo pipefail

        # Build the image with BuildKit enabled for cache mounts.
        echo "Building Docker image with BuildKit..."
        BUILD_LOG=\$(mktemp)
        if ! DOCKER_BUILDKIT=1 $STAGING_COMPOSE build --progress=plain 2>&1 | tee "\$BUILD_LOG"; then
            echo "DEPLOY_BUILD_FAILED"
            cat "\$BUILD_LOG" | grep -E '(error:|ERROR|failed)' | head -20
            rm -f "\$BUILD_LOG"
            exit 1
        fi

        # Show filtered build output.
        cat "\$BUILD_LOG" | grep -E '(^#[0-9]+ \[|CACHED|DONE|ERROR|error:|Build of product|exporting to image|naming to)' | head -50
        rm -f "\$BUILD_LOG"

        # Stop the existing staging container if running (prod is a different project).
        $STAGING_COMPOSE down 2>/dev/null || true

        echo "Starting staging container..."
        $STAGING_COMPOSE up -d 2>&1 | grep -v "^\$"

        # Reload Caddy if it's running (picks up the staging site block).
        if systemctl is-active --quiet caddy 2>/dev/null; then
            echo "Reloading Caddy..."
            systemctl reload caddy
        fi

        echo ""
        echo "Container status:"
        $STAGING_COMPOSE ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || $STAGING_COMPOSE ps
REMOTE_SCRIPT
    )
    BUILD_EXIT_CODE=$?

    # Filter out Ubuntu MOTD noise and display output.
    echo "$BUILD_OUTPUT" | grep -v -E '(^Welcome to|Documentation:|Management:|Support:|System (information|load)|Usage of|Memory usage|Swap usage|Processes:|Users logged|IPv[46] address|Expanded Security|update.*applied|additional updates|additional security|Learn more about|ubuntu\.com|help\.ubuntu)' | grep -v '^[[:space:]]*$'

    if [ $BUILD_EXIT_CODE -ne 0 ] || echo "$BUILD_OUTPUT" | grep -q "DEPLOY_BUILD_FAILED"; then
        error "Staging Docker build failed! Deployment aborted (prod untouched)."
        exit 1
    fi

    info "Waiting for staging server to be healthy..."
    sleep 5

    info "Testing staging deployment..."
    HEALTH_CHECK=$(curl -s "$STAGING_HEALTH_URL" 2>/dev/null || echo "failed")
    if echo "$HEALTH_CHECK" | grep -q '"status":"ok"'; then
        info "Staging deployment successful! Server is healthy."
        echo ""
        echo -e "${GREEN}Gallager STAGING relay is now running.${NC}"
        echo ""
        echo "Health check: $STAGING_HEALTH_URL"
        echo ""
        echo "Point a TEST host Mac + viewer at (Remote Access → Server URL):"
        echo "  wss://staging.gallager.gustavo.eng.br"
        echo "Your everyday devices stay on wss://gallager.gustavo.eng.br."
    else
        warn "Staging health check failed or server is still starting."
        echo "Check manually: curl $STAGING_HEALTH_URL"
        echo "Container logs: $0 staging-logs"
    fi
}

# Follow staging logs.
staging_logs() {
    SERVER_HOST=$(get_server_host)
    REMOTE_HOST="$DEPLOY_USER@$SERVER_HOST"
    info "Fetching STAGING logs from $SERVER_HOST..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "cd $STAGING_REMOTE_DIR && $STAGING_COMPOSE logs -f --tail=200"
}

# Show staging status + recent logs.
staging_status() {
    SERVER_HOST=$(get_server_host)
    REMOTE_HOST="$DEPLOY_USER@$SERVER_HOST"
    info "Checking STAGING relay status on $SERVER_HOST..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "cd $STAGING_REMOTE_DIR && $STAGING_COMPOSE ps && echo '' && $STAGING_COMPOSE logs --tail=10"
}

# Stop the staging relay (prod untouched).
staging_stop() {
    SERVER_HOST=$(get_server_host)
    REMOTE_HOST="$DEPLOY_USER@$SERVER_HOST"
    info "Stopping Gallager STAGING relay..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "cd $STAGING_REMOTE_DIR && $STAGING_COMPOSE down"
    info "Staging stopped. Production was not touched."
}

# Show logs (warnings and errors only by default)
logs() {
    SERVER_HOST=$(get_server_host)
    REMOTE_HOST="$DEPLOY_USER@$SERVER_HOST"

    local mode="${1:-}"

    case "$mode" in
        all|info)
            info "Fetching all logs from $SERVER_HOST..."
            ssh -o LogLevel=ERROR "$REMOTE_HOST" "cd $REMOTE_DIR && docker compose logs -f --tail=100"
            ;;
        debug)
            info "Restarting container with debug logging..."
            ssh -o LogLevel=ERROR "$REMOTE_HOST" "cd $REMOTE_DIR && LOG_LEVEL=debug docker compose up -d && docker compose logs -f --tail=100"
            warn "Note: Container is now running with debug logging. Run 'deploy.sh restart' to restore normal logging."
            ;;
        *)
            info "Fetching warnings and errors from $SERVER_HOST..."
            ssh -o LogLevel=ERROR "$REMOTE_HOST" "cd $REMOTE_DIR && docker compose logs -f --tail=500 2>&1 | grep -E '\[ (WARNING|ERROR|CRITICAL) \]|error|Error|ERROR|warning|Warning|WARNING'"
            ;;
    esac
}

# Stop the server
stop() {
    SERVER_HOST=$(get_server_host)
    REMOTE_HOST="$DEPLOY_USER@$SERVER_HOST"

    info "Stopping ClaudeSpy relay server..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "cd $REMOTE_DIR && docker compose down"
    info "Server stopped."
}

# Restart the server
restart() {
    SERVER_HOST=$(get_server_host)
    REMOTE_HOST="$DEPLOY_USER@$SERVER_HOST"

    info "Restarting ClaudeSpy relay server..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "cd $REMOTE_DIR && docker compose restart"
    info "Server restarted."
}

# Show status
status() {
    SERVER_HOST=$(get_server_host)
    REMOTE_HOST="$DEPLOY_USER@$SERVER_HOST"

    info "Checking ClaudeSpy relay server status..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "cd $REMOTE_DIR && docker compose ps && echo '' && docker compose logs --tail=10"
}

# Show help
usage() {
    echo "ClaudeSpy Relay Server Deployment"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  deploy          Deploy or update the PROD server (default)"
    echo "  test            Build + boot + health-check in isolation on the server (no prod impact)"
    echo "  staging         Deploy the isolated STAGING relay (licensing ON, staging.gallager.gustavo.eng.br)"
    echo "  staging-logs    Follow staging container logs"
    echo "  staging-status  Show staging container status + recent logs"
    echo "  staging-stop    Stop the staging relay (prod untouched)"
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
    echo "  HEALTH_CHECK_URL  URL for health check (default: http://\$DEPLOY_HOST:8080/health)"
    echo "  TEST_REMOTE_DIR   Isolated dir for 'test' (default: /opt/claudespy-test)"
    echo "  TEST_PORT         Host port for the 'test' container (default: 8099)"
    echo ""
    echo "  # Staging (second isolated relay on the same box):"
    echo "  STAGING_REMOTE_DIR  Staging install dir (default: /opt/claudespy-staging)"
    echo "  STAGING_PROJECT     Compose project name (default: claudespy-staging)"
    echo "  STAGING_HEALTH_URL  Staging health URL (default: https://staging.gallager.gustavo.eng.br/health)"
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
