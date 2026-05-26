import Dependencies
import Foundation

/// A pending "open this markdown file?" prompt attached to a tmux session.
///
/// Created when a plugin sidecar emits `AppAction.openFileSuggestion`
/// for a markdown file (the Claude/Codex translators fire this whenever a
/// `Write` PostToolUse lands a `.md` / `.markdown` path). Cleared when
/// the user accepts/dismisses, or 30 seconds after the user submits a new
/// prompt.
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

    @ObservationIgnored
    @Dependency(\.continuousClock) private var clock

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
            try? await self?.clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.suggestionsBySession.removeValue(forKey: sessionName)
            self?.dismissalTasks.removeValue(forKey: sessionName)
        }
    }

    /// Removes any suggestion (and pending timer) for a session that no longer exists.
    public func sessionRemoved(sessionName: String) {
        dismiss(sessionName: sessionName)
    }

    private func cancelDismissalTask(for sessionName: String) {
        dismissalTasks[sessionName]?.cancel()
        dismissalTasks[sessionName] = nil
    }
}
