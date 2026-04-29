import AppKit
import ClaudeSpyCommon
import Dependencies
import SwiftUI

extension View {
    /// Shared right-click context menu for files, used by both the file
    /// navigator tree (`FileBrowserView`) and the open-file tabs in
    /// `WindowTabBar`. Centralizing the items here keeps the two menus in
    /// sync — adding an item here surfaces it in both places automatically.
    ///
    /// Pass `nil` for `onOpenFileInNewTab` when the file is already shown as
    /// a tab; the "Open in New Tab" item is then suppressed in the same way
    /// it's suppressed for directories.
    func fileContextMenu(
        fullPath: String?,
        directoryPath: String,
        isDirectory: Bool,
        onOpenFileInNewTab: ((String) -> Void)? = nil
    ) -> some View {
        let relativePath = fullPath.map { String($0.dropFirst(directoryPath.count + 1)) }

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
                Button("Open in Finder") {
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
