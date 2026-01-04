import ClaudeSpyCommon
import SwiftUI

/// The main application view showing available tmux panes
public struct MainView: View {
    @Environment(TmuxService.self) private var tmuxService
    @Environment(MirrorWindowManager.self) private var windowManager

    /// Refresh interval in seconds
    private let refreshInterval: TimeInterval = 5

    public init() {}

    public var body: some View {
        PaneListView(
            panes: tmuxService.panes,
            isLoading: tmuxService.isRefreshing,
            error: tmuxService.lastError,
            onRefresh: { await tmuxService.refreshPanes() },
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
                        await tmuxService.refreshPanes()
                    }
                } label: {
                    Symbols.arrowClockwise.image
                }
                .help("Refresh pane list")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(tmuxService.isRefreshing)
            }
        }
        .task {
            // Initial load
            await tmuxService.refreshPanes()

            // Auto-refresh every 5 seconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                guard !Task.isCancelled else { break }
                await tmuxService.refreshPanes()
            }
        }
    }
}
