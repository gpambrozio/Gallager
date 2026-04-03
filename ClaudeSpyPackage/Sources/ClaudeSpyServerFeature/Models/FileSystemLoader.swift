import Files
import Foundation
import OrderedCollections

/// Maximum file size to load content for (256 KB).
private let maxFileSize: UInt64 = 256 * 1_024

/// Directories to skip when building the file tree.
private let skippedDirectories: Set<String> = [
    ".git", ".build", ".swiftpm", "node_modules", ".DS_Store",
    "DerivedData", "Pods", ".Trash", "xcuserdata",
]

/// Result of loading a file tree, including stable ID mappings for lazy loading.
struct FileTreeLoadResult: Sendable {
    let root: FullFileOrFolder<TextFileContents>
    /// Maps filesystem path strings to stable UUIDs, enabling tree rebuilds
    /// that preserve expansion and selection state.
    let stableIds: [String: UUID]
    /// Filesystem paths of folders whose children have been loaded.
    let loadedFolderPaths: Set<String>
}

/// Loads a directory from the filesystem into a ProjectNavigator `FileTree`,
/// loading only the specified depth. Folders beyond the depth limit are empty
/// placeholders that get populated when the user expands them.
///
/// - Parameters:
///   - url: The URL of the directory to load.
///   - expandedPaths: Folder paths that should have their children loaded regardless of depth.
///   - stableIds: Previous path→UUID mapping to preserve tree identity across rebuilds.
/// - Returns: A `FileTreeLoadResult` with the tree, stable IDs, and loaded folder paths.
func loadFileTree(
    at url: URL,
    expandedPaths: Set<String>,
    stableIds: [String: UUID]
) async -> FileTreeLoadResult {
    await Task.detached {
        var ids = stableIds
        var loadedPaths = Set<String>()
        let root = loadDirectory(
            at: url,
            path: url.path,
            depth: 1,
            expandedPaths: expandedPaths,
            stableIds: &ids,
            loadedPaths: &loadedPaths
        )
        return FileTreeLoadResult(root: root, stableIds: ids, loadedFolderPaths: loadedPaths)
    }.value
}

extension FullFileOrFolder: @retroactive @unchecked Sendable { }

/// Recursively loads a directory into a `FullFileOrFolder` hierarchy,
/// respecting the depth limit and expanded paths.
private func loadDirectory(
    at url: URL,
    path: String,
    depth: Int,
    expandedPaths: Set<String>,
    stableIds: inout [String: UUID],
    loadedPaths: inout Set<String>
) -> FullFileOrFolder<TextFileContents> {
    let folderUUID = stableIds[path] ?? {
        let id = UUID()
        stableIds[path] = id
        return id
    }()

    let fm = FileManager.default
    guard
        let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
        return .folder(FullFolder<TextFileContents>(children: [:], persistentID: folderUUID))
    }

    // Only load children if we're within depth or this folder is explicitly expanded
    let shouldLoadChildren = depth > 0 || expandedPaths.contains(path)
    guard shouldLoadChildren else {
        return .folder(FullFolder<TextFileContents>(children: [:], persistentID: folderUUID))
    }

    loadedPaths.insert(path)

    var children = OrderedDictionary<String, FullFileOrFolder<TextFileContents>>()

    for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
        let name = item.lastPathComponent

        if skippedDirectories.contains(name) { continue }

        let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let isDirectory = resourceValues?.isDirectory == true
        let childPath = item.path

        if isDirectory {
            children[name] = loadDirectory(
                at: item,
                path: childPath,
                depth: depth - 1,
                expandedPaths: expandedPaths,
                stableIds: &stableIds,
                loadedPaths: &loadedPaths
            )
        } else {
            let fileUUID = stableIds[childPath] ?? {
                let id = UUID()
                stableIds[childPath] = id
                return id
            }()

            let fileSize = UInt64(resourceValues?.fileSize ?? 0)
            let contents: TextFileContents
            if fileSize <= maxFileSize, let data = try? Data(contentsOf: item) {
                contents = (try? TextFileContents(name: name, data: data)) ?? TextFileContents(text: "[Error reading file]")
            } else {
                contents = TextFileContents(text: "[File too large to display]")
            }
            children[name] = .file(File(contents: contents, persistentID: fileUUID))
        }
    }

    return .folder(FullFolder<TextFileContents>(children: children, persistentID: folderUUID))
}
