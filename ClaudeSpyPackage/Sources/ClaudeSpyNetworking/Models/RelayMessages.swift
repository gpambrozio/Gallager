import Foundation

// MARK: - Peer Handshake

/// First encrypted message each peer sends to its partner after E2EE is
/// established. Carries version info used for compatibility gating without
/// involving the relay server.
public struct PeerHelloMessage: Codable, Sendable {
    /// Marketing version of the sending peer (e.g. "1.23").
    public let appVersion: String

    /// Minimum partner version the sending peer is willing to talk to.
    public let minRequiredPartnerVersion: String

    public init(appVersion: String, minRequiredPartnerVersion: String) {
        self.appVersion = appVersion
        self.minRequiredPartnerVersion = minRequiredPartnerVersion
    }
}

// MARK: - Hook Event Relay

/// A hook event wrapped for relay through the external server
public struct HookEventMessage: Codable, Sendable {
    public let pairId: String
    public let event: HookEvent

    public init(pairId: String, event: HookEvent) {
        self.pairId = pairId
        self.event = event
    }

    /// Project name extracted from the event's project path
    public var projectName: String? {
        guard let projectPath = event.projectPath, !projectPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }
}

// MARK: - Session State

/// Complete session state for sync between host and viewer
public struct SessionStateMessage: Codable, Sendable {
    public let pairId: String
    /// Unified per-pane state keyed by pane ID
    public let paneStates: [String: PaneState]
    /// Discovered coding-agent projects on the host
    public let claudeProjects: [AgentProject]?
    /// The host's home directory path (e.g., "/Users/gustavo" or "/home/gustavo")
    public let homeDirectory: String

    public init(
        pairId: String,
        paneStates: [String: PaneState],
        claudeProjects: [AgentProject]? = nil,
        homeDirectory: String = ""
    ) {
        self.pairId = pairId
        self.paneStates = paneStates
        self.claudeProjects = claudeProjects
        self.homeDirectory = homeDirectory
    }

    /// Returns a copy with the `pairId` replaced. Centralises the per-connection
    /// rebuild so adding a new field can only forget to forward it in one place
    /// (here) — call sites can't silently drop fields by reconstructing the
    /// initialiser from memory.
    public func withPairId(_ pairId: String) -> SessionStateMessage {
        SessionStateMessage(
            pairId: pairId,
            paneStates: paneStates,
            claudeProjects: claudeProjects,
            homeDirectory: homeDirectory
        )
    }
}

// MARK: - Pane State

/// Unified per-pane state combining tmux metadata, Claude session info, and runtime flags.
/// Used both locally on macOS and over the wire for iOS viewer sync.
public struct PaneState: Codable, Sendable, Identifiable {
    // MARK: - Tmux Pane Identity & Metadata

    /// The tmux pane ID (e.g., "%0", "%5")
    public let paneId: String

    /// The full target string (e.g., "mysession:0.1")
    public var target: String

    /// The session name containing this pane
    public var sessionName: String

    /// The window index within the session
    public var windowIndex: Int

    /// The pane index within the window
    public var paneIndex: Int

    /// The command currently running in the pane
    public var command: String?

    /// The current working directory of the pane
    public var currentPath: String?

    /// Width of the pane in columns
    public var width: Int

    /// Height of the pane in rows
    public var height: Int

    /// Whether this pane is the active pane in its window
    public var isActive: Bool

    /// The tmux window layout string for this pane's window
    public var windowLayout: String

    /// The tmux window name for this pane's window
    public var windowName: String

    /// Whether this pane's window is the active window in its session
    public var isWindowActive: Bool

    // MARK: - Custom Description

    /// User-defined description for this window, shown prominently in the sidebar
    public var customDescription: String?

    // MARK: - Custom Color

    /// User-assigned color for this session, shown as a dot in the sidebar.
    /// Persisted via the tmux `@gallager-color` user option.
    public var customColor: SessionColor?

    // MARK: - Custom Emoji

    /// User-assigned emoji for this session, shown as a small icon in the
    /// sidebar. Free-form text so any platform-supported emoji works.
    /// Persisted via the tmux `@gallager-emoji` user option.
    public var customEmoji: String?

    // MARK: - Terminal State

    /// Terminal title detected via OSC escape sequences
    public var terminalTitle: String?

    // MARK: - Git State

    /// The git branch name for this pane's current working directory, if it's a git repo
    public var gitBranch: String?

    // MARK: - Claude Session

    /// The Claude Code session running in this pane, if any
    public var agentSession: AgentSession?

    // MARK: - Behavior Flags

    /// Whether yolo mode is enabled (auto-approve permissions)
    public var yoloMode: Bool

    // MARK: - CLI Session State Override

    /// Pane state set via the gallager CLI's `session-state` command.
    /// Overrides the indicator shown in the sidebar until cleared, either
    /// explicitly or by a hook event that updates the underlying session.
    public var cliSessionState: CLISessionState?

    // MARK: - Editor Session

    /// Active prompt editor session (Ctrl-G), if any
    public var editorSession: EditorSessionInfo?

    // MARK: - Progress

    /// Latest `OSC 9;4` progress emitted by this pane, if any. Drives the
    /// session-row progress bar on the host's local sidebar and on remote
    /// viewers (iOS, Mac-as-viewer). `nil` means no active progress.
    public var progress: TerminalProgressState?

    // MARK: - Computed Properties

    public var id: String {
        paneId
    }

    /// Window identifier combining session name and window index (e.g., "mysession:0")
    public var windowId: String {
        "\(sessionName):\(windowIndex)"
    }

    public init(
        paneId: String,
        target: String = "",
        sessionName: String = "",
        windowIndex: Int = 0,
        paneIndex: Int = 0,
        command: String? = nil,
        currentPath: String? = nil,
        width: Int = 80,
        height: Int = 24,
        isActive: Bool = false,
        windowLayout: String = "",
        windowName: String = "",
        isWindowActive: Bool = false,
        customDescription: String? = nil,
        customColor: SessionColor? = nil,
        customEmoji: String? = nil,
        terminalTitle: String? = nil,
        gitBranch: String? = nil,
        agentSession: AgentSession? = nil,
        yoloMode: Bool = false,
        cliSessionState: CLISessionState? = nil,
        editorSession: EditorSessionInfo? = nil,
        progress: TerminalProgressState? = nil
    ) {
        self.paneId = paneId
        self.target = target
        self.sessionName = sessionName
        self.windowIndex = windowIndex
        self.paneIndex = paneIndex
        self.command = command
        self.currentPath = currentPath
        self.width = width
        self.height = height
        self.isActive = isActive
        self.windowLayout = windowLayout
        self.windowName = windowName
        self.isWindowActive = isWindowActive
        self.customDescription = customDescription
        self.customColor = customColor
        self.customEmoji = customEmoji
        self.terminalTitle = terminalTitle
        self.gitBranch = gitBranch
        self.agentSession = agentSession
        self.yoloMode = yoloMode
        self.cliSessionState = cliSessionState
        self.editorSession = editorSession
        self.progress = progress
    }
}

// MARK: - Editor Session

/// Information about an active prompt editor session for relay to viewers.
/// Included in PaneState when a Ctrl-G editor session is active.
public struct EditorSessionInfo: Codable, Sendable {
    /// Unique identifier for this editor session
    public let sessionId: UUID
    /// The content of the file being edited
    public let content: String

    public init(sessionId: UUID, content: String) {
        self.sessionId = sessionId
        self.content = content
    }
}

// MARK: - Push Notification Token

/// Message from viewer to register a push notification token
public struct RegisterPushTokenMessage: Codable, Sendable {
    /// The APNs device token as a hex string
    public let deviceToken: String

    public init(deviceToken: String) {
        self.deviceToken = deviceToken
    }
}

/// Server response to push token registration
public struct PushTokenRegisteredMessage: Codable, Sendable {
    public let success: Bool
    public let error: String?

    public init(success: Bool, error: String? = nil) {
        self.success = success
        self.error = error
    }
}

// MARK: - Agent Projects

/// Information about a discovered coding-agent project (Claude Code, Codex,
/// or any third-party plugin's project type).
///
/// `pluginID` identifies which plugin discovered the project — the Mac app
/// routes per-project actions (open in editor, start session, etc.) back
/// to the owning plugin by that id. Values match the plugin manifest's
/// `id` field: e.g. `"claude-code"`, `"codex"`.
public struct AgentProject: Codable, Sendable, Identifiable, Hashable {
    /// Unique identifier (plugin + path; two plugins can share a working directory).
    public var id: String {
        "\(pluginID):\(path)"
    }

    /// Project name (last component of path)
    public let name: String

    /// Full path to project directory
    public let path: String

    /// Timestamp of last activity in this project (for sorting by recency)
    public let lastUsed: Date?

    /// Custom `CLAUDE_CONFIG_DIR` for this project, if the project was discovered
    /// in a non-default `.claude` folder. `nil` when the project lives in the
    /// default `~/.claude` location. Always `nil` for non-Claude plugins.
    public let claudeConfigDir: String?

    /// Which plugin owns this project. Matches the plugin manifest's `id`.
    public let pluginID: String

    public init(
        name: String,
        path: String,
        lastUsed: Date? = nil,
        claudeConfigDir: String? = nil,
        pluginID: String = "claude-code"
    ) {
        self.name = name
        self.path = path
        self.lastUsed = lastUsed
        self.claudeConfigDir = claudeConfigDir
        self.pluginID = pluginID
    }

    // MARK: - Codable

    // Custom decoder supports two on-the-wire shapes for cross-host
    // compatibility (see `feedback_no-backward-compat`):
    //
    // - Modern: `plugin_id` is a string matching a plugin manifest id.
    // - Legacy: `agent` is a `CodingAgent` raw value (`"claude-code"` or
    //   `"codex"`). Hosts running pre-plugin-system builds emit this shape.
    //
    // Encoding always emits the modern `plugin_id` key so newer peers see
    // the canonical wire format.
    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case lastUsed
        case claudeConfigDir
        case pluginID = "plugin_id"
        case agent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.path = try container.decode(String.self, forKey: .path)
        self.lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        self.claudeConfigDir = try container.decodeIfPresent(String.self, forKey: .claudeConfigDir)
        if let id = try container.decodeIfPresent(String.self, forKey: .pluginID) {
            self.pluginID = id
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .agent) {
            // Cross-host fallback: a peer on the pre-plugin-system build
            // sent an `agent` raw value (e.g. "claude-code" / "codex").
            // Use it verbatim — those raw values are already the plugin ids.
            self.pluginID = legacy
        } else {
            // Safest default for a project from an older peer that didn't
            // emit either key: it's a Claude Code project. Pre-plugin
            // builds only knew about Claude Code.
            self.pluginID = "claude-code"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(lastUsed, forKey: .lastUsed)
        try container.encodeIfPresent(claudeConfigDir, forKey: .claudeConfigDir)
        try container.encode(pluginID, forKey: .pluginID)
    }
}

public extension Sequence where Element == AgentProject {
    /// Sorts projects newest-first by `lastUsed`. Projects without a
    /// timestamp fall to the bottom in name order. Centralising this so the
    /// scanner, the project-list API, and the relay session-state response
    /// can't drift.
    func sortedByLastUsed() -> [AgentProject] {
        sorted { lhs, rhs in
            switch (lhs.lastUsed, rhs.lastUsed) {
            case let (lhsDate?, rhsDate?):
                lhsDate > rhsDate
            case (nil, .some):
                false
            case (.some, nil):
                true
            case (nil, nil):
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }
}

// MARK: - Viewer Connection Notifications

/// Message sent when a paired viewer connects, includes public key for E2EE session establishment
public struct ViewerConnectedMessage: Codable, Sendable {
    /// Base64-encoded public key of the connecting viewer
    public let publicKey: String

    /// Unique identifier for the public key
    public let publicKeyId: String

    /// Device name the partner is reporting (viewer name when sent to host,
    /// host name when sent to viewer). `nil` when the partner hasn't been seen
    /// before or when the relay is using the legacy notification path that
    /// doesn't carry a name. Lets either side update the stored device name
    /// without waiting for a full re-pair.
    public let deviceName: String?

    public init(publicKey: String, publicKeyId: String, deviceName: String? = nil) {
        self.publicKey = publicKey
        self.publicKeyId = publicKeyId
        self.deviceName = deviceName
    }
}
