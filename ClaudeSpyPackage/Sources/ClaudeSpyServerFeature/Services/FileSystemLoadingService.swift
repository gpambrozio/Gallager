import AppKit
import Dependencies
import DependenciesMacros
import Files
import Foundation
import OrderedCollections
import os

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

let imageExtensions: Set = [
    "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico", "svg",
]

let videoExtensions: Set = [
    "mp4", "mov", "m4v", "avi", "mkv", "mp3", "wav", "aac", "m4a", "flac", "ogg", "aiff",
]

let markdownExtensions: Set = ["md", "markdown"]

// MARK: - File Tree Load Result

/// Result of loading a file tree, including stable ID mappings for lazy loading.
public struct FileTreeLoadResult: Sendable {
    public let root: FullFileOrFolder<TextFileContents>
    /// Maps filesystem path strings to stable UUIDs, enabling tree rebuilds
    /// that preserve expansion and selection state.
    public let stableIds: [String: UUID]
    /// Filesystem paths of folders whose children have been loaded.
    public let loadedFolderPaths: Set<String>
    /// Filesystem paths that are symbolic links. Used by the navigator to render
    /// links with a distinct visual indicator (italic name + link badge).
    public let symlinkedPaths: Set<String>

    public init(
        root: FullFileOrFolder<TextFileContents>,
        stableIds: [String: UUID],
        loadedFolderPaths: Set<String>,
        symlinkedPaths: Set<String> = []
    ) {
        self.root = root
        self.stableIds = stableIds
        self.loadedFolderPaths = loadedFolderPaths
        self.symlinkedPaths = symlinkedPaths
    }
}

// MARK: - File Search Result

/// A file found during a directory search, with its path information.
public struct FileSearchResult: Sendable, Identifiable, Equatable {
    public var id: String {
        fullPath
    }

    public let fullPath: String
    public let relativePath: String
    public let name: String

    public init(fullPath: String, relativePath: String, name: String) {
        self.fullPath = fullPath
        self.relativePath = relativePath
        self.name = name
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
    public var readTextFile: @Sendable (_ path: String) async -> String? = { _ in nil }

    /// Reads an image file and returns an NSImage, or nil if not a valid image.
    public var readImageFile: @Sendable (_ path: String) async -> NSImage? = { _ in nil }

    /// Returns a URL that native viewers (PDFView, AVPlayer, WebView) can load directly.
    /// For live mode, returns the file's path as a URL.
    /// For in-memory mode, returns the bundle path or a temp file URL.
    public var resolveFileURL: @Sendable (_ path: String) -> URL? = { path in
        URL(fileURLWithPath: path)
    }

    /// Returns an async stream that yields whenever any of the given directories change
    /// (file created, deleted, or renamed within them).
    public var directoryChanges: @Sendable (_ paths: Set<String>) -> AsyncStream<Void> = { _ in
        AsyncStream { $0.finish() }
    }

    /// Returns an async stream that yields whenever the file at the given path changes on disk.
    public var fileChanges: @Sendable (_ path: String) -> AsyncStream<Void> = { _ in
        AsyncStream { $0.finish() }
    }

    /// Streams batches of file paths under a directory for search.
    ///
    /// Yields incremental batches as the filesystem is scanned so callers can
    /// surface partial results without waiting for the full scan to complete.
    /// In a git work tree the scan honours `.gitignore` (via `git ls-files`);
    /// otherwise it walks the directory directly, skipping only `.git` and the
    /// usual OS-level entries.
    public var collectAllFiles: @Sendable (_ rootURL: URL) -> AsyncStream<[FileSearchResult]> = { _ in
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
                    var symlinkedPaths = Set<String>()
                    let root = loadDirectory(
                        at: url,
                        path: url.path,
                        depth: 1,
                        expandedPaths: expandedPaths,
                        stableIds: &ids,
                        loadedPaths: &loadedPaths,
                        symlinkedPaths: &symlinkedPaths
                    )
                    return FileTreeLoadResult(
                        root: root,
                        stableIds: ids,
                        loadedFolderPaths: loadedPaths,
                        symlinkedPaths: symlinkedPaths
                    )
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
                await Task.detached {
                    try? String(contentsOfFile: path, encoding: .utf8)
                }.value
            },
            readImageFile: { path in
                await Task.detached {
                    NSImage(contentsOfFile: path)
                }.value
            },
            resolveFileURL: { path in
                URL(fileURLWithPath: path)
            },
            directoryChanges: { paths in
                AsyncStream { continuation in
                    let queue = DispatchQueue(label: "directory-watcher", qos: .utility)
                    var sources: [DispatchSourceFileSystemObject] = []

                    for path in paths {
                        let fd = open(path, O_EVTONLY)
                        guard fd >= 0 else { continue }

                        let source = DispatchSource.makeFileSystemObjectSource(
                            fileDescriptor: fd,
                            eventMask: [.write, .link, .rename],
                            queue: queue
                        )
                        source.setEventHandler {
                            continuation.yield()
                        }
                        source.setCancelHandler {
                            close(fd)
                        }
                        source.resume()
                        sources.append(source)
                    }

                    let capturedSources = sources
                    continuation.onTermination = { _ in
                        for source in capturedSources {
                            source.cancel()
                        }
                    }
                }
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
                        let flags = source.data
                        if flags.contains(.delete) || flags.contains(.rename) {
                            continuation.finish()
                            return
                        }
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
            },
            collectAllFiles: { url in
                AsyncStream { continuation in
                    let task = Task.detached(priority: .utility) {
                        if isInsideGitWorkTree(at: url) {
                            collectFilesUsingGit(at: url, continuation: continuation)
                        } else {
                            collectFilesByWalking(
                                at: url,
                                rootPath: url.path,
                                continuation: continuation
                            )
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in
                        task.cancel()
                    }
                }
            }
        )
    }
}

// MARK: - In-Memory (Tests / E2E)

/// Describes a fake file in the in-memory filesystem.
public struct FakeFile: Sendable {
    public let kind: FileContentKind
    /// Text content for text/markdown/html files. Nil for binary types.
    public let textContent: String?
    /// Path to a real file on disk to serve for binary types (loaded from test bundle).
    public let bundlePath: String?
    /// When true, first read hangs indefinitely (cancelled by task); second read succeeds.
    public let isPending: Bool
    /// When true, the file is removed from the tree after its first successful read and
    /// a directory change is signalled. Used to exercise "file deleted while tab is open".
    public let isEphemeral: Bool

    public static func text(_ content: String) -> FakeFile {
        FakeFile(kind: .text, textContent: content, bundlePath: nil, isPending: false, isEphemeral: false)
    }

    /// A text file that hangs on first read, succeeds on subsequent reads.
    /// Use with `dynamicEntries` on `inMemory()` to test loading indicators
    /// and directory change detection together.
    public static func pendingText(_ content: String) -> FakeFile {
        FakeFile(kind: .text, textContent: content, bundlePath: nil, isPending: true, isEphemeral: false)
    }

    /// A text file that, after its content is returned, removes itself from the tree
    /// and signals a directory change. Used to simulate external file deletion.
    public static func ephemeralText(_ content: String) -> FakeFile {
        FakeFile(kind: .text, textContent: content, bundlePath: nil, isPending: false, isEphemeral: true)
    }

    public static func markdown(_ content: String) -> FakeFile {
        FakeFile(kind: .markdown, textContent: content, bundlePath: nil, isPending: false, isEphemeral: false)
    }

    public static func html(_ content: String) -> FakeFile {
        FakeFile(kind: .html, textContent: content, bundlePath: nil, isPending: false, isEphemeral: false)
    }

    public static func image(bundlePath: String) -> FakeFile {
        FakeFile(kind: .image, textContent: nil, bundlePath: bundlePath, isPending: false, isEphemeral: false)
    }

    public static func pdf(bundlePath: String) -> FakeFile {
        FakeFile(kind: .pdf, textContent: nil, bundlePath: bundlePath, isPending: false, isEphemeral: false)
    }

    public static func video(bundlePath: String) -> FakeFile {
        FakeFile(kind: .video, textContent: nil, bundlePath: bundlePath, isPending: false, isEphemeral: false)
    }

    public static func unsupported() -> FakeFile {
        FakeFile(kind: .unsupported, textContent: nil, bundlePath: nil, isPending: false, isEphemeral: false)
    }
}

/// Describes a fake directory tree for the in-memory filesystem.
public enum FakeEntry: Sendable {
    case file(FakeFile)
    case folder([String: FakeEntry])
}

public extension FileSystemLoadingService {
    /// Creates an in-memory service backed by a fake filesystem tree.
    ///
    /// The tree is built using the actual URL passed to `loadFileTree`, so paths in
    /// `stableIds` and `reverseIds` match the real directory path. Content lookups
    /// use relative path matching so they work regardless of the root directory.
    ///
    /// - Parameters:
    ///   - tree: The initial fake filesystem tree.
    ///   - dynamicEntries: Entries added to the root after a `.pendingText` file is successfully loaded.
    ///     Use together with `.pendingText` to test loading indicators and directory change detection.
    static func inMemory(
        tree: [String: FakeEntry],
        dynamicEntries: [String: FakeEntry] = [:]
    ) -> FileSystemLoadingService {
        // Index files by relative path for flexible content lookup
        var relativeFiles: [String: FakeFile] = [:]
        func collectFiles(_ entries: [String: FakeEntry], prefix: String) {
            for (name, entry) in entries {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                switch entry {
                case let .file(fake):
                    relativeFiles[path] = fake
                case let .folder(children):
                    collectFiles(children, prefix: path)
                }
            }
        }
        collectFiles(tree, prefix: "")
        // Also index dynamic entries so their content is readable
        collectFiles(dynamicEntries, prefix: "")
        let capturedRelFiles = relativeFiles

        // Shared state: tracks which pending files have had their first read attempt.
        // After a pending file's second read succeeds, dynamic entries are activated
        // and a directory change is signalled.
        let pendingAttempted = OSAllocatedUnfairLock<Set<String>>(initialState: [])
        let dynamicActivated = OSAllocatedUnfairLock(initialState: false)
        let dirContinuation = OSAllocatedUnfairLock<AsyncStream<Void>.Continuation?>(initialState: nil)
        // Relative paths that have been "deleted" by ephemeral files being read.
        // Entries in this set are hidden from tree loads and file listings.
        let deletedRelativePaths = OSAllocatedUnfairLock<Set<String>>(initialState: [])

        /// Returns the relative-path key for a full filesystem path, if one exists.
        @Sendable
        func relativePathKey(for path: String) -> String? {
            capturedRelFiles.keys.first(where: { path.hasSuffix("/" + $0) })
        }

        /// Finds the fake file for a full filesystem path by matching its suffix
        /// against the relative path index. Returns nil for paths already deleted.
        @Sendable
        func findFile(for path: String) -> FakeFile? {
            guard let key = relativePathKey(for: path) else { return nil }
            if deletedRelativePaths.withLock({ $0.contains(key) }) { return nil }
            return capturedRelFiles[key]
        }

        return FileSystemLoadingService(
            loadFileTree: { url, expandedPaths, existingIds in
                let rootPath = url.path
                var ids = existingIds

                func stableId(for path: String) -> UUID {
                    if let existing = ids[path] { return existing }
                    let id = UUID()
                    ids[path] = id
                    return id
                }

                var loadedPaths = Set<String>()

                // Merge dynamic entries into tree when activated
                let effectiveTree: [String: FakeEntry]
                if dynamicActivated.withLock({ $0 }) {
                    effectiveTree = tree.merging(dynamicEntries) { _, new in new }
                } else {
                    effectiveTree = tree
                }

                let deleted = deletedRelativePaths.withLock { $0 }

                func buildFolder(
                    _ entries: [String: FakeEntry],
                    path: String,
                    relativePath: String,
                    depth: Int
                ) -> FullFileOrFolder<TextFileContents> {
                    let folderUUID = stableId(for: path)
                    guard depth > 0 || expandedPaths.contains(path) else {
                        return .folder(FullFolder<TextFileContents>(children: [:], persistentID: folderUUID))
                    }
                    loadedPaths.insert(path)
                    var children = OrderedDictionary<String, FullFileOrFolder<TextFileContents>>()
                    for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
                        let childRelative = relativePath.isEmpty ? name : relativePath + "/" + name
                        if deleted.contains(childRelative) { continue }
                        let childPath = path + "/" + name
                        switch entry {
                        case .file:
                            children[name] = .file(
                                File(contents: TextFileContents(text: ""), persistentID: stableId(for: childPath))
                            )
                        case let .folder(subEntries):
                            children[name] = buildFolder(
                                subEntries,
                                path: childPath,
                                relativePath: childRelative,
                                depth: depth - 1
                            )
                        }
                    }
                    return .folder(FullFolder<TextFileContents>(children: children, persistentID: folderUUID))
                }

                let root = buildFolder(effectiveTree, path: rootPath, relativePath: "", depth: 1)
                return FileTreeLoadResult(root: root, stableIds: ids, loadedFolderPaths: loadedPaths)
            },
            detectFileKind: { path in
                findFile(for: path)?.kind ?? .unsupported
            },
            readTextFile: { path in
                guard let fake = findFile(for: path) else { return nil }

                // Pending file: first read hangs, second read succeeds
                if fake.isPending {
                    let isFirstAttempt = pendingAttempted.withLock { attempted in
                        if attempted.contains(path) { return false }
                        attempted.insert(path)
                        return true
                    }
                    if isFirstAttempt {
                        // Hang until the task is cancelled (user navigates away)
                        do {
                            try await Task.sleep(for: .seconds(3_600))
                        } catch {
                            // CancellationError — expected when user selects a different file
                        }
                        return nil
                    }
                    // Second+ read: activate dynamic entries and signal directory change
                    if !dynamicEntries.isEmpty {
                        let wasAlreadyActive = dynamicActivated.withLock { activated in
                            let was = activated
                            activated = true
                            return was
                        }
                        if !wasAlreadyActive {
                            dirContinuation.withLock { continuation in
                                _ = continuation?.yield()
                            }
                        }
                    }
                }

                let content: String?
                if let text = fake.textContent {
                    content = text
                } else if let bundlePath = fake.bundlePath {
                    content = try? String(contentsOfFile: bundlePath, encoding: .utf8)
                } else {
                    content = nil
                }

                // Ephemeral file: after returning content, mark as deleted and signal directory change
                if fake.isEphemeral, let key = relativePathKey(for: path) {
                    let wasNewlyDeleted = deletedRelativePaths.withLock { deleted -> Bool in
                        guard !deleted.contains(key) else { return false }
                        deleted.insert(key)
                        return true
                    }
                    if wasNewlyDeleted {
                        dirContinuation.withLock { continuation in
                            _ = continuation?.yield()
                        }
                    }
                }

                return content
            },
            readImageFile: { path in
                guard let bundlePath = findFile(for: path)?.bundlePath else { return nil }
                return NSImage(contentsOfFile: bundlePath)
            },
            resolveFileURL: { path in
                guard let fake = findFile(for: path) else { return nil }
                if let bundlePath = fake.bundlePath {
                    return URL(fileURLWithPath: bundlePath)
                }
                if let text = fake.textContent {
                    let filename = URL(fileURLWithPath: path).lastPathComponent
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("claudespy-e2e-\(filename)")
                    try? text.write(to: tempURL, atomically: true, encoding: .utf8)
                    return tempURL
                }
                return nil
            },
            directoryChanges: { _ in
                AsyncStream { continuation in
                    dirContinuation.withLock { $0 = continuation }
                    continuation.onTermination = { _ in
                        dirContinuation.withLock { $0 = nil }
                    }
                }
            },
            fileChanges: { _ in
                AsyncStream { $0.finish() }
            },
            collectAllFiles: { url in
                let rootPath = url.path
                var results: [FileSearchResult] = []
                let effectiveTree: [String: FakeEntry]
                if dynamicActivated.withLock({ $0 }) {
                    effectiveTree = tree.merging(dynamicEntries) { _, new in new }
                } else {
                    effectiveTree = tree
                }
                let deleted = deletedRelativePaths.withLock { $0 }
                func collect(_ entries: [String: FakeEntry], prefix: String) {
                    for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
                        let relativePath = prefix.isEmpty ? name : prefix + "/" + name
                        if deleted.contains(relativePath) { continue }
                        switch entry {
                        case .file:
                            let fullPath = rootPath + "/" + relativePath
                            results.append(FileSearchResult(
                                fullPath: fullPath, relativePath: relativePath, name: name
                            ))
                        case let .folder(children):
                            collect(children, prefix: relativePath)
                        }
                    }
                }
                collect(effectiveTree, prefix: "")
                let snapshot = results
                return AsyncStream { continuation in
                    if !snapshot.isEmpty {
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                }
            }
        )
    }
}

// MARK: - Private Helpers

/// OS-level files and directories to skip when building the file tree or
/// walking the filesystem for search.
private let skippedEntries: Set = [
    ".DS_Store", ".Trash", ".Spotlight-V100", ".fseventsd",
    ".TemporaryItems", ".DocumentRevisions-V100",
]

/// Number of files to accumulate before yielding a batch from `collectAllFiles`.
private let collectAllFilesBatchSize = 200

/// Returns `true` if `url` (or any ancestor) contains a `.git` directory or file,
/// which indicates we're inside a git work tree (or worktree of a bare repo).
private func isInsideGitWorkTree(at url: URL) -> Bool {
    let fm = FileManager.default
    var dir = url.standardizedFileURL
    while true {
        let gitPath = dir.appendingPathComponent(".git").path
        if fm.fileExists(atPath: gitPath) { return true }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { return false }
        dir = parent
    }
}

/// Streams file paths from the directory by invoking `git ls-files`, which
/// honours the project's `.gitignore` rules. Files are yielded in batches.
private func collectFilesUsingGit(
    at url: URL,
    continuation: AsyncStream<[FileSearchResult]>.Continuation
) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = [
        "-C", url.path,
        "ls-files",
        "--cached",
        "--others",
        "--exclude-standard",
        "-z",
    ]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        return
    }

    let rootPath = url.path
    let handle = stdoutPipe.fileHandleForReading
    var buffer = Data()
    var batch: [FileSearchResult] = []

    while true {
        if Task.isCancelled {
            if process.isRunning { process.terminate() }
            break
        }
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)

        while let nullIdx = buffer.firstIndex(of: 0) {
            let pathData = buffer.subdata(in: buffer.startIndex..<nullIdx)
            buffer.removeSubrange(buffer.startIndex...nullIdx)
            guard
                !pathData.isEmpty,
                let relativePath = String(data: pathData, encoding: .utf8)
            else { continue }

            let name: String
            if let lastSlash = relativePath.lastIndex(of: "/") {
                name = String(relativePath[relativePath.index(after: lastSlash)...])
            } else {
                name = relativePath
            }

            batch.append(FileSearchResult(
                fullPath: rootPath + "/" + relativePath,
                relativePath: relativePath,
                name: name
            ))

            if batch.count >= collectAllFilesBatchSize {
                continuation.yield(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
    }

    if !batch.isEmpty {
        continuation.yield(batch)
    }

    process.waitUntilExit()
    // Drain stderr to release the FD; ignore content.
    _ = try? stderrPipe.fileHandleForReading.readToEnd()
}

/// Recursively walks `url`, yielding batches of file paths. Used as a fallback
/// when the directory is not part of a git work tree. Skips only `.git` and
/// the OS-level entries that are never useful in search results.
private func collectFilesByWalking(
    at url: URL,
    rootPath: String,
    continuation: AsyncStream<[FileSearchResult]>.Continuation
) {
    var batch: [FileSearchResult] = []
    let fm = FileManager.default
    let prefix = rootPath + "/"

    func walk(_ dir: URL) {
        guard !Task.isCancelled else { return }
        guard
            let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        else { return }

        for item in items {
            if Task.isCancelled { return }
            let name = item.lastPathComponent
            if skippedEntries.contains(name) { continue }
            if name == ".git" { continue }

            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                walk(item)
            } else {
                let fullPath = item.path
                let relativePath = fullPath.hasPrefix(prefix)
                    ? String(fullPath.dropFirst(prefix.count))
                    : name
                batch.append(FileSearchResult(
                    fullPath: fullPath,
                    relativePath: relativePath,
                    name: name
                ))
                if batch.count >= collectAllFilesBatchSize {
                    continuation.yield(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    walk(url)

    if !batch.isEmpty {
        continuation.yield(batch)
    }
}

/// FullFileOrFolder contains File which wraps FileWrapper (not Sendable).
/// Safe here because we only transfer the tree once from Task.detached back to MainActor,
/// and TextFileContents holds only a String with no shared mutable state.
extension FullFileOrFolder: @retroactive @unchecked Sendable { }

/// Recursively loads a directory into a `FullFileOrFolder` hierarchy,
/// respecting the depth limit and expanded paths.
private func loadDirectory(
    at url: URL,
    path: String,
    depth: Int,
    expandedPaths: Set<String>,
    stableIds: inout [String: UUID],
    loadedPaths: inout Set<String>,
    symlinkedPaths: inout Set<String>
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
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
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

        // URL.isDirectoryKey reports false for any symlink — even one pointing to a folder —
        // so symlinks need an explicit follow via FileManager.fileExists to classify the target.
        let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isSymbolicLink = resourceValues?.isSymbolicLink == true
        let isDirectory: Bool
        if isSymbolicLink {
            var dirFlag: ObjCBool = false
            isDirectory = fm.fileExists(atPath: item.path, isDirectory: &dirFlag) && dirFlag.boolValue
        } else {
            isDirectory = resourceValues?.isDirectory == true
        }
        // Preserve the symlink-relative path through recursion so paths shown to the user
        // and stored in stableIds reflect the link chain rather than the resolved target.
        let childPath = path + "/" + name
        if isSymbolicLink {
            symlinkedPaths.insert(childPath)
        }

        if isDirectory {
            // contentsOfDirectory(at:) refuses to traverse a symlink (POSIX "Not a directory"),
            // so resolve before recursing while keeping childPath as the symlink path.
            let urlForRecursion = isSymbolicLink ? item.resolvingSymlinksInPath() : item
            children[name] = loadDirectory(
                at: urlForRecursion,
                path: childPath,
                depth: depth - 1,
                expandedPaths: expandedPaths,
                stableIds: &stableIds,
                loadedPaths: &loadedPaths,
                symlinkedPaths: &symlinkedPaths
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
    let prefix = handle.readData(ofLength: 512)
    guard !prefix.isEmpty else { return true }
    return !prefix.contains(0)
}
