import SwiftUI
import ClaudeSpyCommon

/// Detailed view of a single Claude session with event history and command controls.
struct SessionDetailView: View {
    let paneId: String
    let session: ClaudeSession

    @Environment(RelayClient.self) private var relayClient
    @Environment(SessionStore.self) private var sessionStore

    @State private var showingCancelConfirmation = false
    @State private var lastCommandResult: CommandResult?

    var body: some View {
        List {
            // Command section
            Section {
                commandButtons
            } header: {
                Text("Commands")
            } footer: {
                if let result = lastCommandResult {
                    commandResultView(result)
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
        #endif
        .confirmationDialog(
            "Cancel Operation?",
            isPresented: $showingCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Operation", role: .destructive) {
                Task {
                    await sendCancelCommand()
                }
            }
            Button("Never Mind", role: .cancel) {}
        } message: {
            Text("This will send Ctrl+C to interrupt the current Claude Code operation.")
        }
    }

    // MARK: - Command Buttons

    private var commandButtons: some View {
        HStack(spacing: 16) {
            // Cancel operation button
            Button {
                showingCancelConfirmation = true
            } label: {
                VStack(spacing: 8) {
                    Symbols.stopFill.image
                        .font(.title2)
                    Text("Cancel")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(!relayClient.isMacConnected)

            // Accept/Yes button (sends 'y' + Enter)
            Button {
                Task {
                    await sendKeystroke("y\n")
                }
            } label: {
                VStack(spacing: 8) {
                    Symbols.checkmarkCircleFill.image
                        .font(.title2)
                    Text("Accept")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .disabled(!relayClient.isMacConnected)

            // Reject/No button (sends 'n' + Enter)
            Button {
                Task {
                    await sendKeystroke("n\n")
                }
            } label: {
                VStack(spacing: 8) {
                    Symbols.xmarkCircleFill.image
                        .font(.title2)
                    Text("Reject")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(!relayClient.isMacConnected)
        }
    }

    // MARK: - Command Result

    private func commandResultView(_ result: CommandResult) -> some View {
        HStack {
            (result.success ? Symbols.checkmarkCircle : Symbols.xmarkCircle).image
            Text(result.message)
        }
        .font(.caption)
        .foregroundStyle(result.success ? .green : .red)
    }

    // MARK: - Actions

    private func sendCancelCommand() async {
        let command = CommandMessage.cancel(paneId: paneId)
        await sendCommand(command)
    }

    private func sendKeystroke(_ keys: String) async {
        let command = CommandMessage.keystroke(paneId: paneId, keys: keys)
        await sendCommand(command)
    }

    private func sendCommand(_ command: CommandMessage) async {
        lastCommandResult = nil

        relayClient.onCommandResponse = { [command] response in
            if response.commandId == command.id {
                Task { @MainActor in
                    if response.success {
                        lastCommandResult = CommandResult(
                            success: true,
                            message: "Command sent successfully"
                        )
                    } else {
                        lastCommandResult = CommandResult(
                            success: false,
                            message: response.error ?? "Command failed"
                        )
                    }
                }
            }
        }

        await relayClient.sendCommand(command)

        // Clear result after delay
        try? await Task.sleep(for: .seconds(3))
        lastCommandResult = nil
    }
}

// MARK: - Command Result Model

private struct CommandResult {
    let success: Bool
    let message: String
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
}
