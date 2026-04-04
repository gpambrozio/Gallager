import AppKit
import Dependencies
import DependenciesMacros
import Files
import Foundation
import OrderedCollections

// MARK: - File Content Kind

/// The type of content a file represents, used to select the appropriate viewer.
public enum FileContentKind: Sendable {
    case image
    case pdf
    case video
    case html
    case markdown
    case text
    case unsupported
}

let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico", "svg",
]

let videoExtensions: Set<String> = [
    "mp4", "mov", "m4v", "avi", "mkv", "mp3", "wav", "aac", "m4a", "flac", "ogg", "aiff",
]

let markdownExtensions: Set<String> = ["md", "markdown"]

// MARK: - File Tree Load Result

/// Result of loading a file tree, including stable ID mappings for lazy loading.
public struct FileTreeLoadResult: Sendable {
    public let root: FullFileOrFolder<TextFileContents>
    /// Maps filesystem path strings to stable UUIDs, enabling tree rebuilds
    /// that preserve expansion and selection state.
    public let stableIds: [String: UUID]
    /// Filesystem paths of folders whose children have been loaded.
    public let loadedFolderPaths: Set<String>

    public init(
        root: FullFileOrFolder<TextFileContents>,
        stableIds: [String: UUID],
        loadedFolderPaths: Set<String>
    ) {
        self.root = root
        self.stableIds = stableIds
        self.loadedFolderPaths = loadedFolderPaths
    }
}

// MARK: - Dependency Client

/// Service for all file system operations used by the file browser.
/// Wraps directory scanning, file type detection, content reading, and file monitoring.
@DependencyClient
public struct FileSystemLoadingService: Sendable {
    /// Loads a directory tree one level deep, with expanded paths loaded on demand.
    public var loadFileTree: @Sendable (
        _ url: URL,
        _ expandedPaths: Set<String>,
        _ stableIds: [String: UUID]
    ) async -> FileTreeLoadResult = { _, _, _ in
        FileTreeLoadResult(root: .folder(FullFolder<TextFileContents>(children: [:])), stableIds: [:], loadedFolderPaths: [])
    }

    /// Detects the content kind of a file at the given path.
    public var detectFileKind: @Sendable (_ path: String) -> FileContentKind = { _ in .unsupported }

    /// Reads a text file and returns its contents, or nil if not readable as UTF-8.
    public var readTextFile: @Sendable (_ path: String) -> String? = { _ in nil }

    /// Reads an image file and returns an NSImage, or nil if not a valid image.
    public var readImageFile: @Sendable (_ path: String) -> NSImage? = { _ in nil }

    /// Returns an async stream that yields whenever the file at the given path changes on disk.
    public var fileChanges: @Sendable (_ path: String) -> AsyncStream<Void> = { _ in
        AsyncStream { $0.finish() }
    }
}

// MARK: - DependencyKey

extension FileSystemLoadingService: DependencyKey {
    public static var liveValue: FileSystemLoadingService {
        FileSystemLoadingService(
            loadFileTree: { url, expandedPaths, stableIds in
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
            },
            detectFileKind: { path in
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                if imageExtensions.contains(ext) { return .image }
                if ext == "pdf" { return .pdf }
                if videoExtensions.contains(ext) { return .video }
                if markdownExtensions.contains(ext) { return .markdown }
                if ext == "html" || ext == "htm" { return .html }
                if looksLikeText(at: path) { return .text }
                return .unsupported
            },
            readTextFile: { path in
                try? String(contentsOfFile: path, encoding: .utf8)
            },
            readImageFile: { path in
                NSImage(contentsOfFile: path)
            },
            fileChanges: { path in
                // DispatchSource required: no Swift Concurrency API for kqueue file monitoring.
                AsyncStream { continuation in
                    let fd = open(path, O_EVTONLY)
                    guard fd >= 0 else {
                        continuation.finish()
                        return
                    }

                    let source = DispatchSource.makeFileSystemObjectSource(
                        fileDescriptor: fd,
                        eventMask: [.write, .delete, .rename],
                        queue: .global(qos: .utility)
                    )

                    source.setEventHandler {
                        continuation.yield()
                    }

                    source.setCancelHandler {
                        close(fd)
                    }

                    continuation.onTermination = { _ in
                        source.cancel()
                    }

                    source.resume()
                }
            }
        )
    }
}

// MARK: - Private Helpers

/// OS-level files and directories to skip when building the file tree.
private let skippedEntries: Set<String> = [
    ".DS_Store", ".Trash", ".Spotlight-V100", ".fseventsd",
    ".TemporaryItems", ".DocumentRevisions-V100",
]

// FullFileOrFolder contains File which wraps FileWrapper (not Sendable).
// Safe here because we only transfer the tree once from Task.detached back to MainActor,
// and TextFileContents holds only a String with no shared mutable state.
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
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    else {
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

        if skippedEntries.contains(name) { continue }

        let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
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

            // Contents are loaded on-demand in the detail view, not during tree building.
            children[name] = .file(File(contents: TextFileContents(text: ""), persistentID: fileUUID))
        }
    }

    return .folder(FullFolder<TextFileContents>(children: children, persistentID: folderUUID))
}

/// Checks if a file is likely text by reading a small prefix and looking for null bytes.
private func looksLikeText(at path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? handle.close() }
    let prefix = handle.readData(ofLength: 8_192)
    guard !prefix.isEmpty else { return true }
    return !prefix.contains(0)
}
