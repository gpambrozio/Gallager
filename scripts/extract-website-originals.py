#!/usr/bin/env python3
"""One-off extractor for the artifact bundles in deploy/.

Decodes each deploy/*.html self-unpacking bundle into:
  website/.originals/<page>.html    the real page markup (JSON-decoded template)
  website/.originals/modernist.css  the shared design-system CSS (from index)
  website/.originals/logo-full.png  the full-size logo
  website/public/fonts/*.woff2      the three Archivo subsets
  website/public/favicon.svg        the orange G mark

Part of the Astro port (docs/superpowers/plans/2026-07-20-website-restructure.md).
Delete this script together with deploy/ once the port is verified.
"""
import base64
import gzip
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEPLOY = ROOT / "deploy"
ORIGINALS = ROOT / "website" / ".originals"
PUBLIC = ROOT / "website" / "public"
# @font-face src order in the design CSS (each subset repeats for 3 weights).
FONT_SUBSETS = ["vietnamese", "latin-ext", "latin"]


def read_block(text, kind):
    m = re.search(
        rf'<script type="__bundler/{kind}">\n(.*?)\n  </script>', text, re.S
    )
    if not m:
        sys.exit(f"missing __bundler/{kind} block")
    return m.group(1)


def asset_bytes(entry):
    raw = base64.b64decode(entry["data"])
    return gzip.decompress(raw) if entry.get("compressed") else raw


def main():
    ORIGINALS.mkdir(parents=True, exist_ok=True)
    (PUBLIC / "fonts").mkdir(parents=True, exist_ok=True)

    for page in sorted(DEPLOY.glob("*.html")):
        text = page.read_text()
        template = json.loads(read_block(text, "template"))
        manifest = json.loads(read_block(text, "manifest"))
        (ORIGINALS / page.name).write_text(template)

        if page.stem != "index":
            continue

        # Shared design-system CSS: first <style> block of the template head.
        css = re.search(r"<style>(.*?)</style>", template, re.S).group(1)
        (ORIGINALS / "modernist.css").write_text(css)

        # Fonts, deduped in first-appearance order (vietnamese, latin-ext, latin).
        seen = []
        for uuid in re.findall(r'src: url\("([0-9a-f-]+)"\)', css):
            if uuid not in seen:
                seen.append(uuid)
        if len(seen) != len(FONT_SUBSETS):
            sys.exit(f"expected {len(FONT_SUBSETS)} font files, found {len(seen)}")
        for uuid, subset in zip(seen, FONT_SUBSETS):
            (PUBLIC / "fonts" / f"archivo-{subset}.woff2").write_bytes(
                asset_bytes(manifest[uuid])
            )

        # Logo: the manifest's only image/png.
        pngs = [v for v in manifest.values() if v["mime"] == "image/png"]
        if len(pngs) != 1:
            sys.exit(f"expected 1 png in manifest, found {len(pngs)}")
        (ORIGINALS / "logo-full.png").write_bytes(asset_bytes(pngs[0]))

        # Favicon: the orange G placeholder SVG in the loader shell.
        svg = re.search(
            r'<div id="__bundler_thumbnail">(<svg.*?</svg>)', text
        ).group(1)
        (PUBLIC / "favicon.svg").write_text(svg + "\n")

    print("extracted OK")


if __name__ == "__main__":
    main()
