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

        /// Tests that exercise `ProcessRunner.liveValue` (e.g. tmux/`LayoutDriver`
        /// integration tests) read this dependency unconditionally. Resolve to
        /// `nil` so `ProcessRunner` falls back to the inherited PATH (the test
        /// process's full shell PATH) — no shell spawn, no behavior change — rather
        /// than tripping the auto-generated unimplemented test value. Tests that
        /// assert injection override it explicitly via `withDependencies`.
        public static var testValue: LoginShellPath {
            LoginShellPath(resolve: { nil })
        }
    }

    /// Caches the one-time login-shell PATH resolution for the process lifetime.
    final private class PathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved = false
        private var cached: String?

        func value() -> String? {
            lock.lock()
            if resolved {
                let v = cached
                lock.unlock()
                return v
            }
            lock.unlock()

            // Resolution runs without the lock — concurrent first callers may each spawn a
            // shell, and the first writer wins; fine since the PATH is idempotent.
            let result = Self.runResolution()

            lock.lock()
            defer { lock.unlock() }
            if !resolved {
                resolved = true
                cached = result
            }
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
