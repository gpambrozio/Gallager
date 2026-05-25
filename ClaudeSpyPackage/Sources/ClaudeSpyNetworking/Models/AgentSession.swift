import Foundation

// MARK: - Agent Session

/// Tracks a single coding-agent session on a host.
///
/// Replaces the legacy `ClaudeSession`. Status (`working`, `attention`,
/// `lastEventTimestamp`) is no longer derived from a buffered `[HookEvent]` —
/// the agent's plugin sidecar pushes updates via `update_session_status`
/// callbacks routed through `PluginEventDispatcher`. Sessions are identified
/// by the agent's own session id (not the tmux pane id), so a pane can host
/// successive sessions over time without reusing the same identity.
public struct AgentSession: Codable, Sendable, Equatable, Identifiable {
    /// Session id reported by the agent (e.g. Claude Code's UUID `session_id`).
    public let id: String

    /// Plugin id that owns this session (matches `PluginPresentation.id`).
    /// Replaces the legacy `agent: CodingAgent` field.
    public let pluginID: String

    /// The tmux pane id the session is bound to, if any.
    public var tmuxPane: String?

    /// Project working-directory path, if known.
    public var projectPath: String?

    /// Whether the agent is currently processing (was `isWorking`).
    public var working: Bool

    /// Whether the session needs user attention (was `needsAttention`).
    public var attention: Bool

    /// Timestamp of the most recent status-bearing event for this session.
    /// Used for sorting "by recent activity" without keeping a buffer.
    public var lastEventTimestamp: Date?

    // 'events: [HookEvent]' field is DROPPED — status now comes from
    // update_session_status callbacks via PluginEventDispatcher.

    public init(
        id: String,
        pluginID: String,
        tmuxPane: String? = nil,
        projectPath: String? = nil,
        working: Bool = false,
        attention: Bool = false,
        lastEventTimestamp: Date? = nil
    ) {
        self.id = id
        self.pluginID = pluginID
        self.tmuxPane = tmuxPane
        self.projectPath = projectPath
        self.working = working
        self.attention = attention
        self.lastEventTimestamp = lastEventTimestamp
    }

    // MARK: - Display Helpers

    /// Project folder name extracted from `projectPath`, if set.
    public var projectFolderName: String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    /// Display name: project folder name when available, else the session id.
    public var displayName: String {
        projectFolderName ?? id
    }

    /// Human-readable status label used for accessibility and tests.
    public var statusLabel: String {
        if attention { return "Attention" }
        if working { return "Working" }
        return "Idle"
    }

    // MARK: - Mutating Helpers

    /// Marks the session as no longer needing attention.
    public mutating func markHandled() {
        attention = false
    }

    // MARK: - Codable

    /// Cross-host decode: accept the legacy `agent: CodingAgent` field if
    /// present (older peer), populate `pluginID` from its raw value. Encode
    /// always emits the modern `plugin_id` key.
    ///
    /// Per `feedback_no-backward-compat`, the `decodeIfPresent` fallback is the
    /// permanent safety net for cross-host version skew.
    private enum CodingKeys: String, CodingKey {
        case id
        case pluginID = "plugin_id"
        case tmuxPane = "tmux_pane"
        case projectPath = "project_path"
        case working
        case attention
        case lastEventTimestamp = "last_event_timestamp"
        case agent // legacy fallback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        if let pluginID = try container.decodeIfPresent(String.self, forKey: .pluginID) {
            self.pluginID = pluginID
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .agent) {
            // Older peer emitted the legacy `agent` raw value
            // (e.g. "claude-code" / "codex"). Those raw values are already
            // valid plugin ids — use verbatim.
            self.pluginID = legacy
        } else {
            // Pre-plugin-system peer with neither key — assume Claude Code,
            // the only agent older builds knew about.
            self.pluginID = "claude-code"
        }
        self.tmuxPane = try container.decodeIfPresent(String.self, forKey: .tmuxPane)
        self.projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
        self.working = try (container.decodeIfPresent(Bool.self, forKey: .working)) ?? false
        self.attention = try (container.decodeIfPresent(Bool.self, forKey: .attention)) ?? false
        self.lastEventTimestamp = try container.decodeIfPresent(Date.self, forKey: .lastEventTimestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(pluginID, forKey: .pluginID)
        try container.encodeIfPresent(tmuxPane, forKey: .tmuxPane)
        try container.encodeIfPresent(projectPath, forKey: .projectPath)
        try container.encode(working, forKey: .working)
        try container.encode(attention, forKey: .attention)
        try container.encodeIfPresent(lastEventTimestamp, forKey: .lastEventTimestamp)
    }
}
