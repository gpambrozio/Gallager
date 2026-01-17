import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Detailed view of a single Claude session with event history and terminal snapshot.
struct SessionDetailView: View {
    let paneId: String

    @Environment(IOSSettings.self) private var settings
    @State private var service: SessionDetailService

    init(
        paneId: String,
        sessionStore: SessionStore,
        relayClient: RelayClient
    ) {
        self.paneId = paneId
        self.service = SessionDetailService(
            paneId: paneId,
            sessionStore: sessionStore,
            relayClient: relayClient
        )
    }

    var body: some View {
        bodyContent
            .navigationTitle("Session")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let session = service.session {
            @Bindable var bindableService = service

            sessionContent(session: session)
            #if os(iOS)
                .navigationDestination(isPresented: $bindableService.showLiveTerminal) {
                    LiveTerminalView(
                        paneId: paneId,
                        responseState: $bindableService.responseState,
                        isConnected: service.isMacConnected,
                        settings: settings,
                        sendCommand: { command in
                            await service.sendCommand(command)
                        }
                    )
                }
            #endif
        } else {
            ContentUnavailableView(
                "Session Not Found",
                symbol: .exclamationmarkTriangle,
                description: "This session may have ended or the pane no longer exists."
            )
        }
    }

    @ViewBuilder
    private func sessionContent(session: ClaudeSession) -> some View {
        List {
            // Terminal section
            Section {
                viewTerminalButton()
            } header: {
                Text("Terminal")
            }

            // Context-sensitive response section based on latest event
            if
                let responseState = service.responseState,
                let responseView = responseState.event.responseView(
                    isConnected: service.isMacConnected,
                    sendCommand: { command in
                        await service.sendCommand(command)
                    },
                    state: responseState
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
                            .fill(service.isPaneActive ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(service.isPaneActive ? "Active" : "Inactive")
                    }
                }
            }
        }
    }

    // MARK: - View Terminal Button

    @ViewBuilder
    private func viewTerminalButton() -> some View {
        Button {
            service.showLiveTerminal = true
        } label: {
            HStack {
                Symbols.terminal.image
                Text("View Terminal")
                Spacer()
                Symbols.arrowRight.image
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!service.isMacConnected)
    }
}

#Preview {
    NavigationStack {
        SessionDetailView(
            paneId: "%1",
            sessionStore: SessionStore(),
            relayClient: RelayClient()
        )
    }
    .environment(IOSSettings.shared)
}
