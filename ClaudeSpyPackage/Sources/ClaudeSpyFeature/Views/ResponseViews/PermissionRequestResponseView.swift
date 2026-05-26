import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Permission approval form. Shows the plain-text description rendered by the
/// plugin sidecar and renders one button per `PermissionRequest.Suggestion`
/// plus a hard "Deny" button.
///
/// Allow buttons emit `.permission(.allow, appliedSuggestionId: <id>)`. The
/// "Deny" button emits `.permission(.deny, appliedSuggestionId: nil)`. iOS
/// never knows what the suggestion means — it round-trips the `id` back to the
/// sidecar, which applies the agent-specific behavior.
struct PermissionRequestResponseView: View {
    let hostID: String
    let sessionID: String
    let pluginID: String
    let requestID: String
    let request: PermissionRequest
    let isConnected: Bool
    let submitter: AgentResponseSubmitter

    @State private var isSending = false
    @State private var feedback: Feedback?

    private enum Feedback: Equatable {
        case allowed(suggestionID: String?)
        case denied
    }

    var body: some View {
        if let feedback {
            feedbackRow(feedback)
        } else {
            permissionContent
        }
    }

    // MARK: - Permission Content

    private var permissionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolRequestCard

            descriptionCard

            // Side-by-side Allow / Deny default actions.
            actionButtonRow

            // Per-suggestion buttons (e.g. "Always allow", "Allow once").
            if !request.suggestions.isEmpty {
                suggestionStack
            }

            if isSending {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var toolRequestCard: some View {
        Group {
            if let toolName = request.toolName {
                HStack {
                    Text("Tool:")
                        .foregroundStyle(.secondary)
                    Text(toolName)
                        .fontWeight(.medium)
                    Spacer()
                }
                .font(.subheadline)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
    }

    private var descriptionCard: some View {
        Text(request.description)
            .font(.callout)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            .textSelection(.enabled)
    }

    private var actionButtonRow: some View {
        HStack(spacing: 12) {
            // Deny (left).
            Button {
                submit(decision: .deny, suggestionID: nil)
            } label: {
                Label("Deny", symbol: .xmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.red)
            .disabled(!isConnected || isSending)

            // Allow (right). Submits with no specific suggestion id; the
            // sidecar decides the agent-side mapping for "plain allow".
            Button {
                submit(decision: .allow, suggestionID: nil)
            } label: {
                Label("Allow", symbol: .checkmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.green)
            .disabled(!isConnected || isSending)
        }
    }

    private var suggestionStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Symbols.lockFill.image
                    .foregroundStyle(.blue)
                Text("Save Permission Rule")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            ForEach(request.suggestions, id: \.id) { suggestion in
                Button {
                    submit(decision: .allow, suggestionID: suggestion.id)
                } label: {
                    HStack(spacing: 8) {
                        if let badge = suggestion.badge {
                            Text(badge.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.blue))
                        }
                        Text(suggestion.label)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .tint(.blue)
                .disabled(!isConnected || isSending)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Feedback

    private func feedbackRow(_ feedback: Feedback) -> some View {
        HStack {
            switch feedback {
            case .allowed:
                Symbols.checkmarkCircleFill.image
                    .foregroundStyle(.green)
                Text("Allowed")
                    .foregroundStyle(.secondary)
            case .denied:
                Symbols.xmarkCircleFill.image
                    .foregroundStyle(.red)
                Text("Denied")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func submit(decision: PermissionResponse.Decision, suggestionID: String?) {
        isSending = true

        Task {
            await submitter.submit(
                hostID: hostID,
                sessionID: sessionID,
                pluginID: pluginID,
                requestID: requestID,
                response: .permission(
                    PermissionResponse(decision: decision, appliedSuggestionId: suggestionID)
                )
            )
            isSending = false
            feedback = decision == .allow ? .allowed(suggestionID: suggestionID) : .denied
        }
    }
}

// MARK: - Previews

#Preview("Permission Request - no suggestions") {
    NavigationStack {
        List {
            Section("Response") {
                PermissionRequestResponseView(
                    hostID: "host",
                    sessionID: "session",
                    pluginID: "claude-code",
                    requestID: "req-1",
                    request: PermissionRequest(
                        toolName: "Bash",
                        description: "Run `swift compile --verbose --enable-testing` to compile the project.",
                        suggestions: [],
                        isAutoApprovable: false
                    ),
                    isConnected: true,
                    submitter: PreviewAgentResponseSubmitter()
                )
            }
        }
    }
}

#Preview("Permission Request - with suggestions") {
    NavigationStack {
        List {
            Section("Response") {
                PermissionRequestResponseView(
                    hostID: "host",
                    sessionID: "session",
                    pluginID: "claude-code",
                    requestID: "req-1",
                    request: PermissionRequest(
                        toolName: "Bash",
                        description: "Run `git status` to check the current branch state.",
                        suggestions: [
                            PermissionRequest.Suggestion(
                                id: "session-once",
                                label: "Allow once",
                                badge: "THIS SESSION"
                            ),
                            PermissionRequest.Suggestion(
                                id: "always",
                                label: "Always allow `git status`",
                                badge: "ALWAYS"
                            ),
                        ],
                        isAutoApprovable: false
                    ),
                    isConnected: true,
                    submitter: PreviewAgentResponseSubmitter()
                )
            }
        }
    }
}
