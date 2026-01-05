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
            onRefresh: { await refreshPanes() },
            onOpenMirror: { pane in
                windowManager.openMirror(for: pane)
            }
        )
        .navigationTitle("Available Panes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await refreshPanes()
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
            await refreshPanes()

            // Auto-refresh every 5 seconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                guard !Task.isCancelled else { break }
                await refreshPanes()
            }
        }
    }

    private func refreshPanes() async {
        let panes = await tmuxService.refreshPanes()
        windowManager.cleanupInactiveSessions(currentPanes: panes)
    }
}
