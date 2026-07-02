import Foundation
import GitWorkbench

/// E2E-only ``GitWorkbenchProvider`` that reports a **clean** repository by default and flips to the
/// standard mock fixture (the 7 changed files) only when a sentinel file says so (issue #573).
///
/// This keeps the Git tab's changed-file badge — which now loads eagerly for the displayed session —
/// from appearing in every scenario's tab bar just because the in-memory mock always has changes.
/// A scenario opts in with the `setGitMockChanges(true)` step (which writes the sentinel file); the
/// `repositoryChanges()` stream then notices and the store reloads, so the badge appears live.
///
/// Everything except working-tree status is delegated to a real ``MockGitProvider`` so History,
/// Stashes, diffs, branches/remotes, and actions still render the familiar fixtures.
struct E2EGitProvider: GitWorkbenchProvider {
    private let base = MockGitProvider(delay: .zero)
    /// Path to the sentinel file. Trimmed contents `== "1"` means "the working tree is dirty".
    let changesFilePath: String

    private func hasChanges() -> Bool {
        guard let raw = try? String(contentsOfFile: changesFilePath, encoding: .utf8) else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    // MARK: Data source

    func loadStatus() async throws -> RepositoryStatus {
        let status = try await base.loadStatus()
        guard hasChanges() else {
            // Clean working tree: same repo + branch, but nothing changed and nothing to push/pull,
            // so `RepositorySummary.changedFileCount` is 0 and the badge stays hidden.
            return RepositoryStatus(
                repositoryName: status.repositoryName,
                currentBranch: status.currentBranch,
                upstream: status.upstream,
                ahead: 0,
                behind: 0,
                files: [],
                author: status.author
            )
        }
        // GitWorkbench 1.6.0 added three binary (image/PDF) entries to the mock working-tree fixture to
        // demo its new image/PDF diff viewer. Drop them so the E2E Git tab keeps the deterministic
        // seven-text-file fixture the committed screenshot baselines — and the "7 changed files" badge
        // assertion — were built against. Filtering by renderable-binary kind (rather than hard-coding
        // the three paths) stays correct if future fixtures add more of the same.
        return RepositoryStatus(
            repositoryName: status.repositoryName,
            currentBranch: status.currentBranch,
            upstream: status.upstream,
            ahead: status.ahead,
            behind: status.behind,
            files: status.files.filter { BinaryContent.kind(forPath: $0.path) == nil },
            author: status.author
        )
    }

    func loadHistory(of ref: String?, before: Commit.ID?, limit: Int) async throws -> [Commit] {
        try await base.loadHistory(of: ref, before: before, limit: limit)
    }

    func loadStashes() async throws -> [Stash] {
        try await base.loadStashes()
    }

    func loadBranches() async throws -> [Branch] {
        // GitWorkbench 1.6.0 gave the mock branches ahead/behind counts, which now render an
        // `AheadBehindBadge` in each branch row. Keep those values so the badge actually renders in
        // the E2E Git view; the affected screenshot baselines are dropped so CI regenerates them.
        try await base.loadBranches()
    }

    func loadRemoteBranches() async throws -> [RemoteBranch] {
        try await base.loadRemoteBranches()
    }

    func loadDiff(_ request: DiffRequest) async throws -> FileDiff {
        try await base.loadDiff(request)
    }

    /// Polls the sentinel file and emits whenever its dirty/clean state flips, so the store reloads
    /// and the badge updates the moment a scenario calls `setGitMockChanges(_:)`. Polling (rather than
    /// FSEvents) keeps this dependency-free and is more than fast enough for E2E.
    func repositoryChanges() -> AsyncStream<Void>? {
        let path = changesFilePath
        return AsyncStream { continuation in
            let task = Task {
                func snapshot() -> Bool {
                    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
                    return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                }
                var last = snapshot()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400))
                    let now = snapshot()
                    if now != last {
                        last = now
                        continuation.yield(())
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Actions (delegated; the badge scenario doesn't exercise these)

    func stage(_ files: [FileChange]) async throws {
        try await base.stage(files)
    }

    func unstage(_ files: [FileChange]) async throws {
        try await base.unstage(files)
    }

    func discard(_ file: FileChange) async throws {
        try await base.discard(file)
    }

    func commit(message: String, staged: [FileChange]) async throws -> Commit {
        try await base.commit(message: message, staged: staged)
    }

    func pull() async throws -> SyncResult {
        try await base.pull()
    }

    func push() async throws -> SyncResult {
        try await base.push()
    }

    func fetch() async throws -> SyncResult {
        try await base.fetch()
    }

    func switchBranch(to branch: Branch) async throws {
        try await base.switchBranch(to: branch)
    }

    func checkoutRemoteBranch(_ branch: RemoteBranch) async throws {
        try await base.checkoutRemoteBranch(branch)
    }

    func applyStash(_ stash: Stash) async throws {
        try await base.applyStash(stash)
    }

    func popStash(_ stash: Stash) async throws {
        try await base.popStash(stash)
    }

    func dropStash(_ stash: Stash) async throws {
        try await base.dropStash(stash)
    }

    // MARK: History context-menu actions (right-click a commit; delegated to the mock)

    func checkout(_ commit: Commit) async throws {
        try await base.checkout(commit)
    }

    func resetHEAD(to commit: Commit, mode: ResetMode) async throws {
        try await base.resetHEAD(to: commit, mode: mode)
    }

    func revert(_ commit: Commit) async throws {
        try await base.revert(commit)
    }

    func cherryPick(_ commit: Commit) async throws {
        try await base.cherryPick(commit)
    }

    func createBranch(named name: String, at commit: Commit) async throws {
        try await base.createBranch(named: name, at: commit)
    }

    func createTag(named name: String, at commit: Commit) async throws {
        try await base.createTag(named: name, at: commit)
    }
}
