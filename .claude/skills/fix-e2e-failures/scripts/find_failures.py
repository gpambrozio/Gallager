#!/usr/bin/env python3
"""Find and summarize E2E test failures from the ClaudeSpyTestResults repository.

Pulls latest results, finds the most recent failing run, and outputs a
structured JSON summary of all failures with actionable details.

Usage:
    python find_failures.py [--results-dir PATH]

Output (JSON to stdout):
    {
        "status": "failures_found" | "all_passed" | "build_failed" | "no_results",
        "report": { ... },       # only when status == "failures_found"
        "message": "..."         # human-readable summary
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


def extract_failures(report: dict, results_dir: str) -> list[dict]:
    """Extract failed scenarios with actionable details."""
    failures = []

    for scenario in report.get("scenarios", []):
        if scenario.get("success"):
            continue

        failure = {
            "scenarioName": scenario["scenarioName"],
            "error": scenario.get("error", "Unknown error"),
            "failedStep": scenario.get("failedStep"),
            "failedStepDescription": None,
            "type": "functional",
            "screenshot": None,
        }

        # Find the failed step details
        for step in scenario.get("steps", []):
            if step["stepNumber"] == scenario.get("failedStep"):
                failure["failedStepDescription"] = step.get("description")

                # Check if it's a screenshot failure
                ss = step.get("screenshot")
                if ss and not ss.get("passed"):
                    failure["type"] = "screenshot_mismatch"
                    images_dir = os.path.join(results_dir, "images")
                    failure["screenshot"] = {
                        "label": ss.get("label"),
                        "diffPercentage": ss.get("diffPercentage"),
                        "actualImage": os.path.join(images_dir, f"{ss['imageHash']}.png") if ss.get("imageHash") else None,
                        "baselineImage": os.path.join(images_dir, f"{ss['baselineHash']}.png") if ss.get("baselineHash") else None,
                        "diffImage": os.path.join(images_dir, f"{ss['diffHash']}.png") if ss.get("diffHash") else None,
                    }
                break

        failures.append(failure)

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
        lines.append(f"FAILED: {f['scenarioName']}")
        lines.append(f"  Step {f['failedStep']}: {f['failedStepDescription']}")
        lines.append(f"  Type: {f['type']}")
        lines.append(f"  Error: {f['error']}")
        if f["screenshot"]:
            lines.append(f"  Screenshot: {f['screenshot']['label']} ({f['screenshot']['diffPercentage']}% diff)")
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
