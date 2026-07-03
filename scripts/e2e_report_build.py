#!/usr/bin/env python3
"""Build report.json for an E2E run: run metadata + scenario results with
content-addressed screenshot and video artifacts.

Extracted from the inline heredoc in e2e-report.sh so the artifact-store and
video-merge logic is unit-testable (scripts/tests/test_e2e_report_build.py).
Reads the same environment variables e2e-report.sh has always exported.
"""
import hashlib
import json
import os
import shutil
import sys


def store_artifact(src_path, ext, images_dir):
    """Compute SHA-256, copy to <images_dir>/<hash><ext> if absent, return hash."""
    if not src_path or not os.path.isfile(src_path):
        return None
    h = hashlib.sha256()
    with open(src_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    sha = h.hexdigest()
    dest = os.path.join(images_dir, f"{sha}{ext}")
    if not os.path.exists(dest):
        shutil.copy2(src_path, dest)
    return sha


def scenario_dir_name(name):
    """Mirror TestOrchestrator.scenarioDirName(for:) — MUST stay in sync."""
    return "".join(
        c for c in name.lower().replace(" ", "-") if c.isalnum() or c in "-_"
    )


def attach_video(scenario, screenshots_dir, images_dir):
    """Attach a content-addressed video + seek chapters when the recording
    pipeline left video.mp4/video.json in the scenario's screenshots dir."""
    sdir = os.path.join(screenshots_dir, scenario_dir_name(scenario.get("scenarioName", "")))
    video_path = os.path.join(sdir, "video.mp4")
    meta_path = os.path.join(sdir, "video.json")
    if not (os.path.isfile(video_path) and os.path.isfile(meta_path)):
        return
    try:
        with open(meta_path) as f:
            meta = json.load(f)
    except Exception as e:
        print(f"Warning: unreadable {meta_path}: {e}", file=sys.stderr)
        return
    sha = store_artifact(video_path, ".mp4", images_dir)
    if not sha:
        return
    scenario["video"] = {
        "hash": sha,
        "duration": meta.get("durationSeconds"),
        "mode": meta.get("mode"),
        "steps": meta.get("steps", []),
    }


def process_screenshot(ss, screenshots_dir, baselines_dir, images_dir):
    """Convert a path-based screenshot dict to hash-based fields."""
    label = ss.get("label", "")
    passed = ss.get("passed", True)
    baseline_created = ss.get("baselineCreated", False)
    diff_percentage = ss.get("diffPercentage")

    actual_path = ss.get("actualPath") or os.path.join(screenshots_dir, f"{label}.png")
    baseline_path = ss.get("baselinePath") or os.path.join(baselines_dir, f"{label}.png")
    diff_path = ss.get("diffPath")

    actual_hash = store_artifact(actual_path, ".png", images_dir)
    baseline_hash = store_artifact(baseline_path, ".png", images_dir)
    diff_hash = store_artifact(diff_path, ".png", images_dir) if diff_path else None

    if passed and not baseline_created and diff_percentage is not None:
        image_hash = baseline_hash
        result_baseline_hash = baseline_hash
        result_diff_hash = None
    elif not passed:
        image_hash = actual_hash
        result_baseline_hash = baseline_hash
        result_diff_hash = diff_hash
    elif baseline_created:
        image_hash = actual_hash
        result_baseline_hash = actual_hash
        result_diff_hash = None
    else:
        image_hash = actual_hash
        result_baseline_hash = baseline_hash
        result_diff_hash = None

    return {
        "label": label,
        "imageHash": image_hash,
        "baselineHash": result_baseline_hash,
        "diffHash": result_diff_hash,
        "diffPercentage": diff_percentage,
        "passed": passed,
        "baselineCreated": baseline_created,
    }


def process_failure_screenshot(fs, images_dir):
    """Convert a path-based failure screenshot dict to a hash-based field."""
    target = fs.get("target", "")
    path = fs.get("path")
    image_hash = store_artifact(path, ".png", images_dir) if path else None
    return {
        "target": target,
        "imageHash": image_hash,
    }


def main():
    metadata = {
        "branch": os.environ["BRANCH"],
        "commit": os.environ["COMMIT"],
        "commitFull": os.environ["COMMIT_FULL"],
        "commitMessage": os.environ["COMMIT_MSG"],
        "prNumber": os.environ["PR_NUMBER"] or None,
        "prUrl": os.environ["PR_URL"] or None,
        "prTitle": os.environ["PR_TITLE"] or None,
        "timestamp": os.environ["TIMESTAMP"],
        "date": os.environ["DATE_DISPLAY"],
        "folder": os.environ["RESULT_FOLDER"],
        "allPassed": os.environ["ALL_PASSED"] == "true",
        "buildFailed": os.environ["BUILD_FAILED"] == "true",
    }

    report_dir = os.environ["REPORT_DIR"]
    images_dir = os.environ["IMAGES_DIR"]
    screenshots_dir = os.environ["SCREENSHOTS_DIR"]
    baselines_dir = os.environ["BASELINES_DIR"]

    results = []
    try:
        with open(os.path.join(report_dir, "results.json")) as f:
            results = json.load(f)
    except Exception as e:
        print(f"Warning: could not read results.json: {e}", file=sys.stderr)

    for scenario in results:
        for step in scenario.get("steps", []):
            ss = step.get("screenshot")
            if ss:
                step["screenshot"] = process_screenshot(
                    ss, screenshots_dir, baselines_dir, images_dir
                )
            failures = step.get("failureScreenshots") or []
            if failures:
                step["failureScreenshots"] = [
                    process_failure_screenshot(f, images_dir) for f in failures
                ]
        attach_video(scenario, screenshots_dir, images_dir)

    report = {"metadata": metadata, "scenarios": results}
    with open(os.path.join(report_dir, "report.json"), "w") as f:
        json.dump(report, f, indent=2)

    image_count = len(os.listdir(images_dir)) if os.path.isdir(images_dir) else 0
    video_count = sum(1 for s in results if s.get("video"))
    print(f"Report written to report.json ({image_count} artifacts in "
          f"content-addressed store, {video_count} video(s))")


if __name__ == "__main__":
    main()
