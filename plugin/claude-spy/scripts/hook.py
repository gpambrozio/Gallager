#!/usr/bin/env python3
import sys
import os
from urllib.request import urlopen, Request
from urllib.parse import urlencode
from urllib.error import URLError

def read_port():
    """Read the hook server port from the per-user port file."""
    port_file = os.path.expanduser('~/.claudespy-port')
    try:
        with open(port_file, 'r') as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return None

def main():
    tmux_pane = os.environ.get('TMUX_PANE', '')

    if not tmux_pane:
        # Exit if not running inside tmux
        exit(0)

    port = read_port()
    if port is None:
        # ClaudeSpy is not running or port file missing
        exit(0)

    project_path = os.environ.get('CLAUDE_PROJECT_DIR', '')

    # Read stdin
    stdin_data = sys.stdin.read()

    # Properly encode query parameters
    query_params = urlencode({
        'project_path': project_path,
        'tmux_pane': tmux_pane
    })

    # Make POST request
    url = f"http://localhost:{port}/api/hooks?{query_params}"

    try:
        req = Request(url,
                     data=stdin_data.encode('utf-8'),
                     headers={'Content-Type': 'application/json'},
                     method='POST')
        with urlopen(req, timeout=5) as response:
            # Read response but don't do anything with it
            response.read().decode('utf-8')
            exit(0)
    except (URLError, Exception):
        # Fallback response if server is not available
        exit(0)

if __name__ == '__main__':
    main()
