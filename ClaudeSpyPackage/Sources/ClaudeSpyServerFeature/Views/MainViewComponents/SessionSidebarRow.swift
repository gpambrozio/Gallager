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

                // OTEL meter + model + permission-mode chip (issue #597).
                SessionTelemetrySummary(
                    telemetry: primaryAgentPaneState?.telemetry,
                    permissionMode: primaryAgentPaneState?.permissionMode
                )
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
