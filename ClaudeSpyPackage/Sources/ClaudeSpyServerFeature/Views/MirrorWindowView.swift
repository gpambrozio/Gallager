import ClaudeSpyCommon
import SwiftUI

/// View for a single pane mirror window
struct MirrorWindowView: View {
    let paneInfo: PaneInfo

    @Environment(AppSettings.self) private var settings
    @Environment(MirrorWindowManager.self) private var windowManager

    @State private var streamState: StreamState = .disconnected
    @State private var streamWidth: Int?
    @State private var streamHeight: Int?
    @State private var terminalTitle: String?

    private var windowTitle: String {
        if let terminalTitle, !terminalTitle.isEmpty {
            return terminalTitle
        }
        return "Mirror: \(paneInfo.paneId) (\(paneInfo.target))"
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalContainerView(
                paneInfo: paneInfo,
                onStateChange: { state, width, height in
                    streamState = state
                    streamWidth = width
                    streamHeight = height
                },
                onTitleChange: { title in
                    terminalTitle = title
                    windowManager.updateTerminalTitle(target: paneInfo.target, title: title)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if settings.showStatusBar {
                statusBar
            }
        }
        .navigationTitle(windowTitle)
        .onAppear {
            // Restore previously detected title when view is recreated (e.g., switching panes in sidebar)
            if terminalTitle == nil, let savedTitle = windowManager.terminalTitles[paneInfo.target] {
                terminalTitle = savedTitle
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

            Text("\(streamWidth ?? paneInfo.width)x\(streamHeight ?? paneInfo.height)")

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
