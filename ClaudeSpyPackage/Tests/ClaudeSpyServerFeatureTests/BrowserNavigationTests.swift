import Foundation
import Testing
import WebKit
@testable import ClaudeSpyServerFeature

@Suite("BrowserNavigationPolicy")
struct BrowserNavigationPolicyTests {
    @Test("Explicit cancellation is ignorable")
    func cancelledIsIgnorable() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect(BrowserNavigationPolicy.isIgnorableNavigationError(error))
    }

    @Test("WebKit frame-load-interrupted (download handoff) is ignorable")
    func frameLoadInterruptedIsIgnorable() {
        let error = NSError(domain: "WebKitErrorDomain", code: 102)
        #expect(BrowserNavigationPolicy.isIgnorableNavigationError(error))
    }

    @Test("Real load failures are not ignorable")
    func realFailuresAreNotIgnorable() {
        let dnsFailure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        #expect(!BrowserNavigationPolicy.isIgnorableNavigationError(dnsFailure))

        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(!BrowserNavigationPolicy.isIgnorableNavigationError(offline))

        // Code 102 only means "frame load interrupted" in WebKit's domain.
        let unrelated102 = NSError(domain: NSURLErrorDomain, code: 102)
        #expect(!BrowserNavigationPolicy.isIgnorableNavigationError(unrelated102))
    }

    @Test(
        "Content-Disposition attachment detection",
        arguments: [
            ("attachment", true),
            ("attachment; filename=\"report.pdf\"", true),
            ("ATTACHMENT; filename=x.zip", true),
            (" attachment ; filename=x", true),
            ("inline", false),
            ("inline; filename=\"image.png\"", false),
        ]
    )
    func attachmentDisposition(disposition: String, expected: Bool) throws {
        let url = try #require(URL(string: "https://example.com/file"))
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Disposition": disposition]
            )
        )
        #expect(BrowserNavigationPolicy.isAttachment(response) == expected)
    }

    @Test("Responses without a disposition header are not attachments")
    func missingDispositionHeader() throws {
        let url = try #require(URL(string: "https://example.com/page"))
        let httpResponse = try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])
        )
        #expect(!BrowserNavigationPolicy.isAttachment(httpResponse))

        // Non-HTTP responses (file:, data:) can't carry the header at all.
        let plainResponse = URLResponse(
            url: url, mimeType: "text/html", expectedContentLength: 10, textEncodingName: nil
        )
        #expect(!BrowserNavigationPolicy.isAttachment(plainResponse))
    }
}

@Suite("BrowserDownload destination")
@MainActor
struct BrowserDownloadDestinationTests {
    private let directory = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)

    @Test("First download keeps the suggested name")
    func keepsSuggestedName() {
        let url = BrowserDownload.uniqueDestinationURL(
            preferredFilename: "report.pdf",
            in: directory
        ) { _ in false }
        #expect(url.path == "/tmp/downloads/report.pdf")
    }

    @Test("Collisions append -2, -3, … before the extension")
    func collisionsGetCounterSuffix() {
        var existing: Set = ["/tmp/downloads/report.pdf", "/tmp/downloads/report-2.pdf"]
        let url = BrowserDownload.uniqueDestinationURL(
            preferredFilename: "report.pdf",
            in: directory
        ) { existing.contains($0.path) }
        #expect(url.path == "/tmp/downloads/report-3.pdf")

        existing = ["/tmp/downloads/archive"]
        let extensionless = BrowserDownload.uniqueDestinationURL(
            preferredFilename: "archive",
            in: directory
        ) { existing.contains($0.path) }
        #expect(extensionless.path == "/tmp/downloads/archive-2")
    }

    @Test("Empty suggested filename falls back to a generic name")
    func emptyFilenameFallsBack() {
        let url = BrowserDownload.uniqueDestinationURL(
            preferredFilename: "",
            in: directory
        ) { _ in false }
        #expect(url.path == "/tmp/downloads/Download")
    }

    @Test("Dotfile names survive the counter suffix")
    func dotfileNames() {
        let existing: Set = ["/tmp/downloads/.gitignore"]
        let url = BrowserDownload.uniqueDestinationURL(
            preferredFilename: ".gitignore",
            in: directory
        ) { existing.contains($0.path) }
        #expect(url.path == "/tmp/downloads/.gitignore-2")
    }
}
