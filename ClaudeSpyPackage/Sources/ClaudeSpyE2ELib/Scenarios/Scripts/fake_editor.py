#!/usr/bin/env python3
"""
Fake editor stand-in for E2E testing of the "Open in Editor" feature.

Behaves just enough like a real editor for the macOS app's `EditorClient` to
launch us as if we were a registered application. We immediately write the
file path we received as our first argument to a known location under the
host's `$TMPDIR` so the test scenario can verify the editor was invoked with
the expected file.

Usage: python3 fake_editor.py <file_path> [<file_path>...]
"""

import os
import sys
import datetime


def main() -> int:
    log_path = os.environ.get(
        "GALLAGER_FAKE_EDITOR_LOG",
        os.path.join(os.environ.get("TMPDIR", "/tmp"), "gallager-fake-editor.log"),
    )

    args = sys.argv[1:]
    timestamp = datetime.datetime.utcnow().isoformat()

    try:
        with open(log_path, "a", encoding="utf-8") as f:
            for arg in args:
                f.write(f"{timestamp}\t{arg}\n")
            if not args:
                f.write(f"{timestamp}\t(no arguments)\n")
    except Exception as exc:  # noqa: BLE001
        print(f"fake_editor: failed to write log: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
