import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Sidebar row displaying a remote tmux session, grouped by session name.
struct RemoteSessionSidebarRow: View {
    @Environment(AppSettings.self) private var settings

    let session: TmuxSession
    let claudeSession: ClaudeSession?
    var homeDirectory: String?

    /// The latest event subtitle from the Claude session's pane
    private var latestEventSubtitle: String? {
        session.windows
            .flatMap(\.panes)
            .compactMap(\.claudeSession?.latestEvent?.action.subtitle)
            .first
    }

    /// CLI-driven state override propagated from the host, if any.
    private var cliSessionState: CLISessionState? {
        session.windows
            .flatMap(\.panes)
            .compactMap(\.cliSessionState)
            .first
    }

    /// Latest `OSC 9;4` progress from the host, picked from the first pane
    /// in this session that has one. Same iteration shape as the host's
    /// `SessionSidebarRow.sessionProgress` and the iOS session list, so when
    /// multiple panes in one session emit progress all three platforms agree
    /// on which pane wins.
    private var sessionProgress: TerminalProgressState? {
        session.windows.lazy
            .flatMap(\.panes)
            .compactMap(\.progress)
            .first
    }

    var body: some View {
        rowContent
            .overlay(alignment: .leading) {
                SessionColorBar(color: session.customColor)
                    .padding(.leading, -16)
            }
            .overlay(alignment: .bottom) {
                if let sessionProgress {
                    TerminalProgressBar(state: sessionProgress)
                        .padding(.bottom, -4)
                }
            }
    }

    private var rowContent: some View {
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

                if let customEmoji = session.customEmoji {
                    SessionEmojiBadge(emoji: customEmoji)
                        .font(.system(size: 14))
                }
            }
            .frame(width: 20)

            SessionFieldsView(
                fields: claudeSession != nil ? settings.sidebarFields : settings.sidebarTerminalFields,
                customDescription: session.customDescription,
                projectName: claudeSession?.displayName,
                sessionName: session.sessionName,
                terminalTitle: session.activeWindow?.activePane?.terminalTitle,
                command: session.activeWindow?.activePane?.command,
                currentPath: session.activeWindow?.activePane?.currentPath,
                gitBranch: session.activeWindow?.activePane?.gitBranch,
                latestEvent: latestEventSubtitle,
                homeDirectory: homeDirectory
            )

            Spacer()
        }
        // Expose session name to macOS accessibility tree so e2e tests can find sessions
        // regardless of which sidebar fields are configured.
        .accessibilityValue(session.sessionName)
        // Invisible text exposing session status and project name to macOS accessibility
        // tree for e2e tests. The Button that wraps this row can combine children into a
        // single label, dropping leaf Texts — these hidden labels give tests stable targets.
        .overlay {
            ZStack {
                if let status = cliSessionState?.statusLabel ?? claudeSession?.statusLabel {
                    Text(status)
                        .accessibilityLabel(status)
                }
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
    }
}
