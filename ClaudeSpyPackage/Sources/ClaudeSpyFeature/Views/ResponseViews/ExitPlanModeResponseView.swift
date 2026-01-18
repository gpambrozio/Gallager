import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

// MARK: - Exit Plan Mode Response View

/// Response view for ExitPlanMode that displays the plan and requested permissions.
struct ExitPlanModeResponseView: View {
    let params: ExitPlanModeParameters
    let isConnected: Bool
    let sendCommand: CommandSender
    let state: ResponseState

    @State private var isPlanExpanded = true

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
            // Header
            HStack {
                Symbols.listBulletClipboard.image
                    .foregroundStyle(.blue)
                Text("Plan Approval")
                    .font(.headline)
                Spacer()
            }

            // Allowed Prompts section
            if let prompts = params.allowedPrompts, !prompts.isEmpty {
                allowedPromptsSection(prompts)
            }

            // Plan section (collapsible)
            if let plan = params.plan, !plan.isEmpty {
                planSection(plan)
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

    // MARK: - Allowed Prompts

    private func allowedPromptsSection(_ prompts: [ExitPlanModeParameters.AllowedPrompt]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Requested Permissions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(prompts.enumerated()), id: \.offset) { _, prompt in
                promptRow(prompt)
            }
        }
    }

    private func promptRow(_ prompt: ExitPlanModeParameters.AllowedPrompt) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(prompt.tool)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.orange))

            Text(prompt.prompt)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
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

            // Approve button
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
        // Send "3" to approve the plan
        await sendCommand(.sendKeystroke([.text("3")]))
        state.isSending = false
        state.response = .accepted
    }

    private func rejectPlan() async {
        state.isSending = true
        // Send Escape to reject
        await sendCommand(.sendKeystroke([.escape]))
        state.isSending = false
        state.response = .rejected
    }
}

// MARK: - Preview Helpers

extension ExitPlanModeParameters {
    static var preview: ExitPlanModeParameters {
        ExitPlanModeParameters(
            plan: """
            # Implementation Plan

            ## Summary
            Implement a new feature for user authentication.

            ## Steps
            1. Add login screen
            2. Implement OAuth flow
            3. Store tokens securely
            4. Add logout functionality

            ## Files to modify
            - `AuthService.swift`
            - `LoginView.swift`
            - `AppCoordinator.swift`
            """,
            allowedPrompts: [
                ExitPlanModeParameters.AllowedPrompt(tool: "Bash", prompt: "build iOS target"),
                ExitPlanModeParameters.AllowedPrompt(tool: "Bash", prompt: "run tests"),
                ExitPlanModeParameters.AllowedPrompt(tool: "Bash", prompt: "install dependencies"),
            ]
        )
    }

    static var previewPromptsOnly: ExitPlanModeParameters {
        ExitPlanModeParameters(
            plan: nil,
            allowedPrompts: [
                ExitPlanModeParameters.AllowedPrompt(tool: "Bash", prompt: "build the project"),
                ExitPlanModeParameters.AllowedPrompt(tool: "Bash", prompt: "run unit tests"),
            ]
        )
    }
}

// MARK: - Previews

#Preview("Exit Plan Mode") {
    let params = ExitPlanModeParameters.preview
    let event = HookEvent(
        action: .permissionRequest(PermissionRequestBody(
            sessionId: "test-session",
            hookEventName: "PermissionRequest",
            toolName: "ExitPlanMode",
            toolInput: .exitPlanMode(params)
        )),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return NavigationStack {
        List {
            Section("Plan Approval") {
                ExitPlanModeResponseView(
                    params: params,
                    isConnected: true,
                    sendCommand: { _ in },
                    state: state
                )
            }
        }
    }
}

#Preview("Exit Plan Mode - Prompts Only") {
    let params = ExitPlanModeParameters.previewPromptsOnly
    let event = HookEvent(
        action: .permissionRequest(PermissionRequestBody(
            sessionId: "test-session",
            hookEventName: "PermissionRequest",
            toolName: "ExitPlanMode",
            toolInput: .exitPlanMode(params)
        )),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return NavigationStack {
        List {
            Section("Plan Approval") {
                ExitPlanModeResponseView(
                    params: params,
                    isConnected: true,
                    sendCommand: { _ in },
                    state: state
                )
            }
        }
    }
}
