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
private struct TerminalContainerView: UIViewRepresentable {
    let snapshot: TerminalSnapshotMessage
    let fontName: String
    let fontSize: CGFloat

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = true

        let terminalView = createTerminalView()
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(terminalView)

        // Store reference for updates
        context.coordinator.terminalView = terminalView
        context.coordinator.scrollView = scrollView

        // Calculate terminal size based on dimensions and font
        let cellSize = FontMetrics.calculateCellSize(fontName: fontName, fontSize: fontSize)
        let terminalWidth = CGFloat(snapshot.width) * cellSize.width + FontMetrics.horizontalBuffer
        let terminalHeight = CGFloat(snapshot.totalLines) * cellSize.height

        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            terminalView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            terminalView.widthAnchor.constraint(equalToConstant: terminalWidth),
            terminalView.heightAnchor.constraint(equalToConstant: terminalHeight),
        ])

        scrollView.contentSize = CGSize(width: terminalWidth, height: terminalHeight)

        // Feed the snapshot content to the terminal
        if let content = snapshot.content {
            terminalView.feed(byteArray: ArraySlice(content))
        } else {
            // Show error state if content decoding failed
            let errorLabel = UILabel()
            errorLabel.text = "Failed to decode terminal content"
            errorLabel.textColor = .systemRed
            errorLabel.textAlignment = .center
            errorLabel.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(errorLabel)
            NSLayoutConstraint.activate([
                errorLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
                errorLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            ])
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Font changes would require recreating the terminal view
        // For now, we don't support dynamic font changes
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func createTerminalView() -> TerminalView {
        // Create terminal with fixed dimensions matching snapshot
        let terminalView = TerminalView(frame: .zero)

        // Configure font
        let font = UIFont(name: fontName, size: fontSize)
            ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.font = font

        // Configure terminal dimensions
        terminalView.getTerminal().resize(cols: snapshot.width, rows: snapshot.totalLines)

        // Set dark theme colors
        terminalView.nativeForegroundColor = UIColor(white: 0.9, alpha: 1.0)
        terminalView.nativeBackgroundColor = UIColor.black

        // Disable input - this is read-only
        terminalView.isUserInteractionEnabled = false

        return terminalView
    }

    @MainActor
    class Coordinator {
        var terminalView: TerminalView?
        var scrollView: UIScrollView?
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
                content: "Hello, World!\nThis is a test terminal snapshot.\n".data(using: .utf8)!
            )
        )
    }
    .environment(IOSSettings.shared)
}
#endif
