#!/usr/bin/env python3
"""Unit tests for e2e_report_build.py.

Run: python3 scripts/tests/test_e2e_report_build.py
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import e2e_report_build as rb


class ScenarioDirName(unittest.TestCase):
    def test_mirrors_swift_sanitizer(self):
        # Shared parity fixture — the Swift side asserts the same cases against
        # TestOrchestrator.scenarioDirName(for:) in RecordingCoordinatorTests.
        fixture_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "scenario_dir_name_fixture.json"
        )
        with open(fixture_path, encoding="utf-8") as f:
            cases = json.load(f)["cases"]
        self.assertTrue(cases)
        for case in cases:
            self.assertEqual(
                rb.scenario_dir_name(case["name"]), case["expected"], msg=case["name"]
            )


class StoreArtifact(unittest.TestCase):
    def test_content_addressed_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "video.mp4")
            with open(src, "wb") as f:
                f.write(b"fake-video-bytes")
            images = os.path.join(tmp, "images")
            os.makedirs(images)
            sha = rb.store_artifact(src, ".mp4", images)
            self.assertTrue(os.path.isfile(os.path.join(images, f"{sha}.mp4")))
            # Idempotent — same content, same hash, no error on re-store.
            self.assertEqual(sha, rb.store_artifact(src, ".mp4", images))

    def test_missing_source_returns_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(rb.store_artifact(os.path.join(tmp, "nope.mp4"), ".mp4", tmp))


class AttachVideo(unittest.TestCase):
    def test_attaches_hash_duration_and_chapters(self):
        with tempfile.TemporaryDirectory() as tmp:
            images = os.path.join(tmp, "images")
            os.makedirs(images)
            sdir = os.path.join(tmp, "shots", "video-demo")
            os.makedirs(sdir)
            with open(os.path.join(sdir, "video.mp4"), "wb") as f:
                f.write(b"vid")
            meta = {
                "durationSeconds": 12.3,
                "mode": "speedup",
                "steps": [{"stepNumber": 1, "start": 0.5,
                           "description": "d", "status": "passed"}],
            }
            with open(os.path.join(sdir, "video.json"), "w") as f:
                json.dump(meta, f)

            scenario = {"scenarioName": "Video Demo"}
            rb.attach_video(scenario, os.path.join(tmp, "shots"), images)

            self.assertIn("video", scenario)
            self.assertEqual(scenario["video"]["duration"], 12.3)
            self.assertEqual(scenario["video"]["mode"], "speedup")
            self.assertEqual(scenario["video"]["steps"][0]["start"], 0.5)
            stored = os.path.join(images, scenario["video"]["hash"] + ".mp4")
            self.assertTrue(os.path.isfile(stored))

    def test_no_video_files_is_a_noop(self):
        scenario = {"scenarioName": "Video Demo"}
        with tempfile.TemporaryDirectory() as tmp:
            rb.attach_video(scenario, tmp, tmp)
        self.assertNotIn("video", scenario)


if __name__ == "__main__":
    unittest.main()
