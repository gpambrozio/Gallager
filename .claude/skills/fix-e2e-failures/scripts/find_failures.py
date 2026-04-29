#!/usr/bin/env python3
"""Find and summarize E2E test failures from the ClaudeSpyTestResults repository.

Pulls latest results, finds the most recent failing run, and outputs a
structured JSON summary of all failures with actionable details.

Screenshot mismatches are non-fatal in the orchestrator — a scenario continues
running after a failed screenshot comparison, so a single scenario can produce
multiple failed steps. This script extracts every failed step, not just the
first one.

Usage:
    python find_failures.py [--results-dir PATH]

Output (JSON to stdout):
    {
        "status": "failures_found" | "all_passed" | "build_failed" | "no_results",
        "failures": [...],  # one entry per failed SCENARIO (not per step)
        "message": "..."    # human-readable summary
    }

    Each scenario failure entry has shape:
    {
        "scenarioName": "...",
        "error": "...",            # the scenario's top-level error string
        "failedStep": 47,          # first failed step (compat with old reports)
        "failedSteps": [           # EVERY failed step in the scenario
            {
                "stepNumber": 47,
                "description": "...",
                "error": "...",
                "type": "screenshot_mismatch" | "functional",
                "screenshot": {           # only when type == screenshot_mismatch
                    "label": "...",
                    "diffPercentage": 2.97,
                    "actualImage": "/.../hash.png",
                    "baselineImage": "/.../hash.png",
                    "diffImage": "/.../hash.png"
                }
            },
            ...
        ],
        "hasFatalFailure": bool    # true if any failed step was NOT a screenshot mismatch
    }
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys


def pull_results(results_dir: str) -> None:
    """Pull latest test results."""
    subprocess.run(
        ["git", "-C", results_dir, "pull", "--rebase"],
        capture_output=True,
    )


def find_latest_failure(results_dir: str) -> dict | None:
    """Find the most recent failing (non-build-failure) entry in index.json."""
    index_path = os.path.join(results_dir, "results", "index.json")
    if not os.path.exists(index_path):
        return None

    with open(index_path) as f:
        entries = json.load(f)

    for entry in entries:  # already sorted newest-first
        if entry.get("buildFailed"):
            continue
        if not entry.get("allPassed"):
            return entry

    return None


def load_report(results_dir: str, folder: str) -> dict:
    """Load the full report.json for a given run folder."""
    report_path = os.path.join(results_dir, "results", folder, "report.json")
    with open(report_path) as f:
        return json.load(f)


def _step_failure_detail(step: dict, images_dir: str) -> dict:
    """Build the detail dict for a single failed step."""
    detail = {
        "stepNumber": step["stepNumber"],
        "description": step.get("description"),
        "error": step.get("error"),
        "type": "functional",
        "screenshot": None,
        "failureScreenshots": [],
    }
    ss = step.get("screenshot")
    if ss and not ss.get("passed"):
        detail["type"] = "screenshot_mismatch"
        detail["screenshot"] = {
            "label": ss.get("label"),
            "diffPercentage": ss.get("diffPercentage"),
            "actualImage": os.path.join(images_dir, f"{ss['imageHash']}.png") if ss.get("imageHash") else None,
            "baselineImage": os.path.join(images_dir, f"{ss['baselineHash']}.png") if ss.get("baselineHash") else None,
            "diffImage": os.path.join(images_dir, f"{ss['diffHash']}.png") if ss.get("diffHash") else None,
        }
    # Diagnostic screenshots captured at the moment a non-comparison step
    # fails (one per running platform — iOS sim, mac host, mac viewers).
    # Only present on functional failures; screenshot-mismatch steps already
    # have actual/baseline/diff in `screenshot`.
    for fs in step.get("failureScreenshots") or []:
        image_hash = fs.get("imageHash")
        if not image_hash:
            continue
        detail["failureScreenshots"].append({
            "target": fs.get("target", ""),
            "image": os.path.join(images_dir, f"{image_hash}.png"),
        })
    return detail


def extract_failures(report: dict, results_dir: str) -> list[dict]:
    """Extract failed scenarios with details of EVERY failed step.

    A single scenario can fail multiple times because screenshot mismatches are
    non-fatal — the orchestrator records the failed step and continues. Only a
    non-screenshot error stops the scenario early.
    """
    images_dir = os.path.join(results_dir, "images")
    failures: list[dict] = []

    for scenario in report.get("scenarios", []):
        if scenario.get("success"):
            continue

        failed_steps = [
            _step_failure_detail(step, images_dir)
            for step in scenario.get("steps", [])
            if not step.get("success")
        ]

        has_fatal = any(s["type"] == "functional" for s in failed_steps)

        failures.append({
            "scenarioName": scenario["scenarioName"],
            "error": scenario.get("error", "Unknown error"),
            "failedStep": scenario.get("failedStep"),
            "failedSteps": failed_steps,
            "hasFatalFailure": has_fatal,
        })

    return failures


def build_summary(entry: dict, report: dict, failures: list[dict]) -> str:
    """Build a human-readable summary of failures."""
    lines = [
        f"Branch: {entry['branch']} (commit {entry['commit']})",
        f"PR: {entry.get('prUrl', 'none')}",
        f"Date: {entry['date']}",
        f"Results: {entry['passedScenarios']}/{entry['totalScenarios']} passed, {entry['failedScenarios']} failed",
        "",
    ]

    for f in failures:
        lines.append(f"FAILED: {f['scenarioName']}  ({len(f['failedSteps'])} failed step(s))")
        for s in f["failedSteps"]:
            lines.append(f"  Step {s['stepNumber']} [{s['type']}]: {s['description']}")
            if s["type"] == "screenshot_mismatch" and s["screenshot"]:
                ss = s["screenshot"]
                lines.append(f"    Screenshot: {ss['label']} ({ss['diffPercentage']}% diff)")
            if s.get("error"):
                lines.append(f"    Error: {s['error']}")
            for fs in s.get("failureScreenshots") or []:
                lines.append(f"    Failure screenshot ({fs['target']}): {fs['image']}")
        if f["hasFatalFailure"]:
            lines.append("  (scenario stopped early at first non-screenshot error)")
        lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Find E2E test failures")
    parser.add_argument(
        "--results-dir",
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "ClaudeSpyTestResults"),
        help="Path to ClaudeSpyTestResults repository",
    )
    args = parser.parse_args()

    results_dir = os.path.abspath(args.results_dir)

    if not os.path.isdir(results_dir):
        json.dump({"status": "no_results", "message": f"Results directory not found: {results_dir}"}, sys.stdout, indent=2)
        return

    # Pull latest
    pull_results(results_dir)

    # Check for build failures first (most recent entry)
    index_path = os.path.join(results_dir, "results", "index.json")
    if os.path.exists(index_path):
        with open(index_path) as f:
            entries = json.load(f)
        if entries and entries[0].get("buildFailed"):
            json.dump({
                "status": "build_failed",
                "message": f"Latest run ({entries[0]['branch']} @ {entries[0]['commit']}) had a build failure. No test results to analyze.",
                "entry": entries[0],
            }, sys.stdout, indent=2)
            return

    # Find latest failure
    entry = find_latest_failure(results_dir)
    if not entry:
        json.dump({"status": "all_passed", "message": "All recent E2E runs passed."}, sys.stdout, indent=2)
        return

    # Load report and extract failures
    report = load_report(results_dir, entry["folder"])
    failures = extract_failures(report, results_dir)
    summary = build_summary(entry, report, failures)

    json.dump({
        "status": "failures_found",
        "message": summary,
        "metadata": report.get("metadata", {}),
        "failures": failures,
        "entry": entry,
    }, sys.stdout, indent=2)


if __name__ == "__main__":
    main()
