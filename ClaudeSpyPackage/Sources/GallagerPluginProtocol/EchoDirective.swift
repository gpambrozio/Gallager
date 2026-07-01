import ClaudeSpyNetworking
import Foundation

/// JSON directive an `EchoPluginCore` ingress frame payload carries: the
/// `PluginEvent` fields a test wants produced.
///
/// Lives outside `#if DEBUG` so the Release-built `EchoPluginSidecar` executable
/// can import it directly from `GallagerPluginProtocol`.
public struct EchoDirective: Codable, Sendable, Equatable {
    public let sessionID: String
    /// The session state the produced `PluginEvent` carries (`nil` = no opinion).
    public let state: AgentState?
    public let notification: NotificationSpec?
    public let appActions: [AppAction]?
    public let tmuxPane: String?
    public let projectPath: String?
    /// Test-only artificial processing delay (ms) applied in `handleIngress`.
    public let delayMs: Int?
    /// If `true`, the sidecar calls `abort()` — used to test crash-loop detection.
    public let abort: Bool?

    public init(
        sessionID: String,
        state: AgentState? = nil,
        notification: NotificationSpec? = nil,
        appActions: [AppAction]? = nil,
        tmuxPane: String? = nil,
        projectPath: String? = nil,
        delayMs: Int? = nil,
        abort: Bool? = nil
    ) {
        self.sessionID = sessionID
        self.state = state
        self.notification = notification
        self.appActions = appActions
        self.tmuxPane = tmuxPane
        self.projectPath = projectPath
        self.delayMs = delayMs
        self.abort = abort
    }
}
