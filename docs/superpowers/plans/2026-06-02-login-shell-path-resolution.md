# Login-Shell PATH Resolution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make GUI-launched subprocesses use the user's real login-shell `$PATH`, so the plugin cores' `/usr/bin/env claude/codex plugin list` finds CLIs in `~/.local/bin`, Homebrew, mise/nvm, etc. (currently reported "Agent not found").

**Architecture:** A new cached `LoginShellPath` dependency resolves the user's PATH once via `<shell> -ilc 'printf …$PATH'`. `ProcessRunner.liveValue` injects that PATH into every subprocess's environment, with a common-dirs fallback if resolution fails. No plugin-core changes.

**Tech Stack:** Swift 6, Point-Free Dependencies (`@DependencyClient`/`DependencyKey`), `Foundation.Process`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-02-login-shell-path-resolution-design.md`.

---

## File Structure

**Create:**
- `ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/LoginShellPath.swift` — the resolver dependency (shell-resolve + PATH extraction + cached live resolution).
- `ClaudeSpyPackage/Tests/ClaudeSpyCommonTests/LoginShellPathTests.swift`
- `ClaudeSpyPackage/Tests/ClaudeSpyCommonTests/ProcessRunnerPathInjectionTests.swift`

**Modify:**
- `ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/ProcessRunner.swift` — inject the resolved PATH into the subprocess env; add the pure `effectivePath` helper.

**No changes** to `ClaudeCodeCLIInstaller`/`CodexCLIInstaller` or the cores — they already invoke `/usr/bin/env <command>`.

---

## Task 1: `LoginShellPath` resolver (pure helpers TDD, then the dependency)

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/LoginShellPath.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyCommonTests/LoginShellPathTests.swift`

- [ ] **Step 1: Write the failing tests** — create `LoginShellPathTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeSpyCommon

#if os(macOS)
    @Suite("LoginShellPath")
    struct LoginShellPathTests {
        @Test("extractPath returns the substring after the marker, trimmed")
        func extractsAfterMarker() {
            let out = "compinit noise\n\(LoginShellPath.marker)/Users/x/.local/bin:/opt/homebrew/bin:/usr/bin"
            #expect(LoginShellPath.extractPath(fromMarkerOutput: out) == "/Users/x/.local/bin:/opt/homebrew/bin:/usr/bin")
        }

        @Test("extractPath is nil when the marker is absent")
        func nilWhenNoMarker() {
            #expect(LoginShellPath.extractPath(fromMarkerOutput: "no marker here") == nil)
        }

        @Test("extractPath is nil when nothing follows the marker")
        func nilWhenEmptyAfterMarker() {
            #expect(LoginShellPath.extractPath(fromMarkerOutput: "\(LoginShellPath.marker)   ") == nil)
        }

        @Test("resolveUserShell honors $SHELL when set")
        func usesShellEnv() {
            #expect(LoginShellPath.resolveUserShell(environment: ["SHELL": "/bin/zsh"]) == "/bin/zsh")
        }

        @Test("resolveUserShell falls back to a non-empty path when $SHELL is empty")
        func fallsBackWhenShellEmpty() {
            // Empty $SHELL → passwd entry or /bin/sh; either way non-empty + absolute.
            let resolved = LoginShellPath.resolveUserShell(environment: ["SHELL": ""])
            #expect(!resolved.isEmpty)
            #expect(resolved.hasPrefix("/"))
        }
    }
#endif
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ClaudeSpyPackage && swift test --filter LoginShellPath 2>&1 | tail -15`
Expected: FAIL — `LoginShellPath` does not exist.

- [ ] **Step 3: Implement `LoginShellPath.swift`**

```swift
#if os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation

    /// Resolves the user's real login-shell `$PATH`.
    ///
    /// A macOS app launched from Finder/Dock inherits launchd's minimal PATH
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), not the user's `.zprofile`/`.zshrc` PATH.
    /// This resolves the full PATH once (via `<shell> -ilc`) and caches it, so
    /// subprocesses can find CLIs in `~/.local/bin`, Homebrew, mise/nvm, etc.
    /// Returns `nil` if resolution fails; the caller applies its own fallback.
    @DependencyClient
    public struct LoginShellPath: Sendable {
        public var resolve: @Sendable () -> String? = { nil }
    }

    extension LoginShellPath {
        /// Marker prefixing the PATH in the resolution command's stdout, so the
        /// value survives any noise an interactive `.zshrc` writes to stdout.
        static let marker = "__GALLAGER_PATH__:"

        /// The user's login shell: `$SHELL`, else the passwd entry, else `/bin/sh`.
        /// Mirrors `TmuxService.userShellPath` (kept local to avoid a cross-module
        /// refactor; the duplication is three lines).
        static func resolveUserShell(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> String {
            if let shell = environment["SHELL"], !shell.isEmpty { return shell }
            if let pw = getpwuid(geteuid())?.pointee, let cstr = pw.pw_shell {
                let resolved = String(cString: cstr)
                if !resolved.isEmpty { return resolved }
            }
            return "/bin/sh"
        }

        /// Extracts the PATH that follows `marker` in the command output.
        static func extractPath(fromMarkerOutput output: String) -> String? {
            guard let range = output.range(of: marker) else { return nil }
            let value = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    extension LoginShellPath: DependencyKey {
        public static var liveValue: LoginShellPath {
            let cache = PathCache()
            return LoginShellPath(resolve: { cache.value() })
        }

        public static var previewValue: LoginShellPath {
            LoginShellPath(resolve: { "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" })
        }
    }

    /// Caches the one-time login-shell PATH resolution for the process lifetime.
    private final class PathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved = false
        private var cached: String?

        func value() -> String? {
            lock.lock()
            defer { lock.unlock() }
            if resolved { return cached }
            resolved = true
            cached = Self.runResolution()
            return cached
        }

        private static func runResolution() -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: LoginShellPath.resolveUserShell())
            // `-ilc`: interactive + login so both .zprofile and .zshrc are sourced
            // (mise/nvm/rbenv typically hook PATH via .zshrc).
            process.arguments = ["-ilc", "printf '\(LoginShellPath.marker)%s' \"$PATH\""]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            do { try process.run() } catch { return nil }

            // Terminate a slow/hung interactive shell after 8s. `readDataToEndOfFile`
            // actively drains stdout (so a >64KB-noisy .zshrc can't deadlock), and
            // returns once the shell exits or is terminated by the timer.
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 8)
            timer.setEventHandler { if process.isRunning { process.terminate() } }
            timer.resume()

            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()

            return LoginShellPath.extractPath(fromMarkerOutput: String(data: data, encoding: .utf8) ?? "")
        }
    }
#endif
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ClaudeSpyPackage && swift test --filter LoginShellPath 2>&1 | tail -15`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/LoginShellPath.swift ClaudeSpyPackage/Tests/ClaudeSpyCommonTests/LoginShellPathTests.swift
git commit -m "feat(common): LoginShellPath resolver for the user's login-shell PATH"
```

---

## Task 2: Inject the resolved PATH in `ProcessRunner`

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/ProcessRunner.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyCommonTests/ProcessRunnerPathInjectionTests.swift`

- [ ] **Step 1: Write the failing tests** — create `ProcessRunnerPathInjectionTests.swift`:

```swift
import Dependencies
import Foundation
import Testing
@testable import ClaudeSpyCommon

#if os(macOS)
    @Suite("ProcessRunner PATH injection")
    struct ProcessRunnerPathInjectionTests {
        @Test("effectivePath returns the resolved PATH verbatim when non-empty")
        func usesResolved() {
            #expect(ProcessRunner.effectivePath(resolved: "/a:/b", inherited: "/usr/bin:/bin") == "/a:/b")
        }

        @Test("effectivePath prepends missing common dirs to inherited when resolved is nil")
        func fallbackPrependsCommonDirs() {
            let result = ProcessRunner.effectivePath(resolved: nil, inherited: "/usr/bin:/bin")
            let parts = result.split(separator: ":").map(String.init)
            #expect(parts.contains("/opt/homebrew/bin"))
            #expect(parts.contains("/usr/local/bin"))
            #expect(parts.contains("/usr/bin"))
            #expect(parts.contains("/bin"))
            // Inherited entries are not duplicated and remain at the tail.
            #expect(parts.suffix(2) == ["/usr/bin", "/bin"])
            #expect(parts.filter { $0 == "/usr/bin" }.count == 1)
        }

        @Test("effectivePath does not duplicate a common dir already inherited")
        func fallbackNoDuplicate() {
            let result = ProcessRunner.effectivePath(resolved: nil, inherited: "/opt/homebrew/bin:/usr/bin")
            #expect(result.split(separator: ":").filter { $0 == "/opt/homebrew/bin" }.count == 1)
        }

        @Test("live ProcessRunner injects the resolved PATH into the child environment")
        func injectsResolvedPathIntoChild() async throws {
            try await withDependencies {
                $0[LoginShellPath.self] = LoginShellPath(resolve: { "/zzz-test-marker:/usr/bin:/bin" })
            } operation: {
                let runner = ProcessRunner.liveValue
                let result = try await runner.run("/usr/bin/env", ["sh", "-c", "printf %s \"$PATH\""], nil, 10)
                #expect(result.stdoutString == "/zzz-test-marker:/usr/bin:/bin")
            }
        }

        @Test("caller-supplied environment still merges on top of the injected PATH")
        func callerEnvStillMerges() async throws {
            try await withDependencies {
                $0[LoginShellPath.self] = LoginShellPath(resolve: { "/usr/bin:/bin" })
            } operation: {
                let runner = ProcessRunner.liveValue
                let result = try await runner.run(
                    "/usr/bin/env", ["sh", "-c", "printf %s \"$CLAUDE_CONFIG_DIR\""],
                    ["CLAUDE_CONFIG_DIR": "/tmp/cfg"], 10
                )
                #expect(result.stdoutString == "/tmp/cfg")
            }
        }
    }
#endif
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ClaudeSpyPackage && swift test --filter "ProcessRunner PATH injection" 2>&1 | tail -20`
Expected: FAIL — `ProcessRunner.effectivePath` does not exist (and the live test sees no injection).

- [ ] **Step 3: Add the `effectivePath` helper.** In `ProcessRunner.swift`, add this extension (place it just after the `ProcessResult` struct or near the `ProcessRunner` struct definition; it is pure and not platform-gated):

```swift
public extension ProcessRunner {
    /// The PATH to use for a subprocess: the resolved login-shell PATH when
    /// available, else the inherited PATH with common install dirs prepended
    /// (so the most common CLIs still resolve if shell resolution failed).
    static func effectivePath(resolved: String?, inherited: String?) -> String {
        if let resolved, !resolved.isEmpty { return resolved }
        let commonDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSString(string: "~/.local/bin").expandingTildeInPath,
            NSString(string: "~/.npm-global/bin").expandingTildeInPath,
        ]
        let inheritedParts = (inherited ?? "").split(separator: ":").map(String.init)
        let existing = Set(inheritedParts)
        let prefix = commonDirs.filter { !existing.contains($0) }
        return (prefix + inheritedParts).joined(separator: ":")
    }
}
```

- [ ] **Step 4: Inject the PATH in `liveValue`.** In `ProcessRunner.swift`, inside the `#if os(macOS)` `liveValue` `run` closure, replace the environment-building block:

```swift
                    // Set up environment
                    var env = ProcessInfo.processInfo.environment
                    if let additionalEnv = environment {
                        for (key, value) in additionalEnv {
                            env[key] = value
                        }
                    }
                    process.environment = env
```

with:

```swift
                    // Set up environment. A GUI app inherits launchd's minimal PATH,
                    // so inject the user's real login-shell PATH (resolved once,
                    // cached) before the caller's overrides — otherwise `/usr/bin/env
                    // <cmd>` can't find CLIs in ~/.local/bin, Homebrew, mise/nvm, etc.
                    @Dependency(LoginShellPath.self) var loginShellPath
                    var env = ProcessInfo.processInfo.environment
                    env["PATH"] = effectivePath(resolved: loginShellPath.resolve(), inherited: env["PATH"])
                    if let additionalEnv = environment {
                        for (key, value) in additionalEnv {
                            env[key] = value
                        }
                    }
                    process.environment = env
```

(The `@Dependency` read is at the top of the closure, synchronous — consistent with the existing `@Dependency(\.continuousClock)` read in the same closure.)

- [ ] **Step 5: Run to verify it passes**

Run: `cd ClaudeSpyPackage && swift test --filter "ProcessRunner PATH injection" 2>&1 | tail -20`
Expected: PASS (5 tests). If the live tests are flaky on the runner, confirm `/usr/bin/env` and `/bin/sh` exist (they do on macOS).

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyCommon/Services/ProcessRunner.swift ClaudeSpyPackage/Tests/ClaudeSpyCommonTests/ProcessRunnerPathInjectionTests.swift
git commit -m "fix(common): inject login-shell PATH into ProcessRunner subprocesses"
```

---

## Task 3: Full build/test + real-app verification

**Files:** none (verification only).

- [ ] **Step 1: Full unit suite**

Run: `cd ClaudeSpyPackage && swift test 2>&1 | tail -15`
Expected: 0 failures (the new tests pass; existing tests unaffected — `LoginShellPath` has a deterministic preview/test value and existing callers inject `ProcessRunner` directly).

- [ ] **Step 2: Build the macOS app (Debug + Release)**

Run: `xcodebuild -workspace ClaudeSpy.xcworkspace -scheme ClaudeSpyServer -configuration Release -destination 'platform=macOS' -skipMacroValidation -skipPackagePluginValidation build 2>&1 | tee ${TMPDIR:-/tmp}/loginpath_build.log | xcsift --format toon --warnings`
Expected: `status: success`, 0 errors. (`LoginShellPath` is `#if os(macOS)`; the iOS app doesn't reference it.)

- [ ] **Step 3: Real-app verification (manual).**

Build + launch the macOS app, open **Settings → Agents**, and confirm:
- The Claude Code folder row shows **Install** / **Installed** (not "Agent not found").
- Switch to Codex — same.
This is the actual fix proof. (Optional CLI sanity: with the app running, `gallager plugin call claude-code installStatus` should report a non-`agent-unavailable` status when `claude` is on your login-shell PATH.)

- [ ] **Step 4: Commit (if any verification fixups were needed; otherwise skip).**

---

## Self-Review Checklist (author)

- **Spec coverage:** Component 1 `LoginShellPath` resolver — Task 1 ✓ (`-ilc`, marker extraction, cache, shell-resolve chain, fallback `nil`). Component 2 ProcessRunner injection — Task 2 ✓ (`effectivePath`, inject before caller overrides, common-dirs fallback). Error handling (never throws, timeout, stderr ignored, stdin=/dev/null) — Task 1 Step 3 ✓. Testing — Tasks 1–2 ✓. Out-of-scope (no core changes, Command default stays bare, TmuxService untouched) — honored ✓.
- **Placeholders:** none — all code is literal; no "add error handling"-style steps.
- **Type/name consistency:** `LoginShellPath.resolve`/`marker`/`resolveUserShell`/`extractPath`, `ProcessRunner.effectivePath(resolved:inherited:)`, the `__GALLAGER_PATH__:` marker, and the `-ilc` flag are used identically across Tasks 1–2 and the tests.
- **Risk noted:** the live ProcessRunner injection tests run real `/usr/bin/env sh` subprocesses (deterministic on macOS). `LoginShellPath` live resolution runs a real interactive shell — only exercised in the app/Task-3 manual step, not unit tests (unit tests inject the dependency).
