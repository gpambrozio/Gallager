#!/usr/bin/env python3
"""PostToolUse hook: nudge the agent through project-workflow chores after a PR is opened.

Claude Code runs this after every `Bash` tool call (the matcher in
`.claude/settings.json` scopes it to Bash). When the command that just ran was a
pull-request-creating command (`gh pr create`), the hook emits a
`hookSpecificOutput.additionalContext` block so the agent works through the
documentation / CLAUDE.md / CLI / e2e-scenario checklist before stopping.

For any other command the hook stays silent (no stdout, exit 0), so it is a no-op
on the vast majority of Bash calls.

Hook contract: https://code.claude.com/docs/en/hooks.md#posttooluse
"""
import json
import re
import sys

# `gh pr create` is how this repo opens pull requests. The pattern tolerates env
# prefixes (`GH_TOKEN=… gh pr create`), `cd … && gh pr create`, and arbitrary
# whitespace between tokens. `\b` keeps it from matching inside longer words.
PR_CREATE_PATTERN = re.compile(r"\bgh\s+pr\s+create\b")

ADDITIONAL_CONTEXT = """Use the Task tool to work through these items before stopping:

1. Document Updates: Determine if any documentation needs to be updated and update them
2. Claude.md File Updates: Check if the /claude.md file or any related files require updates and update them.
3. New Feature cli addition:
   * For new features consider if adding a new command to the cli would add value to users. If it does then add the command and make sure to update both the cli documents and the `gallager` skill that ships with claude and codex plugins.
4. New Feature End-to-End Scenario:
    * If a new feature is introduced, an end-to-end scenario **must** be created and run to prove the feature's functionality.
    * The scenario must contain screenshots that clearly show the feature working as intended.
    * Look at all screenshots to make sure they reflect what you'd expect.
    * Commit the baseline images.
5. Bug Fix Scenario:
    * If a bug is being fixed, a scenario **must** be created that consistently reproduces the bug without the fix.
    * The same scenario must then demonstrate that the fix successfully resolves the bug.
    * Include screenshots showing the scenario reproducing the bug as comments in the pull request
    * Commit the baseline images.
6. Check if scenarios need to be updated
    * If this pr changes behavior that was tested on a scenario update the scenario
    * Run the scenario to make sure it passes.
    * Remove baselines that will change so that ci updates them
    * If the behavior has no scenario testing it then create it, make sure it passes and make sure the screenshots show what you'd expect."""


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
            "additionalContext": ADDITIONAL_CONTEXT,
        }
    }
    json.dump(output, sys.stdout)


if __name__ == "__main__":
    main()
