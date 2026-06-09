import Dependencies
import Foundation
import GitWorkbench
import GitWorkbenchGitKit

/// Vends a ``GitWorkbenchProvider`` for a repository directory so the Git tab
/// (issue #258) can be backed by the real `git` CLI in production while previews
/// and E2E scenarios get a deterministic, in-memory mock.
///
/// Modeled as a small factory closure rather than a single provider instance
/// because each session's Git tab points at a different repository — the host
/// calls `provider(repositoryURL:)` with the same folder the file explorer uses.
///
/// Registered as a Point-Free `DependencyKey`; read it with
/// `@Dependency(GitWorkbenchProviderClient.self)`. The E2E entry point swaps in
/// ``mock`` via `prepareDependencies` (see `ClaudeSpyServerApp`), so scenarios
/// render stable `GitWorkbench` fixtures (repo "aurora-cli", branch
/// "feat/auto-sync") instead of running `git` against a fake filesystem.
public struct GitWorkbenchProviderClient: Sendable {
    /// Builds a provider for the repository rooted at `repositoryURL`. The URL
    /// may point at any directory inside a work tree — `CLIGitProvider` resolves
    /// the actual top level via `git rev-parse --show-toplevel`.
    public var provider: @Sendable (_ repositoryURL: URL) -> any GitWorkbenchProvider

    public init(provider: @escaping @Sendable (_ repositoryURL: URL) -> any GitWorkbenchProvider) {
        self.provider = provider
    }
}

// MARK: - DependencyKey

extension GitWorkbenchProviderClient: DependencyKey {
    /// Live provider backed by the system `git` CLI.
    public static let liveValue = GitWorkbenchProviderClient { url in
        CLIGitProvider(repositoryURL: url)
    }

    /// Deterministic fixtures for previews. `.zero` artificial latency means the
    /// workbench populates immediately, so previews render the familiar fixtures.
    public static let mock = GitWorkbenchProviderClient { _ in
        MockGitProvider(delay: .zero)
    }

    /// E2E provider that starts **clean** and flips to the mock fixture only when the
    /// sentinel file at `changesFilePath` is set via the `setGitMockChanges(_:)` step
    /// (issue #573). Used so the eagerly-loaded Git tab badge doesn't show in every
    /// scenario — only the ones that explicitly introduce changes.
    public static func e2e(changesFilePath: String) -> GitWorkbenchProviderClient {
        GitWorkbenchProviderClient { _ in
            E2EGitProvider(changesFilePath: changesFilePath)
        }
    }

    public static let previewValue = mock
    public static let testValue = mock
}
