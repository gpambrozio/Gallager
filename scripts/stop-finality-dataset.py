#!/usr/bin/env python3
"""Stop-finality eval dataset pipeline (spec 2026-07-30).

Subcommands, run in order:
  mine      harvest turn-final assistant messages from ~/.claude/projects
  prelabel  Claude pre-labels candidates via `claude -p`   (added in Task 5)
  review    emit contested rows for human labeling         (added in Task 5)
  finalize  write ~/.gallager/eval/stop-finality-mined.json (added in Task 5)

All working files live under ~/.gallager/eval/ and are NEVER committed —
they contain verbatim excerpts from real sessions.
"""

import argparse
import hashlib
import json
import random
import re
import sys
from pathlib import Path

EVAL_DIR = Path.home() / ".gallager" / "eval"
CANDIDATES = EVAL_DIR / "stop-finality-candidates.jsonl"
PROJECTS = Path.home() / ".claude" / "projects"

# Entry types that are transcript metadata, not conversation turns.
META_TYPES = {
    "last-prompt", "mode", "permission-mode", "attachment", "ai-title",
    "file-history-snapshot", "file-history-delta", "summary", "system",
}

# Enrichment filter: shapes that might be WAITING. Everything matching is
# kept; non-matches are randomly sampled to fill the cap so FINAL coverage
# stays representative.
WAITING_HINTS = re.compile(
    r"await|waiting|wait for|monitor|report back|check back|dispatched"
    r"|kicked off|in the background|once it (completes|finishes)"
    r"|still running|will (update|resume|pick|summarize|verify)"
    r"|nothing (more )?to do until",
    re.IGNORECASE,
)

CAP = 300
MIN_LENGTH = 5


def is_real_user_turn(obj):
    content = (obj.get("message") or {}).get("content")
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        return any(block.get("type") == "text" for block in content
                   if isinstance(block, dict))
    return False


def assistant_text(obj):
    content = (obj.get("message") or {}).get("content")
    if not isinstance(content, list):
        return None
    texts = [block.get("text", "") for block in content
             if isinstance(block, dict) and block.get("type") == "text"]
    joined = "\n\n".join(t for t in texts if t.strip()).strip()
    return joined or None


def mine(args):
    files = sorted(PROJECTS.glob("*/*.jsonl"))
    parse_errors = 0
    seen_hashes = set()
    hint_rows, other_rows = [], []

    for path in files:
        entries = []
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    parse_errors += 1
                    continue
                if obj.get("type") in META_TYPES:
                    continue
                entries.append(obj)

        for index, obj in enumerate(entries):
            if obj.get("type") != "assistant" or obj.get("isSidechain"):
                continue
            text = assistant_text(obj)
            if not text or len(text) < MIN_LENGTH:
                continue
            # Turn-final: next conversation entry is a real user turn, or EOF.
            nxt = entries[index + 1] if index + 1 < len(entries) else None
            if nxt is not None and not (nxt.get("type") == "user"
                                        and is_real_user_turn(nxt)):
                continue
            digest = hashlib.sha256(text.encode()).hexdigest()[:10]
            if digest in seen_hashes:
                continue
            seen_hashes.add(digest)
            row = {
                "id": f"m{digest}",
                "message": text,
                "project": path.parent.name,
                "session": path.stem,
                "timestamp": obj.get("timestamp", ""),
            }
            (hint_rows if WAITING_HINTS.search(text) else other_rows).append(row)

    random.seed(42)
    fill = max(0, CAP - len(hint_rows))
    sampled = random.sample(other_rows, min(fill, len(other_rows)))
    rows = hint_rows + sampled

    EVAL_DIR.mkdir(parents=True, exist_ok=True)
    with open(CANDIDATES, "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")

    print(f"scanned {len(files)} transcripts "
          f"({parse_errors} unparseable lines skipped)")
    print(f"turn-final messages: {len(hint_rows) + len(other_rows)} unique "
          f"({len(hint_rows)} waiting-shaped, kept all; "
          f"{len(sampled)}/{len(other_rows)} others sampled)")
    print(f"wrote {len(rows)} candidates → {CANDIDATES}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("mine", help="harvest turn-final messages").set_defaults(fn=mine)
    args = parser.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
