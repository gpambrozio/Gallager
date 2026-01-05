#!/bin/bash
# Setup Caddy to use conf.d directory for multi-project configuration
# Run this once on the server to migrate from single Caddyfile to conf.d approach
#
# Usage: ssh root@<server> 'bash -s' < scripts/setup-caddy-confd.sh

set -e

echo "Setting up Caddy conf.d directory structure..."

# Create conf.d directory
mkdir -p /etc/caddy/conf.d

# Backup current Caddyfile
if [ -f /etc/caddy/Caddyfile ]; then
    cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.backup.$(date +%Y%m%d_%H%M%S)
    echo "Backed up existing Caddyfile"
fi

# Check if import directive already exists
if grep -q "import /etc/caddy/conf.d/\*" /etc/caddy/Caddyfile 2>/dev/null; then
    echo "Caddyfile already imports conf.d, skipping..."
else
    # Extract existing site blocks and move to conf.d
    # First, let's see what's in the current Caddyfile
    echo "Current Caddyfile contents:"
    cat /etc/caddy/Caddyfile
    echo ""

    # Create a new Caddyfile that imports conf.d
    # Keep global options at the top if any exist
    cat > /etc/caddy/Caddyfile << 'EOF'
# Global Caddy configuration
{
    # Email for Let's Encrypt certificates
    email admin@gustavo.eng.br
}

# Import all site configurations from conf.d
import /etc/caddy/conf.d/*
EOF

    echo "Created new Caddyfile with conf.d import"

    # If there was an existing site config (CleanCast), move it to conf.d
    if [ -f /etc/caddy/Caddyfile.backup.* ]; then
        # Extract site blocks from backup (everything that's not global options)
        LATEST_BACKUP=$(ls -t /etc/caddy/Caddyfile.backup.* | head -1)

        # Check if backup has site config (not just the new template)
        if grep -q "reverse_proxy" "$LATEST_BACKUP" 2>/dev/null; then
            echo "Found existing site configuration, extracting to conf.d/cleancast.caddy..."

            # Extract the site block (everything after global options or from start if no global)
            # This is a simplified extraction - may need adjustment based on actual Caddyfile format
            if grep -q "^{" "$LATEST_BACKUP"; then
                # Has global options, extract everything after the closing }
                awk '/^[a-zA-Z].*\{/,0' "$LATEST_BACKUP" > /etc/caddy/conf.d/cleancast.caddy
            else
                # No global options, the whole file is site config
                cp "$LATEST_BACKUP" /etc/caddy/conf.d/cleancast.caddy
            fi

            echo "Extracted CleanCast config to /etc/caddy/conf.d/cleancast.caddy"
        fi
    fi
fi

# Validate Caddy configuration
echo "Validating Caddy configuration..."
caddy validate --config /etc/caddy/Caddyfile

# Reload Caddy
echo "Reloading Caddy..."
systemctl reload caddy

echo ""
echo "Caddy conf.d setup complete!"
echo ""
echo "Directory structure:"
ls -la /etc/caddy/
echo ""
echo "conf.d contents:"
ls -la /etc/caddy/conf.d/ 2>/dev/null || echo "(empty)"
echo ""
echo "To add a new site, create a file in /etc/caddy/conf.d/ and reload Caddy."
