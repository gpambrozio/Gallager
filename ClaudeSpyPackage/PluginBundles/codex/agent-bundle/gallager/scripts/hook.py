#!/usr/bin/env python3
"""Gallager hook bridge — forwards a Codex CLI hook payload to the
sidecar's Unix socket via the GALLAGER_INGRESS_SOCK env var.

If the socket env is unset or the path doesn't exist, exit silently
(Gallager isn't running and we shouldn't block Codex).
"""
import json
import os
import socket
import struct
import sys

sock_path = os.environ.get("GALLAGER_INGRESS_SOCK")
if not sock_path or not os.path.exists(sock_path):
    sys.exit(0)

try:
    payload = json.load(sys.stdin)
except Exception as e:  # noqa: BLE001 — must not propagate, Codex shouldn't block
    sys.stderr.write(f"[gallager-hook] could not parse stdin: {e}\n")
    sys.exit(0)

# Forward the env vars the sidecar needs to correlate pane/project/session.
# Same set as the Claude bridge — the sidecar's IngressContext understands
# both agents' env vocabulary and the unused keys are simply absent.
ctx_keys = (
    "TMUX_PANE",
    "CLAUDE_PROJECT_DIR",
    "CLAUDE_SESSION_ID",
    "CODEX_PROJECT_DIR",
    "CODEX_SESSION_ID",
)
context = {k: os.environ[k] for k in ctx_keys if k in os.environ}

frame = json.dumps({"context": context, "payload": payload}).encode("utf-8")
length = struct.pack(">I", len(frame))

try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(2.0)
        s.connect(sock_path)
        s.sendall(length + frame)
except OSError as e:
    sys.stderr.write(f"[gallager-hook] socket error: {e}\n")
    sys.exit(0)
