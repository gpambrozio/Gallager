#!/usr/bin/env python3
"""Inline base64 screenshots into a baseline-review HTML report.

Replaces every `__DATAURI:<key>__` token in the HTML file with a
`data:image/png;base64,...` URI built from `<img-dir>/<key>.png`.
This makes the report a single self-contained file that opens anywhere
without loose image dependencies.

Usage:
    inline-images.py <html-file> <img-dir>

Every token must have a matching `<key>.png` in <img-dir>, or the script
exits non-zero and lists what's missing (so you never ship a broken report).
"""
import base64
import os
import re
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2

    html_path, img_dir = sys.argv[1], sys.argv[2]
    with open(html_path) as f:
        html = f.read()

    tokens = sorted(set(re.findall(r"__DATAURI:([A-Za-z0-9_]+)__", html)))
    if not tokens:
        print("No __DATAURI:<key>__ tokens found — nothing to inline.")
        return 0

    missing = []
    for key in tokens:
        png = os.path.join(img_dir, key + ".png")
        if not os.path.exists(png):
            missing.append(key)
            continue
        with open(png, "rb") as im:
            b64 = base64.b64encode(im.read()).decode()
        html = html.replace(f"__DATAURI:{key}__", f"data:image/png;base64,{b64}")

    if missing:
        print("MISSING IMAGES (expected <key>.png in %s):" % img_dir)
        for k in missing:
            print("  -", k)
        return 1

    leftover = re.findall(r"__DATAURI:[A-Za-z0-9_]+__", html)
    if leftover:
        print("ERROR: tokens left unreplaced:", leftover)
        return 1

    with open(html_path, "w") as f:
        f.write(html)

    size_mb = os.path.getsize(html_path) / 1e6
    print(f"Inlined {len(tokens)} images into {html_path} ({size_mb:.1f} MB).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
