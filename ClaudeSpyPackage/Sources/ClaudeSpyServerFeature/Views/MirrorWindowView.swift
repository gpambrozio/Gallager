import ClaudeSpyCommon
#if DEBUG
    import Logging
#endif
import SwiftUI

/// View for a single pane mirror window
struct MirrorWindowView: View {
    let paneInfo: PaneInfo

    @Environment(AppSettings.self) private var settings

    @State private var streamState: StreamState = .disconnected
    @State private var streamWidth: Int?
    @State private var streamHeight: Int?

    #if DEBUG
        @Environment(MirrorWindowManager.self) private var windowManager
        @Environment(PaneStreamManager.self) private var paneStreamManager
        private let logger = Logger(label: "com.claudespy.mirrorwindowview")

        private var recorder: SessionRecorder {
            windowManager.recorder(for: paneInfo.paneId)
        }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            TerminalContainerView(
                paneInfo: paneInfo,
                onStateChange: { state, width, height in
                    Task { @MainActor in
                        #if DEBUG
                            let wasActive = streamState.isActive
                        #endif
                        streamState = state
                        streamWidth = width
                        streamHeight = height

                        #if DEBUG
                            // Auto-start recording when stream connects
                            if !wasActive, state.isActive, !recorder.isRecording {
                                startRecording()
                            }
                        #endif
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if settings.showStatusBar {
                statusBar
            }
        }
        #if DEBUG
        .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    recordingToolbar
                }
            }
        #endif
            .navigationTitle("Mirror: \(paneInfo.paneId) (\(paneInfo.target))")
    }

    #if DEBUG
        // MARK: - Toolbar

        @ViewBuilder
        private var recordingToolbar: some View {
            if recorder.isRecording {
                Text(formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(formattedFileSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        await recorder.export()
                    }
                } label: {
                    Label("Export Recording", symbol: .squareAndArrowUp)
                }
                .help("Export recording to file")
            }
        }
    #endif

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

            #if DEBUG
                if recorder.isRecording {
                    Divider()
                        .frame(height: 12)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                        Text("REC \(formattedDuration)")
                    }
                }
            #endif

            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    #if DEBUG
        // MARK: - Actions

        private func startRecording() {
            Task {
                do {
                    try await recorder.start(
                        paneId: paneInfo.paneId,
                        target: paneInfo.target,
                        paneStreamManager: paneStreamManager
                    )
                } catch {
                    logger.error("Failed to start recording: \(error)")
                }
            }
        }

        // MARK: - Computed Properties

        private var formattedDuration: String {
            let total = Int(recorder.duration)
            let hours = total / 3_600
            let minutes = (total % 3_600) / 60
            let seconds = total % 60
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, seconds)
            }
            return String(format: "%d:%02d", minutes, seconds)
        }

        private var formattedFileSize: String {
            ByteCountFormatter.string(fromByteCount: Int64(recorder.fileSize), countStyle: .file)
        }
    #endif

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
