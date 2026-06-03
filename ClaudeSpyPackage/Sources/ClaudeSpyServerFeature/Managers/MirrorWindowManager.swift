import ClaudeSpyCommon
import ClaudeSpyNetworking
import Dependencies
import Foundation
import Logging

/// Manages pane state, agent session status, and session tracking.
@Observable
@MainActor
final public class MirrorWindowManager {
    /// Unified per-pane state keyed by pane ID.
    /// Contains tmux metadata, agent session, terminal title, and yolo mode.
    public private(set) var paneStates: [String: PaneState] = [:]

    /// Task for periodic session validation
    private var sessionValidationTask: Task<Void, Never>?

    /// Called when session metadata (description, color, or emoji) changes,
    /// to push updated state to viewers.
    public var onSessionMetadataChanged: (@MainActor @Sendable () async -> Void)?

    /// Interval between session validation checks (in seconds)
    private let validationInterval: TimeInterval = 5

    @ObservationIgnored
    @Dependency(ProcessRunner.self) private var processRunner

    private let logger = Logger(label: "com.claudespy.mirrorwindowmanager")
    private let settings: AppSettings
    private let tmuxService: TmuxService

    /// Pane stream manager for sharing streams
    public var paneStreamManager: PaneStreamManager

    /// Editor session manager for prompt editing
    public let editorSessionManager: EditorSessionManager

    public init(
        settings: AppSettings,
        tmuxService: TmuxService,
        paneStreamManager: PaneStreamManager,
        editorSessionManager: EditorSessionManager
    ) {
        self.settings = settings
        self.tmuxService = tmuxService
        self.paneStreamManager = paneStreamManager
        self.editorSessionManager = editorSessionManager
    }

    // MARK: - Pane State Management

    /// Updates the pane states dictionary from tmux pane metadata.
    /// Creates new entries for newly discovered panes, updates metadata for existing panes,
    /// and removes entries for panes that no longer exist (cleaning up associated state).
    ///
    /// An empty `panes` argument is a legitimate signal that the tmux server has
    /// no panes (e.g. the user just closed the last session and the server
    /// exited). When that happens we must clear `paneStates` so the UI stops
    /// showing stale sessions; refusing to clear leaves the just-closed session
    /// pinned in the session list and tab bars indefinitely. The producer-side
    /// guards in `TmuxService.refreshPanes()` only set `panes = []` on
    /// confident server-down paths, so we trust them here. Surprising wipes
    /// are still observable via the warnings below and the producer-side logs.
    public func updatePaneStates(from panes: [PaneInfo]) {
        if panes.isEmpty && !paneStates.isEmpty {
            logger.warning("updatePaneStates clearing non-empty state from empty panes", metadata: [
                "existingPaneCount": "\(paneStates.count)",
                "existingAgentSessionCount": "\(paneStates.values.filter { $0.agentSession != nil }.count)",
            ])
        }

        let currentPaneIds = Set(panes.map(\.paneId))

        // Update or create entries for current panes
        for pane in panes {
            if var state = paneStates[pane.paneId] {
                pane.updateMetadata(of: &state)
                paneStates[pane.paneId] = state
            } else {
                paneStates[pane.paneId] = pane.makePaneState()
            }
        }

        // Remove stale entries — but skip status-only minimal states.
        // `applyPluginStatus` creates a `PaneState(paneId:agentSession:)` with
        // default-empty `sessionName` when a status arrives for a pane the
        // windowManager hasn't yet observed; the first refresh that sees the pane
        // fills in metadata. A refresh whose
        // `list-panes` snapshot was taken BEFORE the hook arrived (the subprocess
        // ran while MainActor was suspended) won't include that pane, and removing
        // the entry here would silently drop the SessionStart and lose the project
        // decoration. Empty `sessionName` is a reliable signal that no refresh has
        // confirmed the pane yet — refresh-derived entries always carry the tmux
        // session name. The next refresh that does see the pane confirms it; if the
        // pane truly never appears in tmux a follow-up hook with the same paneId
        // updates in place rather than accumulating.
        let stalePaneIds = paneStates.keys.filter { paneId in
            guard !currentPaneIds.contains(paneId) else { return false }
            return paneStates[paneId]?.sessionName.isEmpty == false
        }
        for paneId in stalePaneIds {
            removeStaleState(paneId: paneId)
        }
    }

    // MARK: - Periodic Session Validation

    /// Starts a background task that periodically validates sessions against actual tmux panes.
    /// Sessions for panes that no longer exist are automatically removed.
    public func startPeriodicSessionValidation() {
        // Cancel any existing task
        sessionValidationTask?.cancel()

        sessionValidationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.validationInterval ?? 5))

                guard !Task.isCancelled, let self else { break }

                // Refresh panes and update state. Right-click context menus
                // host their own NSMenu (see StableContextMenu) so SwiftUI
                // reconciliation from this refresh no longer dismisses an
                // open popup mid-hover.
                let panes = await self.tmuxService.refreshPanes()
                self.updatePaneStates(from: panes)
                await self.refreshGitBranches()
            }
        }
    }

    /// Stops the periodic session validation task.
    public func stopPeriodicSessionValidation() {
        sessionValidationTask?.cancel()
        sessionValidationTask = nil
    }

    // MARK: - Session Management

    /// Updates the agent session for the given pane ID, creating pane state if needed.
    /// Encapsulates the copy-mutate-reassign pattern for struct values in dictionaries.
    /// - Parameters:
    ///   - paneId: The tmux pane ID
    ///   - update: A closure that mutates the session
    private func updateSession(paneId: String, _ update: (inout AgentSession) -> Void) {
        var session = paneStates[paneId]?.agentSession ?? AgentSession(paneId: paneId)
        update(&session)
        if paneStates[paneId] != nil {
            paneStates[paneId]?.agentSession = session
        } else {
            // Pane not yet known from tmux refresh — create minimal state
            paneStates[paneId] = PaneState(paneId: paneId, agentSession: session)
        }
    }

    /// Marks panes as agent sessions based on process detection at startup.
    /// Only creates sessions for panes that don't already have one (the plugin
    /// status path takes precedence).
    /// - Parameter panes: Mapping of pane ID to the detected plugin id and cwd.
    public func markDetectedAgentSessions(_ panes: [String: TmuxService.DetectedAgentPane]) {
        for (paneId, info) in panes where paneStates[paneId] != nil && paneStates[paneId]?.agentSession == nil {
            updateSession(paneId: paneId) { session in
                session.detectedProjectPath = info.path
                session.pluginID = info.pluginID
            }
        }
    }

    /// Ends the agent session on a pane: removes its `AgentSession` so the sidebar
    /// row reverts from the idle/working status indicator to the plain terminal
    /// glyph, and drops the pane's session-scoped guard state. This is the
    /// agent-blind equivalent of the legacy `claudeSession = nil` on `SessionEnd`;
    /// it's driven by the `.sessionEnded` app action (Claude's hook, or Codex's
    /// process-exit monitor), NOT by a `working == false` status (a `Stop` leaves
    /// the session alive and idle — only an end removes it). The pane state itself
    /// is kept (the terminal is still open); it's reclaimed separately when the
    /// pane closes.
    /// - Returns: whether a session was actually removed (so the caller can push
    ///   updated state to viewers only when something changed).
    @discardableResult
    public func endAgentSession(forPane paneId: String) -> Bool {
        guard paneStates[paneId]?.agentSession != nil else { return false }
        paneStates[paneId]?.agentSession = nil
        panesWithBlockingForm.remove(paneId)
        pendingApprovalByPane.removeValue(forKey: paneId)
        openResponseRequestByPane.removeValue(forKey: paneId)
        return true
    }

    // MARK: - Plugin Status (in-process plugin runtime)

    /// Applies a session-status update produced by the in-process plugin runtime
    /// (spec §5, `PluginEvent.working`/`.attention`). This is the SOLE status
    /// driver: it ensures the pane has an `AgentSession` (so the pane registers
    /// as an active session and counts toward attention/sleep-prevention), then
    /// sets the session's `isWorking` / `needsAttention` Bools directly.
    ///
    /// The pane is keyed by `tmuxPane`. A `working == nil` opinion leaves
    /// `isWorking` unchanged ("no opinion" tick); `attention` is always applied.
    /// Setting any definitive status also clears a stale CLI override on this
    /// pane and its session siblings so plugin activity wins over a prior
    /// `session.set_state` from the CLI.
    ///
    /// - Parameters:
    ///   - pluginID: The plugin that produced the status (owns the session).
    ///   - sessionID: The plugin's opaque session id (informational here).
    ///   - working: `true`/`false` working opinion, or `nil` for "no opinion".
    ///   - attention: Whether the session needs user attention.
    ///   - tmuxPane: The pane this status targets (the session key).
    ///   - projectPath: Optional project path, recorded on the session so the
    ///     sidebar can render a name before any tmux refresh tick.
    public func applyPluginStatus(
        pluginID: String,
        sessionID: String,
        working: Bool?,
        attention: Bool,
        opensBlockingForm: Bool = false,
        tmuxPane: String?,
        projectPath: String?
    ) {
        guard let paneId = tmuxPane, !paneId.isEmpty else {
            logger.debug("Dropping plugin status with no tmuxPane", metadata: [
                "pluginID": "\(pluginID)",
                "sessionID": "\(sessionID)",
            ])
            return
        }

        // Ensure a session exists for this pane and set the status Bools directly.
        // Record the project path so the sidebar has a name before the next tmux
        // refresh confirms the pane.
        updateSession(paneId: paneId) { session in
            session.pluginID = pluginID
            if let projectPath, !projectPath.isEmpty {
                session.detectedProjectPath = projectPath
            }
            if let working {
                session.isWorking = working
            }
            session.needsAttention = attention
        }

        // Blocking-form guard, maintained ATOMICALLY with the status set above —
        // this whole method runs in one MainActor turn, *before* SwiftUI's
        // `pendingSessionCount` onChange (which auto-marks the viewed session
        // handled) can fire. So opening a permission / question / plan form
        // registers the guard in the same beat attention is raised, and a viewer
        // looking at the session can't race ahead and clear an attention that
        // still needs a response. A plain working event — the agent advancing
        // past a form with no form of its own — lifts the guard and drops any
        // stale pending approval.
        if opensBlockingForm {
            panesWithBlockingForm.insert(paneId)
        } else if working == true {
            panesWithBlockingForm.remove(paneId)
            pendingApprovalByPane.removeValue(forKey: paneId)
            // The agent advanced past its form, so drop the retained open request
            // too — otherwise the authoritative session-state snapshot would
            // resurrect a form the viewer already closed on this working tick
            // (iOS clears it the same way in `SessionStore.handleAgentStatus`).
            // The dispatcher fans status out *before* the response-request sink,
            // so an open form arriving in this same envelope is re-set after this
            // clear and survives.
            openResponseRequestByPane.removeValue(forKey: paneId)
        }

        // Record arrival order for the "most recent activity" sort.
        lastActivityByPane[paneId] = Date()

        // A definitive status wins over any CLI-driven override so subsequent
        // plugin activity is reflected. The sidebar aggregates state across every
        // pane in the session, so clear the override on every sibling pane.
        if working != nil || attention {
            let sessionName = paneStates[paneId]?.sessionName
            if let sessionName, !sessionName.isEmpty {
                for (otherId, state) in paneStates where state.sessionName == sessionName {
                    paneStates[otherId]?.cliSessionState = nil
                }
            } else {
                paneStates[paneId]?.cliSessionState = nil
            }
        }
    }

    /// Updates the terminal title for a pane.
    /// - Parameters:
    ///   - paneId: The tmux pane ID
    ///   - title: The new terminal title
    public func updateTerminalTitle(paneId: String, title: String) {
        paneStates[paneId]?.terminalTitle = title
    }

    /// Updates the `OSC 9;4` progress signal for a pane. `.removed` clears it.
    /// Returns `true` if the stored value actually changed; the caller can use
    /// that to decide whether to push session state to viewers.
    @discardableResult
    public func setPaneProgress(_ progress: TerminalProgressState, for paneId: String) -> Bool {
        guard paneStates[paneId] != nil else { return false }
        let normalized: TerminalProgressState? = progress == .removed ? nil : progress
        if paneStates[paneId]?.progress == normalized {
            return false
        }
        paneStates[paneId]?.progress = normalized
        return true
    }

    /// Set of pane IDs that have active agent sessions
    public var activeSessionPaneIds: Set<String> {
        Set(paneStates.filter { $0.value.agentSession != nil }.keys)
    }

    /// Number of sessions that need user attention
    public var pendingSessionCount: Int {
        paneStates.values.filter { $0.agentSession?.needsAttention == true }.count
    }

    /// All sessions sorted with attention-needing sessions first
    public var sortedSessions: [AgentSession] {
        paneStates.values
            .compactMap(\.agentSession)
            .sorted {
                if $0.needsAttention != $1.needsAttention {
                    return $0.needsAttention
                }
                return $0.paneId < $1.paneId
            }
    }

    // MARK: - Mark Handled

    /// Panes with an open **blocking** response form (permission / question / plan
    /// approval). Their attention is owed an explicit response, so
    /// `markSessionHandled` must not clear it on mere viewing/selection. Maintained
    /// by the dispatcher's open/retract sinks and cleared when the agent goes busy.
    private var panesWithBlockingForm: Set<String> = []

    /// When each pane last received a plugin status update, used for the
    /// "most recent activity" sidebar sort. The agent-blind `PluginEvent` carries
    /// no event timestamp (the trailing-event buffer was dropped, spec §16), so
    /// recency is sourced from status-arrival order instead — which matches the
    /// order the host received the events in.
    private var lastActivityByPane: [String: Date] = [:]

    /// The most recent plugin-status arrival time for a pane, if any.
    public func lastActivity(for paneId: String) -> Date? {
        lastActivityByPane[paneId]
    }

    /// A pending auto-approvable permission form shown because the pane was NOT in
    /// yolo mode when it arrived. If yolo is enabled while it's open, the app
    /// approves it immediately (#315) — this carries the ids needed to deliver the
    /// approval back to the owning core.
    public struct PendingApproval: Sendable, Equatable {
        public let pluginID: String
        public let requestID: String
    }

    /// The pending auto-approvable permission per pane (see `PendingApproval`).
    private var pendingApprovalByPane: [String: PendingApproval] = [:]

    /// The full open response form per pane, retained so a viewer that connects
    /// after the form opened can still render it (the live `agentResponseRequest`
    /// push only reaches already-connected viewers). Read when building the
    /// `SessionStateMessage` snapshot; set/cleared by the open/retract sinks and
    /// dropped when the session ends. Covers *all* open forms (not just blocking
    /// ones) since iOS shows a form for any open request.
    private var openResponseRequestByPane: [String: PaneOpenResponseRequest] = [:]

    /// Records whether a pane currently has an open blocking response form.
    /// - Parameters:
    ///   - open: `true` to mark the pane as awaiting an explicit response.
    ///   - paneId: The pane the form targets.
    public func setBlockingResponseForm(open: Bool, for paneId: String) {
        if open {
            panesWithBlockingForm.insert(paneId)
        } else {
            panesWithBlockingForm.remove(paneId)
            pendingApprovalByPane.removeValue(forKey: paneId)
        }
    }

    /// Records (or clears, with `nil`) the pane's pending auto-approvable permission
    /// so enabling yolo can approve it immediately (#315).
    public func setPendingApproval(_ approval: PendingApproval?, for paneId: String) {
        if let approval {
            pendingApprovalByPane[paneId] = approval
        } else {
            pendingApprovalByPane.removeValue(forKey: paneId)
        }
    }

    /// The pane's pending auto-approvable permission, if one is open.
    public func pendingApproval(for paneId: String) -> PendingApproval? {
        pendingApprovalByPane[paneId]
    }

    /// Records (or clears, with `nil`) the pane's open response form so it can be
    /// replayed to a viewer that connects after it opened, via the
    /// `SessionStateMessage` snapshot.
    public func setOpenResponseRequest(_ request: PaneOpenResponseRequest?, for paneId: String) {
        if let request {
            openResponseRequestByPane[paneId] = request
        } else {
            openResponseRequestByPane.removeValue(forKey: paneId)
        }
    }

    /// Every open response form across panes, for the catch-up snapshot.
    public var openResponseRequests: [PaneOpenResponseRequest] {
        Array(openResponseRequestByPane.values)
    }

    /// Marks a session as handled (user has seen it), clearing the `needsAttention` flag.
    /// - Parameter paneId: The pane ID whose session should be marked handled
    public func markSessionHandled(paneId: String) {
        guard paneStates[paneId]?.agentSession?.needsAttention == true else { return }
        // A blocking form (permission / question / plan approval) requires an
        // explicit response — viewing/selecting the session must not clear it.
        if panesWithBlockingForm.contains(paneId) { return }
        paneStates[paneId]?.agentSession?.markHandled()
    }

    // MARK: - CLI Session State Override

    /// Sets the CLI-driven session state override for a pane. Pass `nil` to
    /// clear the override and revert to whatever the underlying Claude session
    /// (or absence of one) reports. No-op if the pane isn't tracked yet —
    /// callers should refresh tmux state first so `sessionName` is populated;
    /// otherwise the session-wide hook clearing in `handleHookEvent` can't
    /// match siblings.
    /// - Parameters:
    ///   - state: The override to apply, or `nil` to clear.
    ///   - paneId: The pane to apply the override to.
    /// - Returns: `true` when an existing pane was updated.
    @discardableResult
    public func setCLISessionState(_ state: CLISessionState?, for paneId: String) -> Bool {
        guard paneStates[paneId] != nil else { return false }
        paneStates[paneId]?.cliSessionState = state
        return true
    }

    // MARK: - Yolo Mode

    /// Sets yolo mode for a pane's agent session.
    /// When enabled, auto-approvable permission requests are approved by the
    /// plugin path (the app calls `deliverResponse(.permission(.allow))` for an
    /// `isAutoApprovable` request on a yolo pane — spec §6), so this method only
    /// records the flag.
    /// - Parameters:
    ///   - enabled: Whether to enable or disable yolo mode
    ///   - paneId: The pane ID to set yolo mode for
    public func setYoloMode(enabled: Bool, for paneId: String) {
        if paneStates[paneId] != nil {
            paneStates[paneId]?.yoloMode = enabled
        } else {
            // Create minimal state if needed
            paneStates[paneId] = PaneState(paneId: paneId, yoloMode: enabled)
        }
    }

    /// Whether yolo mode is enabled for the given pane
    public func isYoloModeEnabled(for paneId: String) -> Bool {
        paneStates[paneId]?.yoloMode ?? false
    }

    // MARK: - Session Descriptions

    /// Sets a custom description for a session, updating every pane in every window
    /// of that session so the description survives switching windows/tabs.
    /// The description is persisted as a tmux user option so it survives app restarts.
    /// - Parameters:
    ///   - description: The description text, or nil to clear
    ///   - sessionName: The tmux session name
    public func setSessionDescription(_ description: String?, for sessionName: String) {
        let normalizedDescription = description?.isEmpty == true ? nil : description
        // Optimistic local update for immediate UI feedback; tmux remains the source
        // of truth and the next refresh reconciles from it.
        for (paneId, state) in paneStates where state.sessionName == sessionName {
            paneStates[paneId]?.customDescription = normalizedDescription
        }
        Task { [tmuxService] in
            try? await tmuxService.setSessionDescription(normalizedDescription, for: sessionName)
            await onSessionMetadataChanged?()
        }
    }

    // MARK: - Session Colors

    /// Sets a custom color for a session, applied to every pane so it survives
    /// switching windows. Persisted as a tmux user option (see `TmuxService`).
    /// - Parameters:
    ///   - color: The color, or nil to clear
    ///   - sessionName: The tmux session name
    public func setSessionColor(_ color: SessionColor?, for sessionName: String) {
        // Optimistic local update for immediate UI feedback; tmux remains the source
        // of truth and the next refresh reconciles from it.
        for (paneId, state) in paneStates where state.sessionName == sessionName {
            paneStates[paneId]?.customColor = color
        }
        Task { [tmuxService, logger] in
            do {
                try await tmuxService.setSessionColor(color, for: sessionName)
            } catch {
                logger.warning("Failed to persist session color", metadata: [
                    "session": "\(sessionName)",
                    "error": "\(error)",
                ])
            }
            await onSessionMetadataChanged?()
        }
    }

    // MARK: - Session Emoji

    /// Sets a custom emoji for a session, applied to every pane so it survives
    /// switching windows. Persisted as a tmux user option (see `TmuxService`).
    /// - Parameters:
    ///   - emoji: The emoji string, or nil/empty to clear
    ///   - sessionName: The tmux session name
    public func setSessionEmoji(_ emoji: String?, for sessionName: String) {
        let normalizedEmoji = emoji?.isEmpty == true ? nil : emoji
        // Optimistic local update for immediate UI feedback; tmux remains the source
        // of truth and the next refresh reconciles from it.
        for (paneId, state) in paneStates where state.sessionName == sessionName {
            paneStates[paneId]?.customEmoji = normalizedEmoji
        }
        Task { [tmuxService, logger] in
            do {
                try await tmuxService.setSessionEmoji(normalizedEmoji, for: sessionName)
            } catch {
                logger.warning("Failed to persist session emoji", metadata: [
                    "session": "\(sessionName)",
                    "error": "\(error)",
                ])
            }
            await onSessionMetadataChanged?()
        }
    }

    // MARK: - Git Branch Detection

    private static let gitPath = "/usr/bin/git"

    /// Refreshes git branch info for all panes that have a current path.
    func refreshGitBranches() async {
        var panesForPath: [String: [String]] = [:]
        for (paneId, state) in paneStates {
            guard let path = state.currentPath, !path.isEmpty else { continue }
            panesForPath[path, default: []].append(paneId)
        }

        await withTaskGroup(of: (String, String?).self) { group in
            for path in panesForPath.keys {
                group.addTask { [processRunner] in
                    let branch = await Self.detectGitBranch(at: path, processRunner: processRunner)
                    return (path, branch)
                }
            }

            for await (path, branch) in group {
                for paneId in panesForPath[path] ?? [] {
                    paneStates[paneId]?.gitBranch = branch
                }
            }
        }
    }

    /// Detects the git branch for a given directory path.
    /// Returns nil if the path is not inside a git repository.
    private static func detectGitBranch(
        at path: String,
        processRunner: ProcessRunner
    ) async -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard
            let result = try? await processRunner.run(
                gitPath,
                ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"],
                nil,
                5
            ) else { return nil }

        guard result.isSuccess else { return nil }
        let branch = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty { return nil }
        // `git rev-parse --abbrev-ref HEAD` returns the literal "HEAD" when the
        // working copy is in a detached-HEAD state. Surface that explicitly
        // rather than showing "HEAD" in the sidebar.
        if branch == "HEAD" { return "(detached)" }
        return branch
    }

    // MARK: - State Cleanup

    /// Removes state for a pane that no longer exists.
    private func removeStaleState(paneId: String) {
        paneStates.removeValue(forKey: paneId)
    }
}
