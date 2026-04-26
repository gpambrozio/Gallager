import ClaudeSpyNetworking
import Foundation

/// A pending "open this markdown file?" prompt attached to a tmux session.
///
/// Created when a `Write` PostToolUse hook lands a markdown file. Cleared when
/// the user accepts/dismisses, or 30 seconds after the user submits a new prompt.
public struct MarkdownOpenSuggestion: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Absolute path of the markdown file Claude wrote.
    public let filePath: String
    /// Directory the file should be displayed relative to in the new tab —
    /// captured from the hook's `projectPath` so the file tab keeps a stable
    /// header even when the user has moved to a different window or pane in
    /// the same session before clicking Yes.
    public let directoryPath: String
    /// Session this suggestion belongs to (so it survives window switches).
    public let sessionName: String
    /// True for plan files — UI shows a generic "the plan" label since the
    /// filename is typically a random string.
    public let isPlan: Bool

    public init(
        filePath: String,
        directoryPath: String,
        sessionName: String,
        isPlan: Bool,
        id: UUID = UUID()
    ) {
        self.id = id
        self.filePath = filePath
        self.directoryPath = directoryPath
        self.sessionName = sessionName
        self.isPlan = isPlan
    }

    /// Filename portion of the path, used in the prompt label for non-plan files.
    public var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

/// Tracks "open this markdown file?" prompts per tmux session and times them out
/// 30 seconds after the user submits a new prompt.
@Observable
@MainActor
final public class MarkdownOpenSuggestionStore {
    public private(set) var suggestionsBySession: [String: MarkdownOpenSuggestion] = [:]

    @ObservationIgnored
    private var dismissalTasks: [String: Task<Void, Never>] = [:]

    private let autoDismissDelay: Duration

    public init(autoDismissDelay: Duration = .seconds(30)) {
        self.autoDismissDelay = autoDismissDelay
    }

    deinit {
        for task in dismissalTasks.values {
            task.cancel()
        }
    }

    /// Replaces any existing suggestion for the same session with `suggestion`,
    /// cancelling any pending auto-dismiss timer.
    public func suggest(_ suggestion: MarkdownOpenSuggestion) {
        suggestionsBySession[suggestion.sessionName] = suggestion
        cancelDismissalTask(for: suggestion.sessionName)
    }

    /// Removes the suggestion for the given session (used by the Yes/No buttons).
    public func dismiss(sessionName: String) {
        suggestionsBySession.removeValue(forKey: sessionName)
        cancelDismissalTask(for: sessionName)
    }

    /// Starts a one-shot 30-second auto-dismiss timer the first time the user
    /// submits a prompt while a suggestion is pending. Subsequent prompts do
    /// not reset the timer — the suggestion goes away ~30s after the first
    /// new prompt regardless of how chatty the user gets.
    public func userSubmittedPrompt(sessionName: String) {
        guard suggestionsBySession[sessionName] != nil else { return }
        guard dismissalTasks[sessionName] == nil else { return }
        let delay = autoDismissDelay
        dismissalTasks[sessionName] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.suggestionsBySession.removeValue(forKey: sessionName)
            self?.dismissalTasks.removeValue(forKey: sessionName)
        }
    }

    /// Removes any suggestion (and pending timer) for a session that no longer exists.
    public func sessionRemoved(sessionName: String) {
        dismiss(sessionName: sessionName)
    }

    /// Inspects an incoming hook event and updates state when relevant. The
    /// caller resolves `sessionName` from `event.tmuxPane` since the store has
    /// no knowledge of pane→session mapping.
    public func handleHookEvent(_ event: HookEvent, sessionName: String) {
        switch event.action {
        case let .postToolUse(body):
            guard
                let toolInput = body.toolInput,
                case let .write(params) = toolInput,
                Self.isMarkdownPath(params.filePath)
            else { return }
            let directoryPath = event.projectPath
                ?? URL(fileURLWithPath: params.filePath).deletingLastPathComponent().path
            suggest(MarkdownOpenSuggestion(
                filePath: params.filePath,
                directoryPath: directoryPath,
                sessionName: sessionName,
                isPlan: Self.isPlanPath(params.filePath, projectPath: event.projectPath)
            ))
        case .userPromptSubmit:
            userSubmittedPrompt(sessionName: sessionName)
        default:
            break
        }
    }

    /// True when `path` ends with `.md` or `.markdown`. Case-insensitive.
    private static func isMarkdownPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }

    /// True when the file is recognisably a Claude-generated plan: either the
    /// immediate parent directory is `plans/`, or the basename is `plan` /
    /// `plan-foo` / `plan_foo`. Distinct from `planning.md` or `planet.md`
    /// which are treated as ordinary markdown so their filename is shown.
    ///
    /// Files that live inside the current project's folder are never plans —
    /// a `plans/` directory or `plan.md` checked into the repo is project
    /// documentation, not a transient Claude plan.
    private static func isPlanPath(_ path: String, projectPath: String?) -> Bool {
        if let projectPath, isPath(path, inside: projectPath) {
            return false
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
        if parent == "plans" { return true }
        let basename = url.deletingPathExtension().lastPathComponent.lowercased()
        if basename == "plan" { return true }
        return basename.hasPrefix("plan-") || basename.hasPrefix("plan_")
    }

    /// True when `path` resolves to a location strictly inside `parent`.
    /// Both inputs are standardized so `..` segments and trailing slashes
    /// don't affect the comparison; `/foo/bar` is correctly rejected as a
    /// child of `/foo/ba`.
    private static func isPath(_ path: String, inside parent: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardized.path
        let normalizedParent = URL(fileURLWithPath: parent).standardized.path
        let parentWithSlash = normalizedParent.hasSuffix("/")
            ? normalizedParent
            : normalizedParent + "/"
        return normalizedPath.hasPrefix(parentWithSlash)
    }

    private func cancelDismissalTask(for sessionName: String) {
        dismissalTasks[sessionName]?.cancel()
        dismissalTasks[sessionName] = nil
    }
}
