#if os(macOS)
    import AppKit
    import ClaudeSpyServerFeature
    import Files
    import Foundation
    import OrderedCollections

    // MARK: - Fake File Types

    /// Describes a fake file in the in-memory filesystem.
    public struct FakeFile: Sendable {
        public let kind: FileContentKind
        /// Text content for text/markdown/html files. Nil for binary types (image, pdf, video).
        public let textContent: String?
        /// Path to a real file on disk to serve for binary types (loaded from test bundle).
        public let bundlePath: String?

        public static func text(_ content: String) -> FakeFile {
            FakeFile(kind: .text, textContent: content, bundlePath: nil)
        }

        public static func markdown(_ content: String) -> FakeFile {
            FakeFile(kind: .markdown, textContent: content, bundlePath: nil)
        }

        public static func html(_ content: String) -> FakeFile {
            FakeFile(kind: .html, textContent: content, bundlePath: nil)
        }

        public static func image(bundlePath: String) -> FakeFile {
            FakeFile(kind: .image, textContent: nil, bundlePath: bundlePath)
        }

        public static func pdf(bundlePath: String) -> FakeFile {
            FakeFile(kind: .pdf, textContent: nil, bundlePath: bundlePath)
        }

        public static func video(bundlePath: String) -> FakeFile {
            FakeFile(kind: .video, textContent: nil, bundlePath: bundlePath)
        }

        public static func unsupported() -> FakeFile {
            FakeFile(kind: .unsupported, textContent: nil, bundlePath: nil)
        }
    }

    /// Describes a fake directory tree for the in-memory filesystem.
    public enum FakeEntry: Sendable {
        case file(FakeFile)
        case folder([String: FakeEntry])
    }

    // MARK: - In-Memory Service

    public extension FileSystemLoadingService {
        /// Creates an in-memory service backed by a fake filesystem tree.
        /// The root path is used as the base for all generated paths.
        static func inMemory(
            rootPath: String = "/FakeRoot",
            tree: [String: FakeEntry] = defaultFakeTree()
        ) -> FileSystemLoadingService {
            // Build flat path→file lookup and stable IDs from the tree
            var files: [String: FakeFile] = [:]
            var stableIds: [String: UUID] = [:]
            var folderPaths: Set<String> = []

            func walk(_ entries: [String: FakeEntry], parentPath: String) {
                stableIds[parentPath] = stableIds[parentPath] ?? UUID()
                folderPaths.insert(parentPath)
                for (name, entry) in entries {
                    let path = parentPath + "/" + name
                    stableIds[path] = stableIds[path] ?? UUID()
                    switch entry {
                    case let .file(fake):
                        files[path] = fake
                    case let .folder(children):
                        walk(children, parentPath: path)
                    }
                }
            }
            walk(tree, parentPath: rootPath)

            let capturedFiles = files
            let capturedStableIds = stableIds
            let capturedFolderPaths = folderPaths

            return FileSystemLoadingService(
                loadFileTree: { _, expandedPaths, existingIds in
                    // Merge existing IDs with our stable set
                    var ids = capturedStableIds
                    for (k, v) in existingIds {
                        ids[k] = v
                    }

                    // Build only folders that are in expandedPaths or at depth 0
                    func buildFolder(
                        _ entries: [String: FakeEntry],
                        path: String,
                        depth: Int
                    ) -> FullFileOrFolder<TextFileContents> {
                        let folderUUID = ids[path]!
                        let shouldLoad = depth > 0 || expandedPaths.contains(path)
                        guard shouldLoad else {
                            return .folder(FullFolder<TextFileContents>(children: [:], persistentID: folderUUID))
                        }

                        var children = OrderedDictionary<String, FullFileOrFolder<TextFileContents>>()
                        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
                            let childPath = path + "/" + name
                            switch entry {
                            case .file:
                                let fileUUID = ids[childPath]!
                                children[name] = .file(
                                    File(contents: TextFileContents(text: ""), persistentID: fileUUID)
                                )
                            case let .folder(subEntries):
                                children[name] = buildFolder(subEntries, path: childPath, depth: depth - 1)
                            }
                        }
                        return .folder(FullFolder<TextFileContents>(children: children, persistentID: folderUUID))
                    }

                    let root = buildFolder(tree, path: rootPath, depth: 1)
                    return FileTreeLoadResult(root: root, stableIds: ids, loadedFolderPaths: capturedFolderPaths)
                },
                detectFileKind: { path in
                    capturedFiles[path]?.kind ?? .unsupported
                },
                readTextFile: { path in
                    if let fake = capturedFiles[path] {
                        if let text = fake.textContent { return text }
                        if let bundlePath = fake.bundlePath {
                            return try? String(contentsOfFile: bundlePath, encoding: .utf8)
                        }
                    }
                    return nil
                },
                readImageFile: { path in
                    if let bundlePath = capturedFiles[path]?.bundlePath {
                        return NSImage(contentsOfFile: bundlePath)
                    }
                    return nil
                },
                fileChanges: { _ in
                    // No file changes in the fake filesystem
                    AsyncStream { $0.finish() }
                }
            )
        }

        // MARK: - Default Fake Tree

        /// Builds a fake filesystem tree with sample files for all supported viewer types.
        ///
        /// - Parameters:
        ///   - imagePath: Path to a sample image file (e.g. from test bundle).
        ///   - pdfPath: Path to a sample PDF file.
        ///   - videoPath: Path to a sample video file.
        /// - Returns: A tree suitable for `inMemory(tree:)`.
        static func defaultFakeTree(
            imagePath: String? = nil,
            pdfPath: String? = nil,
            videoPath: String? = nil
        ) -> [String: FakeEntry] {
            let imagePath = imagePath ?? Bundle.module.path(forResource: "test_image", ofType: "png", inDirectory: "SampleFiles")
            let pdfPath = pdfPath ?? Bundle.module.path(forResource: "test_pdf", ofType: "pdf", inDirectory: "SampleFiles")
            let videoPath = videoPath ?? Bundle.module.path(forResource: "test_video", ofType: "mp4", inDirectory: "SampleFiles")
            var tree: [String: FakeEntry] = [
                "README.md": .file(.markdown("""
                # Fake Project

                This is a **test project** for the file browser.

                ## Features
                - Folder recursion
                - Multiple file types
                - Markdown rendering
                """)),
                "hello.txt": .file(.text("Hello, world!\nThis is a plain text file.\n")),
                "page.html": .file(.html("""
                <!DOCTYPE html>
                <html>
                <head><title>Test Page</title></head>
                <body>
                    <h1>Hello from HTML</h1>
                    <p>This is a test HTML page rendered in the file browser.</p>
                </body>
                </html>
                """)),
                "binary.dat": .file(.unsupported()),
                "src": .folder([
                    "main.swift": .file(.text("""
                    import Foundation

                    @main
                    struct App {
                        static func main() {
                            print("Hello, world!")
                        }
                    }
                    """)),
                    "utils": .folder([
                        "helper.swift": .file(.text("""
                        /// A helper function for testing folder recursion.
                        func greet(_ name: String) -> String {
                            "Hello, \\(name)!"
                        }
                        """)),
                    ]),
                ]),
                "docs": .folder([
                    "guide.md": .file(.markdown("""
                    # User Guide

                    ## Getting Started
                    1. Open the app
                    2. Select a session
                    3. Browse files

                    ## Tips
                    - Use the context menu to copy paths
                    - Images scale to fit the pane
                    """)),
                ]),
            ]
            if let imagePath {
                tree["photo.png"] = .file(.image(bundlePath: imagePath))
            }
            if let pdfPath {
                tree["document.pdf"] = .file(.pdf(bundlePath: pdfPath))
            }
            if let videoPath {
                tree["clip.mp4"] = .file(.video(bundlePath: videoPath))
            }
            return tree
        }
    }
#endif
