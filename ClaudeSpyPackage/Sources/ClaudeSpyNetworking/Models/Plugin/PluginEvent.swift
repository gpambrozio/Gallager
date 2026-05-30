import Foundation

// MARK: - PluginEvent

/// The single carrier for everything a plugin wants to change about app state.
/// There is no second mechanism. A core returns one from `handleIngress` or
/// pushes one via `host.emit`; a single dispatcher fans its fields out to the
/// session-status, notification, response-request, and app-action sinks (spec §5).
public struct PluginEvent: Codable, Sendable, Equatable {
    public let pluginID: String
    public let sessionID: String

    /// Drives `AgentSession.isWorking`. `nil` means "no opinion, leave state
    /// alone" (the event neither enters nor leaves the agent loop).
    public let working: Bool?

    /// Drives `AgentSession.needsAttention` for this event.
    public let attention: Bool

    /// A pre-baked Mac notification + iOS push (strings formatted by the core).
    public let notification: NotificationSpec?

    /// Opens / retracts an iOS response form (see `ResponseRequestPayload`).
    public let responseRequest: ResponseRequestPayload?

    /// Discrete agent-blind Mac-side triggers (markdown suggestion, pane close…).
    public let appActions: [AppAction]

    /// Bootstraps the `AgentSession`↔pane mapping (from the ingress context).
    public let tmuxPane: String?

    /// Lets the app render the project name before any tmux refresh tick.
    public let projectPath: String?

    public init(
        pluginID: String,
        sessionID: String,
        working: Bool? = nil,
        attention: Bool = false,
        notification: NotificationSpec? = nil,
        responseRequest: ResponseRequestPayload? = nil,
        appActions: [AppAction] = [],
        tmuxPane: String? = nil,
        projectPath: String? = nil
    ) {
        self.pluginID = pluginID
        self.sessionID = sessionID
        self.working = working
        self.attention = attention
        self.notification = notification
        self.responseRequest = responseRequest
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

// MARK: - ResponseRequestPayload

/// Open or retract an iOS response form for a `requestID`. The `request` is
/// optional: non-`nil` opens the form, `nil` retracts it (the agent advanced on
/// its own, or the user answered Mac-side first). This keeps retraction on the
/// single envelope — there is no separate dismiss callback (spec §5).
public struct ResponseRequestPayload: Codable, Sendable, Equatable {
    public let requestID: String
    public let request: AgentResponseRequest?

    public init(requestID: String, request: AgentResponseRequest?) {
        self.requestID = requestID
        self.request = request
    }
}

// MARK: - AppAction

/// The closed, agent-blind vocabulary of Mac-side feature triggers a plugin can
/// fire (spec §6). The app owns the behavior; the core only states intent.
public enum AppAction: Codable, Sendable, Equatable {
    /// The core saw a write to a `.md`/`.markdown` path; surface an "open this
    /// file?" prompt.
    case openFileSuggestion(sessionID: String, path: String, displayName: String, isPlan: Bool)

    /// Clear outstanding file suggestions (e.g. on prompt submit).
    case dismissFileSuggestions(sessionID: String)

    /// The core signals a session end (any reason). The app resets the pane's
    /// session-scoped state — e.g. yolo mode, so a fresh session doesn't inherit
    /// it — and, when `closePaneEligible` is true (the agent exited cleanly at the
    /// prompt), closes the pane **iff** the user's `closePaneOnSessionEnd`
    /// preference is on. The core states intent; the app owns yolo and the pref.
    case sessionEnded(sessionID: String, closePaneEligible: Bool)
}
