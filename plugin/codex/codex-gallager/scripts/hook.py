#!/usr/bin/env python3
"""Codex CLI hook bridge for the Gallager monitoring app.

Reads a Codex hook payload on stdin and POSTs it to the locally-running
Gallager HTTP server at `http://localhost:<port>/api/hooks`. The port is
discovered from `~/.claudespy-port`; if it's missing or Gallager isn't
running, the bridge exits silently so Codex never blocks.

Codex doesn't expose a project-dir env var the way Claude Code does, so
the working directory comes straight from the `cwd` field of the hook
payload.
"""
import json
import os
import sys
from urllib.error import URLError
from urllib.request import urlopen, Request
from urllib.parse import urlencode


def read_port():
    """Read the hook server port from the per-user port file."""
    port_file = os.path.expanduser('~/.claudespy-port')
    try:
        with open(port_file, 'r') as f:
            port = int(f.read().strip())
            if 1 <= port <= 65535:
                return port
            return None
    except (OSError, ValueError):
        return None


def main():
    tmux_pane = os.environ.get('TMUX_PANE', '')
    if not tmux_pane:
        sys.exit(0)

    port = read_port()
    if port is None:
        sys.exit(0)

    stdin_data = sys.stdin.read()

    project_path = ''
    if stdin_data:
        try:
            payload = json.loads(stdin_data)
            if isinstance(payload, dict):
                cwd = payload.get('cwd')
                if isinstance(cwd, str):
                    project_path = cwd
        except ValueError:
            pass

    query_params = urlencode({
        'project_path': project_path,
        'tmux_pane': tmux_pane,
        'agent': 'codex',
    })
    url = f"http://localhost:{port}/api/hooks?{query_params}"

    try:
        req = Request(
            url,
            data=stdin_data.encode('utf-8'),
            headers={'Content-Type': 'application/json'},
            method='POST',
        )
        with urlopen(req, timeout=5) as response:
            response.read().decode('utf-8')
    except Exception:
        # Never block Codex on a Gallager outage.
        pass

    sys.exit(0)


if __name__ == '__main__':
    main()
