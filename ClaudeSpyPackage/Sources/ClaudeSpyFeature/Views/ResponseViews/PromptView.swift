import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Text input view for sending messages to Claude.
struct PromptView: View {
    let isConnected: Bool
    let sendCommand: CommandSender
    let state: ResponseState

    @State private var inputText = ""
    @FocusState private var isTextFieldFocused: Bool

    private var isInputEmpty: Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
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

    private var textField: some View {
        TextField("Send a message to Claude...", text: $inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(3...6)
            .padding(12)
            .background(textFieldBackground)
            .overlay(textFieldBorder)
            .focused($isTextFieldFocused)
            .disabled(state.isSending || !isConnected)
    }

    private var textFieldBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.1))
    }

    private var textFieldBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        state.isSending = true

        Task {
            await sendCommand(.sendKeystroke([.text(trimmed), .enter]))
            inputText = ""
            state.isSending = false
        }
    }
}

// MARK: - Preview

#Preview("Prompt View") {
    let event = HookEvent(
        action: .sessionStart(SessionStartBody(sessionId: "test", hookEventName: "SessionStart")),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return NavigationStack {
        List {
            Section("Response") {
                PromptView(
                    isConnected: true,
                    sendCommand: { _ in },
                    state: state
                )
            }
        }
    }
}
