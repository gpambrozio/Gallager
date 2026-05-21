#!/usr/bin/env python3
"""Bridge script that forwards Claude Code / Codex CLI hook events to the
local ClaudeSpy HTTP server.

Invoked with optional `--agent claude-code` (default) or `--agent codex`.
Reads the hook payload (JSON) on stdin and POSTs it to
`http://localhost:<port>/api/hooks` with `project_path`, `tmux_pane`, and
`agent` query parameters so the server can attribute the event correctly.

For Claude Code, project_path comes from CLAUDE_PROJECT_DIR. Codex doesn't
set a project-dir env var, so we fall back to the `cwd` field in the JSON
payload (and CODEX_CWD if Codex ever exports one).
"""
import json
import os
import sys
from urllib.error import URLError
from urllib.parse import urlencode
from urllib.request import urlopen, Request


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


def parse_agent():
    """Returns the agent identifier from argv, defaulting to 'claude-code'."""
    args = sys.argv[1:]
    for i, arg in enumerate(args):
        if arg == '--agent' and i + 1 < len(args):
            value = args[i + 1].strip().lower()
            if value in ('codex', 'claude-code', 'claude'):
                # Normalize "claude" to "claude-code" for the wire format.
                return 'claude-code' if value == 'claude' else value
    return 'claude-code'


def resolve_project_path(agent, payload):
    """Picks the best available project path for the given agent."""
    if agent == 'codex':
        # Codex's hook payload carries cwd directly.
        if isinstance(payload, dict):
            cwd = payload.get('cwd')
            if isinstance(cwd, str) and cwd:
                return cwd
        return os.environ.get('CODEX_CWD', '')
    return os.environ.get('CLAUDE_PROJECT_DIR', '')


def main():
    tmux_pane = os.environ.get('TMUX_PANE', '')
    if not tmux_pane:
        # Exit if not running inside tmux
        sys.exit(0)

    port = read_port()
    if port is None:
        # ClaudeSpy is not running or port file missing
        sys.exit(0)

    agent = parse_agent()

    # Read stdin
    stdin_data = sys.stdin.read()

    # For Codex we need cwd from the payload; for Claude Code the env var
    # is authoritative and we don't need to parse the body.
    project_path = ''
    if agent == 'codex':
        try:
            payload = json.loads(stdin_data) if stdin_data else None
        except (ValueError, TypeError):
            payload = None
        project_path = resolve_project_path(agent, payload)
    else:
        project_path = resolve_project_path(agent, None)

    query_params = urlencode({
        'project_path': project_path,
        'tmux_pane': tmux_pane,
        'agent': agent,
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
            sys.exit(0)
    except (URLError, Exception):
        # Fallback: never block the agent if the server is down.
        sys.exit(0)


if __name__ == '__main__':
    main()
