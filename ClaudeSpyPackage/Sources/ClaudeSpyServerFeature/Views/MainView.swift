import ClaudeSpyCommon
import SwiftUI

/// The main application view showing available tmux panes
public struct MainView: View {
    @Environment(TmuxService.self) private var tmuxService
    @Environment(MirrorWindowManager.self) private var windowManager

    @State private var panes: [PaneInfo] = []
    @State private var isLoading = false
    @State private var error: String?

    public init() {}

    public var body: some View {
        PaneListView(
            panes: panes,
            isLoading: isLoading,
            error: error,
            onRefresh: { await loadPanes() },
            onOpenMirror: { pane in
                windowManager.openMirror(for: pane)
            },
            hasClaudePane: { paneId in
                windowManager.hasActiveClaudePane(paneId)
            }
        )
        .navigationTitle("Available Panes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await loadPanes()
                    }
                } label: {
                    Symbols.arrowClockwise.image
                }
                .help("Refresh pane list")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(isLoading)
            }
        }
        .task {
            await loadPanes()
        }
    }

    private func loadPanes() async {
        guard !isLoading else { return }

        isLoading = true
        error = nil

        do {
            try await tmuxService.checkAvailability()
            panes = try await tmuxService.listPanes()
        } catch {
            self.error = error.localizedDescription
            panes = []
        }

        isLoading = false
    }
}
