import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol

/// Discovers Codex CLI projects by scanning `~/.codex/sessions/` (or
/// `$CODEX_HOME/sessions/`) for date-partitioned rollout `.jsonl` files,
/// producing agent-blind `AgentProject` entries tagged with this plugin's id.
///
/// Ported faithfully from the legacy `CodexProjectScanner` /
/// `LiveCodexProjectScanner` in `ClaudeSpyServerFeature/Services/`, simplified to
/// a synchronous `Sendable` value type (the actor owns the off-loop scheduling).
/// Codex stores sessions under `<sessions>/YYYY/MM/DD/rollout-*.jsonl`
/// (date-partitioned, not project-partitioned); each rollout's first JSON line
/// carries a `cwd` field, which we aggregate by working directory to recover the
/// set of projects the user has run Codex against.
///
/// Defensive by mandate (spec §13): it parses real-world, possibly-hostile
/// rollout files, so every read/decode is wrapped in `do/try/catch` with no
/// force-unwraps — a malformed rollout skips, it never traps. The scan root is
/// injected so a test can point it at a temp fixture.
struct CodexScanner {
    private let fileManager = FileManager.default

    /// Cap on rollout files we read per scan. Codex can accumulate many
    /// rollouts; we read newest-first so older ones rarely add useful info.
    private static let maxRolloutsToRead = 500

    /// The default Codex sessions root: `$CODEX_HOME/sessions` if `CODEX_HOME`
    /// is set, otherwise `~/.codex/sessions`. Injected into `scan` so tests can
    /// point at a fixture.
    static func defaultSessionsRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
                .standardizedFileURL
                .appendingPathComponent("sessions")
        }
        return home
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
            .standardizedFileURL
    }

    /// Scans `sessionsRoot` for Codex rollouts and groups them by `cwd`.
    ///
    /// - Parameters:
    ///   - sessionsRoot: The `…/sessions` directory to walk. Injected so tests
    ///     can point at a temp fixture.
    ///   - home: The home directory used only to exclude itself from results.
    /// - Returns: Discovered projects, most-recently-used first.
    func scan(
        sessionsRoot: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [AgentProject] {
        let homeStandardized = home.standardizedFileURL
        var projectsByPath: [String: AgentProject] = [:]

        let rollouts = enumerateRollouts(under: sessionsRoot, limit: Self.maxRolloutsToRead)

        // Read newest-first; the first rollout that yields a cwd for a given
        // project wins, and we still merge by `started_at` below.
        for rollout in rollouts {
            guard let meta = Self.readSessionMeta(at: rollout.url) else { continue }
            guard let cwd = meta.cwd, !cwd.isEmpty else { continue }

            let projectURL = URL(fileURLWithPath: cwd).standardizedFileURL

            // The home directory itself is never a project.
            if projectURL == homeStandardized { continue }

            // Verify the project directory still exists on disk before
            // surfacing it — rollouts can outlive their working directory.
            var isDirectory: ObjCBool = false
            guard
                fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }

            let candidate = AgentProject(
                name: projectURL.lastPathComponent,
                path: projectURL.path,
                lastUsed: meta.startedAt,
                configDir: nil,
                pluginID: CodexPluginCore.pluginID
            )

            if let existing = projectsByPath[candidate.path] {
                if shouldReplace(existing: existing, with: candidate) {
                    projectsByPath[candidate.path] = candidate
                }
            } else {
                projectsByPath[candidate.path] = candidate
            }
        }

        return Array(projectsByPath.values).sortedByLastUsed()
    }

    /// Newer `lastUsed` wins when the same project path appears under two
    /// rollouts.
    private func shouldReplace(existing: AgentProject, with candidate: AgentProject) -> Bool {
        switch (existing.lastUsed, candidate.lastUsed) {
        case let (existingDate?, candidateDate?):
            candidateDate > existingDate
        case (nil, .some):
            true
        default:
            false
        }
    }

    // MARK: - Rollout enumeration

    /// Bundles a rollout URL with its mtime so we can restore newest-first
    /// ordering when merging metas.
    private struct RolloutCandidate {
        let url: URL
        let mtime: Date
    }

    /// Returns rollout file URLs under the sessions root, newest first, up to
    /// `limit` candidates. Leans on Codex's `YYYY/MM/DD/` partition to stop
    /// walking once the limit is reached rather than enumerating the full tree,
    /// sorting, and slicing. Falls back to a recursive scan if the
    /// year/month/day layout isn't present (e.g. Codex changes its schema).
    private func enumerateRollouts(under root: URL, limit: Int) -> [RolloutCandidate] {
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return [] }

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

        return recursiveEnumerateRollouts(under: root, limit: limit)
    }

    /// Lists immediate subdirectories of `dir` whose names are all-digit (e.g.
    /// `2026`, `05`, `21`), sorted descending. Since sibling names share a length
    /// at each level, lexicographic descending equals numeric descending.
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
            )
        else { return [] }
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

    /// Fallback used when Codex's YYYY/MM/DD layout isn't present. Walks the
    /// whole tree, sorts by mtime, and truncates.
    private func recursiveEnumerateRollouts(under root: URL, limit: Int) -> [RolloutCandidate] {
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
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

    // MARK: - Session meta (defensive — never traps)

    private struct SessionMeta {
        let cwd: String?
        let startedAt: Date?
    }

    /// Number of JSON-parseable lines to inspect at the head of a rollout while
    /// looking for the session-meta record. Scanning a few lines is cheap
    /// insurance against Codex inserting a non-meta event ahead of the meta.
    private static let metaScanLineLimit = 8

    /// Reads up to the first `metaScanLineLimit` JSON-parseable lines of a
    /// rollout and tries to extract `cwd` / `started_at`. Codex's exact schema
    /// is evolving, so we accept a small set of plausible key spellings to stay
    /// forward-compatible. Never traps — any read/decode failure returns `nil`.
    private static func readSessionMeta(at url: URL) -> SessionMeta? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Read up to 64KB — the session-meta line is at the head and is
        // typically a few hundred bytes.
        guard
            let data = try? handle.read(upToCount: 64 * 1_024),
            !data.isEmpty,
            let text = String(data: data, encoding: .utf8)
        else { return nil }

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
                return nil
            }
        }

        return nil
    }

    /// Two formatters cover the rollout timestamp variants we've observed: with
    /// fractional seconds and without. Mutating a formatter's formatOptions
    /// per-call is not thread-safe, so we keep two and pick one.
    /// `nonisolated(unsafe)` is safe because we never mutate after creation.
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
}
