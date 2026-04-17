#!/usr/bin/env python3
"""
Simulates the Gallager CLI `edit` command for E2E testing.

Connects to the app's E2E API socket, sends a JSON-RPC `editor.open` request,
then blocks until the app responds (after the user finishes editing in the overlay).

Usage: python3 editor_trigger.py <pane_id> <file_path>
"""
import json
import os
import socket
import sys
import uuid

if len(sys.argv) < 3:
    print("Usage: editor_trigger.py <pane_id> <file_path>", file=sys.stderr)
    sys.exit(1)

pane_id = sys.argv[1]
file_path = sys.argv[2]
sock_path = os.path.join(os.environ.get("TMPDIR", "/tmp"), "gallager-e2e.sock")

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect(sock_path)
except Exception as e:
    print(f"Failed to connect to {sock_path}: {e}", file=sys.stderr)
    sys.exit(1)

request = {
    "id": str(uuid.uuid4()),
    "method": "editor.open",
    "params": {
        "pane_id": pane_id,
        "file_path": file_path,
    },
}
sock.sendall((json.dumps(request) + "\n").encode())

# Block reading the response until the app finishes editing and writes it
buffer = b""
try:
    while b"\n" not in buffer:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buffer += chunk
except Exception:
    pass

sock.close()

# Print the final file contents so the terminal shows the edit result
try:
    with open(file_path, "r") as f:
        print(f"Editor result: {f.read().strip()}")
except Exception:
    print("Editor session complete")
