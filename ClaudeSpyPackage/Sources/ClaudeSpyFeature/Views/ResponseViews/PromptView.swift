import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Free-text prompt input for sending a message to the agent. Renders the
/// placeholder copy supplied by the plugin sidecar and emits a
/// `PromptResponse` envelope on submit; the sidecar translates the structured
/// response into the agent-specific delivery (keystrokes, JSON-RPC, ...).
struct PromptView: View {
    let hostID: String
    let sessionID: String
    let pluginID: String
    let requestID: String
    let request: PromptRequest
    let isConnected: Bool
    let submitter: AgentResponseSubmitter

    @State private var inputText = ""
    @State private var isSending = false
    @State private var hasSubmitted = false
    @FocusState private var isTextFieldFocused: Bool

    private var placeholder: String {
        request.placeholder ?? "Send a message..."
    }

    private var isInputEmpty: Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if hasSubmitted {
            submittedFeedback
        } else {
            textField
                .padding(.vertical, 8)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Send") {
                                sendMessage()
                            }
                            .disabled(isInputEmpty || !isConnected)
                        }
                    }
                }
        }
    }

    private var textField: some View {
        TextField(placeholder, text: $inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(3...6)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .focused($isTextFieldFocused)
            .disabled(isSending || !isConnected)
            .accessibilityLabel(placeholder)
    }

    private var submittedFeedback: some View {
        HStack {
            Symbols.arrowUpCircleFill.image
                .foregroundStyle(.blue)
            Text("Prompt submitted")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true

        Task {
            await submitter.submit(
                hostID: hostID,
                sessionID: sessionID,
                pluginID: pluginID,
                requestID: requestID,
                response: .prompt(PromptResponse(text: trimmed))
            )
            inputText = ""
            isSending = false
            hasSubmitted = true
        }
    }
}

// MARK: - Preview

#Preview("Prompt View") {
    NavigationStack {
        List {
            Section("Response") {
                PromptView(
                    hostID: "host",
                    sessionID: "session",
                    pluginID: "claude-code",
                    requestID: "req-1",
                    request: PromptRequest(placeholder: "Send a message to Claude..."),
                    isConnected: true,
                    submitter: PreviewAgentResponseSubmitter()
                )
            }
        }
    }
}

// MARK: - Preview Helper

/// No-op submitter for previews. Lives next to PromptView so every response
/// view's preview can construct one cheaply.
@MainActor
final class PreviewAgentResponseSubmitter: AgentResponseSubmitter {
    func submit(
        hostID: String,
        sessionID: String,
        pluginID: String,
        requestID: String,
        response: AgentResponse
    ) async { }

    func dismiss(requestID: String) async { }
}
