import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Plan approval form. Renders the plan text from the sidecar; if
/// `request.allowEdit` is `true`, exposes an editable text area so the user
/// can tweak the plan before approving. On submit, emits
/// `ApprovePlanResponse` — sidecar applies the agent-specific delivery.
struct ExitPlanModeResponseView: View {
    let hostID: String
    let sessionID: String
    let pluginID: String
    let requestID: String
    let request: ApprovePlanRequest
    let isConnected: Bool
    let submitter: AgentResponseSubmitter

    @State private var isPlanExpanded = true
    @State private var editedPlan = ""
    @State private var isSending = false
    @State private var feedback: Feedback?

    private enum Feedback: Equatable {
        case approved
        case rejected
    }

    private var canEdit: Bool { request.allowEdit }

    var body: some View {
        if let feedback {
            feedbackRow(feedback)
        } else {
            planContent
                .task {
                    if editedPlan.isEmpty { editedPlan = request.plan }
                }
        }
    }

    private var planContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Symbols.listBulletClipboard.image
                    .foregroundStyle(.blue)
                Text("Plan Approval")
                    .font(.headline)
                Spacer()
            }

            planSection

            actionButtons

            if isSending {
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

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPlanExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(canEdit ? "Implementation Plan (editable)" : "Implementation Plan")
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
                if canEdit {
                    TextEditor(text: $editedPlan)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 200, maxHeight: 400)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
                } else {
                    ScrollView {
                        Text(request.plan)
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
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                submit(decision: .reject)
            } label: {
                Label("Reject", symbol: .xmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.red)
            .disabled(!isConnected || isSending)

            Button {
                submit(decision: .approve)
            } label: {
                Label("Approve", symbol: .checkmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.green)
            .disabled(!isConnected || isSending)
        }
    }

    private func feedbackRow(_ feedback: Feedback) -> some View {
        HStack {
            switch feedback {
            case .approved:
                Symbols.checkmarkCircleFill.image
                    .foregroundStyle(.green)
                Text("Plan approved")
                    .foregroundStyle(.secondary)
            case .rejected:
                Symbols.xmarkCircleFill.image
                    .foregroundStyle(.red)
                Text("Plan rejected")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    // MARK: - Submit

    private func submit(decision: ApprovePlanResponse.Decision) {
        isSending = true

        // Per Spec §7.2.1, `editedPlan` is only present when `allowEdit` is
        // true AND the user actually changed the plan. On reject, never send
        // the edited plan — the sidecar would have no use for it.
        let edited: String?
        if decision == .approve, canEdit, editedPlan != request.plan {
            edited = editedPlan
        } else {
            edited = nil
        }

        Task {
            await submitter.submit(
                hostID: hostID,
                sessionID: sessionID,
                pluginID: pluginID,
                requestID: requestID,
                response: .approvePlan(
                    ApprovePlanResponse(decision: decision, editedPlan: edited)
                )
            )
            isSending = false
            feedback = decision == .approve ? .approved : .rejected
        }
    }
}

// MARK: - Previews

#Preview("Exit Plan Mode - read-only") {
    NavigationStack {
        List {
            Section("Plan Approval") {
                ExitPlanModeResponseView(
                    hostID: "host",
                    sessionID: "session",
                    pluginID: "claude-code",
                    requestID: "req-1",
                    request: ApprovePlanRequest(
                        plan: """
                        # Implementation Plan

                        ## Summary
                        Add a login screen and OAuth flow.

                        ## Steps
                        1. Add login screen
                        2. Implement OAuth flow
                        3. Store tokens in Keychain
                        4. Add logout functionality
                        """,
                        allowEdit: false
                    ),
                    isConnected: true,
                    submitter: PreviewAgentResponseSubmitter()
                )
            }
        }
    }
}

#Preview("Exit Plan Mode - editable") {
    NavigationStack {
        List {
            Section("Plan Approval") {
                ExitPlanModeResponseView(
                    hostID: "host",
                    sessionID: "session",
                    pluginID: "claude-code",
                    requestID: "req-1",
                    request: ApprovePlanRequest(
                        plan: """
                        # Implementation Plan
                        1. Add login screen
                        2. Implement OAuth flow
                        """,
                        allowEdit: true
                    ),
                    isConnected: true,
                    submitter: PreviewAgentResponseSubmitter()
                )
            }
        }
    }
}
