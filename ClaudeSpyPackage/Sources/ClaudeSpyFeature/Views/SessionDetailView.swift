import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Detailed view of a single Claude session with event history and terminal snapshot.
struct SessionDetailView: View {
    let paneId: String
    let session: ClaudeSession

    @Environment(RelayClient.self) private var relayClient
    @Environment(SessionStore.self) private var sessionStore
    @Environment(IOSSettings.self) private var settings

    @State private var isLoadingSnapshot = false
    @State private var terminalSnapshot: TerminalSnapshotMessage?
    @State private var snapshotError: String?

    var body: some View {
        List {
            // Terminal section
            Section {
                viewTerminalButton
            } header: {
                Text("Terminal")
            } footer: {
                if let error = snapshotError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            // Context-sensitive response section based on latest event
            if let latestEvent = session.latestEvent,
               let responseView = latestEvent.responseView(
                   isConnected: relayClient.isMacConnected,
                   sendCommand: sendCommand
               ) {
                Section("Response") {
                    responseView
                }
            }

            // Events section
            Section("Recent Events") {
                if session.events.isEmpty {
                    Text("No events yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.events) { event in
                        EventRowView(event: event)
                    }
                }
            }

            // Session info section
            Section("Session Info") {
                LabeledContent("Pane ID", value: paneId)

                if let projectPath = session.events.first?.projectPath {
                    LabeledContent("Project") {
                        Text(projectPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Status") {
                    HStack {
                        Circle()
                            .fill(sessionStore.isPaneActive(paneId) ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(sessionStore.isPaneActive(paneId) ? "Active" : "Inactive")
                    }
                }
            }
        }
        .navigationTitle("Session")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $terminalSnapshot) { snapshot in
            TerminalSnapshotView(snapshot: snapshot)
        }
        #endif
    }

    // MARK: - View Terminal Button

    private var viewTerminalButton: some View {
        Button {
            Task {
                await requestTerminalSnapshot()
            }
        } label: {
            HStack {
                if isLoadingSnapshot {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Symbols.terminal.image
                }
                Text("View Terminal")
                Spacer()
                if !isLoadingSnapshot {
                    Symbols.arrowRight.image
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!relayClient.isMacConnected || isLoadingSnapshot)
    }

    // MARK: - Actions

    private func sendCommand(_ command: CommandType) async {
        await relayClient.sendCommand(CommandMessage(paneId: paneId, command: command))
    }

    private func requestTerminalSnapshot() async {
        isLoadingSnapshot = true
        snapshotError = nil

        let command = CommandMessage(paneId: paneId, command: .captureSnapshot(scrollbackMultiplier: 3))
        let result = await relayClient.sendSnapshotCommand(command)

        isLoadingSnapshot = false

        switch result {
        case .success(let snapshot):
            terminalSnapshot = snapshot
        case .failure(let error):
            snapshotError = error.localizedDescription
        }
    }

}

#Preview {
    NavigationStack {
        SessionDetailView(
            paneId: "%1",
            session: ClaudeSession(paneId: "%1")
        )
    }
    .environment(RelayClient())
    .environment(SessionStore())
    .environment(IOSSettings.shared)
}
