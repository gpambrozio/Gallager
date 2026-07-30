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
# The hint regex over-triggers on FINAL prose, but unhinted plain-FINAL
# messages are production's majority class and must stay represented.
MIN_OTHER_FILL = 100

VERDICTS = EVAL_DIR / "stop-finality-verdicts.jsonl"
CONTESTED = EVAL_DIR / "stop-finality-contested.json"
MINED = EVAL_DIR / "stop-finality-mined.json"
BATCH = 20
CONFIDENCE_FLOOR = 0.8

PRELABEL_PROMPT = """\
You label coding-agent turn-final messages for a binary classifier eval.
For each message decide: did the agent FINISH its turn ("final") or is it
PAUSING while background work it depends on completes ("waiting")?

"waiting" requires the message to state the agent will continue when
still-running work completes: "I'll report back", "Awaiting its report",
"Waiting on Task 3", "nothing to do until it reports". Summaries of
completed work, error reports, and questions to the user are "final" even
when they mention builds, tests, commands, or background jobs.

Reply with ONLY a JSON array, no prose, no code fences:
[{"id": "...", "label": "waiting" or "final", "confidence": 0.0-1.0}, ...]

Messages:
"""


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
    fill = max(MIN_OTHER_FILL, CAP - len(hint_rows))
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


def load_candidates():
    return [json.loads(line) for line in open(CANDIDATES, encoding="utf-8")]


def save_candidates(rows):
    with open(CANDIDATES, "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def prelabel(args):
    import subprocess
    rows = load_candidates()
    pending = [r for r in rows if "claudeLabel" not in r]
    print(f"{len(pending)} rows to label ({len(rows) - len(pending)} already done)")
    for start in range(0, len(pending), BATCH):
        batch = pending[start:start + BATCH]
        payload = json.dumps(
            [{"id": r["id"], "message": r["message"]} for r in batch],
            ensure_ascii=False,
        )
        proc = subprocess.run(
            ["claude", "-p", PRELABEL_PROMPT + payload],
            capture_output=True, text=True, timeout=600,
        )
        if proc.returncode != 0:
            sys.exit(f"claude -p failed: {proc.stderr[:500]}")
        text = proc.stdout.strip()
        if text.startswith("```"):
            text = text.strip("`").lstrip("json").strip()
        labels = {item["id"]: item for item in json.loads(text)}
        for row in batch:
            got = labels.get(row["id"])
            if got is None or got.get("label") not in ("waiting", "final"):
                sys.exit(f"bad label response for {row['id']}: {text[:300]}")
            row["claudeLabel"] = got["label"]
            row["claudeConfidence"] = float(got.get("confidence", 0.5))
        save_candidates(rows)  # checkpoint per batch — rerun-safe
        print(f"labeled {start + len(batch)}/{len(pending)}")


def review(args):
    rows = load_candidates()
    unlabeled = [r["id"] for r in rows if "claudeLabel" not in r]
    if unlabeled:
        sys.exit(f"run prelabel first — {len(unlabeled)} rows unlabeled")
    if not VERDICTS.exists():
        sys.exit(
            "missing on-device verdicts — run:\n  cd ClaudeSpyPackage && "
            f"swift run StopFinalityEval --verdicts {CANDIDATES} {VERDICTS}"
        )
    verdicts = {json.loads(l)["id"]: json.loads(l)["onDevice"]
                for l in open(VERDICTS, encoding="utf-8") if l.strip()}
    contested = []
    for row in rows:
        on_device = verdicts.get(row["id"])
        if (on_device != row["claudeLabel"]
                or row["claudeConfidence"] < CONFIDENCE_FLOOR):
            contested.append({
                "id": row["id"],
                "message": row["message"],
                "claudeLabel": row["claudeLabel"],
                "claudeConfidence": row["claudeConfidence"],
                "onDevice": on_device,
                "label": None,  # ← human fills "waiting" or "final"
            })
    CONTESTED.write_text(
        json.dumps(contested, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"{len(contested)} contested rows → {CONTESTED}")
    print('fill each "label" field with "waiting" or "final", then run finalize')


def finalize(args):
    rows = load_candidates()
    overrides = {}
    if CONTESTED.exists():
        contested = json.loads(CONTESTED.read_text(encoding="utf-8"))
        missing = [c["id"] for c in contested if c["label"] not in ("waiting", "final")]
        if missing:
            sys.exit(f"contested rows still unlabeled: {missing}")
        overrides = {c["id"]: c["label"] for c in contested}
    dataset = [{
        "id": row["id"],
        "message": row["message"],
        "expected": overrides.get(row["id"], row["claudeLabel"]),
        "source": "mined",
        "notes": f"{row['project']}/{row['session']} {row['timestamp']}",
    } for row in rows]
    MINED.write_text(
        json.dumps(dataset, indent=2, ensure_ascii=False), encoding="utf-8")
    waiting = sum(1 for d in dataset if d["expected"] == "waiting")
    print(f"wrote {len(dataset)} cases ({waiting} waiting, "
          f"{len(dataset) - waiting} final) → {MINED}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("mine", help="harvest turn-final messages").set_defaults(fn=mine)
    sub.add_parser("prelabel", help="Claude pre-labels candidates").set_defaults(fn=prelabel)
    sub.add_parser("review", help="emit contested rows").set_defaults(fn=review)
    sub.add_parser("finalize", help="write the mined dataset").set_defaults(fn=finalize)
    args = parser.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
