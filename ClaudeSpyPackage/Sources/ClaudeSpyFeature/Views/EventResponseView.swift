import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Closure type for sending commands from response views.
/// Takes a CommandType directly - SessionDetailView adds the paneId when sending.
typealias CommandSender = @MainActor (CommandType) async -> Void

// MARK: - Event Response Extension

extension HookEvent {
    /// Returns a contextual response view based on the event type, or nil if no response UI is needed.
    @MainActor
    func responseView(
        isConnected: Bool,
        sendCommand: @escaping CommandSender
    ) -> AnyView? {
        switch action {
        case .sessionStart, .stop:
            AnyView(PromptView(isConnected: isConnected, sendCommand: sendCommand))
        case let .notification(body) where body.notificationType == "idle_prompt":
            AnyView(PromptView(isConnected: isConnected, sendCommand: sendCommand))
        case let .permissionRequest(body):
            AnyView(PermissionRequestResponseView(
                request: body,
                isConnected: isConnected,
                sendCommand: sendCommand
            ))
        default:
            nil
        }
    }
}

// MARK: - Prompt View

/// Text input view for sending messages to Claude.
struct PromptView: View {
    let isConnected: Bool
    let sendCommand: CommandSender

    @State private var inputText = ""
    @State private var isSending = false
    @FocusState private var isTextFieldFocused: Bool

    private var isInputEmpty: Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 12) {
            textField
            sendButtonRow
        }
        .padding(.vertical, 8)
    }

    private var textField: some View {
        TextField("Send a message to Claude...", text: $inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(3...6)
            .padding(12)
            .background(textFieldBackground)
            .overlay(textFieldBorder)
            .focused($isTextFieldFocused)
            .disabled(isSending || !isConnected)
    }

    private var textFieldBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.1))
    }

    private var textFieldBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
    }

    private var sendButtonRow: some View {
        HStack {
            Spacer()
            Button {
                sendMessage()
            } label: {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Send")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isInputEmpty || isSending || !isConnected)
        }
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true

        Task {
            await sendCommand(.sendKeystroke([.text(trimmed), .enter]))
            inputText = ""
            isSending = false
        }
    }
}

// MARK: - Permission Request Response View

/// Accept/Reject buttons with permission suggestions for permission requests.
struct PermissionRequestResponseView: View {
    let request: PermissionRequestBody
    let isConnected: Bool
    let sendCommand: CommandSender

    @State private var isSending = false
    @State private var customInstructions = ""
    @State private var didReject = false
    @State private var didRespond = false
    @FocusState private var isTextFieldFocused: Bool

    private var suggestions: [PermissionSuggestion] {
        request.permissionSuggestions ?? []
    }

    private var isInputEmpty: Bool {
        customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if didRespond {
            EmptyView()
        } else if didReject {
            PromptView(isConnected: isConnected, sendCommand: sendCommand)
        } else {
            permissionContent
        }
    }

    private var permissionContent: some View {
        VStack(spacing: 12) {
            // Show what's being requested
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

            // Accept button
            Button {
                Task {
                    await sendResponse(.sendKeystroke([.text("1")]))
                    didRespond = true
                }
            } label: {
                Label("Accept", symbol: .checkmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.green)
            .disabled(!isConnected || isSending)

            // Permission suggestions (single combined button)
            if !suggestions.isEmpty {
                combinedSuggestionsButton
            }

            // Reject button
            Button {
                Task {
                    await sendResponse(.sendKeystroke([.escape]))
                    didReject = true
                }
            } label: {
                Label("Reject", symbol: .xmarkCircleFill)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(.red)
            .disabled(!isConnected || isSending)

            // Custom instructions text area
            VStack(spacing: 8) {
                TextField("Custom instructions...", text: $customInstructions, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(textFieldBackground)
                    .overlay(textFieldBorder)
                    .focused($isTextFieldFocused)
                    .disabled(isSending || !isConnected)

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
                        .disabled(isInputEmpty || isSending || !isConnected)
                    }
                }
            }

            if isSending {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }

    private var combinedSuggestionsButton: some View {
        Button {
            Task {
                // Send "2" to select the first suggestion option
                await sendResponse(.sendKeystroke([.text("2")]))
                didRespond = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Accept Suggestion:")
                    .fontWeight(.medium)
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    HStack {
                        Text("\(index + 2).")
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(suggestionLabel(for: suggestion))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .tint(.blue)
        .disabled(!isConnected || isSending)
    }

    private func suggestionLabel(for suggestion: PermissionSuggestion) -> String {
        // Build a descriptive label from the suggestion
        var parts: [String] = []

        if let type = suggestion.type {
            parts.append(type)
        }

        if let rules = suggestion.rules, !rules.isEmpty {
            let ruleDescriptions = rules.compactMap { rule -> String? in
                rule.ruleContent ?? rule.toolName
            }
            if !ruleDescriptions.isEmpty {
                parts.append(contentsOf: ruleDescriptions)
            }
        }

        if let behavior = suggestion.behavior {
            parts.append(behavior)
        }

        if let destination = suggestion.destination {
            parts.append("→ \(destination)")
        }

        return parts.isEmpty ? (suggestion.type?.capitalized ?? "Option") : parts.joined(separator: " ")
    }

    private var textFieldBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.1))
    }

    private var textFieldBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
    }

    private func sendResponse(_ command: CommandType) async {
        isSending = true
        await sendCommand(command)
        isSending = false
    }

    private func sendCustomInstructions() async {
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let optionNumber = suggestions.isEmpty ? 2 : 3
        isSending = true
        await sendCommand(.sendKeystroke([.text("\(optionNumber)"), .text(trimmed), .enter]))
        customInstructions = ""
        isSending = false
        didRespond = true
    }
}

#Preview("Prompt View") {
    List {
        Section("Response") {
            PromptView(
                isConnected: true,
                sendCommand: { _ in }
            )
        }
    }
}

#Preview("Permission Request") {
    List {
        Section("Response") {
            PermissionRequestResponseView(
                request: PermissionRequestBody.preview,
                isConnected: true,
                sendCommand: { _ in }
            )
        }
    }
}

#Preview("Permission Request with Suggestions") {
    List {
        Section("Response") {
            PermissionRequestResponseView(
                request: PermissionRequestBody.previewWithSuggestions,
                isConnected: true,
                sendCommand: { _ in }
            )
        }
    }
}

// MARK: - Preview Helpers

extension PermissionRequestBody {
    static var preview: PermissionRequestBody {
        try! JSONDecoder().decode(
            PermissionRequestBody.self,
            from: """
            {
                "session_id": "test-session",
                "hook_event_name": "PermissionRequest",
                "tool_name": "Bash"
            }
            """.data(using: .utf8)!
        )
    }

    static var previewWithSuggestions: PermissionRequestBody {
        try! JSONDecoder().decode(
            PermissionRequestBody.self,
            from: """
            {
                "session_id": "test-session",
                "hook_event_name": "PermissionRequest",
                "tool_name": "Bash",
                "permission_suggestions": [
                    {
                        "type": "allow_once",
                        "behavior": "Allow this command once"
                    },
                    {
                        "type": "allow_session",
                        "rules": [
                            {
                                "toolName": "Bash",
                                "ruleContent": "git status"
                            }
                        ],
                        "behavior": "Allow for this session"
                    },
                    {
                        "type": "allow_always",
                        "rules": [
                            {
                                "toolName": "Bash",
                                "ruleContent": "git *"
                            }
                        ],
                        "destination": "project"
                    }
                ]
            }
            """.data(using: .utf8)!
        )
    }
}
