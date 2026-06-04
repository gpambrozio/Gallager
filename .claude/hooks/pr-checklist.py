#!/usr/bin/env python3
"""PostToolUse hook: nudge the agent through project-workflow chores after a PR is opened.

Claude Code runs this after every `Bash` tool call (the matcher in
`.claude/settings.json` scopes it to Bash). When the command that just ran was a
pull-request-creating command (`gh pr create`), the hook emits a
`hookSpecificOutput.additionalContext` block so the agent works through the
documentation / CLAUDE.md / CLI / e2e-scenario checklist before stopping.

The checklist text lives in the sibling `pr-checklist.md` so it can be edited
without touching this script.

For any other command the hook stays silent (no stdout, exit 0), so it is a no-op
on the vast majority of Bash calls.

Hook contract: https://code.claude.com/docs/en/hooks.md#posttooluse
"""
import json
import re
import sys
from pathlib import Path

# `gh pr create` is how this repo opens pull requests. The pattern tolerates env
# prefixes (`GH_TOKEN=… gh pr create`), `cd … && gh pr create`, and arbitrary
# whitespace between tokens. The leading `\b` keeps it from matching inside longer
# words; the trailing lookahead requires whitespace or end-of-string after
# `create` so it does not fire on `gh pr create-from-draft` and friends (`\b`
# would, since `-` is a non-word character).
PR_CREATE_PATTERN = re.compile(r"\bgh\s+pr\s+create(?=\s|$)")

# Checklist injected as additionalContext, kept in a sibling markdown file so the
# wording can be edited without editing this script.
CHECKLIST_PATH = Path(__file__).resolve().parent / "pr-checklist.md"


def load_checklist() -> str:
    """Read the post-PR checklist from the sibling markdown file.

    Read lazily (only when a PR-creating command fires) so a missing or unreadable
    file surfaces loudly at PR-creation time rather than on every Bash call.
    """
    return CHECKLIST_PATH.read_text(encoding="utf-8").strip()


def command_creates_pr(payload: dict) -> bool:
    """True when the tool call that just ran was a `gh pr create` Bash command."""
    if payload.get("tool_name") != "Bash":
        return False
    command = payload.get("tool_input", {}).get("command", "")
    if not isinstance(command, str):
        return False
    return PR_CREATE_PATTERN.search(command) is not None


def main() -> None:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return  # Malformed input — stay out of the way.

    if not isinstance(payload, dict) or not command_creates_pr(payload):
        return  # Not a PR-creating command — no output, no-op.

    output = {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": load_checklist(),
        }
    }
    json.dump(output, sys.stdout)


if __name__ == "__main__":
    main()
