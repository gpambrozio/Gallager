import Foundation
import Testing
@testable import ClaudeSpyServerFeature

/// Covers the pure download-destination and error-filtering logic behind the
/// browser's new download and error-surfacing features (issue #639). The
/// WKWebView-driven parts (delegate wiring, progress observation, the SwiftUI
/// chrome) can't be unit-tested here, so this focuses on the deterministic
/// helpers: filename de-duplication, filename sanitization, and which
/// navigation errors are worth showing the user.
@MainActor
struct BrowserDownloadTests {
    private let directory = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)

    // MARK: - Destination resolution

    @Test("A non-colliding filename is used verbatim in the downloads folder")
    func noCollision() {
        let destination = BrowserTabState.resolveDownloadDestination(
            directory: directory,
            suggestedFilename: "report.pdf",
            fileExists: { _ in false }
        )
        #expect(destination.lastPathComponent == "report.pdf")
        #expect(destination.deletingLastPathComponent().path == directory.path)
    }

    @Test("A colliding filename gets a numeric suffix before the extension")
    func collisionSuffix() {
        let taken: Set = ["report.pdf"]
        let destination = BrowserTabState.resolveDownloadDestination(
            directory: directory,
            suggestedFilename: "report.pdf",
            fileExists: { taken.contains($0.lastPathComponent) }
        )
        #expect(destination.lastPathComponent == "report (1).pdf")
    }

    @Test("The suffix increments until a free name is found")
    func collisionIncrements() {
        let taken: Set = ["report.pdf", "report (1).pdf", "report (2).pdf"]
        let destination = BrowserTabState.resolveDownloadDestination(
            directory: directory,
            suggestedFilename: "report.pdf",
            fileExists: { taken.contains($0.lastPathComponent) }
        )
        #expect(destination.lastPathComponent == "report (3).pdf")
    }

    @Test("An extensionless filename still gets a bare numeric suffix")
    func collisionNoExtension() {
        let taken: Set = ["archive"]
        let destination = BrowserTabState.resolveDownloadDestination(
            directory: directory,
            suggestedFilename: "archive",
            fileExists: { taken.contains($0.lastPathComponent) }
        )
        #expect(destination.lastPathComponent == "archive (1)")
    }

    @Test("Only the final extension is preserved when de-duplicating multi-dot names")
    func collisionMultiDot() {
        let taken: Set = ["archive.tar.gz"]
        let destination = BrowserTabState.resolveDownloadDestination(
            directory: directory,
            suggestedFilename: "archive.tar.gz",
            fileExists: { taken.contains($0.lastPathComponent) }
        )
        #expect(destination.lastPathComponent == "archive.tar (1).gz")
    }

    @Test("A blank suggested filename falls back to a default before resolving")
    func collisionBlankFallsBack() {
        let destination = BrowserTabState.resolveDownloadDestination(
            directory: directory,
            suggestedFilename: "",
            fileExists: { _ in false }
        )
        #expect(destination.lastPathComponent == "download")
    }

    // MARK: - Filename sanitization

    @Test("Path separators are stripped so a download can't escape the folder")
    func sanitizesPathSeparators() {
        #expect(BrowserTabState.sanitizedFilename("../../etc/passwd") == "..-..-etc-passwd")
        #expect(BrowserTabState.sanitizedFilename("a/b/c.txt") == "a-b-c.txt")
    }

    @Test("Blank, whitespace-only, and dot-only names fall back to a default")
    func sanitizesDegenerateNames() {
        #expect(BrowserTabState.sanitizedFilename("") == "download")
        #expect(BrowserTabState.sanitizedFilename("   ") == "download")
        #expect(BrowserTabState.sanitizedFilename(".") == "download")
        #expect(BrowserTabState.sanitizedFilename("..") == "download")
    }

    @Test("An ordinary filename passes through sanitization unchanged")
    func sanitizesOrdinaryName() {
        #expect(BrowserTabState.sanitizedFilename("photo 1.jpeg") == "photo 1.jpeg")
    }

    // MARK: - Error filtering

    @Test("Cancelled and download-conversion errors are not surfaced")
    func filtersNonErrors() {
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect(BrowserTabState.shouldReport(cancelled) == false)

        // WebKitErrorFrameLoadInterruptedByPolicyChange — fired when a
        // navigation is converted into a download.
        let frameInterrupted = NSError(domain: "WebKitErrorDomain", code: 102)
        #expect(BrowserTabState.shouldReport(frameInterrupted) == false)
    }

    @Test("Real network failures are surfaced")
    func reportsRealErrors() {
        let hostNotFound = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        #expect(BrowserTabState.shouldReport(hostNotFound))

        let notConnected = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(BrowserTabState.shouldReport(notConnected))

        // A different WebKit error code (not the download-conversion one) is a
        // genuine failure worth showing.
        let otherWebKitError = NSError(domain: "WebKitErrorDomain", code: 101)
        #expect(BrowserTabState.shouldReport(otherWebKitError))
    }
}
