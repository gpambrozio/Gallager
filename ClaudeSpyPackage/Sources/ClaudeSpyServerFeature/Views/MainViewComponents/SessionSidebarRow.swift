import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// A row displaying a tmux session in the sidebar
struct SessionSidebarRow: View {
    @Environment(MirrorWindowManager.self) private var windowManager
    @Environment(AppSettings.self) private var settings

    let session: LocalTmuxSession

    /// Progress state for this session, picked from the first pane that has
    /// one. Same iteration shape as the Mac-as-viewer (`RemoteSessionSidebarRow`)
    /// and iOS (`SessionListView.sessionRow`) sites so all three render the
    /// same pane's progress when multiple panes are emitting at once.
    /// Recomputed on each render — observation tracks `windowManager.paneStates`
    /// and re-renders this row only when the lookup result actually changes.
    private var sessionProgress: TerminalProgressState? {
        session.windows.lazy
            .flatMap(\.panes)
            .compactMap { windowManager.paneStates[$0.paneId]?.progress }
            .first
    }

    /// The active window (or first)
    private var activeWindow: LocalTmuxWindow? {
        session.activeWindow
    }

    /// The primary pane to show info for (active pane or first pane in active window)
    private var primaryPane: PaneInfo? {
        activeWindow?.activePane
    }

    private var primaryPaneState: PaneState? {
        guard let pane = primaryPane else { return nil }
        return windowManager.paneStates[pane.paneId]
    }

    /// The first pane state in any window backing an agent session, if any. Also
    /// the source of its OTEL telemetry / permission mode (#597).
    private var primaryAgentPaneState: PaneState? {
        for window in session.windows {
            for pane in window.panes {
                if let state = windowManager.paneStates[pane.paneId], state.agentSession != nil {
                    return state
                }
            }
        }
        return nil
    }

    /// The first Claude session found in any pane of any window, if any.
    private var claudeSession: AgentSession? {
        primaryAgentPaneState?.agentSession
    }

    /// CLI-driven state override, if any pane in the session has one set.
    private var cliSessionState: CLISessionState? {
        for window in session.windows {
            for pane in window.panes {
                if let state = windowManager.paneStates[pane.paneId]?.cliSessionState {
                    return state
                }
            }
        }
        return nil
    }

    /// The first non-empty terminal title found across all windows
    private var terminalTitle: String? {
        for window in session.windows {
            for pane in window.panes {
                if let title = windowManager.paneStates[pane.paneId]?.terminalTitle, !title.isEmpty {
                    return title
                }
            }
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SessionStatusBadge(
                cliSessionState: cliSessionState,
                claudeSession: claudeSession,
                customEmoji: primaryPaneState?.customEmoji
            )

            VStack(alignment: .leading, spacing: 2) {
                SessionFieldsView(
                    fields: claudeSession != nil ? settings.sidebarFields : settings.sidebarTerminalFields,
                    customDescription: primaryPaneState?.customDescription,
                    projectName: claudeSession?.displayName,
                    sessionName: session.sessionName,
                    terminalTitle: terminalTitle,
                    command: primaryPane?.command,
                    currentPath: primaryPane?.currentPath,
                    gitBranch: primaryPaneState?.gitBranch,
                    // The plugin model dropped the per-event buffer (spec §16),
                    // so there's no "latest event" subtitle to surface.
                    latestEvent: nil
                )

                // OTEL meter + model + permission-mode chip (issue #597), shown
                // only when the user has added the "Token Usage" field to the
                // sidebar (Preferences > Sidebar). Opt-in, so rows stay clean by
                // default.
                if settings.sidebarFields.contains(.tokenUsage) {
                    SessionTelemetrySummary(
                        telemetry: primaryAgentPaneState?.telemetry,
                        permissionMode: primaryAgentPaneState?.permissionMode
                    )
                }
            }

            Spacer()
        }
        // Expose session name to macOS accessibility tree so e2e tests can find sessions
        // regardless of which sidebar fields are configured (session name may not appear as
        // visible Text). Also expose status since ProgressView (working state) prevents AX
        // from reading .accessibilityValue directly on the indicator.
        .accessibilityValue(session.sessionName)
        .overlay {
            SessionAccessibilityOverlay(
                status: cliSessionState?.statusLabel ?? claudeSession?.statusLabel,
                projectName: claudeSession?.displayName
            )
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            SessionColorBar(color: primaryPaneState?.customColor)
                .padding(.leading, -16)
        }
        .overlay(alignment: .bottom) {
            if let sessionProgress {
                TerminalProgressBar(state: sessionProgress)
                    .padding(.bottom, -4)
            }
        }
    }
}

#if DEBUG
    // MARK: - Preview

    /// Builds one preview row as a `(session, state)` pair. The session wraps a
    /// single active window/pane keyed by `paneId`; the matching `PaneState` carries
    /// the status, custom styling, telemetry, and git metadata the row renders. The
    /// row reads `command`/`currentPath` off the pane and everything else off the
    /// state, so both are populated consistently.
    private func previewSidebarRow(
        paneId: String,
        sessionName: String,
        command: String,
        currentPath: String,
        customEmoji: String? = nil,
        customColor: SessionColor? = nil,
        customDescription: String? = nil,
        gitBranch: String? = nil,
        terminalTitle: String? = nil,
        agentState: AgentState? = nil,
        projectPath: String? = nil,
        cliSessionState: CLISessionState? = nil,
        telemetry: SessionTelemetry? = nil,
        permissionMode: String? = nil,
        progress: TerminalProgressState? = nil
    ) -> (session: LocalTmuxSession, state: PaneState) {
        let target = "\(sessionName):0.0"
        let pane = PaneInfo(
            paneId: paneId,
            target: target,
            sessionName: sessionName,
            windowIndex: 0,
            paneIndex: 0,
            command: command,
            currentPath: currentPath,
            width: 120,
            height: 40,
            isActive: true,
            windowName: "main",
            isWindowActive: true
        )
        let window = LocalTmuxWindow(
            id: "\(sessionName):0",
            sessionName: sessionName,
            windowIndex: 0,
            windowName: "main",
            windowLayout: "",
            isWindowActive: true,
            panes: [pane]
        )
        let session = LocalTmuxSession(sessionName: sessionName, windows: [window])

        let agentSession = agentState.map {
            AgentSession(
                paneId: paneId,
                pluginID: "claude-code",
                detectedProjectPath: projectPath,
                state: $0
            )
        }
        let state = PaneState(
            paneId: paneId,
            target: target,
            sessionName: sessionName,
            command: command,
            currentPath: currentPath,
            isActive: true,
            windowName: "main",
            isWindowActive: true,
            customDescription: customDescription,
            customColor: customColor,
            customEmoji: customEmoji,
            terminalTitle: terminalTitle,
            gitBranch: gitBranch,
            agentSession: agentSession,
            cliSessionState: cliSessionState,
            progress: progress,
            permissionMode: permissionMode,
            telemetry: telemetry
        )
        return (session, state)
    }

    /// One of every distinct sidebar row the app can show: Claude sessions across
    /// all statuses and permission modes (incl. the OTEL token meter), a session
    /// with custom styling + git branch + progress, and plain / CLI-driven terminals.
    private let previewSidebarVariants: [(session: LocalTmuxSession, state: PaneState)] = [
        // Claude — working, default mode (calm shield chip) + live token meter.
        previewSidebarRow(
            paneId: "%1", sessionName: "claudespy", command: "claude",
            currentPath: "~/Development/ClaudeSpy",
            agentState: .working, projectPath: "/Users/dev/Development/ClaudeSpy",
            telemetry: SessionTelemetry(tokensUsed: 12_400, costUSD: 0.42, model: "claude-opus-4-8"),
            permissionMode: "default"
        ),
        // Claude — working unsupervised (loud bypass chip) + a custom description.
        previewSidebarRow(
            paneId: "%2", sessionName: "infra", command: "claude",
            currentPath: "~/Development/Infra",
            customDescription: "Migrating the relay",
            agentState: .working, projectPath: "/Users/dev/Development/Infra",
            telemetry: SessionTelemetry(tokensUsed: 305_000, costUSD: 2.18, model: "claude-opus-4-8"),
            permissionMode: "bypassPermissions"
        ),
        // Claude — idle, acceptEdits chip.
        previewSidebarRow(
            paneId: "%3", sessionName: "docs", command: "claude",
            currentPath: "~/Development/Docs",
            agentState: .idle, projectPath: "/Users/dev/Development/Docs",
            telemetry: SessionTelemetry(tokensUsed: 4_200, costUSD: 0.09, model: "claude-sonnet-4-6"),
            permissionMode: "acceptEdits"
        ),
        // Claude — done / needs attention, plan chip.
        previewSidebarRow(
            paneId: "%4", sessionName: "api", command: "claude",
            currentPath: "~/Development/API",
            agentState: .doneWorking(summary: "Added the endpoint"),
            projectPath: "/Users/dev/Development/API",
            telemetry: SessionTelemetry(tokensUsed: 88_000, costUSD: 0.74, model: "claude-opus-4-8"),
            permissionMode: "plan"
        ),
        // Claude — awaiting a permission decision.
        previewSidebarRow(
            paneId: "%5", sessionName: "scripts", command: "claude",
            currentPath: "~/Development/Scripts",
            agentState: .awaitingPermission(
                PermissionRequest(title: "Run command", description: "Allow `rm -rf build`?"),
                requestID: "req-perm"
            ),
            projectPath: "/Users/dev/Development/Scripts"
        ),
        // Claude — awaiting a question reply.
        previewSidebarRow(
            paneId: "%6", sessionName: "webapp", command: "claude",
            currentPath: "~/Development/WebApp",
            agentState: .awaitingReplies(
                AskUserQuestionRequest(questions: []),
                requestID: "req-q"
            ),
            projectPath: "/Users/dev/Development/WebApp"
        ),
        // Claude — awaiting plan approval.
        previewSidebarRow(
            paneId: "%7", sessionName: "planner", command: "claude",
            currentPath: "~/Development/Planner",
            agentState: .awaitingPlanApproval(
                ApprovePlanRequest(title: "Refactor plan", plan: "1. Extract service\n2. Wire DI"),
                requestID: "req-plan"
            ),
            projectPath: "/Users/dev/Development/Planner"
        ),
        // Claude — working with a determinate progress bar across the bottom.
        previewSidebarRow(
            paneId: "%8", sessionName: "build", command: "claude",
            currentPath: "~/Development/Build",
            agentState: .working, projectPath: "/Users/dev/Development/Build",
            telemetry: SessionTelemetry(tokensUsed: 21_000, costUSD: 0.31, model: "claude-opus-4-8"),
            permissionMode: "default",
            progress: .normal(65)
        ),
        // Claude — custom emoji + color bar + custom description + git branch.
        previewSidebarRow(
            paneId: "%9", sessionName: "feature", command: "claude",
            currentPath: "~/Development/Feature",
            customEmoji: "🚀", customColor: .purple,
            customDescription: "Sidebar telemetry",
            gitBranch: "feature/otel-telemetry",
            agentState: .working, projectPath: "/Users/dev/Development/Feature",
            telemetry: SessionTelemetry(tokensUsed: 9_900, costUSD: 0.18, model: "claude-opus-4-8"),
            permissionMode: "default"
        ),
        // Plain terminal — no agent session (uses the terminal field layout).
        previewSidebarRow(
            paneId: "%10", sessionName: "shell", command: "zsh",
            currentPath: "~/Development",
            terminalTitle: "zsh — ~/Development"
        ),
        // Terminal — CLI-driven "working" status.
        previewSidebarRow(
            paneId: "%11", sessionName: "devserver", command: "npm run dev",
            currentPath: "~/Development/WebApp",
            terminalTitle: "npm run dev",
            cliSessionState: .working
        ),
        // Terminal — CLI-driven "waiting for input" status.
        previewSidebarRow(
            paneId: "%12", sessionName: "deploy", command: "./deploy.sh",
            currentPath: "~/Development/Infra",
            terminalTitle: "deploy.sh",
            cliSessionState: .waiting
        ),
    ]

    /// Hosts a live `MirrorWindowManager` (built off-screen, like `PaneListPreview`)
    /// seeded with every row variant, then renders them in a sidebar `List`.
    private struct SessionSidebarRowPreview: View {
        @State private var settings = AppSettings()
        @State private var tmuxService = TmuxService()
        @State private var windowManager: MirrorWindowManager?

        var body: some View {
            Group {
                if let windowManager {
                    List(previewSidebarVariants.map(\.session)) { session in
                        SessionSidebarRow(session: session)
                    }
                    .listStyle(.sidebar)
                    .environment(windowManager)
                    .environment(settings)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 300, height: 780)
            .onAppear {
                // Show the OTEL token meter (opt-in field) plus the git branch so the
                // telemetry + git rows are exercised.
                settings.sidebarFields = [.customDescription, .projectName, .currentPath, .gitBranch, .tokenUsage]
                let controlClientManager = TmuxControlClientManager(
                    tmuxPath: settings.tmuxPath,
                    socketPath: settings.tmuxSocket.isEmpty ? nil : settings.tmuxSocket
                )
                let manager = MirrorWindowManager(
                    settings: settings,
                    tmuxService: tmuxService,
                    paneStreamManager: .init(
                        tmuxService: tmuxService,
                        controlClientManager: controlClientManager
                    ),
                    editorSessionManager: EditorSessionManager()
                )
                manager.setPaneStatesForPreview(previewSidebarVariants.map(\.state))
                windowManager = manager
            }
        }
    }

    #Preview("Sidebar rows — all variants") {
        SessionSidebarRowPreview()
    }

    #Preview("Sidebar rows — dark") {
        SessionSidebarRowPreview()
            .preferredColorScheme(.dark)
    }
#endif
