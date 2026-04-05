#if os(macOS)
    import ClaudeSpyServerFeature
    import Foundation

    public extension FileSystemLoadingService {
        /// Builds a fake filesystem tree with sample files for all supported viewer types.
        /// Binary sample files are resolved from the E2E bundle automatically.
        ///
        /// - Parameters:
        ///   - imagePath: Path to a sample image file. Defaults to bundled test_image.png.
        ///   - pdfPath: Path to a sample PDF file. Defaults to bundled test_pdf.pdf.
        ///   - videoPath: Path to a sample video file. Defaults to bundled test_video.mp4.
        /// - Returns: A tree suitable for `inMemory(tree:)`.
        static func defaultFakeTree(
            imagePath: String? = nil,
            pdfPath: String? = nil,
            videoPath: String? = nil
        ) -> [String: FakeEntry] {
            let imagePath = imagePath ?? Bundle.module.path(
                forResource: "test_image", ofType: "png", inDirectory: "SampleFiles"
            )
            let pdfPath = pdfPath ?? Bundle.module.path(
                forResource: "test_pdf", ofType: "pdf", inDirectory: "SampleFiles"
            )
            let videoPath = videoPath ?? Bundle.module.path(
                forResource: "test_video", ofType: "mp4", inDirectory: "SampleFiles"
            )

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
