#if os(iOS)
    import ClaudeSpyCommon
    import ClaudeSpyNetworking
    import SwiftTerm
    import SwiftUI
    import UIKit

    /// Displays a read-only terminal snapshot from the Mac app
    struct TerminalSnapshotView: View {
        let snapshot: TerminalSnapshotMessage

        @Environment(IOSSettings.self) private var settings
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            TerminalContainerView(
                snapshot: snapshot,
                fontName: settings.terminalFontName,
                fontSize: CGFloat(settings.terminalFontSize)
            )
            .navigationTitle("Terminal Snapshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    /// SwiftUI wrapper around SwiftTerm's TerminalView for iOS
    ///
    /// SwiftTerm's iOS TerminalView is a UIScrollView subclass. However, SwiftUI's layout system
    /// will constrain the view to the available space, causing SwiftTerm to recalculate cols.
    ///
    /// Solution: Wrap in our own UIScrollView to provide horizontal scrolling, and explicitly
    /// resize the terminal to our exact dimensions before feeding content.
    private struct TerminalContainerView: UIViewRepresentable {
        let snapshot: TerminalSnapshotMessage
        let fontName: String
        let fontSize: CGFloat

        func makeUIView(context: Context) -> UIScrollView {
            // Check content validity first - return empty scroll view on error
            guard let content = snapshot.content else {
                let scrollView = UIScrollView()
                let errorLabel = UILabel()
                errorLabel.text = "Error: Failed to decode terminal content"
                errorLabel.textColor = .white
                errorLabel.frame = CGRect(x: 10, y: 10, width: 300, height: 30)
                scrollView.addSubview(errorLabel)
                scrollView.backgroundColor = .black
                return scrollView
            }

            // Use FontMetrics to calculate cell size (matches SwiftTerm's internal calculation)
            let cellSize = FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)

            // Calculate the exact frame for our desired dimensions
            let exactWidth = CGFloat(snapshot.width) * cellSize.width
            let exactHeight = CGFloat(snapshot.totalLines) * cellSize.height
            let exactFrame = CGRect(x: 0, y: 0, width: exactWidth, height: exactHeight)

            // Create the terminal with the exact frame
            let font = UIFont(name: fontName, size: fontSize)
                ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let terminalView = TerminalView(frame: exactFrame, font: font)

            // Set dark theme colors
            terminalView.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
            terminalView.nativeBackgroundColor = UIColor.black

            // Feed the snapshot content
            terminalView.feed(byteArray: ArraySlice(content))

            // Disable TerminalView's own scrolling since we wrap it
            terminalView.isScrollEnabled = false
            terminalView.contentOffset = .zero // Reset TerminalView's internal scroll position
            terminalView.inputAssistantItem.leadingBarButtonGroups = []
            terminalView.inputAssistantItem.trailingBarButtonGroups = []

            // Create our own scroll view wrapper for both horizontal and vertical scrolling
            let scrollView = UIScrollView()
            scrollView.backgroundColor = .black
            scrollView.addSubview(terminalView)
            scrollView.contentSize = exactFrame.size
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.showsVerticalScrollIndicator = true
            scrollView.alwaysBounceVertical = true
            scrollView.alwaysBounceHorizontal = false

            // Store references
            context.coordinator.terminalView = terminalView
            context.coordinator.scrollView = scrollView
            context.coordinator.contentHeight = exactFrame.height

            // Scroll to bottom after layout (show most recent content)
            DispatchQueue.main.async {
                let maxY = max(0, exactFrame.height - scrollView.bounds.height)
                scrollView.contentOffset = CGPoint(x: 0, y: maxY)
            }

            return scrollView
        }

        func updateUIView(_ scrollView: UIScrollView, context: Context) {
            // Font changes would require recreating the terminal view
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        @MainActor
        class Coordinator {
            var terminalView: TerminalView?
            var scrollView: UIScrollView?
            var contentHeight: CGFloat = 0
        }
    }

    #Preview {
        NavigationStack {
            TerminalSnapshotView(
                snapshot: TerminalSnapshotMessage(
                    commandId: UUID(),
                    paneId: "%1",
                    width: 80,
                    height: 24,
                    totalLines: 72,
                    content: Data("Hello, World!\nThis is a test terminal snapshot.\n".utf8)
                )
            )
        }
        .environment(IOSSettings.shared)
    }
#endif
