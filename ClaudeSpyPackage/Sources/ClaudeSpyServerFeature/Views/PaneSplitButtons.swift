import ClaudeSpyCommon
import ClaudeSpyNetworking
import SwiftUI

/// Overlay buttons for splitting a pane horizontally or vertically.
/// Shown on hover in the top-right corner of each pane.
///
/// Shared by local (`WindowPaneLayoutView`) and remote (`RemoteWindowPaneLayoutView`)
/// pane tiles — callers supply the split action, which runs through the local
/// `TmuxService` or through a `ViewerConnection`, respectively.
struct PaneSplitButtons: View {
    let split: (SplitDirection) async -> Void

    @State private var isSplitting = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                runSplit(.horizontal)
            } label: {
                Symbols.rectangleSplit2x1Fill.image
            }
            .help("Split Horizontal")

            Button {
                runSplit(.vertical)
            } label: {
                Symbols.rectangleSplit1x2Fill.image
            }
            .help("Split Vertical")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
        .padding(4)
        .disabled(isSplitting)
        .onHover { hovering in
            if hovering {
                NSCursor.arrow.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            // If the view is removed mid-hover (e.g., pane removed, parent
            // toggled), onHover's exit branch never fires — pop here to keep
            // the NSCursor push/pop stack balanced.
            NSCursor.pop()
        }
    }

    private func runSplit(_ direction: SplitDirection) {
        Task {
            isSplitting = true
            defer { isSplitting = false }
            await split(direction)
        }
    }
}
