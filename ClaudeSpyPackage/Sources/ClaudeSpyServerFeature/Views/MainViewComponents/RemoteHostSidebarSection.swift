import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Sidebar section for a remote Mac host's sessions, grouped by tmux session
struct RemoteHostSidebarSection: View {
    let host: PairedHost
    let connection: ViewerConnection?
    let sessionStore: SessionStore
    let creatingSelection: NewSessionCreatingState?
    @Binding var selectedRemoteSession: RemoteSessionSelection?
    let onSelect: (RemoteSessionSelection) -> Void
    let onCreate: (AgentProject?) -> Void
    let onSetDescription: (String, String?) -> Void
    let onSetColor: (String, SessionColor?) -> Void
    let onSetEmoji: (String, String?) -> Void
    let onToggleYolo: (String, Bool) -> Void
    let onCloseSession: (String) -> Void

    @Environment(AppSettings.self) private var settings

    /// Remote sessions grouped by tmux session (mirrors local session grouping)
    private var tmuxSessions: [TmuxSession] {
        sessionStore.sessions(for: host.id)
    }

    private var hasContent: Bool {
        !tmuxSessions.isEmpty
    }

    private var sortedSessions: [TmuxSession] {
        settings.sidebarSortMode.sorted(tmuxSessions) { session in
            SessionSortData.forRemoteSession(
                session,
                sidebarFields: settings.sidebarFields,
                sidebarTerminalFields: settings.sidebarTerminalFields,
                homeDirectory: sessionStore.homeDirectoryByHost[host.id]
            )
        }
    }

    var body: some View {
        Section {
            if connection?.hostSubscriptionInactive == true {
                HStack(alignment: .top, spacing: 8) {
                    Symbols.exclamationmarkTriangle.image
                        .font(.system(size: 16))
                        .foregroundStyle(.orange)
                        .frame(width: 20)
                        .accessibilityHidden(true)

                    Text("Host's subscription expired")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            } else if let mismatch = connection?.versionMismatch {
                RemoteHostVersionMismatchRow(host: host, mismatch: mismatch) {
                    Task { await connection?.enableReconnectAndRetry() }
                }
            } else if hasContent {
                // The remote host's cross-session usage rollup (issue #598),
                // from its SessionStateMessage — same collapsible cell the
                // local section and the iOS list show.
                if let overview = sessionStore.usageOverview(for: host.id), !overview.isEmpty {
                    UsageOverviewView(overview: overview)
                        .padding(.vertical, 2)
                        .accessibilityIdentifier("usage-overview-remote-\(host.id)")
                }
                ForEach(sortedSessions) { session in
                    remoteSessionButton(session)
                }
            } else if connection?.isHostConnected == true {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Text("Host offline")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } header: {
            SectionHeader(
                title: host.displayName(showUsername: settings.hasDuplicateHostName(for: host)),
                symbol: .laptopcomputer,
                isNewSessionDisabled: connection?.isHostConnected != true,
                newSessionButtonIdentifier: "new-session-remote-\(host.id)",
                trailing: {
                    Circle()
                        .fill(hostStatusColor)
                        .frame(width: 8, height: 8)
                },
                popover: {
                    NewSessionContent(
                        title: "New Session on \(host.displayName)",
                        projects: sessionStore.projects(for: host.id),
                        isLoadingProjects: !sessionStore.hasReceivedState(for: host.id),
                        creatingSelection: creatingSelection,
                        onCreate: onCreate
                    )
                }
            )
        }
    }

    @ViewBuilder
    private func remoteSessionButton(_ session: TmuxSession) -> some View {
        let claudePane = session.windows.flatMap(\.panes).first(where: { $0.agentSession != nil })
        let isSelected = selectedRemoteSession?.sessionName == session.sessionName
            && selectedRemoteSession?.hostId == host.id
        // See `sessionButton` — when the row gains a "Working" indicator the
        // merged button becomes `AXBusyIndicator` and swallows the bar's
        // separate accessibility element. Mirror the bar AX info on a sibling
        // outside the Button label so `valueContains` queries keep working.
        let sessionProgress: TerminalProgressState? = session.windows.lazy
            .flatMap(\.panes)
            .compactMap(\.progress)
            .first

        Button {
            onSelect(RemoteSessionSelection(
                hostId: host.id,
                hostName: host.displayName,
                sessionName: session.sessionName
            ))
        } label: {
            RemoteSessionSidebarRow(
                session: session,
                claudeSession: claudePane?.agentSession,
                homeDirectory: sessionStore.homeDirectoryByHost[host.id]
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.2) : nil)
        .accessibilityChildren {
            SessionProgressAccessibilityProxy(progress: sessionProgress)
        }
        .modifier(DescriptionEditingModifier(
            sessionName: session.sessionName,
            currentDescription: session.customDescription,
            currentEmoji: session.customEmoji,
            isDisabled: connection?.isHostConnected != true,
            onSetDescription: onSetDescription,
            onSetEmoji: onSetEmoji,
            additionalMenu: {
                ColorContextMenuButtons(
                    currentColor: session.customColor,
                    isDisabled: connection?.isHostConnected != true
                ) { newColor in
                    onSetColor(session.sessionName, newColor)
                }

                Divider()

                if let claudePane {
                    Toggle(isOn: Binding(
                        get: { sessionStore.isYoloModeEnabled(paneId: claudePane.paneId, hostId: host.id) },
                        set: { onToggleYolo(claudePane.paneId, $0) }
                    )) {
                        Label("Yolo Mode", symbol: .bolt)
                    }
                    .disabled(connection?.isHostConnected != true)

                    Divider()
                }

                Button(role: .destructive) {
                    onCloseSession(session.sessionName)
                } label: {
                    Label("Close Session", symbol: .rectangleStackBadgeMinus)
                }
                .disabled(connection?.isHostConnected != true)

                Divider()
            }
        ))
    }

    private var hostStatusColor: Color {
        guard let connection else { return .gray }
        if connection.hostSubscriptionInactive { return .orange }
        if connection.versionMismatch != nil { return .orange }
        if connection.isHostConnected { return .green }
        if connection.isRelayConnected { return .yellow }
        return .red
    }
}
