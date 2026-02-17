#!/bin/bash

# Binary-safe throttled file output using Python (guaranteed on macOS).
# Reads a file in chunks with configurable delays between each chunk.
#
# Usage: throttled-cat.sh <file> [chunk_size_bytes] [delay_ms]
#   file             — path to the file to stream
#   chunk_size_bytes — bytes per chunk (default: 256)
#   delay_ms         — delay between chunks in milliseconds (default: 50)

set -eo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <file> [chunk_size_bytes] [delay_ms]" >&2
    exit 1
fi

FILE="$1"
CHUNK_SIZE="${2:-256}"
DELAY_MS="${3:-50}"

if [[ ! -f "$FILE" ]]; then
    echo "Error: File not found: $FILE" >&2
    exit 1
fi

# Use exec to replace the bash process with Python for a clean process tree
exec python3 -c "
import sys, time, os

path = sys.argv[1]
chunk = int(sys.argv[2])
delay = int(sys.argv[3]) / 1000.0

stdout = os.fdopen(sys.stdout.fileno(), 'wb', closefd=False)
with open(path, 'rb') as f:
    while True:
        data = f.read(chunk)
        if not data:
            break
        stdout.write(data)
        stdout.flush()
        time.sleep(delay)
" "$FILE" "$CHUNK_SIZE" "$DELAY_MS"
