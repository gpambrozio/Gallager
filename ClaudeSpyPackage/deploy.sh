#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
HCLOUD_SERVER_NAME="cleancast"  # Reuse existing server
REMOTE_DIR="/opt/claudespy"
CADDY_CONF_D="/etc/caddy/conf.d"

# Get server IP from hcloud
get_server_ip() {
    hcloud server ip "$HCLOUD_SERVER_NAME" 2>/dev/null
}

# Print colored output
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    if ! command -v hcloud &> /dev/null; then
        error "hcloud CLI not found. Install with: brew install hcloud"
        exit 1
    fi

    if ! hcloud context active &> /dev/null; then
        error "No active hcloud context. Run: hcloud context create <name>"
        exit 1
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

    # Run server tests
    info "Running server tests..."
    if ! swift test --package-path "$SCRIPT_DIR" --filter ClaudeSpyExternalServerTests 2>&1; then
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

    # Get server IP
    SERVER_IP=$(get_server_ip)
    if [ -z "$SERVER_IP" ]; then
        error "Could not get server IP for '$HCLOUD_SERVER_NAME'"
        exit 1
    fi
    info "Deploying to server: $SERVER_IP"

    REMOTE_USER="root"
    REMOTE_HOST="$REMOTE_USER@$SERVER_IP"

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

    # Copy Caddy config
    info "Installing Caddy configuration..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "cp $REMOTE_DIR/caddy/claudespy.caddy $CADDY_CONF_D/"

    # Ensure data directory exists with correct permissions
    info "Ensuring data directory permissions..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "mkdir -p $REMOTE_DIR/data && chmod 777 $REMOTE_DIR/data"

    # Build and start the container
    info "Building and starting container..."

    # Run remote commands and capture exit code
    BUILD_OUTPUT=$(ssh -T -o LogLevel=ERROR "$REMOTE_HOST" << REMOTE_SCRIPT 2>&1
        cd $REMOTE_DIR
        set -e

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

        # Reload Caddy to pick up new config
        echo "Reloading Caddy..."
        systemctl reload caddy

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
    HEALTH_CHECK=$(curl -s "https://claudespy.gustavo.eng.br/health" 2>/dev/null || echo "failed")

    if echo "$HEALTH_CHECK" | grep -q '"status":"ok"'; then
        info "Deployment successful! Server is healthy."
        echo ""
        echo -e "${GREEN}ClaudeSpy relay server is now running at:${NC}"
        echo "  https://claudespy.gustavo.eng.br"
        echo ""
        echo "Endpoints:"
        echo "  GET  /health                    - Health check"
        echo "  POST /api/pairing/register      - Register pairing code (Mac)"
        echo "  POST /api/pairing/complete      - Complete pairing (iOS)"
        echo "  WS   /api/ws                    - WebSocket connection"
    else
        warn "Health check failed. Server may still be starting."
        echo "Check manually: curl https://claudespy.gustavo.eng.br/health"
    fi
}

# Show logs
logs() {
    SERVER_IP=$(get_server_ip)
    REMOTE_HOST="root@$SERVER_IP"

    info "Fetching logs from $SERVER_IP..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "cd $REMOTE_DIR && docker compose logs -f --tail=100"
}

# Stop the server
stop() {
    SERVER_IP=$(get_server_ip)
    REMOTE_HOST="root@$SERVER_IP"

    info "Stopping ClaudeSpy relay server..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "cd $REMOTE_DIR && docker compose down"
    info "Server stopped."
}

# Restart the server
restart() {
    SERVER_IP=$(get_server_ip)
    REMOTE_HOST="root@$SERVER_IP"

    info "Restarting ClaudeSpy relay server..."
    ssh -o LogLevel=ERROR "$REMOTE_HOST" "cd $REMOTE_DIR && docker compose restart"
    info "Server restarted."
}

# Show help
usage() {
    echo "ClaudeSpy Relay Server Deployment"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  deploy    Deploy or update the server (default)"
    echo "  logs      Show server logs (follow mode)"
    echo "  stop      Stop the server"
    echo "  restart   Restart the server"
    echo "  help      Show this help message"
}

# Main
check_prerequisites

case "${1:-deploy}" in
    deploy)
        deploy
        ;;
    logs)
        logs
        ;;
    stop)
        stop
        ;;
    restart)
        restart
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
