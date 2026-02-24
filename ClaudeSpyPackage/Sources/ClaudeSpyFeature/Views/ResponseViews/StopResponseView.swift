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
            HStack(spacing: 6) {
                Symbols.sparkles.image
                    .font(.caption)
                    .foregroundStyle(.purple)

                Text("Summary")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                (state.isSummaryExpanded ? Symbols.chevronUp.image : Symbols.chevronDown.image)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            // Note: Using onTapGesture instead of Button because .buttonStyle(.plain)
            // doesn't respond to XCUITest runner's synthetic touch events in E2E tests.
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    state.isSummaryExpanded.toggle()
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(state.isSummaryExpanded ? "Collapse summary" : "Expand summary")

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(state.isSummaryExpanded ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("summary-text")
        }
    }
}

// MARK: - Preview

#Preview("Stop with summary") {
    let event = HookEvent(
        action: .stop(StopBody(
            sessionId: "test",
            hookEventName: "Stop",
            lastAssistantMessage: "I've completed the refactoring of the authentication module. The changes include updating the JWT validation logic, adding refresh token support, and migrating the session store to use async/await patterns. All existing tests have been updated to reflect the new architecture and are passing successfully."
        )),
        projectPath: nil,
        tmuxPane: nil
    )
    let state = ResponseState(event: event)

    return NavigationStack {
        List {
            Section("Response") {
                StopResponseView(
                    lastAssistantMessage: "I've completed the refactoring of the authentication module. The changes include updating the JWT validation logic, adding refresh token support, and migrating the session store to use async/await patterns. All existing tests have been updated to reflect the new architecture and are passing successfully.",
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
