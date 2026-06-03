import Foundation

// MARK: - PluginEvent

/// The single carrier for everything a plugin wants to change about app state.
/// There is no second mechanism. A core returns one from `handleIngress` or
/// pushes one via `host.emit`; a single dispatcher fans its fields out to the
/// state, notification, and app-action sinks (spec §5).
public struct PluginEvent: Codable, Sendable, Equatable {
    public let pluginID: String
    public let sessionID: String

    /// The session's new state, or `nil` for "no opinion, leave it unchanged".
    /// Replaces the former working/attention/responseRequest trio (spec §3); the
    /// open response form, when any, rides the `awaiting*` cases. A `nil`-state
    /// event still flows for its `notification` / `appActions`.
    public let state: AgentState?

    /// A pre-baked Mac notification + iOS push (strings formatted by the core).
    public let notification: NotificationSpec?

    /// Discrete agent-blind Mac-side triggers (markdown suggestion, pane close…).
    public let appActions: [AppAction]

    /// Bootstraps the `AgentSession`↔pane mapping (from the ingress context).
    public let tmuxPane: String?

    /// Lets the app render the project name before any tmux refresh tick.
    public let projectPath: String?

    public init(
        pluginID: String,
        sessionID: String,
        state: AgentState? = nil,
        notification: NotificationSpec? = nil,
        appActions: [AppAction] = [],
        tmuxPane: String? = nil,
        projectPath: String? = nil
    ) {
        self.pluginID = pluginID
        self.sessionID = sessionID
        self.state = state
        self.notification = notification
        self.appActions = appActions
        self.tmuxPane = tmuxPane
        self.projectPath = projectPath
    }
}

// MARK: - NotificationSpec

/// A pre-formatted notification. The core owns the copy; the app surfaces a Mac
/// notification AND pushes it to iOS.
public struct NotificationSpec: Codable, Sendable, Equatable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

// MARK: - AppAction

/// The closed, agent-blind vocabulary of Mac-side feature triggers a plugin can
/// fire (spec §6). The app owns the behavior; the core only states intent.
public enum AppAction: Codable, Sendable, Equatable {
    /// The core saw a write to a `.md`/`.markdown` path; surface an "open this
    /// file?" prompt. `projectDir`, when known, is the project root the file
    /// belongs to — the app roots the opened file tab there (so the tree and the
    /// relative-path header use the project, not the file's immediate folder).
    case openFileSuggestion(sessionID: String, path: String, displayName: String, isPlan: Bool, projectDir: String?)

    /// Clear outstanding file suggestions (e.g. on prompt submit).
    case dismissFileSuggestions(sessionID: String)

    /// The core signals a session end (any reason). The app resets the pane's
    /// session-scoped state — e.g. yolo mode, so a fresh session doesn't inherit
    /// it. `closePaneEligible == true` means BOTH that the agent exited cleanly at
    /// the prompt AND that the per-agent `closePaneOnSessionEnd` setting is on (the
    /// core folds in both); the app closes the pane whenever the flag is true and
    /// checks no pref of its own. The app still owns yolo (reset on every end).
    case sessionEnded(sessionID: String, closePaneEligible: Bool)
}
