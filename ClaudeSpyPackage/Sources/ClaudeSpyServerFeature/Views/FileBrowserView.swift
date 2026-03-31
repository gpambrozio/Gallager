import ClaudeSpyCommon
import Files
import ProjectNavigator
import SwiftUI

/// Displays a file tree navigator for a directory with an editor pane for the selected file.
/// Modeled after the NavigatorDemo in the ProjectNavigator package.
struct FileBrowserView: View {
    let directoryPath: String

    @State private var fileTree: FileTree<TextFileContents>?
    @State private var viewState: FileNavigatorViewState<TextFileContents>?

    var body: some View {
        if let fileTree, let viewState {
            fileBrowserContent(fileTree: fileTree, viewState: viewState)
        } else {
            ProgressView("Loading files...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: directoryPath) {
                    let tree = loadFileTree(at: URL(fileURLWithPath: directoryPath))
                    let state = FileNavigatorViewState<TextFileContents>(
                        fileTree: tree,
                        expansions: WrappedUUIDSet(),
                        selection: nil
                    )
                    // Expand the root folder by default
                    state.expansions[tree.root.id] = true
                    self.fileTree = tree
                    self.viewState = state
                }
        }
    }

    @ViewBuilder
    private func fileBrowserContent(
        fileTree: FileTree<TextFileContents>,
        viewState: FileNavigatorViewState<TextFileContents>
    ) -> some View {
        @Bindable var viewState = viewState
        let directoryName = URL(fileURLWithPath: directoryPath).lastPathComponent

        NavigationSplitView {
            List(selection: $viewState.selection) {
                FileNavigator(
                    name: directoryName,
                    item: .constant(fileTree.root),
                    parent: .constant(nil),
                    viewState: viewState,
                    fileLabel: { cursor, _, _ in
                        Label {
                            Text(cursor.name)
                                .font(.callout)
                        } icon: {
                            Symbols.docPlaintextFill.image
                                .foregroundStyle(.secondary)
                        }
                    },
                    folderLabel: { cursor, _, _ in
                        Label {
                            Text(cursor.name)
                                .font(.callout)
                        } icon: {
                            Symbols.folderFill.image
                                .foregroundStyle(.blue)
                        }
                    }
                )
                .navigatorFilter { $0.first != "." }
            }
            .listStyle(.sidebar)
        } detail: {
            fileDetailView(fileTree: fileTree, viewState: viewState)
        }
    }

    @ViewBuilder
    private func fileDetailView(
        fileTree: FileTree<TextFileContents>,
        viewState: FileNavigatorViewState<TextFileContents>
    ) -> some View {
        if let uuid = viewState.selection,
           let file = fileTree.proxy(for: uuid).file
        {
            VStack(alignment: .leading, spacing: 0) {
                // File path header
                if let filePath = fileTree.filePath(of: uuid) {
                    let directoryName = URL(fileURLWithPath: directoryPath).lastPathComponent
                    Text(directoryName + "/" + filePath.string)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(8)
                    Divider()
                }

                // File content editor
                TextEditor(text: .constant(file.contents.text))
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
            }
        } else if let uuid = viewState.selection,
                  fileTree.proxy(for: uuid).file == nil
        {
            // A folder is selected
            ContentUnavailableView(
                "Folder Selected",
                symbol: .folder,
                description: "Select a file to view its contents."
            )
        } else {
            ContentUnavailableView(
                "Select a File",
                symbol: .docPlaintextFill,
                description: "Choose a file from the navigator to view its contents."
            )
        }
    }
}
