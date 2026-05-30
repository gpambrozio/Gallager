import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

// MARK: - Permission Request Response View

/// Accept/Reject buttons with agent-blind suggestion chips for a permission
/// request. Renders from the closed `PermissionRequest` (the core formats all
/// display strings) and submits a structured `AgentResponse.permission`; iOS
/// never builds agent keystrokes (spec §7.1).
struct PermissionRequestResponseView: View {
    let request: PermissionRequest
    let isConnected: Bool
    let submit: ResponseSender
    let state: ResponseState

    @State private var customInstructions = ""
    @FocusState private var isTextFieldFocused: Bool

    private var suggestions: [PermissionSuggestionOption] {
        request.suggestions
    }

    private var isInputEmpty: Bool {
        customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if let response = state.response {
            if case .rejected = response {
                VStack(spacing: 12) {
                    responseFeedback(response)
                }
            } else {
                responseFeedback(response)
            }
        } else {
            permissionContent
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

    // MARK: - Permission Content

    private var permissionContent: some View {
        VStack(spacing: 12) {
            // Tool request card (display strings formatted Mac-side)
            toolRequestCard

            // Side-by-side action buttons
            actionButtonRow

            // Permission suggestions card (if any)
            if !suggestions.isEmpty {
                suggestionCard
            }

            // Custom instructions
            if request.allowsCustomInstructions {
                customInstructionsSection
            }

            if state.isSending {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Tool Request Card

    private var toolRequestCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(request.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            if !request.description.isEmpty {
                Text(request.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
    }

    // MARK: - Action Buttons

    private var actionButtonRow: some View {
        HStack(spacing: 12) {
            // Reject button (left)
            Button {
                Task {
                    state.isSending = true
                    await submit(.permission(decision: .deny, appliedSuggestionID: nil))
                    state.isSending = false
                    state.response = .rejected
                }
            } label: {
                Label("Reject", symbol: .xmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.red)
            .disabled(!isConnected || state.isSending)

            // Accept button (right)
            Button {
                Task {
                    state.isSending = true
                    await submit(.permission(decision: .allow, appliedSuggestionID: nil))
                    state.isSending = false
                    state.response = .accepted
                }
            } label: {
                Label("Accept", symbol: .checkmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.green)
            .disabled(!isConnected || state.isSending)
        }
    }

    // MARK: - Suggestion Card

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 6) {
                Symbols.lockFill.image
                    .foregroundStyle(.blue)
                Text("Save Permission Rule")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            ForEach(suggestions) { suggestion in
                SuggestionRow(suggestion: suggestion) {
                    Task {
                        state.isSending = true
                        await submit(.permission(decision: .allow, appliedSuggestionID: suggestion.id))
                        state.isSending = false
                        state.response = .acceptedWithSuggestion
                    }
                }
                .disabled(!isConnected || state.isSending)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Custom Instructions

    private var customInstructionsSection: some View {
        VStack(spacing: 8) {
            TextField("Custom instructions...", text: $customInstructions, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .focused($isTextFieldFocused)
                .disabled(state.isSending || !isConnected)

            if !isInputEmpty {
                HStack {
                    Spacer()
                    Button {
                        Task {
                            await sendCustomInstructions()
                        }
                    } label: {
                        Text("Send")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInputEmpty || state.isSending || !isConnected)
                }
            }
        }
    }

    private func sendCustomInstructions() async {
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        state.isSending = true
        await submit(.permission(decision: .denyWithFeedback(trimmed), appliedSuggestionID: nil))
        let sentText = customInstructions
        customInstructions = ""
        state.isSending = false
        state.response = .customInstructions(sentText)
    }
}

// MARK: - Suggestion Row

private struct SuggestionRow: View {
    let suggestion: PermissionSuggestionOption
    let apply: () -> Void

    var body: some View {
        Button(action: apply) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(suggestion.label)
                        .font(.subheadline)
                    Spacer()
                    Symbols.checkmarkCircle.image
                        .foregroundStyle(.blue)
                }
                if let detail = suggestion.detail {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview("Permission Request") {
    let request = PermissionRequest(
        title: "Bash",
        description: "swift build --verbose",
        suggestions: [
            PermissionSuggestionOption(id: "suggestion-0", label: "Allow for this session", detail: "Bash swift build"),
        ],
        allowsCustomInstructions: true
    )
    let state = ResponseState(
        request: .permission(request),
        pluginID: "claude-code",
        requestID: "test:perm"
    )

    return NavigationStack {
        List {
            Section("Response") {
                PermissionRequestResponseView(
                    request: request,
                    isConnected: true,
                    submit: { _ in },
                    state: state
                )
            }
        }
    }
}
