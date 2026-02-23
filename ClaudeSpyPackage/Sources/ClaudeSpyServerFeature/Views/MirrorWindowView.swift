import ClaudeSpyCommon
import SwiftUI

/// View for a single pane mirror window
struct MirrorWindowView: View {
    let paneInfo: PaneInfo

    @Environment(AppSettings.self) private var settings

    @State private var streamState: StreamState = .disconnected
    @State private var streamWidth: Int?
    @State private var streamHeight: Int?
    @State private var recorder = SessionRecorder()

    var body: some View {
        VStack(spacing: 0) {
            TerminalContainerView(
                paneInfo: paneInfo,
                recorder: recorder,
                onStateChange: { state, width, height in
                    Task { @MainActor in
                        streamState = state
                        streamWidth = width
                        streamHeight = height
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
                recorder.stop()
            } label: {
                Label("Stop Recording", symbol: .stopFill)
            }
            .help("Stop recording and discard")
        } else {
            Button {
                startRecording()
            } label: {
                Label("Record Session", symbol: .recordCircle)
            }
            .help("Start recording terminal stream")
            .disabled(!streamState.isActive)
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

    private func startRecording() {
        let width = streamWidth ?? paneInfo.width
        let height = streamHeight ?? paneInfo.height

        do {
            try recorder.start(
                paneId: paneInfo.paneId,
                target: paneInfo.target,
                width: width,
                height: height
            )
        } catch {
            // Recording is optional - log and continue
            print("Failed to start recording: \(error)")
        }
    }

    // MARK: - Computed Properties

    private var formattedDuration: String {
        let total = Int(recorder.duration)
        let minutes = total / 60
        let seconds = total % 60
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
