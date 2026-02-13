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

    # Build in release mode to catch cross-module optimization issues
    info "Building server in release mode..."
    if ! swift build -c release --product ClaudeSpyExternalServer --package-path "$SCRIPT_DIR" 2>&1; then
        error "Release build failed! Fix compilation errors before deploying."
        exit 1
    fi
    info "Release build successful."

    # Build and run server tests (build target separately to avoid compiling unrelated targets like SwiftTerm)
    info "Building server tests..."
    if ! swift build --package-path "$SCRIPT_DIR" --target ClaudeSpyExternalServerTests 2>&1; then
        error "Server test build failed! Fix compilation errors before deploying."
        exit 1
    fi
    info "Running server tests..."
    if ! swift test --package-path "$SCRIPT_DIR" --skip-build --filter ClaudeSpyExternalServerTests 2>&1; then
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
    info "Syncing files to server..."
    rsync -az --delete \
        --exclude='.build' \
        --exclude='.git' \
        --exclude='*.xcodeproj' \
        --exclude='*.xcworkspace' \
        --exclude='Tests' \
        --exclude='data' \
        -e ssh \
        "$(dirname "$0")/" \
        "$REMOTE_HOST:$REMOTE_DIR/"

    # Copy Caddy config if directory exists on server
    info "Checking for Caddy configuration..."
    if ssh -o LogLevel=ERROR "$REMOTE_HOST" "test -d $CADDY_CONF_D" 2>/dev/null; then
        if [ -f "$(dirname "$0")/caddy/claudespy.caddy" ]; then
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
    HEALTH_URL="${HEALTH_CHECK_URL:-https://claudespy.gustavo.eng.br/health}"
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
    echo "  deploy        Deploy or update the server (default)"
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
