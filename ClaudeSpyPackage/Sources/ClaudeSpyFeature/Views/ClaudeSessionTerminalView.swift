#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftUI

    /// Terminal view for a Claude session that shows the terminal directly with a toolbar button
    /// to access session info (recent events, session details) in a popover.
    struct ClaudeSessionTerminalView: View {
        let paneId: String
        let settings: IOSSettings

        @State private var service: SessionDetailService
        @State private var showSessionInfo = false

        init(
            paneId: String,
            sessionStore: SessionStore,
            relayClient: RelayClient,
            settings: IOSSettings
        ) {
            self.paneId = paneId
            self.settings = settings
            self.service = SessionDetailService(
                paneId: paneId,
                sessionStore: sessionStore,
                relayClient: relayClient
            )
        }

        var body: some View {
            terminalContent
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSessionInfo = true
                        } label: {
                            Label("Session Info", symbol: .infoCircle)
                        }
                        .popover(isPresented: $showSessionInfo) {
                            sessionInfoPopover
                        }
                    }
                }
                .environment(service.client)
        }

        @ViewBuilder
        private var terminalContent: some View {
            if service.session != nil {
                @Bindable var bindableService = service

                LiveTerminalView(
                    paneId: paneId,
                    responseState: $bindableService.responseState,
                    isConnected: service.isMacConnected,
                    settings: settings,
                    sendCommand: { command in
                        await service.sendCommand(command)
                    }
                )
            } else {
                ContentUnavailableView(
                    "Session Not Found",
                    symbol: .exclamationmarkTriangle,
                    description: "This session may have ended or the pane no longer exists."
                )
            }
        }

        @ViewBuilder
        private var sessionInfoPopover: some View {
            NavigationStack {
                SessionInfoView(
                    session: service.session,
                    paneId: paneId,
                    isPaneActive: service.isPaneActive,
                    isMacConnected: service.isMacConnected,
                    responseState: service.responseState,
                    sendCommand: { command in
                        await service.sendCommand(command)
                    }
                )
                .navigationTitle("Session Info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            showSessionInfo = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .frame(minWidth: 320, idealWidth: 380, minHeight: 400)
        }
    }

    // MARK: - Session Info View

    /// View displaying session information shown in the popover.
    /// Contains recent events, session info, and response UI if applicable.
    private struct SessionInfoView: View {
        let session: ClaudeSession?
        let paneId: String
        let isPaneActive: Bool
        let isMacConnected: Bool
        let responseState: ResponseState?
        let sendCommand: CommandSender

        var body: some View {
            if let session {
                List {
                    // Context-sensitive response section based on latest event
                    if
                        let responseState,
                        let responseView = responseState.event.responseView(
                            isConnected: isMacConnected,
                            sendCommand: sendCommand,
                            state: responseState
                        )
                    {
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
                                    .fill(isPaneActive ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text(isPaneActive ? "Active" : "Inactive")
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Session Not Found",
                    symbol: .exclamationmarkTriangle,
                    description: "This session may have ended."
                )
            }
        }
    }

    #Preview {
        NavigationStack {
            ClaudeSessionTerminalView(
                paneId: "%1",
                sessionStore: SessionStore(),
                relayClient: RelayClient(),
                settings: .shared
            )
        }
        .environment(IOSSettings.shared)
    }
#endif
