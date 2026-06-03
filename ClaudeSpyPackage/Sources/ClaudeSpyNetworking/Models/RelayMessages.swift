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

// MARK: - Session State

/// Complete session state for sync between host and viewer
public struct SessionStateMessage: Codable, Sendable {
    public let pairId: String
    /// Unified per-pane state keyed by pane ID
    public let paneStates: [String: PaneState]
    /// Discovered agent projects on the host (each tagged by `pluginID`).
    /// Carries the merged per-plugin project lists pushed via `host.setProjects`
    /// (spec §7.2 — the project list rides this existing message).
    public let agentProjects: [AgentProject]?
    /// The host's home directory path (e.g., "/Users/gustavo" or "/home/gustavo")
    public let homeDirectory: String
    /// Every response form currently open on the host, so a viewer that connects
    /// (or reconnects) *after* a form opened still renders it. The live
    /// `agent_response_request` push only reaches viewers connected at the
    /// instant it fired; the snapshot makes open forms part of catch-up state
    /// (the same role `paneStates` plays for attention). `nil` from an older
    /// host that doesn't send the field — viewers then leave their open forms to
    /// the live channel; an empty array is authoritative ("no forms open").
    public let openResponseRequests: [PaneOpenResponseRequest]?

    public init(
        pairId: String,
        paneStates: [String: PaneState],
        agentProjects: [AgentProject]? = nil,
        homeDirectory: String = "",
        openResponseRequests: [PaneOpenResponseRequest]? = nil
    ) {
        self.pairId = pairId
        self.paneStates = paneStates
        self.agentProjects = agentProjects
        self.homeDirectory = homeDirectory
        self.openResponseRequests = openResponseRequests
    }

    /// Returns a copy with the `pairId` replaced. Centralises the per-connection
    /// rebuild so adding a new field can only forget to forward it in one place
    /// (here) — call sites can't silently drop fields by reconstructing the
    /// initialiser from memory.
    public func withPairId(_ pairId: String) -> SessionStateMessage {
        SessionStateMessage(
            pairId: pairId,
            paneStates: paneStates,
            agentProjects: agentProjects,
            homeDirectory: homeDirectory,
            openResponseRequests: openResponseRequests
        )
    }
}

/// One open response form carried in a `SessionStateMessage` snapshot. Mirrors
/// the per-pane form the host retains; iOS full-replaces its open forms for the
/// host from this list. Like `AgentResponseRequestMessage` but without the
/// per-connection `pairId` (the snapshot stamps it) and with a non-optional
/// `request` (only *open* forms are listed — a retract is simply absence).
public struct PaneOpenResponseRequest: Codable, Sendable, Equatable {
    /// The pane id the form targets (iOS keys open forms by pane).
    public let sessionId: String
    public let pluginId: String
    public let requestId: String
    public let request: AgentResponseRequest

    public init(sessionId: String, pluginId: String, requestId: String, request: AgentResponseRequest) {
        self.sessionId = sessionId
        self.pluginId = pluginId
        self.requestId = requestId
        self.request = request
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

    // MARK: - Agent Session

    /// The coding-agent session running in this pane, if any
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
