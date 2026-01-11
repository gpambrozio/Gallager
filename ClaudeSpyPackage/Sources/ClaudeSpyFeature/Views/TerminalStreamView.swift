#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftTerm
    import SwiftUI
    import UIKit

    /// Displays a live streaming terminal from the Mac app
    struct TerminalStreamView: View {
        @Bindable var service: SessionDetailService
        @Binding var responseState: ResponseState?
        let isConnected: Bool
        let sendCommand: CommandSender

        @Environment(IOSSettings.self) private var settings
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(spacing: 0) {
                // Response view above terminal if available
                if
                    let responseState,
                    let responseView = responseState.event.responseView(
                        isConnected: isConnected,
                        sendCommand: {
                            await sendCommand($0)
                            dismiss()
                        },
                        state: responseState
                    ) {
                    responseView
                        .padding()
                        .background(Color(.systemGroupedBackground))

                    Divider()
                }

                // Terminal content
                ZStack {
                    if service.isStreaming {
                        StreamingTerminalContainerView(
                            service: service,
                            fontName: settings.terminalFontName,
                            fontSize: CGFloat(settings.terminalFontSize)
                        )
                    } else if service.isStartingStream {
                        VStack {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Connecting to terminal...")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                    } else if let error = service.streamError {
                        VStack {
                            Symbols.exclamationmarkTriangle.image
                                .font(.largeTitle)
                                .foregroundStyle(.red)
                            Text("Stream Error")
                                .font(.headline)
                                .padding(.top, 8)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                            Button("Retry") {
                                Task {
                                    await service.startStreaming()
                                }
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 16)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                    } else {
                        // Initial state - will auto-start streaming
                        Color.black
                            .overlay {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                            }
                    }
                }
            }
            .navigationTitle("Live Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if service.isStreaming {
                            Circle()
                                .fill(.green)
                                .frame(width: 8, height: 8)
                            Text("Live")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
            .task {
                // Auto-start streaming when view appears
                await service.startStreaming()
            }
            .onDisappear {
                // Stop streaming when view disappears
                Task {
                    await service.stopStreaming()
                }
            }
        }
    }

    /// SwiftUI wrapper around SwiftTerm's TerminalView for streaming content
    private struct StreamingTerminalContainerView: UIViewRepresentable {
        @Bindable var service: SessionDetailService
        let fontName: String
        let fontSize: CGFloat

        func makeUIView(context: Context) -> UIScrollView {
            // Use FontMetrics to calculate cell size
            let cellSize = FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)

            // Calculate frame based on current dimensions
            let exactWidth = CGFloat(service.streamWidth) * cellSize.width
            let exactHeight = CGFloat(service.streamHeight) * cellSize.height
            let exactFrame = CGRect(x: 0, y: 0, width: exactWidth, height: exactHeight)

            // Create the terminal with the frame
            let font = UIFont(name: fontName, size: fontSize)
                ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let terminalView = TerminalView(frame: exactFrame, font: font)

            // Set dark theme colors
            terminalView.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
            terminalView.nativeBackgroundColor = UIColor.black

            // Disable TerminalView's own scrolling since we wrap it
            terminalView.isScrollEnabled = false
            terminalView.contentOffset = .zero
            terminalView.inputAssistantItem.leadingBarButtonGroups = []
            terminalView.inputAssistantItem.trailingBarButtonGroups = []

            // Create our own scroll view wrapper
            let scrollView = UIScrollView()
            scrollView.backgroundColor = .black
            scrollView.addSubview(terminalView)
            scrollView.contentSize = exactFrame.size
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.showsVerticalScrollIndicator = true
            scrollView.alwaysBounceVertical = true
            scrollView.alwaysBounceHorizontal = false

            // Store reference to terminal view
            context.coordinator.terminalView = terminalView
            context.coordinator.scrollView = scrollView

            // Set up data callback to feed streaming data to terminal
            service.onStreamData = { [weak terminalView] data in
                terminalView?.feed(byteArray: ArraySlice(data))
            }

            return scrollView
        }

        func updateUIView(_ scrollView: UIScrollView, context: Context) {
            guard let terminalView = context.coordinator.terminalView else { return }

            // Update dimensions if they changed
            let cellSize = FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)
            let newWidth = CGFloat(service.streamWidth) * cellSize.width
            let newHeight = CGFloat(service.streamHeight) * cellSize.height

            if terminalView.frame.size != CGSize(width: newWidth, height: newHeight) {
                terminalView.frame = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
                scrollView.contentSize = CGSize(width: newWidth, height: newHeight)
            }
        }

        static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
            // Clear the data callback when view is dismantled
            // (service.onStreamData is managed externally)
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        @MainActor
        class Coordinator {
            var terminalView: TerminalView?
            var scrollView: UIScrollView?
        }
    }

    #Preview("Streaming Terminal") {
        // Mock service for preview
        let service = SessionDetailService(
            paneId: "%1",
            sessionStore: SessionStore(),
            relayClient: RelayClient()
        )

        NavigationStack {
            TerminalStreamView(
                service: service,
                responseState: .constant(nil),
                isConnected: true,
                sendCommand: { _ in }
            )
        }
        .environment(IOSSettings.shared)
    }
#endif
