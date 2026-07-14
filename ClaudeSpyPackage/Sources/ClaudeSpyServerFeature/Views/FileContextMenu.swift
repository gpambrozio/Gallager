import AppKit
import ClaudeSpyCommon
import Dependencies
import SwiftUI

extension View {
    /// Right-click menu for a file or directory. Used by the file tree, the
    /// content-search results list, and file/tab strips.
    ///
    /// Backed by ``View/stableContextMenu(_:)`` (native `NSMenu`) so the
    /// "Open in Editor" submenu doesn't get dismissed by unrelated
    /// `@Observable` mutations in ancestor views — `paneStates` updates from
    /// Claude hooks at ~1 Hz used to tear down SwiftUI's `.contextMenu`
    /// mid-hover.
    ///
    /// Pass `nil` for `onOpenFileInNewTab` when the file is already shown as
    /// a tab; the "Open in New Tab" item is then suppressed, matching the
    /// directory behaviour.
    func fileContextMenu(
        fullPath: String?,
        directoryPath: String,
        isDirectory: Bool,
        onOpenFileInNewTab: ((String) -> Void)? = nil,
        onShowInFileExplorer: ((String) -> Void)? = nil
    ) -> some View {
        modifier(FileContextMenuModifier(
            fullPath: fullPath,
            directoryPath: directoryPath,
            isDirectory: isDirectory,
            onOpenFileInNewTab: onOpenFileInNewTab,
            onShowInFileExplorer: onShowInFileExplorer
        ))
    }
}

private struct FileContextMenuModifier: ViewModifier {
    let fullPath: String?
    let directoryPath: String
    let isDirectory: Bool
    let onOpenFileInNewTab: ((String) -> Void)?
    let onShowInFileExplorer: ((String) -> Void)?

    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        // Capture environment-derived values at view-construction time so the
        // lazy menu builder closure can run later (on right-click) without
        // needing a live SwiftUI evaluation context.
        let settings = settings
        let openSettings = openSettings
        return content.stableContextMenu {
            fileContextMenuItems(
                fullPath: fullPath,
                directoryPath: directoryPath,
                isDirectory: isDirectory,
                settings: settings,
                openSettings: openSettings,
                onOpenFileInNewTab: onOpenFileInNewTab,
                onShowInFileExplorer: onShowInFileExplorer
            )
        }
    }
}

/// Builds the file/directory right-click menu as declarative
/// ``ContextMenuItem``s. Single-sourced here so every surface that offers
/// "the file-explorer menu" — the file tree (via ``FileContextMenuModifier``),
/// the content-search list, the tab strips, and the Git tab's Changes rows —
/// shares one definition and can never drift.
///
/// Hosts that can't honor a cross-tab action pass `nil` for its callback and
/// the corresponding item is omitted: `onOpenFileInNewTab == nil` drops
/// "Open in New Tab", `onShowInFileExplorer == nil` drops "Show in File
/// Explorer". Returns `[]` (no menu) when `fullPath` is nil.
@MainActor
func fileContextMenuItems(
    fullPath: String?,
    directoryPath: String,
    isDirectory: Bool,
    settings: AppSettings,
    openSettings: OpenSettingsAction,
    onOpenFileInNewTab: ((String) -> Void)?,
    onShowInFileExplorer: ((String) -> Void)?
) -> [ContextMenuItem] {
    guard let fullPath else { return [] }

    var items: [ContextMenuItem] = []

    items.append(.button(title: "Open") {
        NSWorkspace.shared.open(URL(fileURLWithPath: fullPath))
    })

    if !isDirectory, let onOpenFileInNewTab {
        items.append(.button(title: "Open in New Tab") {
            onOpenFileInNewTab(fullPath)
        })
    }

    if !isDirectory {
        items.append(openInEditorSubmenu(
            fullPath: fullPath,
            settings: settings,
            openSettings: openSettings
        ))
    }

    if !isDirectory, let onShowInFileExplorer {
        items.append(.button(title: "Show in File Explorer") {
            onShowInFileExplorer(fullPath)
        })
    }

    items.append(.button(title: "Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: fullPath)]
        )
    })

    items.append(.divider)

    items.append(.button(title: "Copy Path") {
        @Dependency(ClipboardClient.self) var clipboard
        clipboard.setString(fullPath)
    })

    let relativePath = fullPath.hasPrefix(directoryPath + "/")
        ? String(fullPath.dropFirst(directoryPath.count + 1))
        : nil
    if let relativePath {
        items.append(.button(title: "Copy Relative Path") {
            @Dependency(ClipboardClient.self) var clipboard
            clipboard.setString(relativePath)
        })
    }

    if !isDirectory {
        items.append(.button(title: "Copy") {
            @Dependency(ClipboardClient.self) var clipboard
            clipboard.setFileURL(URL(fileURLWithPath: fullPath))
        })
    }

    return items
}

@MainActor
private func openInEditorSubmenu(
    fullPath: String,
    settings: AppSettings,
    openSettings: OpenSettingsAction
) -> ContextMenuItem {
    let configureItem = ContextMenuItem.button(title: "Configure Editors…") {
        @Bindable var bindable = settings
        bindable.selectedSettingsTab = .editors
        openSettings()
    }

    if settings.editors.isEmpty {
        return .submenu(title: "Open in Editor", items: [configureItem])
    }

    var editorItems: [ContextMenuItem] = settings.editors.map { editor in
        let displayName = editor.displayName
        return .button(
            title: displayName,
            image: editor.nsIcon,
            accessibilityLabel: "Open in \(displayName)"
        ) {
            @Dependency(EditorClient.self) var client
            Task {
                let launched = await client.openFile(editor, fullPath)
                if !launched {
                    postEditorLaunchFailed(editorName: displayName, path: fullPath)
                }
            }
        }
    }
    editorItems.append(.divider)
    editorItems.append(configureItem)
    return .submenu(title: "Open in Editor", items: editorItems)
}

/// Posts ``Notification.Name/editorLaunchFailed`` with a human-readable
/// message describing the failed launch. `MainView` listens for this and
/// surfaces it via the shared alert state.
func postEditorLaunchFailed(editorName: String, path: String) {
    let fileName = URL(fileURLWithPath: path).lastPathComponent
    NotificationCenter.default.post(
        name: .editorLaunchFailed,
        object: nil,
        userInfo: [
            editorLaunchFailedMessageKey: "Couldn't open \(fileName) in \(editorName). The editor may no longer be installed.",
        ]
    )
}
