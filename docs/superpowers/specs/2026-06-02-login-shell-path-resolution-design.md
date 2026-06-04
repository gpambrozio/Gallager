# Login-Shell PATH Resolution for Subprocesses

**Date:** 2026-06-02
**Status:** Approved (design)
**Branch:** `plugin-system-v1-in-process` (PR #562)
**Fixes:** Agents tab reports "Agent not found" for `claude`/`codex` even though both are on the user's shell PATH.

## Problem

The plugin cores detect/install an agent CLI by running `/usr/bin/env <command> plugin list`
(and `… plugin install/uninstall`) through `ProcessRunner`. `<command>` defaults to the bare
name `claude` / `codex`. `ProcessRunner.liveValue` launches the subprocess with
`env = ProcessInfo.processInfo.environment` (+ any `CLAUDE_CONFIG_DIR` / `CODEX_HOME`).

When the macOS app is launched from Finder/Dock it inherits **launchd's minimal PATH**
(`/usr/bin:/bin:/usr/sbin:/sbin`), **not** the user's shell PATH from `.zprofile`/`.zshrc`.
So `/usr/bin/env claude` cannot find binaries installed in `~/.local/bin`, `~/.npm-global/bin`,
Homebrew (`/opt/homebrew/bin`), or version-manager paths (mise/nvm/rbenv). It exits `127`, which
the core maps to `.agentUnavailable` → "Agent not found".

This is a regression introduced when install moved to the `/usr/bin/env <command>` approach. The
rest of the app avoids the problem deliberately: `TmuxBinaryLocator` probes known absolute paths,
and `TmuxService` launches agent commands through a **login shell** (`exec <userShellPath> -l`),
which is why "auto-run Claude in project folders" works while install-status detection does not.

Note: the user's `claude` is also a shell **function** in `.zshrc`; functions are never on PATH,
so resolving the on-disk **binary** (which `/usr/bin/env` does) is the correct behavior for
`plugin list`/`install` — we explicitly do NOT want to invoke the function (it injects
`--allow-dangerously-skip-permissions` and switches to `claude-dox` in some directories).

## Goal

Resolve the user's real login-shell PATH once, and inject it into every `ProcessRunner`
subprocess, so `/usr/bin/env <command>` finds CLIs installed anywhere on the user's PATH.

## Decisions (resolved during brainstorming)

| Decision | Choice |
|---|---|
| Where the resolved PATH is applied | In `ProcessRunner.liveValue` (general) — fixes all subprocesses, one place. |
| Shell flavor | `<shell> -ilc` (interactive + login) so both `.zprofile` and `.zshrc` are sourced. |
| Resolution cost | Resolve **once**, cache for the app lifetime. |
| Function vs binary | Resolve PATH and use `/usr/bin/env` (resolves the binary, ignores shell functions). |
| Fallback on failure | Prepend common dirs to the inherited PATH; never throw. |

## Architecture

### Component 1 — `LoginShellPath` (new, `ClaudeSpyCommon`, `@Dependency`)

A `@DependencyClient struct` (mirroring `TmuxBinaryLocator`), macOS-only, exposing:

```swift
public struct LoginShellPath: Sendable {
    /// The user's full login-shell `$PATH`, resolved once and cached.
    /// `nil` if resolution failed (caller applies its own fallback).
    public var resolve: @Sendable () -> String?
}
```

`liveValue` resolution (lazy, cached for the process lifetime):

1. **User shell:** `$SHELL` → `getpwuid(geteuid()).pw_shell` → `/bin/sh` (same chain as
   `TmuxService.userShellPath`; a small, accepted duplication of ~3 lines to avoid a cross-module
   refactor of `TmuxService`).
2. **Resolve PATH:** run `<shell> -ilc '<print>'` via a **direct `Foundation.Process`** (NOT
   `ProcessRunner` — avoids bootstrap recursion), where `<print>` is:
   `printf '__GALLAGER_PATH__:%s' "$PATH"`. Use a unique marker so the PATH can be extracted even
   when `.zshrc` writes noise to stdout. `stdin = /dev/null` so an interactive shell can't block on
   input; capture stdout only.
3. **Timeout:** terminate the process after a fixed wall-clock timeout (8s) so a slow/hung
   `.zshrc` can't stall; treat timeout as failure → `nil`.
4. **Extract:** find the line/segment containing `__GALLAGER_PATH__:` and return the substring
   after it (trimmed). Empty/absent → `nil`.
5. **Cache:** store the first non-nil (or the first attempt's) result; subsequent calls return the
   cache without re-spawning. (A single failed attempt caches `nil` for the session — acceptable;
   the fallback in Component 2 still applies.)

`previewValue`/test value: return a fixed PATH (e.g. `"/opt/homebrew/bin:/usr/bin:/bin"`).

The PATH-extraction and shell-resolution helpers are pure functions so they can be unit-tested
without spawning a shell.

### Component 2 — `ProcessRunner.liveValue` injects the PATH

In the macOS `run` closure, where `env` is built (currently
`var env = ProcessInfo.processInfo.environment` then merge `environment`):

```swift
@Dependency(LoginShellPath.self) var loginShellPath   // read at top of `run`, like the clock dep

var env = ProcessInfo.processInfo.environment
env["PATH"] = Self.effectivePath(resolved: loginShellPath.resolve(), inherited: env["PATH"])
if let additionalEnv = environment {
    for (key, value) in additionalEnv { env[key] = value }   // caller can still override PATH
}
process.environment = env
```

`effectivePath(resolved:inherited:)` (pure, testable):
- If `resolved` is non-empty → return it (it already contains everything the user's shell has).
- Else → prepend the common dirs that aren't already present to `inherited`:
  `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` (expanded), `~/.npm-global/bin` (expanded),
  joined with the inherited PATH. This guarantees the most common installs work even if shell
  resolution fails.

Reading `@Dependency(LoginShellPath.self)` at the top of `run` is consistent with the existing
`@Dependency(\.continuousClock)` read in the same closure. `LoginShellPath`'s own caching means at
most one shell spawn per app session regardless of how many subprocesses run.

## Data flow

```
Agents tab status query / install
  → core.installStatus/install(...)  →  ProcessRunner.run("/usr/bin/env", ["claude","plugin","list"], …)
      → ProcessRunner.liveValue:
          env = launchd env
          env["PATH"] = LoginShellPath.resolve()  (cached; one-time `zsh -ilc 'printf …$PATH'`)
                        ?? commonDirs + inherited
          merge CLAUDE_CONFIG_DIR/CODEX_HOME
          launch  → /usr/bin/env finds ~/.local/bin/claude on the full PATH → exit 0
```

## Error handling

- Resolution never throws: any `Process` error, non-zero exit, empty output, or timeout → `nil` →
  Component 2's common-dirs fallback.
- The resolution subprocess uses `stdin = /dev/null` and an 8s timeout to avoid hangs.
- `stderr` from `.zshrc` (e.g. `compinit` warnings under a no-tty interactive shell) is ignored;
  only the marker-delimited stdout segment is parsed.

## Testing

- **`LoginShellPath` pure helpers** (unit): `extractPath(fromMarkerOutput:)` given
  `"noise\n__GALLAGER_PATH__:/a:/b\n"` → `/a:/b`; missing marker → `nil`; empty after marker →
  `nil`. Shell-resolve chain given `$SHELL` set / unset (the passwd branch is environment-dependent;
  cover the `$SHELL`-present and `$SHELL`-empty-string cases).
- **`ProcessRunner.effectivePath`** (unit): resolved non-empty → returned verbatim; resolved nil →
  common dirs prepended to inherited, with no duplicates, preserving the inherited tail.
- **`ProcessRunner` injection** (unit): with `LoginShellPath` overridden via `withDependencies` to a
  known PATH, run a trivial command that echoes `$PATH` (e.g.
  `/usr/bin/env sh -c 'printf %s "$PATH"'`) and assert the output contains the injected PATH and that
  a caller-supplied `CLAUDE_CONFIG_DIR` still appears in the child env.
- Existing `ProcessRunner` / installer tests: unaffected — they inject `ProcessRunner` directly, and
  the new `LoginShellPath` dependency has a deterministic test/preview value.

## Out of scope

- The Command-field default stays bare `claude` / `codex` (now resolves via the injected PATH).
- `TmuxService.userShellPath` and the tmux `default-command` path are unchanged.
- No change to the `PluginCore` contract or the cores' `/usr/bin/env <command>` invocation shape.

## Rollout

Within the existing branch; no version-floor change. Fixes detection immediately on the next build;
no user action needed (no need to enter absolute command paths).
