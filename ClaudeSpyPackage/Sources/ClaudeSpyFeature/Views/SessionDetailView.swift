import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Detailed view of a single Claude session with event history and live terminal streaming.
struct SessionDetailView: View {
    let paneId: String

    @Environment(RelayClient.self) private var relayClient
    @Environment(SessionStore.self) private var sessionStore
    @Environment(IOSSettings.self) private var settings

    // Note: Service is optional because we need @Environment values (sessionStore, relayClient)
    // which aren't available at init time. We create the service in .task when view appears.
    // This is the standard SwiftUI pattern when services depend on Environment values.
    @State private var service: SessionDetailService?

    /// Whether to show the live terminal stream view
    @State private var showTerminalStream = false

    var body: some View {
        bodyContent
            .task {
                if service == nil {
                    service = SessionDetailService(
                        paneId: paneId,
                        sessionStore: sessionStore,
                        relayClient: relayClient
                    )
                }
            }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let service, let session = service.session {
            @Bindable var bindableService = service

            sessionContent(service: service, session: session)
                .navigationTitle("Session")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(isPresented: $showTerminalStream) {
                    TerminalStreamView(
                        service: service,
                        responseState: $bindableService.responseState,
                        isConnected: service.isMacConnected,
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
            .navigationTitle("Session")
        }
    }

    @ViewBuilder
    private func sessionContent(service: SessionDetailService, session: ClaudeSession) -> some View {
        List {
            // Terminal section
            Section {
                viewTerminalButton(service: service)
            } header: {
                Text("Live Terminal")
            } footer: {
                if let error = service.streamError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
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
    private func viewTerminalButton(service: SessionDetailService) -> some View {
        Button {
            showTerminalStream = true
        } label: {
            HStack {
                Symbols.terminal.image
                Text("View Live Terminal")
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
        SessionDetailView(paneId: "%1")
    }
    .environment(RelayClient())
    .environment(SessionStore())
    .environment(IOSSettings.shared)
}
