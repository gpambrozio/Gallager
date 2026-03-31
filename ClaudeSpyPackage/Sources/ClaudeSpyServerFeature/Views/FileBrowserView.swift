import ClaudeSpyCommon
import Files
import ProjectNavigator
import SwiftUI

/// A draggable vertical divider for resizing adjacent views.
private struct ResizableDivider: View {
    @Binding var dimension: CGFloat
    let minDimension: CGFloat
    let maxDimension: CGFloat

    @State private var isDragging = false
    @State private var initialDimension: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color.gray.opacity(0.3))
            .frame(width: 4)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            initialDimension = dimension
                        }
                        let newWidth = initialDimension + value.translation.width
                        dimension = min(max(newWidth, minDimension), maxDimension)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}

/// Displays a file tree navigator for a directory with an editor pane for the selected file.
/// Modeled after the NavigatorDemo in the ProjectNavigator package.
struct FileBrowserView: View {
    let directoryPath: String

    @State private var fileTree: FileTree<TextFileContents>?
    @State private var viewState: FileNavigatorViewState<TextFileContents>?
    @State private var sidebarWidth: CGFloat = 250

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

        HStack(spacing: 0) {
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
            .scrollContentBackground(.hidden)
            .frame(width: sidebarWidth)

            ResizableDivider(dimension: $sidebarWidth, minDimension: 150, maxDimension: 400)

            fileDetailView(fileTree: fileTree, viewState: viewState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func fileDetailView(
        fileTree: FileTree<TextFileContents>,
        viewState: FileNavigatorViewState<TextFileContents>
    ) -> some View {
        if
            let uuid = viewState.selection,
            let file = fileTree.proxy(for: uuid).file {
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
        } else if
            let uuid = viewState.selection,
            fileTree.proxy(for: uuid).file == nil {
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
