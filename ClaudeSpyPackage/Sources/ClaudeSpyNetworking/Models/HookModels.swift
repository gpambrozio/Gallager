import Foundation

// MARK: - Date Parsing

/// Private date formatter for parsing ISO8601 timestamps
private enum ISO8601Parser {
    /// ISO8601 formatter for parsing timestamps like "2026-01-03T19:00:56.425838"
    /// Note: nonisolated(unsafe) is safe here because we never mutate the formatter after creation
    nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        return formatter.date(from: string)
    }
}

// MARK: - Claude Session

/// Tracks a Claude Code session and its recent hook events
public struct ClaudeSession: Codable, Sendable {
    /// Maximum number of events to retain per session
    private static let maxEvents = 5

    /// The pane ID this session is associated with
    public let paneId: String

    /// Recent hook events, newest first, limited to last 5
    public private(set) var events: [HookEvent] = []

    /// The most recent event (including events not sent to the server).
    public private(set) var latestEvent: HookEvent?

    /// The event ID up to which the user has handled/seen this session.
    /// When this matches the latest event's ID, `needsAttention` returns false.
    public private(set) var handledUpToEventId: UUID?

    /// Project path detected via process scanning at startup (before any hook events arrive).
    public var detectedProjectPath: String?

    public init(paneId: String, detectedProjectPath: String? = nil) {
        self.paneId = paneId
        self.detectedProjectPath = detectedProjectPath
    }

    /// Adds an event to the session, keeping only the last 5
    public mutating func addEvent(_ event: HookEvent) {
        // Only update latestEvent for events that carry meaningful state:
        // either they affect working status or would trigger a notification.
        // Background events (e.g., notification with "permission_prompt" type)
        // should not override a significant event like permissionRequest.
        if event.isWorking != nil || event.wouldTriggerNotification {
            latestEvent = event
        }
        if let working = event.isWorking {
            isWorking = working
        }
        guard event.action.body.shouldSendToServer else { return }
        events.insert(event, at: 0)
        if events.count > Self.maxEvents {
            events.removeLast()
        }
    }

    /// The project folder name extracted from the first event that has a projectPath,
    /// falling back to the detected project path from process scanning at startup.
    /// Returns the last path component (e.g., "ClaudeSpy" from "/Users/user/Dev/ClaudeSpy").
    public var projectFolderName: String? {
        for event in events {
            if let projectPath = event.projectPath, !projectPath.isEmpty {
                return URL(fileURLWithPath: projectPath).lastPathComponent
            }
        }
        if let detectedProjectPath, !detectedProjectPath.isEmpty {
            return URL(fileURLWithPath: detectedProjectPath).lastPathComponent
        }
        return nil
    }

    /// Display name for the session: project folder name if available, otherwise pane ID.
    public var displayName: String {
        projectFolderName ?? paneId
    }

    /// Whether this session needs user attention.
    /// This is true when the latest event would trigger a notification (e.g., permission request, session idle)
    /// AND the user hasn't already handled/seen this event.
    public var needsAttention: Bool {
        guard let latest = latestEvent, latest.wouldTriggerNotification else { return false }
        return latest.id != handledUpToEventId
    }

    /// Whether the session is actively working (Claude is processing, not waiting for input).
    /// Updated when events with a definitive working state are received.
    public private(set) var isWorking = false

    /// Human-readable status label for accessibility and testing.
    public var statusLabel: String {
        if needsAttention { return "Attention" }
        if isWorking { return "Working" }
        return "Idle"
    }

    /// Marks the current latest event as handled, clearing the `needsAttention` flag.
    /// Clears for most notification-triggering events. Permission requests require explicit
    /// user action (approve/deny) and should not be auto-dismissed by viewing the session.
    public mutating func markHandled() {
        guard let latest = latestEvent else { return }
        switch latest.action {
        case .sessionStart,
             .stop,
             .notification,
             .stopFailure,
             .elicitation:
            handledUpToEventId = latest.id
        case .sessionEnd,
             .preToolUse,
             .postToolUse,
             .postToolUseFailure,
             .permissionRequest,
             .permissionDenied,
             .userPromptSubmit,
             .subagentStart,
             .subagentStop,
             .teammateIdle,
             .taskCreated,
             .taskCompleted,
             .preCompact,
             .postCompact,
             .instructionsLoaded,
             .configChange,
             .cwdChanged,
             .fileChanged,
             .elicitationResult,
             .worktreeCreate,
             .worktreeRemove,
             .unknown:
            break
        }
    }
}

// MARK: - Hook Event

/// Represents a received hook event with metadata
public struct HookEvent: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let action: HookAction
    public let projectPath: String?
    public let tmuxPane: String?

    public init(
        action: HookAction,
        projectPath: String?,
        tmuxPane: String?
    ) {
        self.id = UUID()
        // Use timestamp from action if available, otherwise fall back to current time
        self.timestamp = action.timestamp ?? Date()
        self.action = action
        self.projectPath = projectPath
        self.tmuxPane = tmuxPane
    }

    /// Whether this event indicates the session is actively working.
    /// Returns `true` for events that enter the agent loop,
    /// `false` for events that leave it, and `nil` otherwise.
    public var isWorking: Bool? {
        switch action {
        case .userPromptSubmit,
             .preToolUse,
             .permissionRequest,
             .permissionDenied,
             .postToolUse,
             .postToolUseFailure,
             .subagentStart,
             .subagentStop,
             .taskCreated,
             .taskCompleted:
            return true
        case .stop,
             .stopFailure:
            return false
        case .sessionStart,
             .sessionEnd,
             .notification,
             .teammateIdle,
             .preCompact,
             .postCompact,
             .instructionsLoaded,
             .configChange,
             .cwdChanged,
             .fileChanged,
             .elicitation,
             .elicitationResult,
             .worktreeCreate,
             .worktreeRemove,
             .unknown:
            return nil
        }
    }

    public static func == (lhs: HookEvent, rhs: HookEvent) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Hook Body Protocol

public protocol HookBodyProtocol: Codable, Sendable {
    var sessionId: String { get }
    var hookEventName: String { get }
    var timestamp: String? { get }
    var shouldSendToServer: Bool { get }
}

// MARK: - Common Hook Fields

/// Fields common to all hook payloads from Claude Code
public struct CommonHookFields: HookBodyProtocol {
    public static let permissionRequestEventName = "PermissionRequest"

    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let agentId: String?
    public let agentType: String?
    public var shouldSendToServer: Bool { true }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case agentId = "agent_id"
        case agentType = "agent_type"
    }
}

// MARK: - Hook Body Types

public struct SessionStartBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let source: String?
    public var shouldSendToServer: Bool { true }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case source
    }

    public init(
        sessionId: String,
        transcriptPath: String? = nil,
        cwd: String? = nil,
        hookEventName: String,
        timestamp: String? = nil,
        source: String? = nil
    ) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.timestamp = timestamp
        self.source = source
    }
}

public struct PreToolUseBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let toolName: String?
    public let toolInput: ClaudeCodeTool?
    public var shouldSendToServer: Bool { true }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case toolName = "tool_name"
        case toolInput = "tool_input"
    }

    public init(
        sessionId: String,
        transcriptPath: String? = nil,
        cwd: String? = nil,
        hookEventName: String,
        timestamp: String? = nil,
        toolName: String? = nil,
        toolInput: ClaudeCodeTool? = nil
    ) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.timestamp = timestamp
        self.toolName = toolName
        self.toolInput = toolInput
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.hookEventName = try container.decode(String.self, forKey: .hookEventName)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        self.toolName = try container.decodeIfPresent(String.self, forKey: .toolName)

        // Decode tool_input based on tool_name
        if container.contains(.toolInput) {
            self.toolInput = try ClaudeCodeTool.decode(
                from: container.superDecoder(forKey: .toolInput),
                toolName: toolName
            )
        } else {
            self.toolInput = nil
        }
    }
}

public enum SessionEndReason: String, Codable, Sendable {
    case clear
    case resume
    case logout
    case promptInputExit = "prompt_input_exit"
    case bypassPermissionsDisabled = "bypass_permissions_disabled"
    case other

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = SessionEndReason(rawValue: rawValue) ?? .other
    }
}

public struct SessionEndBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let reason: SessionEndReason?
    public var shouldSendToServer: Bool { true }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case reason
    }

    public init(
        sessionId: String,
        transcriptPath: String? = nil,
        cwd: String? = nil,
        hookEventName: String,
        timestamp: String? = nil,
        reason: SessionEndReason? = nil
    ) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.timestamp = timestamp
        self.reason = reason
    }
}

public struct PermissionRequestBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let permissionMode: String?
    public let toolName: String?
    public let toolInput: ClaudeCodeTool?
    public let permissionSuggestions: [PermissionSuggestion]?
    public let timestamp: String?
    public var shouldSendToServer: Bool { true }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case permissionMode = "permission_mode"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case permissionSuggestions = "permission_suggestions"
        case timestamp
    }

    public init(
        sessionId: String,
        transcriptPath: String? = nil,
        cwd: String? = nil,
        hookEventName: String,
        permissionMode: String? = nil,
        toolName: String? = nil,
        toolInput: ClaudeCodeTool? = nil,
        permissionSuggestions: [PermissionSuggestion]? = nil,
        timestamp: String? = nil
    ) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.permissionMode = permissionMode
        self.toolName = toolName
        self.toolInput = toolInput
        self.permissionSuggestions = permissionSuggestions
        self.timestamp = timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.hookEventName = try container.decode(String.self, forKey: .hookEventName)
        self.permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        self.toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        self.permissionSuggestions = try container.decodeIfPresent([PermissionSuggestion].self, forKey: .permissionSuggestions)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)

        if container.contains(.toolInput) {
            self.toolInput = try ClaudeCodeTool.decode(
                from: container.superDecoder(forKey: .toolInput),
                toolName: toolName
            )
        } else {
            self.toolInput = nil
        }
    }
}

public struct PermissionDeniedBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let toolName: String?
    public let toolInput: ClaudeCodeTool?
    public let reason: String
    public var shouldSendToServer: Bool { true }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case reason
    }

    public init(
        sessionId: String,
        transcriptPath: String? = nil,
        cwd: String? = nil,
        hookEventName: String,
        timestamp: String? = nil,
        toolName: String? = nil,
        toolInput: ClaudeCodeTool? = nil,
        reason: String
    ) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.timestamp = timestamp
        self.toolName = toolName
        self.toolInput = toolInput
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.hookEventName = try container.decode(String.self, forKey: .hookEventName)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        self.toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        self.reason = try container.decode(String.self, forKey: .reason)

        if container.contains(.toolInput) {
            self.toolInput = try ClaudeCodeTool.decode(
                from: container.superDecoder(forKey: .toolInput),
                toolName: toolName
            )
        } else {
            self.toolInput = nil
        }
    }
}

public struct PostToolUseBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let toolName: String?
    public let toolInput: ClaudeCodeTool?
    public let toolResponse: AnyCodable?
    public let toolUseId: String?
    public var shouldSendToServer: Bool { true }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolResponse = "tool_response"
        case toolUseId = "tool_use_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.hookEventName = try container.decode(String.self, forKey: .hookEventName)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        self.toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        self.toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
        self.toolResponse = try container.decodeIfPresent(AnyCodable.self, forKey: .toolResponse)

        if container.contains(.toolInput) {
            self.toolInput = try ClaudeCodeTool.decode(
                from: container.superDecoder(forKey: .toolInput),
                toolName: toolName
            )
        } else {
            self.toolInput = nil
        }
    }
}

public struct NotificationBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let message: String?
    public let notificationType: String?
    public var shouldSendToServer: Bool {
        notificationType != "permission_prompt" && notificationType != "idle_prompt"
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case message
        case notificationType = "notification_type"
    }
}

public struct UserPromptSubmitBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let prompt: String?
    public var shouldSendToServer: Bool { true }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case prompt
    }
}

public struct StopBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let stopHookActive: Bool?
    public let lastAssistantMessage: String?
    public var shouldSendToServer: Bool { true }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case stopHookActive = "stop_hook_active"
        case lastAssistantMessage = "last_assistant_message"
    }

    public init(
        sessionId: String,
        transcriptPath: String? = nil,
        cwd: String? = nil,
        hookEventName: String,
        timestamp: String? = nil,
        stopHookActive: Bool? = nil,
        lastAssistantMessage: String? = nil
    ) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.timestamp = timestamp
        self.stopHookActive = stopHookActive
        self.lastAssistantMessage = lastAssistantMessage
    }
}

public struct SubagentStopBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let stopHookActive: Bool?
    public var shouldSendToServer: Bool { false }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case stopHookActive = "stop_hook_active"
    }
}

public struct PostToolUseFailureBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let toolName: String?
    public let toolInput: ClaudeCodeTool?
    public let toolUseId: String?
    public let error: String?
    public let isInterrupt: Bool?
    public var shouldSendToServer: Bool { false }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case error
        case isInterrupt = "is_interrupt"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.hookEventName = try container.decode(String.self, forKey: .hookEventName)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        self.toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        self.toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.isInterrupt = try container.decodeIfPresent(Bool.self, forKey: .isInterrupt)

        if container.contains(.toolInput) {
            self.toolInput = try ClaudeCodeTool.decode(
                from: container.superDecoder(forKey: .toolInput),
                toolName: toolName
            )
        } else {
            self.toolInput = nil
        }
    }
}

public struct SubagentStartBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let agentId: String?
    public let agentType: String?
    public var shouldSendToServer: Bool { false }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case agentId = "agent_id"
        case agentType = "agent_type"
    }
}

public struct TeammateIdleBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let teammateName: String?
    public let teamName: String?
    public var shouldSendToServer: Bool { true }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case teammateName = "teammate_name"
        case teamName = "team_name"
    }
}

public struct TaskCompletedBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let taskId: String?
    public let taskSubject: String?
    public let taskDescription: String?
    public let teammateName: String?
    public let teamName: String?
    public var shouldSendToServer: Bool { true }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case taskId = "task_id"
        case taskSubject = "task_subject"
        case taskDescription = "task_description"
        case teammateName = "teammate_name"
        case teamName = "team_name"
    }
}

public struct PreCompactBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let trigger: String?
    public let customInstructions: String?
    public var shouldSendToServer: Bool { false }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case trigger
        case customInstructions = "custom_instructions"
    }
}

public struct PostCompactBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let trigger: String?
    public var shouldSendToServer: Bool { false }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case trigger
    }
}

public struct InstructionsLoadedBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let source: String?
    public var shouldSendToServer: Bool { false }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case source
    }
}

public struct StopFailureBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let errorType: String?
    public var shouldSendToServer: Bool { true }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case errorType = "error_type"
    }
}

public struct ConfigChangeBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let configType: String?
    public var shouldSendToServer: Bool { false }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case configType = "config_type"
    }
}

public struct CwdChangedBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let oldCwd: String?
    public let newCwd: String?
    public var shouldSendToServer: Bool { false }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case oldCwd = "old_cwd"
        case newCwd = "new_cwd"
    }
}

public struct FileChangedBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let filePath: String?
    public let fileBasename: String?
    public var shouldSendToServer: Bool { false }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case filePath = "file_path"
        case fileBasename = "file_basename"
    }
}

public struct ElicitationBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let mcpServerName: String?
    public var shouldSendToServer: Bool { false }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case mcpServerName = "mcp_server_name"
    }
}

public struct ElicitationResultBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let mcpServerName: String?
    public var shouldSendToServer: Bool { false }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case mcpServerName = "mcp_server_name"
    }
}

public struct WorktreeCreateBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let worktreePath: String?
    public var shouldSendToServer: Bool { false }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case worktreePath = "worktree_path"
    }
}

public struct WorktreeRemoveBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let worktreePath: String?
    public var shouldSendToServer: Bool { false }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case worktreePath = "worktree_path"
    }
}

public struct TaskCreatedBody: HookBodyProtocol {
    public let sessionId: String
    public let transcriptPath: String?
    public let cwd: String?
    public let hookEventName: String
    public let timestamp: String?
    public let taskId: String?
    public let taskSubject: String?
    public let taskDescription: String?
    public let teammateName: String?
    public let teamName: String?
    public var shouldSendToServer: Bool { true }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case timestamp
        case taskId = "task_id"
        case taskSubject = "task_subject"
        case taskDescription = "task_description"
        case teammateName = "teammate_name"
        case teamName = "team_name"
    }
}

// MARK: - Yolo Mode Support

public extension PermissionRequestBody {
    /// Whether this permission request can be auto-approved in yolo mode.
    ///
    /// In yolo mode, all permission requests are auto-approved except:
    /// - `AskUserQuestion` (requires actual user input)
    /// - `ExitPlanMode` (requires explicit plan approval)
    var isYoloAutoApprovable: Bool {
        // When toolInput is nil (e.g., tool_input missing or unparseable), default to
        // auto-approve. A nil toolInput means we can't identify the tool as one that
        // requires explicit user input, so treat it as approvable.
        guard let toolInput else { return true }
        switch toolInput {
        case .askUserQuestion,
             .exitPlanMode:
            return false
        default:
            return true
        }
    }
}

// MARK: - Permission Suggestion Types

/// The type of permission suggestion
public enum PermissionSuggestionType: Codable, Sendable {
    case addRules
    case addDirectories
    case setMode
    case other(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        switch value {
        case "addRules": self = .addRules
        case "addDirectories": self = .addDirectories
        case "setMode": self = .setMode
        default: self = .other(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .addRules: try container.encode("addRules")
        case .addDirectories: try container.encode("addDirectories")
        case .setMode: try container.encode("setMode")
        case let .other(value): try container.encode(value)
        }
    }

    /// Returns the raw string value for display purposes
    public var stringValue: String {
        switch self {
        case .addRules: "Add Rule"
        case .addDirectories: "Add Directory"
        case .setMode: "Set Mode"
        case let .other(value): value
        }
    }

    /// Returns a capitalized display name
    public var displayName: String {
        stringValue.prefix(1).uppercased() + stringValue.dropFirst()
    }
}

/// The behavior for a permission rule
public enum PermissionBehavior: Codable, Sendable {
    case allow
    case other(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        switch value {
        case "allow": self = .allow
        default: self = .other(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .allow: try container.encode("allow")
        case let .other(value): try container.encode(value)
        }
    }

    /// Returns the raw string value for display purposes
    public var stringValue: String {
        switch self {
        case .allow: "Allow"
        case let .other(value): value
        }
    }
}

/// The destination for where the permission should be saved
public enum PermissionDestination: Codable, Sendable, Equatable {
    case session
    case localSettings
    case other(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        switch value {
        case "session": self = .session
        case "localSettings": self = .localSettings
        default: self = .other(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .session: try container.encode("session")
        case .localSettings: try container.encode("localSettings")
        case let .other(value): try container.encode(value)
        }
    }

    /// Returns the raw string value for display purposes
    public var stringValue: String {
        switch self {
        case .session: "Session"
        case .localSettings: "Local Settings"
        case let .other(value): value
        }
    }
}

public struct PermissionSuggestion: Codable, Sendable {
    public let type: PermissionSuggestionType?
    public let rules: [PermissionRule]?
    public let behavior: PermissionBehavior?
    public let destination: PermissionDestination?

    public init(
        type: PermissionSuggestionType?,
        rules: [PermissionRule]? = nil,
        behavior: PermissionBehavior? = nil,
        destination: PermissionDestination? = nil
    ) {
        self.type = type
        self.rules = rules
        self.behavior = behavior
        self.destination = destination
    }
}

public struct PermissionRule: Codable, Sendable {
    public let toolName: String?
    public let ruleContent: String?

    enum CodingKeys: String, CodingKey {
        case toolName
        case ruleContent
    }

    public init(toolName: String?, ruleContent: String?) {
        self.toolName = toolName
        self.ruleContent = ruleContent
    }
}

// MARK: - Hook Action Enum

public enum HookAction: Codable, Sendable {
    case sessionStart(SessionStartBody)
    case preToolUse(PreToolUseBody)
    case postToolUse(PostToolUseBody)
    case postToolUseFailure(PostToolUseFailureBody)
    case sessionEnd(SessionEndBody)
    case permissionRequest(PermissionRequestBody)
    case permissionDenied(PermissionDeniedBody)
    case notification(NotificationBody)
    case userPromptSubmit(UserPromptSubmitBody)
    case stop(StopBody)
    case subagentStart(SubagentStartBody)
    case subagentStop(SubagentStopBody)
    case teammateIdle(TeammateIdleBody)
    case taskCompleted(TaskCompletedBody)
    case preCompact(PreCompactBody)
    case postCompact(PostCompactBody)
    case instructionsLoaded(InstructionsLoadedBody)
    case stopFailure(StopFailureBody)
    case configChange(ConfigChangeBody)
    case cwdChanged(CwdChangedBody)
    case fileChanged(FileChangedBody)
    case elicitation(ElicitationBody)
    case elicitationResult(ElicitationResultBody)
    case worktreeCreate(WorktreeCreateBody)
    case worktreeRemove(WorktreeRemoveBody)
    case taskCreated(TaskCreatedBody)
    case unknown(CommonHookFields)

    private enum CodingKeys: String, CodingKey {
        case type
        case body
    }

    private enum ActionType: String, Codable {
        case sessionStart
        case preToolUse
        case postToolUse
        case postToolUseFailure
        case sessionEnd
        case permissionRequest
        case permissionDenied
        case notification
        case userPromptSubmit
        case stop
        case subagentStart
        case subagentStop
        case teammateIdle
        case taskCompleted
        case preCompact
        case postCompact
        case instructionsLoaded
        case stopFailure
        case configChange
        case cwdChanged
        case fileChanged
        case elicitation
        case elicitationResult
        case worktreeCreate
        case worktreeRemove
        case taskCreated
        case unknown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ActionType.self, forKey: .type)

        switch type {
        case .sessionStart:
            let body = try container.decode(SessionStartBody.self, forKey: .body)
            self = .sessionStart(body)
        case .preToolUse:
            let body = try container.decode(PreToolUseBody.self, forKey: .body)
            self = .preToolUse(body)
        case .postToolUse:
            let body = try container.decode(PostToolUseBody.self, forKey: .body)
            self = .postToolUse(body)
        case .postToolUseFailure:
            let body = try container.decode(PostToolUseFailureBody.self, forKey: .body)
            self = .postToolUseFailure(body)
        case .sessionEnd:
            let body = try container.decode(SessionEndBody.self, forKey: .body)
            self = .sessionEnd(body)
        case .permissionRequest:
            let body = try container.decode(PermissionRequestBody.self, forKey: .body)
            self = .permissionRequest(body)
        case .permissionDenied:
            let body = try container.decode(PermissionDeniedBody.self, forKey: .body)
            self = .permissionDenied(body)
        case .notification:
            let body = try container.decode(NotificationBody.self, forKey: .body)
            self = .notification(body)
        case .userPromptSubmit:
            let body = try container.decode(UserPromptSubmitBody.self, forKey: .body)
            self = .userPromptSubmit(body)
        case .stop:
            let body = try container.decode(StopBody.self, forKey: .body)
            self = .stop(body)
        case .subagentStart:
            let body = try container.decode(SubagentStartBody.self, forKey: .body)
            self = .subagentStart(body)
        case .subagentStop:
            let body = try container.decode(SubagentStopBody.self, forKey: .body)
            self = .subagentStop(body)
        case .teammateIdle:
            let body = try container.decode(TeammateIdleBody.self, forKey: .body)
            self = .teammateIdle(body)
        case .taskCompleted:
            let body = try container.decode(TaskCompletedBody.self, forKey: .body)
            self = .taskCompleted(body)
        case .preCompact:
            let body = try container.decode(PreCompactBody.self, forKey: .body)
            self = .preCompact(body)
        case .postCompact:
            let body = try container.decode(PostCompactBody.self, forKey: .body)
            self = .postCompact(body)
        case .instructionsLoaded:
            let body = try container.decode(InstructionsLoadedBody.self, forKey: .body)
            self = .instructionsLoaded(body)
        case .stopFailure:
            let body = try container.decode(StopFailureBody.self, forKey: .body)
            self = .stopFailure(body)
        case .configChange:
            let body = try container.decode(ConfigChangeBody.self, forKey: .body)
            self = .configChange(body)
        case .cwdChanged:
            let body = try container.decode(CwdChangedBody.self, forKey: .body)
            self = .cwdChanged(body)
        case .fileChanged:
            let body = try container.decode(FileChangedBody.self, forKey: .body)
            self = .fileChanged(body)
        case .elicitation:
            let body = try container.decode(ElicitationBody.self, forKey: .body)
            self = .elicitation(body)
        case .elicitationResult:
            let body = try container.decode(ElicitationResultBody.self, forKey: .body)
            self = .elicitationResult(body)
        case .worktreeCreate:
            let body = try container.decode(WorktreeCreateBody.self, forKey: .body)
            self = .worktreeCreate(body)
        case .worktreeRemove:
            let body = try container.decode(WorktreeRemoveBody.self, forKey: .body)
            self = .worktreeRemove(body)
        case .taskCreated:
            let body = try container.decode(TaskCreatedBody.self, forKey: .body)
            self = .taskCreated(body)
        case .unknown:
            let body = try container.decode(CommonHookFields.self, forKey: .body)
            self = .unknown(body)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .sessionStart(body):
            try container.encode(ActionType.sessionStart, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .preToolUse(body):
            try container.encode(ActionType.preToolUse, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .postToolUse(body):
            try container.encode(ActionType.postToolUse, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .postToolUseFailure(body):
            try container.encode(ActionType.postToolUseFailure, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .sessionEnd(body):
            try container.encode(ActionType.sessionEnd, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .permissionRequest(body):
            try container.encode(ActionType.permissionRequest, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .permissionDenied(body):
            try container.encode(ActionType.permissionDenied, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .notification(body):
            try container.encode(ActionType.notification, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .userPromptSubmit(body):
            try container.encode(ActionType.userPromptSubmit, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .stop(body):
            try container.encode(ActionType.stop, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .subagentStart(body):
            try container.encode(ActionType.subagentStart, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .subagentStop(body):
            try container.encode(ActionType.subagentStop, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .teammateIdle(body):
            try container.encode(ActionType.teammateIdle, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .taskCompleted(body):
            try container.encode(ActionType.taskCompleted, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .preCompact(body):
            try container.encode(ActionType.preCompact, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .postCompact(body):
            try container.encode(ActionType.postCompact, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .instructionsLoaded(body):
            try container.encode(ActionType.instructionsLoaded, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .stopFailure(body):
            try container.encode(ActionType.stopFailure, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .configChange(body):
            try container.encode(ActionType.configChange, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .cwdChanged(body):
            try container.encode(ActionType.cwdChanged, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .fileChanged(body):
            try container.encode(ActionType.fileChanged, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .elicitation(body):
            try container.encode(ActionType.elicitation, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .elicitationResult(body):
            try container.encode(ActionType.elicitationResult, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .worktreeCreate(body):
            try container.encode(ActionType.worktreeCreate, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .worktreeRemove(body):
            try container.encode(ActionType.worktreeRemove, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .taskCreated(body):
            try container.encode(ActionType.taskCreated, forKey: .type)
            try container.encode(body, forKey: .body)
        case let .unknown(body):
            try container.encode(ActionType.unknown, forKey: .type)
            try container.encode(body, forKey: .body)
        }
    }

    /// Returns the underlying hook body for accessing common fields
    public var body: any HookBodyProtocol {
        switch self {
        case let .sessionStart(body): body
        case let .preToolUse(body): body
        case let .postToolUse(body): body
        case let .postToolUseFailure(body): body
        case let .sessionEnd(body): body
        case let .permissionRequest(body): body
        case let .permissionDenied(body): body
        case let .notification(body): body
        case let .userPromptSubmit(body): body
        case let .stop(body): body
        case let .subagentStart(body): body
        case let .subagentStop(body): body
        case let .teammateIdle(body): body
        case let .taskCompleted(body): body
        case let .preCompact(body): body
        case let .postCompact(body): body
        case let .instructionsLoaded(body): body
        case let .stopFailure(body): body
        case let .configChange(body): body
        case let .cwdChanged(body): body
        case let .fileChanged(body): body
        case let .elicitation(body): body
        case let .elicitationResult(body): body
        case let .worktreeCreate(body): body
        case let .worktreeRemove(body): body
        case let .taskCreated(body): body
        case let .unknown(body): body
        }
    }

    public var eventName: String {
        body.hookEventName
    }

    public var sessionId: String {
        body.sessionId
    }

    /// The raw timestamp string from the hook event
    public var timestampString: String? {
        body.timestamp
    }

    /// The parsed timestamp as a Date, or nil if parsing fails
    public var timestamp: Date? {
        ISO8601Parser.parse(timestampString)
    }

    /// Human-readable title for this action
    public var title: String {
        switch self {
        case .sessionStart:
            "Session Started"
        case .sessionEnd:
            "Session Ended"
        case let .preToolUse(body):
            body.toolName ?? "Tool Use"
        case let .postToolUse(body):
            "Done: \(body.toolName ?? "Tool")"
        case let .postToolUseFailure(body):
            "Failed: \(body.toolName ?? "Tool")"
        case let .permissionRequest(body):
            "Permission: \(body.toolName ?? "Request")"
        case let .permissionDenied(body):
            "Denied: \(body.toolName ?? "Tool")"
        case let .notification(body):
            body.notificationType ?? "Notification"
        case .userPromptSubmit:
            "Prompt Submitted"
        case .stop:
            "Session Idle"
        case let .subagentStart(body):
            "Subagent: \(body.agentType ?? "Started")"
        case .subagentStop:
            "Subagent Stopped"
        case let .teammateIdle(body):
            "Teammate Idle: \(body.teammateName ?? "Unknown")"
        case let .taskCompleted(body):
            "Task Done: \(body.taskSubject ?? "Unknown")"
        case let .preCompact(body):
            "Compacting (\(body.trigger ?? "unknown"))"
        case let .postCompact(body):
            "Compacted (\(body.trigger ?? "unknown"))"
        case let .instructionsLoaded(body):
            "Instructions Loaded (\(body.source ?? "unknown"))"
        case let .stopFailure(body):
            "Error: \(body.errorType ?? "Unknown")"
        case let .configChange(body):
            "Config Changed: \(body.configType ?? "Unknown")"
        case .cwdChanged:
            "Directory Changed"
        case let .fileChanged(body):
            "File Changed: \(body.fileBasename ?? "Unknown")"
        case let .elicitation(body):
            "Elicitation: \(body.mcpServerName ?? "MCP")"
        case let .elicitationResult(body):
            "Elicitation Result: \(body.mcpServerName ?? "MCP")"
        case .worktreeCreate:
            "Worktree Created"
        case .worktreeRemove:
            "Worktree Removed"
        case let .taskCreated(body):
            "Task Created: \(body.taskSubject ?? "Unknown")"
        case let .unknown(body):
            body.hookEventName
        }
    }

    /// Optional subtitle with additional context about this action
    public var subtitle: String? {
        switch self {
        case let .sessionStart(body):
            body.cwd ?? body.source
        case .sessionEnd:
            nil
        case let .preToolUse(body):
            body.toolInput?.summary
        case let .postToolUse(body):
            body.toolInput?.summary
        case let .postToolUseFailure(body):
            body.error ?? body.toolInput?.summary
        case let .permissionRequest(body):
            body.permissionMode
        case let .permissionDenied(body):
            body.reason
        case let .notification(body):
            body.message
        case let .userPromptSubmit(body):
            body.prompt
        case let .stop(body):
            body.lastAssistantMessage
        case .subagentStart,
             .subagentStop:
            nil
        case let .teammateIdle(body):
            body.teamName
        case let .taskCompleted(body):
            body.taskDescription
        case let .preCompact(body):
            body.customInstructions
        case .postCompact:
            nil
        case .instructionsLoaded:
            nil
        case let .stopFailure(body):
            body.errorType
        case let .configChange(body):
            body.configType
        case let .cwdChanged(body):
            body.newCwd
        case let .fileChanged(body):
            body.filePath
        case let .elicitation(body):
            body.mcpServerName
        case let .elicitationResult(body):
            body.mcpServerName
        case let .worktreeCreate(body):
            body.worktreePath
        case let .worktreeRemove(body):
            body.worktreePath
        case let .taskCreated(body):
            body.taskDescription
        case .unknown:
            nil
        }
    }

    /// Parse hook action from JSON data by reading hook_event_name.
    public static func from(jsonData: Data) throws -> HookAction {
        let decoder = JSONDecoder()

        // First, extract common fields to determine the type
        let common = try decoder.decode(CommonHookFields.self, from: jsonData)

        switch common.hookEventName {
        case "SessionStart":
            let body = try decoder.decode(SessionStartBody.self, from: jsonData)
            return .sessionStart(body)
        case "PreToolUse":
            let body = try decoder.decode(PreToolUseBody.self, from: jsonData)
            return .preToolUse(body)
        case "PostToolUse":
            let body = try decoder.decode(PostToolUseBody.self, from: jsonData)
            return .postToolUse(body)
        case "PostToolUseFailure":
            let body = try decoder.decode(PostToolUseFailureBody.self, from: jsonData)
            return .postToolUseFailure(body)
        case "SessionEnd":
            let body = try decoder.decode(SessionEndBody.self, from: jsonData)
            return .sessionEnd(body)
        case "PermissionRequest":
            let body = try decoder.decode(PermissionRequestBody.self, from: jsonData)
            return .permissionRequest(body)
        case "PermissionDenied":
            let body = try decoder.decode(PermissionDeniedBody.self, from: jsonData)
            return .permissionDenied(body)
        case "Notification":
            let body = try decoder.decode(NotificationBody.self, from: jsonData)
            return .notification(body)
        case "UserPromptSubmit":
            let body = try decoder.decode(UserPromptSubmitBody.self, from: jsonData)
            return .userPromptSubmit(body)
        case "Stop":
            let body = try decoder.decode(StopBody.self, from: jsonData)
            return .stop(body)
        case "SubagentStart":
            let body = try decoder.decode(SubagentStartBody.self, from: jsonData)
            return .subagentStart(body)
        case "SubagentStop":
            let body = try decoder.decode(SubagentStopBody.self, from: jsonData)
            return .subagentStop(body)
        case "TeammateIdle":
            let body = try decoder.decode(TeammateIdleBody.self, from: jsonData)
            return .teammateIdle(body)
        case "TaskCompleted":
            let body = try decoder.decode(TaskCompletedBody.self, from: jsonData)
            return .taskCompleted(body)
        case "PreCompact":
            let body = try decoder.decode(PreCompactBody.self, from: jsonData)
            return .preCompact(body)
        case "PostCompact":
            let body = try decoder.decode(PostCompactBody.self, from: jsonData)
            return .postCompact(body)
        case "InstructionsLoaded":
            let body = try decoder.decode(InstructionsLoadedBody.self, from: jsonData)
            return .instructionsLoaded(body)
        case "StopFailure":
            let body = try decoder.decode(StopFailureBody.self, from: jsonData)
            return .stopFailure(body)
        case "ConfigChange":
            let body = try decoder.decode(ConfigChangeBody.self, from: jsonData)
            return .configChange(body)
        case "CwdChanged":
            let body = try decoder.decode(CwdChangedBody.self, from: jsonData)
            return .cwdChanged(body)
        case "FileChanged":
            let body = try decoder.decode(FileChangedBody.self, from: jsonData)
            return .fileChanged(body)
        case "Elicitation":
            let body = try decoder.decode(ElicitationBody.self, from: jsonData)
            return .elicitation(body)
        case "ElicitationResult":
            let body = try decoder.decode(ElicitationResultBody.self, from: jsonData)
            return .elicitationResult(body)
        case "WorktreeCreate":
            let body = try decoder.decode(WorktreeCreateBody.self, from: jsonData)
            return .worktreeCreate(body)
        case "WorktreeRemove":
            let body = try decoder.decode(WorktreeRemoveBody.self, from: jsonData)
            return .worktreeRemove(body)
        case "TaskCreated":
            let body = try decoder.decode(TaskCreatedBody.self, from: jsonData)
            return .taskCreated(body)
        default:
            return .unknown(common)
        }
    }
}

// MARK: - AnyCodable Helper

/// Type-erased Codable wrapper for handling arbitrary JSON values
public struct AnyCodable: Codable, Sendable, Equatable {
    public let value: AnyCodableValue

    public init(_ value: Any) {
        self.value = AnyCodableValue(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            self.value = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self.value = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self.value = .double(double)
        } else if let string = try? container.decode(String.self) {
            self.value = .string(string)
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = .array(array.map(\.value))
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = .dictionary(dictionary.mapValues { $0.value })
        } else if container.decodeNil() {
            self.value = .null
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode AnyCodable"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try value.encode(to: &container)
    }
}

/// Sendable-safe value representation for AnyCodable
public enum AnyCodableValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])

    public init(_ value: Any) {
        switch value {
        case let bool as Bool:
            self = .bool(bool)
        case let int as Int:
            self = .int(int)
        case let double as Double:
            self = .double(double)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { AnyCodableValue($0) })
        case let dictionary as [String: Any]:
            self = .dictionary(dictionary.mapValues { AnyCodableValue($0) })
        default:
            self = .null
        }
    }

    public func encode(to container: inout SingleValueEncodingContainer) throws {
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(values):
            try container.encode(values.map { AnyCodable(wrapping: $0) })
        case let .dictionary(values):
            try container.encode(values.mapValues { AnyCodable(wrapping: $0) })
        }
    }
}

private extension AnyCodable {
    init(wrapping value: AnyCodableValue) {
        self.value = value
    }
}
