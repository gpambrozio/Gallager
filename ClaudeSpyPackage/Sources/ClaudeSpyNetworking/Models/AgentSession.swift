import Foundation

// MARK: - Agent Session

/// Tracks a coding-agent session running in a tmux pane. Agent-blind: the
/// `pluginID` tags which plugin owns the session; the working / attention bits
/// are plain `Bool`s set by the plugin runtime's `StatusSink` (spec §16 — the
/// former Claude-specific `ClaudeSession`, with its trailing-5 `HookEvent`
/// buffer and computed-from-events status dropped).
public struct AgentSession: Codable, Sendable, Equatable {
    /// The pane ID this session is associated with.
    public let paneId: String

    /// Id of the plugin that owns this session (e.g. "claude-code", "codex").
    public var pluginID: String

    /// Project path detected via process scanning at startup, or stamped from the
    /// ingress context before any project refresh tick.
    public var detectedProjectPath: String?

    /// Whether the agent is actively working (processing, not waiting for input).
    /// Set by the plugin `StatusSink`. `nil` working in a `PluginEvent` leaves
    /// this unchanged.
    public var isWorking: Bool

    /// Whether this session needs user attention (a permission prompt, idle reply,
    /// etc.). Set by the plugin `StatusSink`.
    public var needsAttention: Bool

    public init(
        paneId: String,
        pluginID: String = "claude-code",
        detectedProjectPath: String? = nil,
        isWorking: Bool = false,
        needsAttention: Bool = false
    ) {
        self.paneId = paneId
        self.pluginID = pluginID
        self.detectedProjectPath = detectedProjectPath
        self.isWorking = isWorking
        self.needsAttention = needsAttention
    }

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
        if needsAttention { return "Attention" }
        if isWorking { return "Working" }
        return "Idle"
    }

    /// Clears the attention flag (e.g. the user opened/handled the session).
    public mutating func markHandled() {
        needsAttention = false
    }

    /// Clears the attention flag unconditionally (e.g. yolo auto-approve).
    public mutating func markAutoApproved() {
        needsAttention = false
    }

    // MARK: - Codable

    /// Tolerant decode so a host running an older/newer version doesn't break the
    /// viewer over incidental field skew (spec §3 wire-compat rule).
    private enum CodingKeys: String, CodingKey {
        case paneId
        case pluginID
        case detectedProjectPath
        case isWorking
        case needsAttention
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.paneId = try container.decode(String.self, forKey: .paneId)
        self.pluginID = try container.decodeIfPresent(String.self, forKey: .pluginID) ?? "claude-code"
        self.detectedProjectPath = try container.decodeIfPresent(String.self, forKey: .detectedProjectPath)
        self.isWorking = try container.decodeIfPresent(Bool.self, forKey: .isWorking) ?? false
        self.needsAttention = try container.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false
    }
}
