#!/usr/bin/env python3
"""Delete E2E proof videos for merged/closed PRs after a grace period.

e2e-attach-video.sh uploads proof videos as ephemeral release assets named
pr<N>-<scenario>[-<label>].mp4 on a rolling prerelease of the results repo
and links them from a PR comment. This sweep deletes the assets of PRs that
merged or closed more than --grace-days ago, then edits the linking comments
(strikes the dead links, appends a deletion note) so readers don't click them.

Run daily by .github/workflows/e2e-video-cleanup.yml; also runnable locally
(your gh auth must reach both repos):

    ./scripts/e2e_video_cleanup.py --dry-run

Tokens: results-repo calls use $RESULTS_REPO_TOKEN when set (CI), otherwise
ambient gh auth; PR-repo calls always use ambient auth ($GH_TOKEN in CI).
"""
import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

DELETED_NOTE = "_Proof videos deleted after the post-merge grace period._"

ASSET_RE = re.compile(r"^pr(\d+)-.+\.mp4$")


def asset_pr_number(name):
    """PR number encoded in a proof-video asset name, or None."""
    match = ASSET_RE.match(name)
    return int(match.group(1)) if match else None


def group_assets_by_pr(names):
    """Map PR number -> asset names, skipping non-matching assets."""
    groups = {}
    for name in names:
        number = asset_pr_number(name)
        if number is not None:
            groups.setdefault(number, []).append(name)
    return groups


def is_eligible(state, closed_at, grace_days, now):
    """True when the PR is merged/closed and past the grace period."""
    if state not in ("MERGED", "CLOSED") or not closed_at:
        return False
    closed = datetime.fromisoformat(closed_at.replace("Z", "+00:00"))
    return now - closed > timedelta(days=grace_days)


def rewrite_comment(body, deleted_urls):
    """Strike deleted links (and any watch-hint sub-bullet under them) and
    append the deletion note.

    e2e-attach-video.sh (see #631) appends a "  - watch: `./scripts/
    e2e-watch-video.sh <asset>`" sub-bullet directly under each video link;
    when the link above it is struck, that command would otherwise still
    read as copy-pasteable for an asset that no longer exists.

    Returns the rewritten body, or None when no deleted URL appears in it
    (which also makes the rewrite idempotent — struck links have no URL left,
    so a second pass matches nothing, including the hint line since it's only
    matched together with the still-linked title).
    """
    new_body = body
    for url in deleted_urls:
        asset = url.rsplit("/", 1)[-1]
        with_hint = re.compile(
            r"\[(?P<title>[^\]]+)\]\(" + re.escape(url) + r"\)"
            r"(?P<rest>[^\n]*\n  - watch: )`(?P<cmd>[^`\n]*" + re.escape(asset) + r")`"
        )
        new_body, hint_struck = with_hint.subn(
            r"~~\g<title>~~\g<rest>~~`\g<cmd>`~~", new_body
        )
        if not hint_struck:
            plain = re.compile(r"\[([^\]]+)\]\(" + re.escape(url) + r"\)")
            new_body = plain.sub(r"~~\1~~", new_body)
    if new_body == body:
        return None
    if DELETED_NOTE not in new_body:
        new_body = new_body.rstrip() + "\n\n" + DELETED_NOTE
    return new_body


def run_gh(args, token=None, input_text=None):
    """Run gh, returning (exit_code, stdout, stderr)."""
    env = dict(os.environ)
    if token:
        env["GH_TOKEN"] = token
    result = subprocess.run(
        ["gh", *args],
        input=input_text,
        capture_output=True,
        text=True,
        env=env,
    )
    return result.returncode, result.stdout, result.stderr


def list_release_assets(results_repo, release_tag, token):
    """Asset names on the rolling release, or None when the release is missing."""
    code, out, err = run_gh(
        ["release", "view", release_tag, "--repo", results_repo, "--json", "assets"],
        token=token,
    )
    if code != 0:
        # Only the release itself missing is benign; a missing repo or bad
        # token must fail loudly, not read as "nothing to do".
        if "release not found" in err.lower():
            return None
        raise SystemExit(f"ERROR: listing assets on {results_repo}: {err.strip()}")
    return [asset["name"] for asset in json.loads(out)["assets"]]


def pr_state(repo, number):
    """{'state': ..., 'closedAt': ...} for a PR, or None when the lookup fails."""
    code, out, err = run_gh(
        ["pr", "view", str(number), "--repo", repo, "--json", "state,closedAt"]
    )
    if code != 0:
        print(f"WARNING: could not look up PR #{number} on {repo}, skipping: {err.strip()}")
        return None
    return json.loads(out)


def delete_asset(results_repo, release_tag, name, token):
    """Delete one release asset. Returns True on success."""
    code, _, err = run_gh(
        ["release", "delete-asset", release_tag, name, "--repo", results_repo, "--yes"],
        token=token,
    )
    if code != 0:
        # Self-heals: the asset is still there, so the next sweep retries.
        print(f"WARNING: could not delete {name}, will retry next run: {err.strip()}")
        return False
    return True


def mark_pr_comments(repo, number, deleted_urls, dry_run):
    """Edit the PR's comments that link deleted assets. Returns True on success."""
    code, out, err = run_gh(
        ["api", f"repos/{repo}/issues/{number}/comments", "--paginate"]
    )
    if code != 0:
        print(f"ERROR: could not list comments on PR #{number}: {err.strip()}")
        return False

    ok = True
    for comment in json.loads(out):
        new_body = rewrite_comment(comment["body"], deleted_urls)
        if new_body is None:
            continue
        if dry_run:
            print(f"DRY RUN: would mark comment {comment['id']} on PR #{number}")
            continue
        code, _, err = run_gh(
            [
                "api",
                "--method",
                "PATCH",
                f"repos/{repo}/issues/comments/{comment['id']}",
                "--input",
                "-",
            ],
            input_text=json.dumps({"body": new_body}),
        )
        if code != 0:
            print(f"ERROR: could not edit comment {comment['id']} on PR #{number}: {err.strip()}")
            ok = False
        else:
            print(f"Marked comment {comment['id']} on PR #{number}")
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--results-repo",
        default="gpambrozio/ClaudeSpyTestResults",
        help="owner/repo hosting the release (default: %(default)s)",
    )
    parser.add_argument(
        "--release-tag",
        default="e2e-videos",
        help="rolling release tag for assets (default: %(default)s)",
    )
    parser.add_argument(
        "--grace-days",
        type=int,
        default=3,
        help="days to keep videos after the PR merges/closes (default: %(default)s)",
    )
    parser.add_argument(
        "--repo",
        default="gpambrozio/ClaudeSpy",
        help="owner/repo the PRs live on (default: %(default)s)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print what would be deleted/edited without mutating anything",
    )
    args = parser.parse_args()

    # strip(): stray whitespace pasted into the secret would ride into the
    # Authorization header and 401 (or be rejected client-side for \n).
    results_token = os.environ.get("RESULTS_REPO_TOKEN", "").strip() or None
    if os.environ.get("GITHUB_ACTIONS") == "true" and not results_token:
        # Without it, results-repo calls fall back to the ambient token, which
        # can't see the private results repo: GitHub 404s, list_release_assets
        # reads that as "release not found", and the sweep exits 0 as if there
        # were nothing to do — a broken/expired secret masquerading as success.
        raise SystemExit(
            "ERROR: RESULTS_REPO_TOKEN is unset in CI; refusing to run with the "
            "ambient token, which cannot see the private results repo."
        )
    now = datetime.now(timezone.utc)

    assets = list_release_assets(args.results_repo, args.release_tag, results_token)
    if assets is None:
        print(f"Release {args.release_tag} not found on {args.results_repo}; nothing to do.")
        return 0

    groups = group_assets_by_pr(assets)
    skipped = len(assets) - sum(len(names) for names in groups.values())
    if skipped:
        print(f"Skipping {skipped} asset(s) not matching pr<N>-*.mp4")
    if not groups:
        print("No proof-video assets found; nothing to do.")
        return 0

    exit_code = 0
    for number, names in sorted(groups.items()):
        info = pr_state(args.repo, number)
        if info is None:
            continue
        if not is_eligible(info["state"], info.get("closedAt"), args.grace_days, now):
            print(f"PR #{number} ({info['state']}): keeping {len(names)} asset(s)")
            continue

        deleted_urls = []
        for name in names:
            if args.dry_run:
                print(f"DRY RUN: would delete {name}")
            elif not delete_asset(args.results_repo, args.release_tag, name, results_token):
                continue
            else:
                print(f"Deleted {name}")
            deleted_urls.append(
                f"https://github.com/{args.results_repo}/releases/download/"
                f"{args.release_tag}/{name}"
            )

        if deleted_urls and not mark_pr_comments(args.repo, number, deleted_urls, args.dry_run):
            # Accepted trade-off (see the design spec under docs/superpowers/
            # specs/2026-07-02-e2e-video-cleanup-design.md): the assets are
            # already gone, so the next sweep can't rebuild deleted_urls for
            # this PR — the orphaned comment stays unmarked. Don't "fix" this by
            # retrying the delete; just make the run red for manual follow-up.
            exit_code = 1

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
