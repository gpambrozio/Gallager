import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// View for a single pane mirror window
struct MirrorWindowView: View {
    let paneState: PaneState

    @Environment(AppSettings.self) private var settings
    @Environment(MirrorWindowManager.self) private var windowManager

    @State private var streamState: StreamState = .disconnected
    @State private var streamWidth: Int?
    @State private var streamHeight: Int?

    var body: some View {
        VStack(spacing: 0) {
            TerminalContainerView(
                paneState: paneState,
                onStateChange: { state, width, height in
                    streamState = state
                    streamWidth = width
                    streamHeight = height
                },
                onTitleChange: { title in
                    windowManager.updateTerminalTitle(paneId: paneState.paneId, title: title)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                PaneEditorOverlay(paneId: paneState.paneId)
            }

            if settings.showStatusBar {
                statusBar
            }
        }
    }

    // MARK: - Subviews

    private var statusBar: some View {
        HStack {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
            }

            Divider()
                .frame(height: 12)

            Text("\(streamWidth ?? paneState.width)x\(streamHeight ?? paneState.height)")

            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Computed Properties

    private var statusColor: Color {
        switch streamState {
        case .connected:
            .green
        case .connecting:
            .orange
        case .disconnected:
            .gray
        case .error:
            .red
        }
    }

    private var statusText: String {
        switch streamState {
        case .connected:
            "Connected"
        case .connecting:
            "Connecting..."
        case .disconnected:
            "Disconnected"
        case let .error(message):
            "Error: \(message)"
        }
    }
}
