#if os(macOS)
    import Foundation
    import Testing
    @testable import CodexPluginCore

    @Suite("CodexLaunchCommandResolver")
    struct CodexLaunchCommandTests {
        // MARK: - Fixtures

        /// Writes a stub executable to a temp dir and returns its path.
        /// The file is just a no-op shell script.
        private static func makeExecutable(named name: String = "codex") throws -> URL {
            let tmp = URL(
                fileURLWithPath: NSTemporaryDirectory(),
                isDirectory: true
            )
            .appendingPathComponent("codex-launch-test-\(UUID().uuidString)", isDirectory: true)
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
            let resolver = CodexLaunchCommandResolver(
                locator: CodexBinaryLocator(find: { stub.path })
            )
            let cmd = try await resolver.resolve(
                settings: CodexSettings(commandPath: "codex")
            )
            #expect(cmd.command == stub.path)
            #expect(cmd.args == [])
            #expect(cmd.env.isEmpty)
        }

        @Test("Resolves verbatim when commandPath is an absolute executable path")
        func resolvesAbsolutePath() async throws {
            let stub = try Self.makeExecutable(named: "codex-absolute")
            let resolver = CodexLaunchCommandResolver(
                locator: CodexBinaryLocator(find: { "/nope/never" })
            )
            let cmd = try await resolver.resolve(
                settings: CodexSettings(commandPath: stub.path)
            )
            #expect(cmd.command == stub.path)
        }

        // MARK: - Missing binary → throws

        @Test("Missing binary via locator throws binaryNotFound")
        func locatorMissingThrows() async throws {
            let resolver = CodexLaunchCommandResolver(
                locator: CodexBinaryLocator(find: { nil })
            )
            await #expect(throws: CodexLaunchCommandResolver.ResolveError.self) {
                _ = try await resolver.resolve(
                    settings: CodexSettings(commandPath: "codex")
                )
            }
        }

        @Test("Absolute path pointing at a missing file throws binaryNotFound")
        func absoluteMissingThrows() async throws {
            let bogus = "/definitely/does/not/exist/codex-\(UUID().uuidString)"
            let resolver = CodexLaunchCommandResolver(
                locator: CodexBinaryLocator(find: { nil })
            )
            do {
                _ = try await resolver.resolve(
                    settings: CodexSettings(commandPath: bogus)
                )
                Issue.record("expected resolver to throw")
            } catch let CodexLaunchCommandResolver.ResolveError.binaryNotFound(name) {
                #expect(name == bogus)
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        @Test("Empty commandPath throws invalidSettings")
        func emptySettingsThrows() async throws {
            let resolver = CodexLaunchCommandResolver(
                locator: CodexBinaryLocator(find: { "/some/codex" })
            )
            do {
                _ = try await resolver.resolve(settings: CodexSettings(commandPath: ""))
                Issue.record("expected resolver to throw")
            } catch let CodexLaunchCommandResolver.ResolveError.invalidSettings(error) {
                #expect(error == .emptyCommandPath)
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        // MARK: - Env

        @Test("Resolver does not synthesize Codex env vars in v1")
        func envIsEmpty() async throws {
            let stub = try Self.makeExecutable()
            let resolver = CodexLaunchCommandResolver(
                locator: CodexBinaryLocator(find: { stub.path })
            )
            let cmd = try await resolver.resolve(
                settings: CodexSettings(),
                projectPath: "/some/project"
            )
            #expect(cmd.env.isEmpty)
        }
    }
#endif
