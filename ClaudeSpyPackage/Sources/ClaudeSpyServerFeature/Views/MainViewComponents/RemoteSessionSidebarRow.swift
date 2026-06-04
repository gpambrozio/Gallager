import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Sidebar row displaying a remote tmux session, grouped by session name
struct RemoteSessionSidebarRow: View {
    @Environment(AppSettings.self) private var settings

    let session: TmuxSession
    let claudeSession: AgentSession?
    var homeDirectory: String?

    /// The plugin model dropped the per-event buffer (spec §16), so there is no
    /// "latest event" subtitle to surface; the field renders empty.
    private var latestEventSubtitle: String? {
        nil
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
            SessionStatusBadge(
                cliSessionState: cliSessionState,
                claudeSession: claudeSession,
                customEmoji: session.customEmoji
            )

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
            SessionAccessibilityOverlay(
                status: cliSessionState?.statusLabel ?? claudeSession?.statusLabel,
                projectName: claudeSession?.displayName
            )
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
