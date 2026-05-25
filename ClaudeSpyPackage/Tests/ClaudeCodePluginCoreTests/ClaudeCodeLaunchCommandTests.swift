#if os(macOS)
    import Foundation
    import Testing
    @testable import ClaudeCodePluginCore

    @Suite("ClaudeCodeLaunchCommandResolver")
    struct ClaudeCodeLaunchCommandTests {
        // MARK: - Fixtures

        /// Writes a stub executable to a temp dir and returns its path.
        /// The file is just a no-op shell script; what matters is that
        /// `FileManager.isExecutableFile(atPath:)` returns true.
        private static func makeExecutable(named name: String = "claude") throws -> URL {
            let tmp = URL(
                fileURLWithPath: NSTemporaryDirectory(),
                isDirectory: true
            )
            .appendingPathComponent("claude-code-launch-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let executable = tmp.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
            return executable
        }

        // MARK: - Locator path

        @Test("Resolves to absolute path via locator when commandPath is a bare name")
        func resolvesViaLocator() async throws {
            let stub = try Self.makeExecutable()
            let resolver = ClaudeCodeLaunchCommandResolver(
                locator: ClaudeBinaryLocator(find: { stub.path })
            )
            let cmd = try await resolver.resolve(
                settings: ClaudeCodeSettings(commandPath: "claude")
            )
            #expect(cmd.command == stub.path)
            #expect(cmd.args == [])
            #expect(cmd.env.isEmpty)
        }

        @Test("Resolves verbatim when commandPath is an absolute executable path")
        func resolvesAbsolutePath() async throws {
            let stub = try Self.makeExecutable(named: "claude-absolute")
            // Locator returns a different path — we should ignore it because
            // settings carry an absolute path directly.
            let resolver = ClaudeCodeLaunchCommandResolver(
                locator: ClaudeBinaryLocator(find: { "/nope/never" })
            )
            let cmd = try await resolver.resolve(
                settings: ClaudeCodeSettings(commandPath: stub.path)
            )
            #expect(cmd.command == stub.path)
        }

        // MARK: - Missing binary → throws

        @Test("Missing binary via locator throws binaryNotFound")
        func locatorMissingThrows() async throws {
            let resolver = ClaudeCodeLaunchCommandResolver(
                locator: ClaudeBinaryLocator(find: { nil })
            )
            await #expect(throws: ClaudeCodeLaunchCommandResolver.ResolveError.self) {
                _ = try await resolver.resolve(
                    settings: ClaudeCodeSettings(commandPath: "claude")
                )
            }
        }

        @Test("Absolute path pointing at a missing file throws binaryNotFound")
        func absoluteMissingThrows() async throws {
            let bogus = "/definitely/does/not/exist/claude-\(UUID().uuidString)"
            let resolver = ClaudeCodeLaunchCommandResolver(
                locator: ClaudeBinaryLocator(find: { nil })
            )
            do {
                _ = try await resolver.resolve(
                    settings: ClaudeCodeSettings(commandPath: bogus)
                )
                Issue.record("expected resolver to throw")
            } catch let ClaudeCodeLaunchCommandResolver.ResolveError.binaryNotFound(name) {
                #expect(name == bogus)
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        @Test("Empty commandPath throws invalidSettings")
        func emptySettingsThrows() async throws {
            let resolver = ClaudeCodeLaunchCommandResolver(
                locator: ClaudeBinaryLocator(find: { "/some/claude" })
            )
            do {
                _ = try await resolver.resolve(settings: ClaudeCodeSettings(commandPath: ""))
                Issue.record("expected resolver to throw")
            } catch let ClaudeCodeLaunchCommandResolver.ResolveError.invalidSettings(error) {
                #expect(error == .emptyCommandPath)
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        // MARK: - Env vars

        @Test("claudeConfigDir populates CLAUDE_CONFIG_DIR in env")
        func claudeConfigDirPopulatesEnv() async throws {
            let stub = try Self.makeExecutable()
            let resolver = ClaudeCodeLaunchCommandResolver(
                locator: ClaudeBinaryLocator(find: { stub.path })
            )
            let cmd = try await resolver.resolve(
                settings: ClaudeCodeSettings(),
                claudeConfigDir: "/home/me/.config/claude"
            )
            #expect(cmd.env["CLAUDE_CONFIG_DIR"] == "/home/me/.config/claude")
        }

        @Test("nil claudeConfigDir omits CLAUDE_CONFIG_DIR")
        func nilClaudeConfigDirOmitsEnv() async throws {
            let stub = try Self.makeExecutable()
            let resolver = ClaudeCodeLaunchCommandResolver(
                locator: ClaudeBinaryLocator(find: { stub.path })
            )
            let cmd = try await resolver.resolve(
                settings: ClaudeCodeSettings(),
                claudeConfigDir: nil
            )
            #expect(cmd.env["CLAUDE_CONFIG_DIR"] == nil)
        }

        @Test("Empty claudeConfigDir is treated as nil")
        func emptyClaudeConfigDirOmitted() async throws {
            let stub = try Self.makeExecutable()
            let resolver = ClaudeCodeLaunchCommandResolver(
                locator: ClaudeBinaryLocator(find: { stub.path })
            )
            let cmd = try await resolver.resolve(
                settings: ClaudeCodeSettings(),
                claudeConfigDir: ""
            )
            #expect(cmd.env.isEmpty)
        }
    }
#endif
