import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Response view for the "agent stopped" case. Shows the agent's last message as
/// a collapsible summary above a reply field. Submits `AgentResponse.replyAfterStop`
/// (an empty reply means "send nothing, just interrupt" — spec §7.1).
struct StopResponseView: View {
    let request: ReplyAfterStopRequest
    let isConnected: Bool
    let submit: ResponseSender
    let state: ResponseState

    @State private var inputText = ""
    @FocusState private var isTextFieldFocused: Bool

    private var placeholder: String {
        request.placeholder ?? "Reply to the agent..."
    }

    var body: some View {
        if let response = state.response {
            responseFeedback(response)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let message = request.summary {
                    summarySection(message: message)
                }
                replyField
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if state.isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Send") {
                            sendReply()
                        }
                        .disabled(!isConnected)
                    }
                }
            }
        }
    }

    private var replyField: some View {
        TextField(placeholder, text: $inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(3...6)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.3), lineWidth: 1))
            .focused($isTextFieldFocused)
            .disabled(state.isSending || !isConnected)
            .accessibilityLabel(placeholder)
    }

    private func summarySection(message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Symbols.sparkles.image
                    .font(.caption)
                    .foregroundStyle(.purple)

                Text("Summary")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                (state.isSummaryExpanded ? Symbols.chevronUp.image : Symbols.chevronDown.image)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            // Note: Using onTapGesture instead of Button because .buttonStyle(.plain)
            // doesn't respond to XCUITest runner's synthetic touch events in E2E tests.
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    state.isSummaryExpanded.toggle()
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(state.isSummaryExpanded ? "Collapse summary" : "Expand summary")

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(state.isSummaryExpanded ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("summary-text")
        }
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

    private func sendReply() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.isSending = true
        Task {
            await submit(.replyAfterStop(text: trimmed))
            inputText = ""
            state.isSending = false
            state.response = .promptSubmitted
        }
    }
}

// MARK: - Preview

#Preview("Stop with summary") {
    let request = ReplyAfterStopRequest(
        title: "Claude is waiting",
        summary: "I've completed the refactoring of the authentication module."
    )
    let state = ResponseState(
        request: .replyAfterStop(request),
        pluginID: "claude-code",
        requestID: "test:stop"
    )

    return NavigationStack {
        List {
            Section("Response") {
                StopResponseView(
                    request: request,
                    isConnected: true,
                    submit: { _ in },
                    state: state
                )
            }
        }
    }
}
