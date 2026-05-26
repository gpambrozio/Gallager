import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Reply-after-stop form. Shows the agent's last assistant message (if any) as
/// a collapsible banner above a text input.
///
/// Submit semantics, per Spec §7.2.1:
/// - Tapping "Just Interrupt" sends an empty string — sidecar treats that as
///   "send nothing, just interrupt."
/// - Typing text and tapping "Send" submits the typed text.
struct StopResponseView: View {
    let hostID: String
    let sessionID: String
    let pluginID: String
    let requestID: String
    let request: ReplyAfterStopRequest
    let isConnected: Bool
    let submitter: AgentResponseSubmitter

    @State private var inputText = ""
    @State private var isSummaryExpanded = false
    @State private var isSending = false
    @State private var hasSubmitted = false
    @FocusState private var isTextFieldFocused: Bool

    private var isInputEmpty: Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = request.lastAssistantMessage {
                summarySection(message: message)
            }

            if hasSubmitted {
                submittedFeedback
            } else {
                inputSection
            }
        }
    }

    // MARK: - Summary

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

                (isSummaryExpanded ? Symbols.chevronUp.image : Symbols.chevronDown.image)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            // Note: onTapGesture (not Button) because Button + .buttonStyle(.plain)
            // doesn't respond to XCUITest synthetic touch events.
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSummaryExpanded.toggle()
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isSummaryExpanded ? "Collapse summary" : "Expand summary")

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(isSummaryExpanded ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("summary-text")
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(spacing: 8) {
            TextField("Reply...", text: $inputText, axis: .vertical)
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
                .accessibilityLabel("Reply to assistant")

            HStack(spacing: 12) {
                Button {
                    sendReply(text: "")
                } label: {
                    Label("Just Interrupt", symbol: .xmarkCircleFill)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .tint(.secondary)
                .disabled(!isConnected || isSending)

                Button {
                    sendReply(text: inputText.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    Label("Send", symbol: .arrowUpCircleFill)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .tint(.blue)
                .disabled(isInputEmpty || !isConnected || isSending)
            }

            if isSending {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var submittedFeedback: some View {
        HStack {
            Symbols.checkmarkCircleFill.image
                .foregroundStyle(.green)
            Text("Reply submitted")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    private func sendReply(text: String) {
        isSending = true

        Task {
            await submitter.submit(
                hostID: hostID,
                sessionID: sessionID,
                pluginID: pluginID,
                requestID: requestID,
                response: .replyAfterStop(ReplyAfterStopResponse(text: text))
            )
            inputText = ""
            isSending = false
            hasSubmitted = true
        }
    }
}

// MARK: - Preview

#Preview("Stop with summary") {
    NavigationStack {
        List {
            Section("Response") {
                StopResponseView(
                    hostID: "host",
                    sessionID: "session",
                    pluginID: "claude-code",
                    requestID: "req-1",
                    request: ReplyAfterStopRequest(
                        lastAssistantMessage:
                        "I've completed the refactoring of the authentication module. The changes include updating the JWT validation logic, adding refresh token support, and migrating the session store to use async/await patterns."
                    ),
                    isConnected: true,
                    submitter: PreviewAgentResponseSubmitter()
                )
            }
        }
    }
}

#Preview("Stop without summary") {
    NavigationStack {
        List {
            Section("Response") {
                StopResponseView(
                    hostID: "host",
                    sessionID: "session",
                    pluginID: "claude-code",
                    requestID: "req-1",
                    request: ReplyAfterStopRequest(lastAssistantMessage: nil),
                    isConnected: true,
                    submitter: PreviewAgentResponseSubmitter()
                )
            }
        }
    }
}
