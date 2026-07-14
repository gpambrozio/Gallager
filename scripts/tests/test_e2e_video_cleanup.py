#!/usr/bin/env python3
"""Unit tests for e2e_video_cleanup.py.

Run: python3 scripts/tests/test_e2e_video_cleanup.py
"""
import os
import sys
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import e2e_video_cleanup as vc

NOW = datetime(2026, 7, 2, 12, 0, 0, tzinfo=timezone.utc)


class AssetPRNumber(unittest.TestCase):
    def test_parses_pr_number(self):
        self.assertEqual(vc.asset_pr_number("pr626-subagent-stop-ignored-failing.mp4"), 626)

    def test_parses_pr_number_without_label(self):
        self.assertEqual(vc.asset_pr_number("pr622-window-description-sync.mp4"), 622)

    def test_rejects_non_video_extension(self):
        self.assertIsNone(vc.asset_pr_number("pr626-notes.txt"))

    def test_rejects_missing_prefix(self):
        self.assertIsNone(vc.asset_pr_number("subagent-stop-ignored.mp4"))

    def test_rejects_bare_pr_number(self):
        self.assertIsNone(vc.asset_pr_number("pr626.mp4"))


class Eligibility(unittest.TestCase):
    def closed_at(self, days_ago):
        return (NOW - timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def test_merged_past_grace_is_eligible(self):
        self.assertTrue(vc.is_eligible("MERGED", self.closed_at(4), 3, NOW))

    def test_closed_past_grace_is_eligible(self):
        self.assertTrue(vc.is_eligible("CLOSED", self.closed_at(4), 3, NOW))

    def test_open_is_never_eligible(self):
        self.assertFalse(vc.is_eligible("OPEN", None, 3, NOW))

    def test_merged_within_grace_is_not_eligible(self):
        self.assertFalse(vc.is_eligible("MERGED", self.closed_at(2), 3, NOW))

    def test_boundary_just_past_grace(self):
        just_past = NOW - timedelta(days=3, minutes=1)
        self.assertTrue(
            vc.is_eligible("MERGED", just_past.strftime("%Y-%m-%dT%H:%M:%SZ"), 3, NOW)
        )

    def test_missing_closed_at_is_not_eligible(self):
        self.assertFalse(vc.is_eligible("CLOSED", None, 3, NOW))


BODY = """## 🎬 E2E Video Proof

Fix verification: the scenario passes.

- **▶ [Subagent Stop Ignored (passing)](https://github.com/gpambrozio/ClaudeSpyTestResults/releases/download/e2e-videos/pr626-subagent-stop-ignored-passing.mp4)** — 3s (speedup), 23 steps

_Ephemeral release asset(s) on gpambrozio/ClaudeSpyTestResults (`e2e-videos` prerelease) — not part of any repo's git history; may be deleted after review._"""

URL = (
    "https://github.com/gpambrozio/ClaudeSpyTestResults/releases/download/"
    "e2e-videos/pr626-subagent-stop-ignored-passing.mp4"
)

BODY_WITH_HINT = """## 🎬 E2E Video Proof

Fix verification: the scenario passes.

- **▶ [Subagent Stop Ignored (passing)](https://github.com/gpambrozio/ClaudeSpyTestResults/releases/download/e2e-videos/pr626-subagent-stop-ignored-passing.mp4)** — 3s (speedup), 23 steps
  - watch: `./scripts/e2e-watch-video.sh pr626-subagent-stop-ignored-passing.mp4`

_Ephemeral release asset(s) on gpambrozio/ClaudeSpyTestResults (`e2e-videos` prerelease) — not part of any repo's git history; may be deleted after review._"""


class RewriteComment(unittest.TestCase):
    def test_strikes_link_and_appends_note(self):
        new_body = vc.rewrite_comment(BODY, [URL])
        self.assertIsNotNone(new_body)
        self.assertNotIn(URL, new_body)
        self.assertIn("- **▶ ~~Subagent Stop Ignored (passing)~~** — 3s (speedup), 23 steps", new_body)
        self.assertTrue(new_body.endswith(vc.DELETED_NOTE))

    def test_untouched_urls_stay_linked(self):
        two_links = BODY + (
            "\n- **▶ [Other](https://github.com/gpambrozio/ClaudeSpyTestResults/"
            "releases/download/e2e-videos/pr626-other.mp4)** — 5s"
        )
        new_body = vc.rewrite_comment(two_links, [URL])
        self.assertIn("[Other](", new_body)
        self.assertIn("~~Subagent Stop Ignored (passing)~~", new_body)

    def test_no_matching_url_returns_none(self):
        self.assertIsNone(vc.rewrite_comment(BODY, ["https://example.com/nope.mp4"]))

    def test_rewrite_is_idempotent(self):
        once = vc.rewrite_comment(BODY, [URL])
        self.assertIsNone(vc.rewrite_comment(once, [URL]))

    def test_note_appended_once_for_multiple_links(self):
        other_url = (
            "https://github.com/gpambrozio/ClaudeSpyTestResults/releases/download/"
            "e2e-videos/pr626-other.mp4"
        )
        two_links = BODY + f"\n- **▶ [Other]({other_url})** — 5s"
        new_body = vc.rewrite_comment(two_links, [URL, other_url])
        self.assertEqual(new_body.count(vc.DELETED_NOTE), 1)

    def test_strikes_watch_hint_alongside_link(self):
        new_body = vc.rewrite_comment(BODY_WITH_HINT, [URL])
        self.assertIsNotNone(new_body)
        self.assertNotIn(URL, new_body)
        self.assertIn("- **▶ ~~Subagent Stop Ignored (passing)~~** — 3s (speedup), 23 steps", new_body)
        self.assertIn(
            "  - watch: ~~`./scripts/e2e-watch-video.sh "
            "pr626-subagent-stop-ignored-passing.mp4`~~",
            new_body,
        )

    def test_watch_hint_rewrite_is_idempotent(self):
        once = vc.rewrite_comment(BODY_WITH_HINT, [URL])
        self.assertIsNone(vc.rewrite_comment(once, [URL]))

    def test_no_hint_line_still_strikes_link_only(self):
        # Comments without watch-hint (pre-watch-hint format) still get struck.
        new_body = vc.rewrite_comment(BODY, [URL])
        self.assertIsNotNone(new_body)
        self.assertNotIn(URL, new_body)
        self.assertIn("- **▶ ~~Subagent Stop Ignored (passing)~~** — 3s (speedup), 23 steps", new_body)
        self.assertNotIn("watch:", new_body)


class GroupAssets(unittest.TestCase):
    def test_groups_by_pr_and_skips_non_matching(self):
        assets = [
            "pr622-window-description-sync.mp4",
            "pr622-cursor-style-changes.mp4",
            "pr626-subagent-stop-ignored-failing.mp4",
            "README.md",
        ]
        self.assertEqual(
            vc.group_assets_by_pr(assets),
            {
                622: [
                    "pr622-window-description-sync.mp4",
                    "pr622-cursor-style-changes.mp4",
                ],
                626: ["pr626-subagent-stop-ignored-failing.mp4"],
            },
        )


if __name__ == "__main__":
    unittest.main()
