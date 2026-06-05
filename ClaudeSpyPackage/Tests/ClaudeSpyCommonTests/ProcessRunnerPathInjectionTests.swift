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
            #expect(parts.suffix(2) == ["/usr/bin", "/bin"])
            #expect(parts.filter { $0 == "/usr/bin" }.count == 1)
        }

        @Test("effectivePath does not duplicate a common dir already inherited")
        func fallbackNoDuplicate() {
            let result = ProcessRunner.effectivePath(resolved: nil, inherited: "/opt/homebrew/bin:/usr/bin")
            #expect(result.split(separator: ":").filter { $0 == "/opt/homebrew/bin" }.count == 1)
        }

        @Test("effectivePath handles nil inherited (returns just the common dirs)")
        func fallbackNilInherited() {
            #expect(!ProcessRunner.effectivePath(resolved: nil, inherited: nil).isEmpty)
        }

        @Test("live ProcessRunner injects the resolved PATH into the child environment")
        func injectsResolvedPathIntoChild() async throws {
            try await withDependencies {
                $0[LoginShellPath.self] = LoginShellPath(resolve: { "/zzz-test-marker:/usr/bin:/bin" })
                $0.continuousClock = ContinuousClock()
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
                $0.continuousClock = ContinuousClock()
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
