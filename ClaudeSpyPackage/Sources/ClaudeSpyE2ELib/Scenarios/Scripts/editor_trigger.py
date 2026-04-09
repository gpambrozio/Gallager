#!/usr/bin/env python3
"""
Simulates the GallagerEditor CLI for E2E testing.

Connects to the editor Unix domain socket, sends paneId\tfilePath\n,
then blocks until the app signals "done\n" or the connection closes.

Usage: python3 editor_trigger.py <pane_id> <file_path>
"""
import socket
import sys
import os

if len(sys.argv) < 3:
    print("Usage: editor_trigger.py <pane_id> <file_path>", file=sys.stderr)
    sys.exit(1)

pane_id = sys.argv[1]
file_path = sys.argv[2]
sock_path = os.path.join(os.environ.get("TMPDIR", "/tmp"), "gallager-editor.sock")

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect(sock_path)
except Exception as e:
    print(f"Failed to connect to {sock_path}: {e}", file=sys.stderr)
    sys.exit(1)

message = f"{pane_id}\t{file_path}\n"
sock.sendall(message.encode())

# Block until the app sends "done\n" or closes the connection
try:
    data = sock.recv(64)
except Exception:
    pass

sock.close()

# Print the final file contents so the terminal shows the edit result
try:
    with open(file_path, "r") as f:
        print(f"Editor result: {f.read().strip()}")
except Exception:
    print("Editor session complete")
