import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Response view for stop events that shows Claude's last assistant message
/// as a summary above the prompt input.
struct StopResponseView: View {
    let lastAssistantMessage: String?
    let isConnected: Bool
    let sendCommand: CommandSender
    let state: ResponseState

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = lastAssistantMessage {
                summarySection(message: message)
            }

            PromptView(isConnected: isConnected, sendCommand: sendCommand, state: state)
        }
    }

    private func summarySection(message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Symbols.sparkles.image
                        .font(.caption)
                        .foregroundStyle(.purple)

                    Text("Summary")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    Spacer()

                    (isExpanded ? Symbols.chevronUp.image : Symbols.chevronDown.image)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse summary" : "Expand summary")

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Preview

#Preview("Stop with summary") {
    let event = HookEvent(
        action: .stop(StopBody(
            sessionId: "test",
            hookEventName: "Stop",
            lastAssistantMessage: "I've completed the refactoring of the authentication module. The changes include: updating the JWT validation logic, adding refresh token support, and migrating the session store to use async/await patterns."
        )),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return NavigationStack {
        List {
            Section("Response") {
                StopResponseView(
                    lastAssistantMessage: "I've completed the refactoring of the authentication module. The changes include: updating the JWT validation logic, adding refresh token support, and migrating the session store to use async/await patterns.",
                    isConnected: true,
                    sendCommand: { _ in },
                    state: state
                )
            }
        }
    }
}

#Preview("Stop without summary") {
    let event = HookEvent(
        action: .stop(StopBody(
            sessionId: "test",
            hookEventName: "Stop",
            lastAssistantMessage: nil
        )),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return NavigationStack {
        List {
            Section("Response") {
                StopResponseView(
                    lastAssistantMessage: nil,
                    isConnected: true,
                    sendCommand: { _ in },
                    state: state
                )
            }
        }
    }
}
