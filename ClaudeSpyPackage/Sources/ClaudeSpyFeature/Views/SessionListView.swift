import ClaudeSpyCommon
import SwiftUI

/// View displaying a list of active Claude sessions from the Mac.
struct SessionListView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(RelayClient.self) private var relayClient
    @Environment(IOSSettings.self) private var settings

    var body: some View {
        Group {
            if sessionStore.hasSessions {
                sessionsList
            } else {
                emptyStateView
            }
        }
        .navigationTitle("Sessions")
        .navigationDestination(for: String.self) { paneId in
            SessionDetailView(
                paneId: paneId,
                sessionStore: sessionStore,
                relayClient: relayClient,
                settings: settings
            )
        }
        .toolbar {
            #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    connectionStatusView
                }
            #else
                ToolbarItem(placement: .automatic) {
                    connectionStatusView
                }
            #endif
        }
    }

    // MARK: - Sessions List

    private var sessionsList: some View {
        List {
            ForEach(sessionStore.sortedSessions, id: \.paneId) { item in
                NavigationLink(value: item.paneId) {
                    SessionRowView(
                        paneId: item.paneId,
                        session: item.session,
                        isActive: sessionStore.isPaneActive(item.paneId)
                    )
                }
            }
        }
        .refreshable {
            await relayClient.requestSessionState()
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Sessions", symbol: .terminal)
        } description: {
            if relayClient.isMacConnected {
                Text("No active Claude Code sessions on your Mac")
            } else {
                Text("Waiting for Mac to connect...")
            }
        } actions: {
            if relayClient.state.isConnected {
                Button("Refresh") {
                    Task {
                        await relayClient.requestSessionState()
                    }
                }
            }
        }
    }

    // MARK: - Connection Status

    private var connectionStatusView: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connectionStatusColor)
                .frame(width: 8, height: 8)

            Text(connectionStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionStatusColor: Color {
        if relayClient.isMacConnected {
            return .green
        } else if relayClient.state.isConnected {
            return .yellow
        } else {
            return .red
        }
    }

    private var connectionStatusText: String {
        if relayClient.isMacConnected {
            return "Mac Online"
        } else if relayClient.state.isConnected {
            return "Waiting for Mac"
        } else {
            return relayClient.state.statusText
        }
    }
}

// MARK: - Session Row View

struct SessionRowView: View {
    let paneId: String
    let session: ClaudeSession
    let isActive: Bool

    private var indicatorColor: Color {
        if session.needsAttention {
            return .red
        } else if isActive {
            return .green
        } else {
            return .gray.opacity(0.3)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Activity indicator - red for notification, green for active, gray for inactive
            Circle()
                .fill(indicatorColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 4) {
                // Project folder name (or pane ID as fallback)
                Text(session.displayName)
                    .font(.headline)

                // Latest event summary
                if let latestEvent = session.latestEvent {
                    HStack {
                        Text(latestEvent.action.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer()

                        Text(DateFormatters.relativeTime(for: latestEvent.timestamp))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Event count
                Text("\(session.events.count) recent events")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        SessionListView()
    }
    .environment(SessionStore())
    .environment(RelayClient())
}
