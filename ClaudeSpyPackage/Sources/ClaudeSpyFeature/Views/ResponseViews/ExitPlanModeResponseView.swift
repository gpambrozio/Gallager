import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

// MARK: - Exit Plan Mode Response View

struct ExitPlanModeResponseView: View {
    let isConnected: Bool
    let sendCommand: CommandSender
    let state: ResponseState

    var body: some View {
        if let response = state.response {
            if case .rejected = response {
                VStack(spacing: 12) {
                    responseFeedback(response)
                    PromptView(isConnected: isConnected, sendCommand: sendCommand, state: state)
                }
            } else {
                responseFeedback(response)
            }
        } else {
            planContent
        }
    }

    // MARK: - Response Feedback

    private func responseFeedback(_ response: ResponseType) -> some View {
        HStack {
            (response.feedbackColor == .green ? Symbols.checkmarkCircleFill.image :
                response.feedbackColor == .red ? Symbols.xmarkCircleFill.image : Symbols.arrowUpCircleFill.image)
                .foregroundStyle(response.feedbackColor)
            Text(response.feedbackMessage)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    // MARK: - Plan Content

    private var planContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Symbols.listBulletClipboard.image
                    .foregroundStyle(.blue)
                Text("Plan Approval")
                    .font(.headline)
                Spacer()
            }

            actionButtons

            if state.isSending {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Sending...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await rejectPlan()
                }
            } label: {
                Label("Reject", symbol: .xmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.red)
            .disabled(!isConnected || state.isSending)

            Button {
                Task {
                    await approvePlan()
                }
            } label: {
                Label("Approve", symbol: .checkmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.green)
            .disabled(!isConnected || state.isSending)
        }
    }

    // MARK: - Actions

    private func approvePlan() async {
        state.isSending = true
        await sendCommand(.sendKeystroke([.text("3")]))
        state.isSending = false
        state.response = .accepted
    }

    private func rejectPlan() async {
        state.isSending = true
        await sendCommand(.sendKeystroke([.escape]))
        state.isSending = false
        state.response = .rejected
    }
}

// MARK: - Previews

#Preview("Exit Plan Mode") {
    let event = HookEvent(
        action: .permissionRequest(PermissionRequestBody(
            sessionId: "test-session",
            hookEventName: "PermissionRequest",
            toolName: "ExitPlanMode",
            toolInput: .exitPlanMode
        )),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return NavigationStack {
        List {
            Section("Plan Approval") {
                ExitPlanModeResponseView(
                    isConnected: true,
                    sendCommand: { _ in },
                    state: state
                )
            }
        }
    }
}
