import Files
import Foundation
import OrderedCollections

/// Maximum file size to load content for (256 KB).
private let maxFileSize: UInt64 = 256 * 1024

/// Directories to skip when building the file tree.
private let skippedDirectories: Set<String> = [
    ".git", ".build", ".swiftpm", "node_modules", ".DS_Store",
    "DerivedData", "Pods", ".Trash", "xcuserdata",
]

/// Loads a directory from the filesystem into a ProjectNavigator `FileTree`.
///
/// - Parameter url: The URL of the directory to load.
/// - Returns: A `FileTree<TextFileContents>` representing the directory contents.
@MainActor
func loadFileTree(at url: URL) -> FileTree<TextFileContents> {
    let root = loadDirectory(at: url)
    return FileTree(files: root)
}

/// Recursively loads a directory into a `FullFileOrFolder` hierarchy.
private func loadDirectory(at url: URL) -> FullFileOrFolder<TextFileContents> {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else {
        return .folder(FullFolder<TextFileContents>(children: [:]))
    }

    var children = OrderedDictionary<String, FullFileOrFolder<TextFileContents>>()

    for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
        let name = item.lastPathComponent

        if skippedDirectories.contains(name) { continue }

        let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let isDirectory = resourceValues?.isDirectory == true

        if isDirectory {
            children[name] = loadDirectory(at: item)
        } else {
            let fileSize = UInt64(resourceValues?.fileSize ?? 0)
            let contents: TextFileContents
            if fileSize <= maxFileSize, let data = try? Data(contentsOf: item) {
                contents = (try? TextFileContents(name: name, data: data)) ?? TextFileContents(text: "[Error reading file]")
            } else {
                contents = TextFileContents(text: "[File too large to display]")
            }
            children[name] = .file(File(contents: contents))
        }
    }

    return .folder(FullFolder<TextFileContents>(children: children))
}
