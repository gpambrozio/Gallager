import Foundation

// MARK: - Agent Session

/// Tracks a coding-agent session running in a tmux pane. Agent-blind: the
/// `pluginID` tags which plugin owns the session; the session's `state` is a
/// single `AgentState` (spec §3) set by the plugin runtime's state sink. The
/// `isWorking` / `needsAttention` Bools are derived from it, so the many read
/// sites are unaffected by the inversion.
public struct AgentSession: Codable, Sendable, Equatable {
    /// The pane ID this session is associated with.
    public let paneId: String

    /// Id of the plugin that owns this session (e.g. "claude-code", "codex").
    public var pluginID: String

    /// Project path detected via process scanning at startup, or stamped from the
    /// ingress context before any project refresh tick.
    public var detectedProjectPath: String?

    /// The session's current state — the single source of truth (spec §3). The
    /// cores set lifecycle/form states; the system owns the `→ idle` transition
    /// (`markHandled`). The open response form, when any, rides the `awaiting*`
    /// cases, so it travels in the snapshot/status messages automatically.
    public var state: AgentState

    public init(
        paneId: String,
        pluginID: String = "claude-code",
        detectedProjectPath: String? = nil,
        state: AgentState = .idle
    ) {
        self.paneId = paneId
        self.pluginID = pluginID
        self.detectedProjectPath = detectedProjectPath
        self.state = state
    }

    /// Derived for the many UI/sort read sites that still ask these questions.
    public var isWorking: Bool { state.isActiveWorking }
    public var needsAttention: Bool { state.needsAttention }

    /// The project folder name from the detected project path (last component),
    /// e.g. "ClaudeSpy" from "/Users/user/Dev/ClaudeSpy".
    public var projectFolderName: String? {
        guard let detectedProjectPath, !detectedProjectPath.isEmpty else { return nil }
        return URL(fileURLWithPath: detectedProjectPath).lastPathComponent
    }

    /// Display name for the session: project folder name if available, else pane ID.
    public var displayName: String {
        projectFolderName ?? paneId
    }

    /// Human-readable status label for accessibility and testing.
    public var statusLabel: String {
        switch state {
        case .working: return "Working"
        case .awaitingPlanApproval: return "Plan approval"
        case .awaitingPermission: return "Permission"
        case .awaitingReplies: return "Questions"
        case .doneWorking: return "Done"
        case .idle: return "Idle"
        }
    }

    /// The user viewed/handled the session. Only a finished session goes idle; a
    /// session awaiting an explicit answer stays put (the code never transitions
    /// an `awaiting*` state here). This replaces the former `panesWithBlockingForm`
    /// guard entirely (spec §"Ownership of transitions").
    public mutating func markHandled() {
        if case .doneWorking = state { state = .idle }
    }

    // MARK: - Codable

    /// Tolerant decode so a host running an older/newer version doesn't break the
    /// viewer over incidental field skew (spec §3 wire-compat rule).
    private enum CodingKeys: String, CodingKey {
        case paneId
        case pluginID
        case detectedProjectPath
        case state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.paneId = try container.decode(String.self, forKey: .paneId)
        self.pluginID = try container.decodeIfPresent(String.self, forKey: .pluginID) ?? "claude-code"
        self.detectedProjectPath = try container.decodeIfPresent(String.self, forKey: .detectedProjectPath)
        self.state = try container.decodeIfPresent(AgentState.self, forKey: .state) ?? .idle
    }
}
