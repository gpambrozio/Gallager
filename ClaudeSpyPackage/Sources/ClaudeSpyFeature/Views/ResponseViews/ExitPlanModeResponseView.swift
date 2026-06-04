import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

// MARK: - Approve Plan Response View

/// Response view for a plan-approval request. Displays the plan (markdown,
/// collapsible) and Approve / Reject actions, submitting a structured
/// `AgentResponse.approvePlan` (spec §7.1). The plan text is formatted Mac-side.
struct ExitPlanModeResponseView: View {
    let request: ApprovePlanRequest
    let isConnected: Bool
    let submit: ResponseSender
    let state: ResponseState

    @State private var isPlanExpanded = true

    var body: some View {
        if let response = state.response {
            responseFeedback(response)
        } else {
            planContent
        }
    }

    // MARK: - Response Feedback

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

    // MARK: - Plan Content

    private var planContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Symbols.listBulletClipboard.image
                    .foregroundStyle(.blue)
                Text(request.title)
                    .font(.headline)
                Spacer()
            }

            // Plan section (collapsible)
            if !request.plan.isEmpty {
                planSection(request.plan)
            }

            // Action buttons
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

    // MARK: - Plan Section

    private func planSection(_ plan: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPlanExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Implementation Plan")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    (isPlanExpanded ? Symbols.chevronUp.image : Symbols.chevronDown.image)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)

            if isPlanExpanded {
                ScrollView {
                    Text(plan)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 300)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Reject button
            Button {
                Task {
                    await respond(.reject)
                }
            } label: {
                Label("Reject", symbol: .xmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.red)
            .disabled(!isConnected || state.isSending)

            // Approve button
            Button {
                Task {
                    await respond(.approve)
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

    private func respond(_ decision: PlanDecision) async {
        state.isSending = true
        await submit(.approvePlan(decision: decision, editedPlan: nil))
        state.isSending = false
        state.response = decision == .approve ? .accepted : .rejected
    }
}

// MARK: - Previews

#Preview("Approve Plan") {
    let request = ApprovePlanRequest(
        title: "Plan Approval",
        plan: """
        # Implementation Plan

        ## Steps
        1. Add login screen
        2. Implement OAuth flow
        """
    )
    let state = ResponseState(
        request: .approvePlan(request),
        pluginID: "claude-code",
        requestID: "test:plan"
    )

    return NavigationStack {
        List {
            Section("Plan Approval") {
                ExitPlanModeResponseView(
                    request: request,
                    isConnected: true,
                    submit: { _ in },
                    state: state
                )
            }
        }
    }
}
