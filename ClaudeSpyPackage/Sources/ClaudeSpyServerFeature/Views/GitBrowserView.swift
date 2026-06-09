import AppKit
import GitWorkbench
import SwiftUI

/// The Git tab's content (issue #258): a thin wrapper around the third-party
/// ``GitWorkbenchView`` so the rest of the app deals with a ClaudeSpy-shaped
/// view and a single place to attach an accessibility identifier for E2E.
///
/// The ``GitWorkbenchStore`` is owned by ``MainView`` and cached per session, so
/// the git state (selected workspace view, file, diff) survives tab/session
/// switches — mirroring how `FileBrowserState` is retained. This view only
/// observes the store; it never creates it.
///
/// Right-click and double-click on a Changes-tab file row are surfaced through
/// GitWorkbench's `onChangesRightClick` / `onChangesDoubleClick` hooks (the
/// store's `repositoryURL` makes those callbacks hand back **absolute** URLs).
/// Right-click pops up the very same native menu as the File Explorer — built
/// by ``fileContextMenuItems(fullPath:directoryPath:isDirectory:settings:openSettings:onOpenFileInNewTab:onShowInFileExplorer:)``
/// — and double-click opens the file in its default app.
struct GitBrowserView: View {
    let store: GitWorkbenchStore
    /// Working-tree root the Git tab is tracking; the menu uses it to compute
    /// the "Copy Relative Path" item, matching the File Explorer.
    let directoryPath: String
    /// Opens the file as a new tab in the File Explorer (powers "Open in New
    /// Tab"). Supplied by ``MainView`` so the Git menu reaches full parity.
    let onOpenFileInNewTab: (String) -> Void
    /// Switches to the File Explorer and reveals the file (powers "Show in File
    /// Explorer"). Supplied by ``MainView``.
    let onShowInFileExplorer: (String) -> Void
    /// Receives the live ``RepositorySummary`` whenever GitWorkbench's state
    /// changes while this tab is mounted (issue #573). ``MainView`` forwards it
    /// to ``MirrorWindowManager/applyGitSummary(path:branch:changedFileCount:)``
    /// so the Git tab badge and sidebar branch update instantly as the user
    /// stages, commits, or switches branches — without waiting for the next
    /// periodic refresh.
    let onSummaryChange: (RepositorySummary) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        GitWorkbenchView(store: store)
            .accessibilityIdentifier("git-workbench")
            .onRepositorySummaryChange { summary in
                // The first fire can be the pre-load placeholder (empty repo
                // name/branch) before the initial load completes; ignore it so
                // we don't briefly blank the branch the periodic refresh set.
                guard !summary.repositoryName.isEmpty else { return }
                onSummaryChange(summary)
            }
            .onChangesDoubleClick { url in
                NSWorkspace.shared.open(url)
            }
            .onChangesRightClick { url in
                // GitWorkbench fires this from the row's `rightMouseDown` on the
                // main actor, so `NSApp.currentEvent` is that right-click. Show
                // the shared File-Explorer menu as a proper contextual menu for
                // it, anchored to the window's content view.
                MainActor.assumeIsolated {
                    guard
                        let event = NSApp.currentEvent,
                        let view = (event.window ?? NSApp.keyWindow)?.contentView
                    else { return }
                    presentStableContextMenu(
                        items: fileContextMenuItems(
                            fullPath: url.path,
                            directoryPath: directoryPath,
                            isDirectory: false,
                            settings: settings,
                            openSettings: openSettings,
                            onOpenFileInNewTab: onOpenFileInNewTab,
                            onShowInFileExplorer: onShowInFileExplorer
                        ),
                        with: event,
                        for: view
                    )
                }
            }
    }
}

extension WorkbenchConfiguration {
    /// The Git tab's configuration: the package's standard light/dark identity
    /// recolored to the app's accent color (`Color.accentColor` — the terracotta
    /// `AccentColor` asset) via the package-provided
    /// ``WorkbenchTheme/withAccent(_:)``, so the embedded GitWorkbench matches the
    /// rest of ClaudeSpy instead of rendering in the package's default purple.
    /// `withAccent` derives the soft/ring/deep accent variants from the base color.
    ///
    /// `repositoryURL` is the working-tree root so the Changes-tab right-click /
    /// double-click callbacks receive an **absolute** file URL (otherwise the
    /// package hands back a repo-relative URL that isn't safe to give
    /// `NSWorkspace`).
    static func claudeSpy(repositoryURL: URL) -> WorkbenchConfiguration {
        var configuration = WorkbenchConfiguration()
        configuration.theme = .standard.withAccent(.accentColor)
        configuration.darkTheme = .darkStandard.withAccent(.accentColor)
        configuration.repositoryURL = repositoryURL
        return configuration
    }
}
