#!/usr/bin/env python3
"""
Ingress hook bridge — starter template.

This script is what your AGENT's hooks invoke (e.g. a Claude Code PostToolUse
hook, or a Codex hook). It reads the hook event on stdin and forwards it to
Gallager's ingress socket, where it lands in your sidecar's `translate_event`.

This is a SEPARATE channel from the sidecar's stdio transport:
  - Sidecar stdio  → Content-Length framing  (sidecar.py)
  - Ingress socket → 4-byte big-endian length prefix + JSON body  (this file)

Your sidecar's `install` method should drop a copy of this script into the
agent's config directory and register it as a hook, substituting the two env
vars below (Gallager sets them when it spawns the sidecar, but the agent's hook
process won't have them — bake them in at install time, or rely on the defaults).
"""
import json
import os
import socket
import struct
import sys

# `install` should template these in. They default to Gallager's conventions so
# the bridge still works if the env happens to be inherited.
PLUGIN_ID = os.environ.get("GALLAGER_PLUGIN_ID", "my-agent")
SOCKET_PATH = os.environ.get(
    "GALLAGER_INGRESS_SOCK",
    os.path.expanduser("~/.gallager/state/ingress.sock"),
)

# TMUX_PANE is how Gallager routes the event to the right pane/session. No pane,
# nothing to route — exit quietly so we never break the agent.
tmux_pane = os.environ.get("TMUX_PANE", "")
if not tmux_pane:
    sys.exit(0)

raw = sys.stdin.read()
try:
    payload = json.loads(raw) if raw.strip() else {}
except Exception:
    sys.exit(0)

# `context` is a flat string→string env snapshot. TMUX_PANE is required; add any
# other env vars your sidecar's translate_event wants to read (project dir, etc).
context = {"TMUX_PANE": tmux_pane}
for var in ("CLAUDE_PROJECT_DIR",):  # EDIT HERE: add your agent's env vars
    val = os.environ.get(var)
    if val:
        context[var] = val

body = json.dumps({"plugin_id": PLUGIN_ID, "context": context, "payload": payload}).encode("utf-8")
frame = struct.pack(">I", len(body)) + body  # 4-byte big-endian length + body

try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5)
        sock.connect(SOCKET_PATH)
        sock.sendall(frame)
except Exception:
    pass  # Gallager not running / socket gone — drop silently, never block the agent.
