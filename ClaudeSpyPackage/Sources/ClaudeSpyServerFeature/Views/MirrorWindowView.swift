import ClaudeSpyCommon
import Logging
import SwiftUI

/// View for a single pane mirror window
struct MirrorWindowView: View {
    let paneInfo: PaneInfo

    @Environment(AppSettings.self) private var settings
    @Environment(MirrorWindowManager.self) private var windowManager

    @State private var streamState: StreamState = .disconnected
    @State private var streamWidth: Int?
    @State private var streamHeight: Int?
    @State private var showDiscardConfirmation = false

    private let logger = Logger(label: "com.claudespy.mirrorwindowview")

    private var recorder: SessionRecorder {
        windowManager.recorder(for: paneInfo.paneId)
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalContainerView(
                paneInfo: paneInfo,
                recorder: recorder,
                onStateChange: { state, width, height in
                    Task { @MainActor in
                        let wasActive = streamState.isActive
                        streamState = state
                        streamWidth = width
                        streamHeight = height

                        // Auto-start recording when stream connects
                        if !wasActive, state.isActive, !recorder.isRecording {
                            startRecording(width: width, height: height)
                        }
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if settings.showStatusBar {
                statusBar
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                recordingToolbar
            }
        }
        .confirmationDialog(
            "Discard Recording?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                Task {
                    await recorder.stop()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The current recording will be permanently discarded.")
        }
        .navigationTitle("Mirror: \(paneInfo.paneId) (\(paneInfo.target))")
    }

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

            Button {
                showDiscardConfirmation = true
            } label: {
                Label("Stop Recording", symbol: .stopFill)
            }
            .help("Stop recording and discard")
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

            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Actions

    private func startRecording(width: Int? = nil, height: Int? = nil) {
        let w = width ?? streamWidth ?? paneInfo.width
        let h = height ?? streamHeight ?? paneInfo.height

        Task {
            do {
                try await recorder.start(
                    paneId: paneInfo.paneId,
                    target: paneInfo.target,
                    width: w,
                    height: h
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
