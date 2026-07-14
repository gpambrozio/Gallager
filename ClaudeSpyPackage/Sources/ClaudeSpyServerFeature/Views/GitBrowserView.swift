import AppKit
import ClaudeSpyCommon
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

    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        GitWorkbenchView(store: store)
            .accessibilityIdentifier("git-workbench")
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
    ///
    /// `preferences` backs GitWorkbench's persistence: the package delegates the
    /// saved diff style **and** the resizable column widths entirely to the host's
    /// `layoutStore` (it never touches `UserDefaults` itself), so without these
    /// both reset to their defaults on every relaunch / store rebuild. A single
    /// constant `persistenceKey` (rather than one per repository) makes the diff
    /// style an app-wide preference — set it once, every session's Git tab honors it.
    static func claudeSpy(
        repositoryURL: URL,
        preferences: PreferencesService
    ) -> WorkbenchConfiguration {
        var configuration = WorkbenchConfiguration()
        configuration.theme = .standard.withAccent(.accentColor)
        configuration.darkTheme = .darkStandard.withAccent(.accentColor)
        configuration.repositoryURL = repositoryURL
        configuration.persistenceKey = "claudeSpyGitWorkbench"
        configuration.layoutStore = .claudeSpy(preferences: preferences)
        return configuration
    }
}

extension WorkbenchLayoutStore {
    /// Backs GitWorkbench's column-width + diff-mode persistence with the app's
    /// ``PreferencesService`` (UserDefaults in production, the in-memory store
    /// under E2E so tests never touch real defaults). GitWorkbench hands us an
    /// opaque `[String: CGFloat]` per persistence key; we JSON-encode it under a
    /// namespaced key. Decode failures fall through to `nil`, so the store cleanly
    /// falls back to its configured defaults on a fresh install or schema change.
    static func claudeSpy(preferences: PreferencesService) -> WorkbenchLayoutStore {
        WorkbenchLayoutStore(
            load: { key in
                guard let data = preferences.data("gitWorkbench.layout.\(key)") else { return nil }
                return try? JSONDecoder().decode([String: CGFloat].self, from: data)
            },
            save: { key, widths in
                preferences.setData(try? JSONEncoder().encode(widths), "gitWorkbench.layout.\(key)")
            }
        )
    }
}
