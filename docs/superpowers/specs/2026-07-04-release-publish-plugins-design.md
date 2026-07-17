# Release: publish repo plugins to the updates site

**Date:** 2026-07-04
**Status:** Approved

## Problem

Plugins that are not bundled inside the app live in `plugins/` (currently only
`plugins/opencode`). They are installable remotely via the app's "Add Plugin from
URL…" flow, which needs a hosted distribution `plugin.json` (with `bundle_url`,
`bundle_sha256`, `manifest_url`) plus the bundle zip — but nothing publishes them.
`scripts/release.sh` should package and upload them to the same site that hosts the
DMGs. Beta builds (`--beta`) are excluded.

## Design

Reuse `scripts/package-plugin.sh` (which already validates the tree, zips it with
the executable bit intact, computes the SHA-256, and emits the distribution
manifest). `release.sh` orchestrates it and uploads the output.

### Hosting layout

Per-plugin directory under the existing updates host:

```
https://updates.gallager.app/plugins/<id>/plugin.json          (manifest — install URL)
https://updates.gallager.app/plugins/<id>/<id>-<version>.zip   (bundle)
```

This matches `package-plugin.sh`'s documented example and avoids `plugin.json`
name collisions between plugins.

### Changes to `scripts/release.sh`

1. **`package_plugins()`** — loops over `plugins/*/plugin.json`. For each plugin,
   reads `id` from the manifest (python3, same as `package-plugin.sh` — not the
   directory basename, so a mismatch cannot bake a wrong URL) and runs:

   ```
   package-plugin.sh <dir> --base-url "$DOWNLOAD_URL_PREFIX/plugins/<id>" \
       --exclude 'tests/*' --exclude 'scripts/*'
   ```

   Output lands in `build/plugins/<id>/` (`<id>-<version>.zip` + distribution
   `plugin.json`). Any packaging failure → `log_error` → release aborts. Missing
   `plugins/` dir or no manifests → log a note and continue.

2. **Ordering — package early, fail fast.** Packaging is fast; it runs right
   after the release confirmation prompt, *before* unit tests and the lengthy
   archive/sign/notarize pipeline, so a bad plugin tree aborts the release in
   seconds. Because `build_archive()` currently begins with `rm -rf "$BUILD_DIR"`
   (which would delete the packaged output), the wipe moves out of
   `build_archive()` to the start of each flow (`main()` and `run_beta_build()`);
   `build_archive()` keeps its `mkdir -p`.

3. **Upload** — in the existing `upload_to_ftp()` lftp session, one extra step
   when `build/plugins` exists: `mirror -R "$BUILD_DIR/plugins" plugins`. Creates
   `plugins/<id>/` remotely and uploads both files, under the same
   `cmd:fail-exit true` error handling.

4. **Final summary** — prints each plugin's manifest URL (what users paste into
   "Add Plugin from URL…" / `gallager plugin install <url>`).

### Explicitly unchanged

- `--beta` path: `run_beta_build` neither packages nor uploads plugins.
- `--skip-upload`: packaging still runs (useful dry-run); upload is skipped.
- No plugin version bumping — plugins carry their own `version`; re-releasing the
  same version re-uploads the same artifacts (idempotent).
- No top-level plugin index — the install flow takes a manifest URL directly.
- No new prerequisites in `check_prerequisites` — `package-plugin.sh` checks its
  own tools (`python3`, `zip`, `unzip`, `shasum`) with clear errors.

### Docs

One-line note in `docs/plugins/sidecar-authoring.md` §7 (Distribution): plugins
under `plugins/` in this repo are packaged and published automatically by
`scripts/release.sh`.

## Testing

- Run the packaging step standalone against `plugins/opencode`; verify the zip
  contains no `tests/` or `scripts/` entries, `plugin.json` is at the root, the
  executable bit survives (`package-plugin.sh` self-verifies), and the emitted
  manifest URLs point at `…/plugins/opencode/…`.
- `bash -n scripts/release.sh` + shellcheck for the edited script.
- The lftp `mirror -R` line is verified by inspection against the existing `put`
  commands (a full release dry-run requires the whole build pipeline).
