#!/usr/bin/env python3
import json
import os
import socket
import struct
import sys

PLUGIN_ID = "claude-code"
SOCKET_PATH = os.path.expanduser("~/.gallager/state/ingress.sock")


def main():
    tmux_pane = os.environ.get("TMUX_PANE", "")
    if not tmux_pane:
        return  # Not inside tmux — nothing to mirror.

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return

    context = {"TMUX_PANE": tmux_pane}
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if project_dir:
        context["CLAUDE_PROJECT_DIR"] = project_dir

    body = json.dumps(
        {"plugin_id": PLUGIN_ID, "context": context, "payload": payload}
    ).encode("utf-8")
    frame = struct.pack(">I", len(body)) + body

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5)
            sock.connect(SOCKET_PATH)
            sock.sendall(frame)
    except Exception:
        return  # Gallager not running / socket gone — drop silently.


if __name__ == "__main__":
    main()
