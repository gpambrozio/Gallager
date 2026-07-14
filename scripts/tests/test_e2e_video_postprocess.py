#!/usr/bin/env python3
"""Unit tests for e2e_video_postprocess.py — pure functions only, no ffmpeg.

Run: python3 scripts/tests/test_e2e_video_postprocess.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..",
    "ClaudeSpyPackage", "Sources", "ClaudeSpyE2ELib", "Scenarios", "Scripts",
))
import e2e_video_postprocess as vp


class ParseFreezedetect(unittest.TestCase):
    STDERR = """
[freezedetect @ 0x600] lavfi.freezedetect.freeze_start: 2.5
[freezedetect @ 0x600] lavfi.freezedetect.freeze_duration: 3.0
[freezedetect @ 0x600] lavfi.freezedetect.freeze_end: 5.5
[freezedetect @ 0x600] lavfi.freezedetect.freeze_start: 9.0
"""

    def test_closed_and_unclosed_spans(self):
        spans = vp.parse_freezedetect(self.STDERR, duration=12.0)
        self.assertEqual(spans, [(2.5, 5.5), (9.0, 12.0)])

    def test_no_freezes(self):
        self.assertEqual(vp.parse_freezedetect("frame=  42 fps=15", 10.0), [])


class BuildEditList(unittest.TestCase):
    def test_speedup_mode(self):
        segments = vp.build_edit_list([(2.0, 5.0)], 10.0, mode="speedup", speedup=8.0)
        self.assertEqual(segments, [(0.0, 2.0, 1.0), (2.0, 5.0, 8.0), (5.0, 10.0, 1.0)])

    def test_remove_mode_keeps_head(self):
        segments = vp.build_edit_list([(2.0, 5.0)], 10.0, mode="remove")
        self.assertEqual(segments, [(0.0, 2.0, 1.0), (2.0, 2.25, 1.0), (5.0, 10.0, 1.0)])

    def test_freeze_at_start_and_end(self):
        segments = vp.build_edit_list(
            [(0.0, 3.0), (8.0, 10.0)], 10.0, mode="speedup", speedup=4.0
        )
        self.assertEqual(
            segments, [(0.0, 3.0, 4.0), (3.0, 8.0, 1.0), (8.0, 10.0, 4.0)]
        )

    def test_no_freezes_single_segment(self):
        self.assertEqual(vp.build_edit_list([], 7.0), [(0.0, 7.0, 1.0)])


class RemapTime(unittest.TestCase):
    SEGMENTS = [(0.0, 2.0, 1.0), (2.0, 5.0, 8.0), (5.0, 10.0, 1.0)]

    def test_before_freeze_is_identity(self):
        self.assertAlmostEqual(vp.remap_time(1.0, self.SEGMENTS), 1.0)

    def test_inside_sped_span(self):
        self.assertAlmostEqual(vp.remap_time(4.0, self.SEGMENTS), 2.0 + 2.0 / 8.0)

    def test_after_sped_span(self):
        self.assertAlmostEqual(vp.remap_time(7.0, self.SEGMENTS), 2.0 + 3.0 / 8.0 + 2.0)

    def test_dropped_region_maps_to_cut_point(self):
        segments = [(0.0, 2.0, 1.0), (5.0, 10.0, 1.0)]  # (2, 5) removed entirely
        self.assertAlmostEqual(vp.remap_time(3.5, segments), 2.0)

    def test_published_duration(self):
        self.assertAlmostEqual(vp.published_duration(self.SEGMENTS), 2.0 + 0.375 + 5.0)


class BuildAss(unittest.TestCase):
    TIMELINE = {
        "scenarioName": "Demo",
        "testStartOffset": 0.4,
        "duration": 10.0,
        "steps": [
            {"stepNumber": 1, "description": "Tap 'New Session'",
             "start": 0.5, "end": 4.0, "status": "passed"},
            {"stepNumber": 2, "description": "Type {weird} text",
             "start": 4.0, "end": None, "status": "failed"},
        ],
    }

    def test_dialogue_lines(self):
        ass = vp.build_ass(self.TIMELINE, 1920, 1080)
        self.assertIn("PlayResX: 1920", ass)
        self.assertIn("Dialogue: 0,0:00:00.50,0:00:04.00,Step,,0,0,0,,Step 1/2", ass)
        # Braces are ASS override control chars — they must never survive.
        self.assertNotIn("{weird}", ass)
        self.assertIn("(weird)", ass)
        # A nil end falls back to the scenario duration.
        self.assertIn("Dialogue: 0,0:00:04.00,0:00:10.00,Step,,0,0,0,,", ass)


if __name__ == "__main__":
    unittest.main()
