import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Free-text input view for sending a prompt to the agent. Renders from a
/// `PromptRequest` and submits a structured `AgentResponse.prompt` (spec §7.1).
struct PromptView: View {
    let request: PromptRequest
    let isConnected: Bool
    let submit: ResponseSender
    let state: ResponseState

    @State private var inputText = ""
    @FocusState private var isTextFieldFocused: Bool

    private var isInputEmpty: Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var placeholder: String {
        request.placeholder ?? "Send a message..."
    }

    var body: some View {
        if let response = state.response {
            responseFeedback(response)
        } else {
            textField
                .padding(.vertical, 8)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        if state.isSending {
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
            .background(textFieldBackground)
            .overlay(textFieldBorder)
            .focused($isTextFieldFocused)
            .disabled(state.isSending || !isConnected)
            .accessibilityLabel(placeholder)
    }

    private var textFieldBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.1))
    }

    private var textFieldBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
    }

    private func responseFeedback(_ response: ResponseType) -> some View {
        HStack {
            (
                response.feedbackColor == .green ? Symbols.checkmarkCircleFill.image :
                    response.feedbackColor == .red ? Symbols.xmarkCircleFill.image : Symbols.arrowUpCircleFill.image
            )
            .foregroundStyle(response.feedbackColor)
            Text(response.feedbackMessage)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        state.isSending = true

        Task {
            await submit(.prompt(text: trimmed))
            inputText = ""
            state.isSending = false
            state.response = .promptSubmitted
        }
    }
}

// MARK: - Preview

#Preview("Prompt View") {
    let state = ResponseState(
        request: .prompt(PromptRequest(title: "Send a message to Claude")),
        pluginID: "claude-code",
        requestID: "test:prompt"
    )

    return NavigationStack {
        List {
            Section("Response") {
                PromptView(
                    request: PromptRequest(title: "Send a message to Claude"),
                    isConnected: true,
                    submit: { _ in },
                    state: state
                )
            }
        }
    }
}
