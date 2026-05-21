#if os(macOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging

    /// A dependency for scanning the local filesystem to discover Codex CLI projects.
    ///
    /// Codex stores sessions under `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
    /// (date-partitioned, not project-partitioned). Each rollout's first JSON
    /// line carries a `cwd` field that we aggregate by working directory to
    /// recover the set of projects the user has run Codex against.
    @DependencyClient
    public struct CodexProjectScanner: Sendable {
        /// Scans for Codex projects and returns a list sorted by most recently used.
        public var scanProjects: @Sendable () async -> [ClaudeProjectInfo] = { [] }
    }

    // MARK: - In-Memory

    public extension CodexProjectScanner {
        static func inMemory(projects: [ClaudeProjectInfo] = [
            ClaudeProjectInfo(name: "AlphaCodex", path: "/Users/test/AlphaCodex", agent: .codex),
            ClaudeProjectInfo(name: "BetaCodex", path: "/Users/test/BetaCodex", agent: .codex),
        ]) -> CodexProjectScanner {
            CodexProjectScanner(scanProjects: { projects })
        }
    }

    // MARK: - DependencyKey

    extension CodexProjectScanner: DependencyKey {
        public static var previewValue: CodexProjectScanner {
            .inMemory()
        }

        public static var liveValue: CodexProjectScanner {
            let scanner = LiveCodexProjectScanner()

            return CodexProjectScanner(
                scanProjects: {
                    await scanner.scanProjects()
                }
            )
        }
    }

    // MARK: - Live Implementation

    /// Actor that scans `~/.codex/sessions/` for rollout files and groups them by cwd.
    ///
    /// Two-pass discovery:
    /// 1. Walk `~/.codex/sessions/**/*.jsonl` and read each rollout's session-meta
    ///    line to recover `cwd` and `started_at`. Aggregate by cwd, keeping the
    ///    newest `started_at` per project.
    /// 2. Fallback: scan a small set of well-known parent directories for
    ///    repositories containing a `.codex/` folder or an `AGENTS.md` file —
    ///    catches projects that have been configured for Codex but haven't yet
    ///    produced a session rollout. Optional and best-effort.
    private actor LiveCodexProjectScanner {
        private let logger = Logger(label: "com.claudespy.codexscanner")
        private let fileManager = FileManager.default

        /// Cap on rollout files we read per scan. Codex can accumulate many
        /// rollouts; we read newest-first so older ones rarely add useful info.
        private static let maxRolloutsToRead = 500

        func scanProjects() async -> [ClaudeProjectInfo] {
            logger.debug("Scanning for Codex projects")

            let sessionsRoot = codexHomeURL().appendingPathComponent("sessions")
            var projectsByPath: [String: ClaudeProjectInfo] = [:]
            let homeDirectory = fileManager.homeDirectoryForCurrentUser.standardizedFileURL

            let rollouts = enumerateRollouts(under: sessionsRoot)
            logger.debug("Found \(rollouts.count) Codex rollout files")

            for rollout in rollouts.prefix(Self.maxRolloutsToRead) {
                guard let meta = readSessionMeta(at: rollout) else { continue }
                guard let cwd = meta.cwd, !cwd.isEmpty else { continue }

                let projectURL = URL(fileURLWithPath: cwd).standardizedFileURL
                if projectURL == homeDirectory { continue }

                // Verify the project directory still exists on disk before
                // surfacing it — rollouts can outlive their working directory.
                var isDirectory: ObjCBool = false
                guard
                    fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else {
                    continue
                }

                let candidate = ClaudeProjectInfo(
                    name: projectURL.lastPathComponent,
                    path: projectURL.path,
                    lastUsed: meta.startedAt,
                    claudeConfigDir: nil,
                    agent: .codex
                )

                if let existing = projectsByPath[candidate.path] {
                    if shouldReplace(existing: existing, with: candidate) {
                        projectsByPath[candidate.path] = candidate
                    }
                } else {
                    projectsByPath[candidate.path] = candidate
                }
            }

            var projects = Array(projectsByPath.values)
            projects.sort { lhs, rhs in
                switch (lhs.lastUsed, rhs.lastUsed) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate > rhsDate
                case (nil, .some):
                    return false
                case (.some, nil):
                    return true
                case (nil, nil):
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }

            logger.info("Found \(projects.count) Codex projects")
            return projects
        }

        // MARK: - Codex Home

        /// Resolves `CODEX_HOME` if set, otherwise `~/.codex`.
        private func codexHomeURL() -> URL {
            if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
                return URL(fileURLWithPath: override).standardizedFileURL
            }
            return fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
                .standardizedFileURL
        }

        // MARK: - Rollout Enumeration

        /// Returns all rollout file URLs under `~/.codex/sessions/**/*.jsonl`,
        /// sorted by file modification date, newest first.
        private func enumerateRollouts(under root: URL) -> [URL] {
            var isDirectory: ObjCBool = false
            guard
                fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                logger.debug("No Codex sessions directory at \(root.path)")
                return []
            }

            guard
                let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                return []
            }

            var urls: [(url: URL, mtime: Date)] = []
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let mtime = values?.contentModificationDate ?? .distantPast
                urls.append((url, mtime))
            }
            urls.sort { $0.mtime > $1.mtime }
            return urls.map(\.url)
        }

        // MARK: - Session Meta

        private struct SessionMeta {
            let cwd: String?
            let startedAt: Date?
        }

        /// Reads the first non-empty JSON line of a rollout and tries to extract
        /// `cwd` / `started_at`. Codex's exact schema is evolving; we accept a
        /// small set of plausible key spellings to stay forward-compatible.
        private func readSessionMeta(at url: URL) -> SessionMeta? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }

            // Read up to 64KB — the session-meta line is at the head and is
            // typically a few hundred bytes.
            guard
                let data = try? handle.read(upToCount: 64 * 1_024),
                !data.isEmpty,
                let text = String(data: data, encoding: .utf8) else {
                return nil
            }

            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let lineData = Data(trimmed.utf8)
                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    continue
                }

                let cwd = (json["cwd"] as? String)
                    ?? (json["working_directory"] as? String)
                    ?? (json["workingDirectory"] as? String)
                    ?? ((json["payload"] as? [String: Any])?["cwd"] as? String)

                let startedAtString = (json["started_at"] as? String)
                    ?? (json["startedAt"] as? String)
                    ?? (json["timestamp"] as? String)

                let startedAt = startedAtString.flatMap(Self.parseISO8601)

                if cwd != nil || startedAt != nil {
                    return SessionMeta(cwd: cwd, startedAt: startedAt)
                }
                // First parseable line that isn't a session-meta line tells us
                // this rollout doesn't lead with metadata — bail rather than
                // scanning the whole file.
                return nil
            }

            return nil
        }

        // Two formatters cover the rollout timestamp variants we've observed:
        // with-fractional-seconds and without. Mutating a formatter's
        // formatOptions per-call is not thread-safe, so we keep two and pick
        // one. `nonisolated(unsafe)` is safe because we never mutate after
        // creation — same pattern used in RelayMessages.
        private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        private nonisolated(unsafe) static let iso8601FormatterNoFractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()

        private static func parseISO8601(_ string: String) -> Date? {
            if let date = iso8601Formatter.date(from: string) { return date }
            return iso8601FormatterNoFractional.date(from: string)
        }

        // MARK: - Merge Helpers

        private func shouldReplace(existing: ClaudeProjectInfo, with candidate: ClaudeProjectInfo) -> Bool {
            switch (existing.lastUsed, candidate.lastUsed) {
            case let (existingDate?, candidateDate?):
                return candidateDate > existingDate
            case (nil, .some):
                return true
            default:
                return false
            }
        }
    }

#endif
