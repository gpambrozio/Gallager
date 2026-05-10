import AppKit
import ClaudeSpyCommon
import Dependencies
import SwiftUI

extension View {
    /// Pass `nil` for `onOpenFileInNewTab` when the file is already shown as a tab;
    /// the "Open in New Tab" item is then suppressed, matching the directory behaviour.
    func fileContextMenu(
        fullPath: String?,
        directoryPath: String,
        isDirectory: Bool,
        onOpenFileInNewTab: ((String) -> Void)? = nil,
        onShowInFileExplorer: ((String) -> Void)? = nil
    ) -> some View {
        let relativePath = fullPath.flatMap {
            $0.hasPrefix(directoryPath + "/")
                ? String($0.dropFirst(directoryPath.count + 1))
                : nil
        }

        return contextMenu {
            if let fullPath {
                Button("Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: fullPath))
                }
                if !isDirectory, let onOpenFileInNewTab {
                    Button("Open in New Tab") {
                        onOpenFileInNewTab(fullPath)
                    }
                }
                if !isDirectory {
                    OpenInEditorMenu(fullPath: fullPath)
                }
                if !isDirectory, let onShowInFileExplorer {
                    Button("Show in File Explorer") {
                        onShowInFileExplorer(fullPath)
                    }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fullPath)])
                }
                Divider()
                Button("Copy Path") {
                    @Dependency(ClipboardClient.self) var clipboard
                    clipboard.setString(fullPath)
                }
                if let relativePath {
                    Button("Copy Relative Path") {
                        @Dependency(ClipboardClient.self) var clipboard
                        clipboard.setString(relativePath)
                    }
                }
                if !isDirectory {
                    Button("Copy") {
                        @Dependency(ClipboardClient.self) var clipboard
                        clipboard.setFileURL(URL(fileURLWithPath: fullPath))
                    }
                }
            }
        }
    }
}

/// "Open in Editor" submenu, used by the file context menu and the Cmd+E
/// keyboard menu. Reads the editor list from `AppSettings` and routes the
/// chosen launch through the `EditorClient` dependency so E2E tests can
/// assert the file path was forwarded to the right editor.
struct OpenInEditorMenu: View {
    let fullPath: String

    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu("Open in Editor") {
            if settings.editors.isEmpty {
                Button("Configure Editors…") {
                    @Bindable var bindable = settings
                    bindable.selectedSettingsTab = .editors
                    openSettings()
                }
            } else {
                ForEach(settings.editors) { editor in
                    Button(editor.displayName) {
                        @Dependency(EditorClient.self) var client
                        Task {
                            _ = await client.openFile(editor, fullPath)
                        }
                    }
                    .accessibilityLabel("Open in \(editor.displayName)")
                }
                Divider()
                Button("Configure Editors…") {
                    @Bindable var bindable = settings
                    bindable.selectedSettingsTab = .editors
                    openSettings()
                }
            }
        }
    }
}
