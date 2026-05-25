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

    /// The first Claude session found in any pane of any window, if any
    private var agentSession: AgentSession? {
        for window in session.windows {
            for pane in window.panes {
                if let session = windowManager.paneStates[pane.paneId]?.agentSession {
                    return session
                }
            }
        }
        return nil
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

    // swiftlint:disable todo
    /// The latest event subtitle from the first pane with a Claude session.
    ///
    /// TODO(plugin-system): `AgentSession` no longer caches hook events. The
    /// per-event subtitle string is gone until Tasks 18+ replace it with
    /// status text pushed by the plugin sidecar.
    private var sessionSubtitle: String? {
        nil
    }

    // swiftlint:enable todo

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SessionStatusBadge(
                cliSessionState: cliSessionState,
                agentSession: agentSession,
                customEmoji: primaryPaneState?.customEmoji
            )

            SessionFieldsView(
                fields: agentSession != nil ? settings.sidebarFields : settings.sidebarTerminalFields,
                customDescription: primaryPaneState?.customDescription,
                projectName: agentSession?.displayName,
                sessionName: session.sessionName,
                terminalTitle: terminalTitle,
                command: primaryPane?.command,
                currentPath: primaryPane?.currentPath,
                gitBranch: primaryPaneState?.gitBranch,
                latestEvent: sessionSubtitle
            )

            Spacer()
        }
        // Expose session name to macOS accessibility tree so e2e tests can find sessions
        // regardless of which sidebar fields are configured (session name may not appear as
        // visible Text). Also expose status since ProgressView (working state) prevents AX
        // from reading .accessibilityValue directly on the indicator.
        .accessibilityValue(session.sessionName)
        .overlay {
            SessionAccessibilityOverlay(
                status: cliSessionState?.statusLabel ?? agentSession?.statusLabel,
                projectName: agentSession?.displayName
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
