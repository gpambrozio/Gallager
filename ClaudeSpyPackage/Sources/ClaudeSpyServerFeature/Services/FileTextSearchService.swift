import Dependencies
import DependenciesMacros
import Foundation

// MARK: - File Text Search Match

/// One matching line from a file content search.
public struct FileTextSearchMatch: Sendable, Identifiable, Equatable {
    public var id: String {
        "\(fullPath):\(lineNumber)"
    }

    public let fullPath: String
    public let relativePath: String
    public let name: String
    /// 1-based line number where the match was found.
    public let lineNumber: Int
    /// The matching line, possibly truncated for very long lines.
    public let lineText: String

    public init(
        fullPath: String,
        relativePath: String,
        name: String,
        lineNumber: Int,
        lineText: String
    ) {
        self.fullPath = fullPath
        self.relativePath = relativePath
        self.name = name
        self.lineNumber = lineNumber
        self.lineText = lineText
    }
}

// MARK: - Dependency Client

/// Service for searching the contents of files under a directory.
///
/// Defined as a separate dependency from `FileSystemLoadingService` so e2e tests
/// can stub deterministic results without relying on the on-disk filesystem.
@DependencyClient
public struct FileTextSearchService: Sendable {
    /// Streams batches of content matches found under `rootURL` for `query`.
    ///
    /// - Parameters:
    ///   - rootURL: The directory to search inside.
    ///   - query: The literal substring to find. Empty queries return no
    ///     results. Matching is case-insensitive.
    /// - Returns: An async stream that yields incremental batches of matches
    ///   as they're discovered, then finishes.
    public var searchFileContents: @Sendable (
        _ rootURL: URL,
        _ query: String
    ) -> AsyncStream<[FileTextSearchMatch]> = { _, _ in
        AsyncStream { $0.finish() }
    }
}

// MARK: - DependencyKey

extension FileTextSearchService: DependencyKey {
    public static var liveValue: FileTextSearchService {
        FileTextSearchService(
            searchFileContents: { rootURL, query in
                AsyncStream { continuation in
                    guard !query.isEmpty else {
                        continuation.finish()
                        return
                    }
                    let task = Task.detached(priority: .utility) {
                        await searchFilesUnder(rootURL: rootURL, query: query, continuation: continuation)
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

public extension FileTextSearchService {
    /// Creates an in-memory service backed by the same fake filesystem tree as
    /// `FileSystemLoadingService.inMemory(tree:)`. Searches each text file's
    /// content for the query and returns matches deterministically.
    ///
    /// `dynamicEntries` mirrors `FileSystemLoadingService.inMemory(tree:dynamicEntries:)`:
    /// pass the same dictionary so files that appear at runtime are also
    /// reachable by content search. We can't observe activation here without
    /// coupling the two services, so all entries are searchable from the
    /// start — adequate for E2E scenarios that use the dynamic feature for
    /// tree changes rather than search-result changes.
    static func inMemory(
        tree: [String: FakeEntry],
        dynamicEntries: [String: FakeEntry] = [:]
    ) -> FileTextSearchService {
        // Snapshot text content keyed by relative path so search results match
        // the same paths the file browser renders.
        var textFiles: [(relativePath: String, content: String)] = []
        func collect(_ entries: [String: FakeEntry], prefix: String) {
            for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                switch entry {
                case let .file(fake):
                    if let text = fake.textContent {
                        textFiles.append((path, text))
                    }
                case let .folder(children):
                    collect(children, prefix: path)
                }
            }
        }
        collect(tree, prefix: "")
        collect(dynamicEntries, prefix: "")
        let snapshot = textFiles

        return FileTextSearchService(
            searchFileContents: { rootURL, query in
                AsyncStream { continuation in
                    guard !query.isEmpty else {
                        continuation.finish()
                        return
                    }
                    let rootPath = rootURL.path
                    var batch: [FileTextSearchMatch] = []
                    let lowered = query.lowercased()
                    for (relativePath, content) in snapshot {
                        let name = (relativePath as NSString).lastPathComponent
                        let fullPath = rootPath + "/" + relativePath
                        var lineNumber = 0
                        for line in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                            lineNumber += 1
                            if line.range(of: lowered, options: .caseInsensitive) != nil {
                                batch.append(FileTextSearchMatch(
                                    fullPath: fullPath,
                                    relativePath: relativePath,
                                    name: name,
                                    lineNumber: lineNumber,
                                    lineText: trimLineForDisplay(String(line))
                                ))
                            }
                        }
                    }
                    if !batch.isEmpty {
                        continuation.yield(batch)
                    }
                    continuation.finish()
                }
            }
        )
    }
}

// MARK: - Private Helpers

/// Maximum number of bytes to read from a single file before giving up. Files
/// larger than this are skipped to keep the search bounded — text content
/// search is meant for source code, not multi-megabyte logs or generated
/// blobs left in the tree.
private let maxFileBytesForSearch = 2 * 1_024 * 1_024 // 2 MB

/// Maximum displayed length of a matching line. Longer lines are truncated to
/// keep the result row from blowing the sidebar layout.
private let maxLineDisplayLength = 240

/// Number of matches to accumulate before yielding a batch.
private let searchBatchSize = 50

/// Number of file paths to accumulate before yielding a batch from the
/// enumeration stage (`git ls-files` parser and the directory walker). Kept
/// as a named constant so both producers share the same threshold.
private let searchFilesBatchSize = 100

/// Walks every file under `rootURL` (respecting `.gitignore` when in a git work
/// tree), reads each as UTF-8 text, and yields batches of matches whose lines
/// case-insensitively contain `query`.
private func searchFilesUnder(
    rootURL: URL,
    query: String,
    continuation: AsyncStream<[FileTextSearchMatch]>.Continuation
) async {
    // Pre-lowercase the needle once and run a case-insensitive `range(of:)`
    // per line. The previous `line.lowercased().contains(...)` allocated a
    // fresh copy of every line, which adds up on near-cap (≈2 MB) source
    // files where the line count can run into the tens of thousands.
    let lowered = query.lowercased()
    let rootPath = rootURL.path
    var batch: [FileTextSearchMatch] = []
    let fileStream = AsyncStream<[FileSearchResult]> { stream in
        let task = Task.detached(priority: .utility) {
            collectFilesForSearch(
                at: rootURL,
                rootPath: rootPath,
                continuation: stream
            )
            stream.finish()
        }
        stream.onTermination = { _ in
            task.cancel()
        }
    }

    for await batchOfPaths in fileStream {
        if Task.isCancelled { return }
        for fileResult in batchOfPaths {
            if Task.isCancelled { return }
            guard let content = readTextForSearch(path: fileResult.fullPath) else { continue }
            var lineNumber = 0
            for line in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                lineNumber += 1
                if line.range(of: lowered, options: .caseInsensitive) != nil {
                    batch.append(FileTextSearchMatch(
                        fullPath: fileResult.fullPath,
                        relativePath: fileResult.relativePath,
                        name: fileResult.name,
                        lineNumber: lineNumber,
                        lineText: trimLineForDisplay(String(line))
                    ))
                    if batch.count >= searchBatchSize {
                        continuation.yield(batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
            }
        }
    }

    if !batch.isEmpty {
        continuation.yield(batch)
    }
}

/// Same enumeration strategy as `FileSystemLoadingService.collectAllFiles`:
/// `git ls-files` if available, otherwise a plain directory walk skipping
/// `.git` and OS-level entries.
private func collectFilesForSearch(
    at url: URL,
    rootPath: String,
    continuation: AsyncStream<[FileSearchResult]>.Continuation
) {
    if isInsideGitWorkTreeForSearch(at: url) {
        runGitLsFilesForSearch(at: url, rootPath: rootPath, continuation: continuation)
    } else {
        walkDirectoryForSearch(at: url, rootPath: rootPath, continuation: continuation)
    }
}

private func isInsideGitWorkTreeForSearch(at url: URL) -> Bool {
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

private func runGitLsFilesForSearch(
    at url: URL,
    rootPath: String,
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
    // Reap the child unconditionally — a thrown error inside the read
    // loop or a cancellation arriving mid-`availableData` would
    // otherwise leave `git ls-files` running past the end of the
    // search.
    defer {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        _ = try? stderrPipe.fileHandleForReading.readToEnd()
    }
    let handle = stdoutPipe.fileHandleForReading
    var buffer = Data()
    var batch: [FileSearchResult] = []
    while true {
        if Task.isCancelled { break }
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
            if batch.count >= searchFilesBatchSize {
                continuation.yield(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
    }
    if !batch.isEmpty {
        continuation.yield(batch)
    }
}

private func walkDirectoryForSearch(
    at url: URL,
    rootPath: String,
    continuation: AsyncStream<[FileSearchResult]>.Continuation
) {
    let skippedNames: Set = [
        ".DS_Store", ".Trash", ".Spotlight-V100", ".fseventsd",
        ".TemporaryItems", ".DocumentRevisions-V100", ".git",
    ]
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
            if skippedNames.contains(name) { continue }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
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
                if batch.count >= searchFilesBatchSize {
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

/// Reads up to `maxFileBytesForSearch` bytes from `path` and decodes as UTF-8.
/// Skips files that look binary (null byte in the first 512 bytes).
private func readTextForSearch(path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let prefix = handle.readData(ofLength: 512)
    if prefix.isEmpty { return nil }
    if prefix.contains(0) { return nil }
    let remaining = handle.readData(ofLength: maxFileBytesForSearch - prefix.count)
    var combined = prefix
    combined.append(remaining)
    return String(data: combined, encoding: .utf8)
}

/// Trims `line` for display: strips leading whitespace and clips overly long
/// lines so a single match doesn't blow up the sidebar.
private func trimLineForDisplay(_ line: String) -> String {
    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
    if trimmed.count > maxLineDisplayLength {
        return String(trimmed.prefix(maxLineDisplayLength)) + "…"
    }
    return String(trimmed)
}
