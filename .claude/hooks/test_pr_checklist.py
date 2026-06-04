#!/usr/bin/env python3
"""Regression tests for pr-checklist.py.

Stdlib-only (no pytest). Runs the hook exactly as Claude Code does — as a
subprocess fed JSON on stdin — and asserts on stdout. Run with:

    python3 .claude/hooks/test_pr_checklist.py
"""
import json
import os
import subprocess
import sys
import unittest

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pr-checklist.py")

# Built at runtime so this test file does not itself contain the literal trigger
# string (which would make the live PostToolUse hook fire on every edit/run here).
TRIGGER = " ".join(["gh", "pr", "create"])


def run(payload):
    """Feed a payload to the hook; return (stdout, exit_code)."""
    raw = payload if isinstance(payload, str) else json.dumps(payload)
    proc = subprocess.run(
        [sys.executable, HOOK],
        input=raw,
        capture_output=True,
        text=True,
    )
    return proc.stdout, proc.returncode


def bash(command):
    return {"tool_name": "Bash", "tool_input": {"command": command}}


class FiresOnPrCreate(unittest.TestCase):
    def assert_fires(self, payload):
        out, code = run(payload)
        self.assertEqual(code, 0)
        data = json.loads(out)  # must be valid JSON
        hso = data["hookSpecificOutput"]
        self.assertEqual(hso["hookEventName"], "PostToolUse")
        self.assertTrue(hso["additionalContext"].startswith("Use the Task tool"))
        self.assertIn("end-to-end scenario", hso["additionalContext"])

    def test_plain(self):
        self.assert_fires(bash(TRIGGER))

    def test_with_flags(self):
        self.assert_fires(bash(f'{TRIGGER} --title "x" --body "y"'))

    def test_chained(self):
        self.assert_fires(bash(f"cd /repo && {TRIGGER} --fill"))

    def test_env_prefix(self):
        self.assert_fires(bash(f"GH_TOKEN=abc {TRIGGER}"))

    def test_extra_whitespace(self):
        self.assert_fires(bash("gh   pr    create --web"))


class StaysSilent(unittest.TestCase):
    def assert_silent(self, payload):
        out, code = run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), "")

    def test_pr_view(self):
        self.assert_silent(bash("gh pr view 123"))

    def test_pr_list(self):
        self.assert_silent(bash("gh pr list"))

    def test_pr_edit(self):
        self.assert_silent(bash("gh pr edit 5 --add-label x"))

    def test_unrelated(self):
        self.assert_silent(bash("git commit -m wip"))

    def test_non_bash_tool(self):
        self.assert_silent({"tool_name": "Edit", "tool_input": {"file_path": "/a.swift"}})

    def test_non_bash_with_command(self):
        self.assert_silent({"tool_name": "Write", "tool_input": {"command": TRIGGER}})

    def test_empty_input(self):
        self.assert_silent("")

    def test_malformed_json(self):
        self.assert_silent("{not valid")

    def test_missing_tool_input(self):
        self.assert_silent({"tool_name": "Bash"})

    def test_command_not_a_string(self):
        self.assert_silent({"tool_name": "Bash", "tool_input": {"command": 123}})

    def test_no_word_boundary(self):
        self.assert_silent(bash("echo ghprcreate"))

    def test_create_hyphenated_subcommand(self):
        # `create` followed by `-` must not fire (e.g. a hypothetical
        # `gh pr create-from-draft`); the trailing lookahead requires whitespace
        # or end-of-string after `create`.
        self.assert_silent(bash(f"{TRIGGER}-from-draft"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
