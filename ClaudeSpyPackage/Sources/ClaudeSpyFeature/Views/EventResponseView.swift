import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Closure type for sending commands from response views.
/// Takes a CommandType directly - SessionDetailView adds the paneId when sending.
typealias CommandSender = @MainActor (CommandType) async -> Void

// MARK: - Event Response Extension

extension HookEvent {
    /// Returns a contextual response view based on the event type, or nil if no response UI is needed.
    @MainActor @ViewBuilder
    func responseView(
        isConnected: Bool,
        sendCommand: @escaping CommandSender
    ) -> some View {
        switch action {
        case let .notification(body) where body.notificationType == "idle_prompt":
            IdleEventResponseView(isConnected: isConnected, sendCommand: sendCommand)
        case let .permissionRequest(body):
            PermissionRequestResponseView(
                request: body,
                isConnected: isConnected,
                sendCommand: sendCommand
            )
        default:
            EmptyView()
        }
    }

    /// Whether this event type has a response view
    var hasResponseView: Bool {
        switch action {
        case let .notification(body):
            body.notificationType == "idle_prompt"
        case .permissionRequest:
            true
        default:
            false
        }
    }
}

// MARK: - Idle Event Response View

/// Text input view shown when Claude is idle, allowing the user to send a prompt.
struct IdleEventResponseView: View {
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

/// Accept/Reject buttons for permission requests.
struct PermissionRequestResponseView: View {
    let request: PermissionRequestBody
    let isConnected: Bool
    let sendCommand: CommandSender

    @State private var isSending = false

    var body: some View {
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

            // Accept/Reject buttons
            HStack(spacing: 16) {
                Button {
                    Task {
                        await sendResponse("n")
                    }
                } label: {
                    Label("Reject", symbol: .xmarkCircleFill)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!isConnected || isSending)

                Button {
                    Task {
                        await sendResponse("y")
                    }
                } label: {
                    Label("Accept", symbol: .checkmarkCircleFill)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!isConnected || isSending)
            }

            if isSending {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }

    private func sendResponse(_ text: String) async {
        isSending = true
        await sendCommand(.sendKeystroke([.text(text), .enter]))
        isSending = false
    }
}

#Preview("Idle Event") {
    List {
        Section("Response") {
            IdleEventResponseView(
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
}
