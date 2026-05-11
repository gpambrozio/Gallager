import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// A row displaying a local tmux session in the sidebar.
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
    private var claudeSession: ClaudeSession? {
        for window in session.windows {
            for pane in window.panes {
                if let session = windowManager.paneStates[pane.paneId]?.claudeSession {
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

    /// The latest event subtitle from the first pane with a Claude session
    private var sessionSubtitle: String? {
        for window in session.windows {
            for pane in window.panes {
                if let subtitle = windowManager.paneStates[pane.paneId]?.claudeSession?.latestEvent?.action.subtitle {
                    return subtitle
                }
            }
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 2) {
                if let cliSessionState {
                    SessionStatusIndicator(cliState: cliSessionState)
                        .font(.system(size: 16))
                } else if let claudeSession {
                    SessionStatusIndicator(session: claudeSession)
                        .font(.system(size: 16))
                } else {
                    Symbols.terminal.image
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }

                if let customEmoji = primaryPaneState?.customEmoji {
                    SessionEmojiBadge(emoji: customEmoji)
                        .font(.system(size: 14))
                }
            }
            .frame(width: 20)

            SessionFieldsView(
                fields: claudeSession != nil ? settings.sidebarFields : settings.sidebarTerminalFields,
                customDescription: primaryPaneState?.customDescription,
                projectName: claudeSession?.displayName,
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
            ZStack {
                if let status = cliSessionState?.statusLabel ?? claudeSession?.statusLabel {
                    Text(status)
                        .accessibilityLabel(status)
                }
                // The project name is rendered by SessionFieldsView, but when the row's
                // Button combines its children's AX into a single label, that leaf can
                // drop out intermittently — exposing it as its own hidden label gives
                // e2e tests a stable element to find.
                if let projectName = claudeSession?.displayName {
                    Text(projectName)
                        .accessibilityLabel(projectName)
                }
            }
            .font(.system(size: 1))
            .opacity(0)
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
