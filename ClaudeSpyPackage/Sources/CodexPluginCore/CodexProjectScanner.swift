#if os(macOS)
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
        public var scanProjects: @Sendable () async -> [AgentProject] = { [] }
    }

    // MARK: - In-Memory

    public extension CodexProjectScanner {
        static func inMemory(projects: [AgentProject] = [
            AgentProject(name: "AlphaCodex", path: "/Users/test/AlphaCodex", pluginID: "codex"),
            AgentProject(name: "BetaCodex", path: "/Users/test/BetaCodex", pluginID: "codex"),
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

        func scanProjects() async -> [AgentProject] {
            logger.debug("Scanning for Codex projects")

            let sessionsRoot = codexHomeURL().appendingPathComponent("sessions")
            var projectsByPath: [String: AgentProject] = [:]
            let homeDirectory = fileManager.homeDirectoryForCurrentUser.standardizedFileURL

            let rollouts = enumerateRollouts(under: sessionsRoot, limit: Self.maxRolloutsToRead)
            logger.debug("Found \(rollouts.count) Codex rollout candidates")

            // Reads block on synchronous FileHandle I/O. Fan them out to a
            // utility-priority task group so a heavy Codex user's 500-file
            // scan doesn't serialize on this actor's executor. Results come
            // back in completion order; we re-sort by rollout mtime below to
            // preserve the "newest rollout wins" merge behavior.
            let metas = await withTaskGroup(
                of: (RolloutCandidate, SessionMeta?).self,
                returning: [(RolloutCandidate, SessionMeta)].self
            ) { group in
                let logger = self.logger
                for rollout in rollouts {
                    group.addTask(priority: .utility) {
                        (rollout, Self.readSessionMeta(at: rollout.url, logger: logger))
                    }
                }
                var results: [(RolloutCandidate, SessionMeta)] = []
                for await (rollout, meta) in group {
                    if let meta { results.append((rollout, meta)) }
                }
                results.sort { $0.0.mtime > $1.0.mtime }
                return results
            }

            for (_, meta) in metas {
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

                let candidate = AgentProject(
                    name: projectURL.lastPathComponent,
                    path: projectURL.path,
                    lastUsed: meta.startedAt,
                    claudeConfigDir: nil,
                    pluginID: "codex"
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

        /// Bundles a rollout URL with its mtime so the parallel reader can
        /// restore newest-first ordering after the TaskGroup yields results
        /// in completion order.
        fileprivate struct RolloutCandidate: Sendable {
            let url: URL
            let mtime: Date
        }

        /// Returns rollout file URLs under `~/.codex/sessions/`, newest first,
        /// up to `limit` candidates. Leans on Codex's `YYYY/MM/DD/` partition
        /// to stop walking once the limit is reached rather than enumerating
        /// the full tree, sorting, and slicing. Falls back to a recursive
        /// scan if the year/month/day layout isn't present (e.g. Codex
        /// changes its on-disk schema).
        private func enumerateRollouts(under root: URL, limit: Int) -> [RolloutCandidate] {
            var isDirectory: ObjCBool = false
            guard
                fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                logger.debug("No Codex sessions directory at \(root.path)")
                return []
            }

            let years = sortedNumericChildren(of: root)
            if !years.isEmpty {
                var candidates: [RolloutCandidate] = []
                outer: for year in years {
                    for month in sortedNumericChildren(of: year) {
                        for day in sortedNumericChildren(of: month) {
                            candidates.append(contentsOf: jsonlFilesInDay(day))
                            if candidates.count >= limit {
                                break outer
                            }
                        }
                    }
                }
                return Array(candidates.prefix(limit))
            }

            logger.debug("Codex sessions root has no year/month/day folders; falling back to recursive scan")
            return recursiveEnumerateRollouts(under: root, limit: limit)
        }

        /// Lists immediate subdirectories of `dir` whose names are all-digit
        /// (e.g. `2026`, `05`, `21`), sorted descending. Since all sibling
        /// names share a length at each level (4-digit years, 2-digit months
        /// and days), lexicographic descending equals numeric descending.
        private func sortedNumericChildren(of dir: URL) -> [URL] {
            let children = (try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return children
                .filter { url in
                    let name = url.lastPathComponent
                    guard !name.isEmpty, name.allSatisfy(\.isASCII), Int(name) != nil else { return false }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                    return values?.isDirectory == true
                }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }

        /// Lists `.jsonl` files directly inside `day`, newest mtime first.
        private func jsonlFilesInDay(_ day: URL) -> [RolloutCandidate] {
            guard
                let files = try? fileManager.contentsOfDirectory(
                    at: day,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                return []
            }
            var result: [RolloutCandidate] = []
            for url in files {
                guard url.pathExtension == "jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let mtime = values?.contentModificationDate ?? .distantPast
                result.append(RolloutCandidate(url: url, mtime: mtime))
            }
            result.sort { $0.mtime > $1.mtime }
            return result
        }

        /// Fallback path used when Codex's YYYY/MM/DD layout isn't present.
        /// Walks the whole tree, sorts by mtime, and truncates — the slow
        /// path the bounded walk above is designed to avoid.
        private func recursiveEnumerateRollouts(under root: URL, limit: Int) -> [RolloutCandidate] {
            guard
                let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                return []
            }
            var candidates: [RolloutCandidate] = []
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let mtime = values?.contentModificationDate ?? .distantPast
                candidates.append(RolloutCandidate(url: url, mtime: mtime))
            }
            candidates.sort { $0.mtime > $1.mtime }
            return Array(candidates.prefix(limit))
        }

        // MARK: - Session Meta

        fileprivate struct SessionMeta: Sendable {
            let cwd: String?
            let startedAt: Date?
        }

        /// Number of JSON-parseable lines to inspect at the head of a rollout
        /// while looking for the session-meta record. Bailing after the first
        /// non-meta JSON line would silently drop every rollout if Codex ever
        /// inserts a non-meta event ahead of the meta record; scanning a few
        /// more lines is cheap insurance.
        private static let metaScanLineLimit = 8

        /// Reads up to the first `metaScanLineLimit` JSON-parseable lines of a
        /// rollout and tries to extract `cwd` / `started_at`. Codex's exact
        /// schema is evolving; we accept a small set of plausible key spellings
        /// to stay forward-compatible.
        ///
        /// `static` and `nonisolated`: invoked from detached utility-priority
        /// tasks so synchronous FileHandle reads don't pin the scanner actor's
        /// executor.
        private static func readSessionMeta(at url: URL, logger: Logger) -> SessionMeta? {
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

            var inspected = 0
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

                let startedAt = startedAtString.flatMap(parseISO8601)

                if cwd != nil || startedAt != nil {
                    return SessionMeta(cwd: cwd, startedAt: startedAt)
                }

                inspected += 1
                if inspected >= metaScanLineLimit {
                    logger.debug("Rollout \(url.lastPathComponent) has no meta in the first \(metaScanLineLimit) JSON lines; skipping")
                    return nil
                }
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

        private func shouldReplace(existing: AgentProject, with candidate: AgentProject) -> Bool {
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
