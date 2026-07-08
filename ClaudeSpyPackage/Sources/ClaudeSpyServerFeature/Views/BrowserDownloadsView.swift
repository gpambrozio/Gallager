import AppKit
import ClaudeSpyCommon
import SwiftUI
@preconcurrency import WebKit

/// Live state for one file download started from a browser tab.
///
/// Acts as the `WKDownloadDelegate` for its `WKDownload` so destination
/// selection, completion, and failure all land here. `WKDownload.delegate` is
/// a weak reference and this object strongly retains the download, so the
/// pairing stays alive exactly as long as the owning `BrowserTabState` keeps
/// the item in its `downloads` array.
@Observable
@MainActor
final class BrowserDownload: NSObject, Identifiable, WKDownloadDelegate {
    enum Phase: Equatable {
        case inProgress
        case completed
        case failed(String)
        case cancelled
    }

    let id = UUID()
    /// Name shown in the downloads bar. Starts as a best guess from the
    /// request URL and is replaced by the server's suggested filename once
    /// the response arrives.
    private(set) var filename: String
    /// Where the finished file lands. Set when the destination is decided;
    /// `nil` until then and for downloads that never got that far. The
    /// transfer itself writes to `inProgressURL` and is moved here by
    /// `downloadDidFinish`.
    private(set) var destinationURL: URL?
    private(set) var phase: Phase = .inProgress
    /// Download progress in `0...1`, or `nil` while the total size is
    /// unknown (server sent no Content-Length) so the bar can render an
    /// indeterminate spinner instead of a stuck-at-zero gauge.
    private(set) var fractionCompleted: Double?

    /// `nil` only for preview fixtures, which have no live transfer.
    @ObservationIgnored private let download: WKDownload?
    @ObservationIgnored private let destinationDirectory: URL
    /// The Safari-style `name.ext.download` intermediate the transfer writes
    /// to before `downloadDidFinish` moves it onto `destinationURL`. Anything
    /// that tears the download down without finishing it (tab close, app
    /// quit) leaves at worst a `.download` file that can't be mistaken for a
    /// completed download.
    @ObservationIgnored private var inProgressURL: URL?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?

    init(download: WKDownload, destinationDirectory: URL) {
        self.download = download
        self.destinationDirectory = destinationDirectory
        self.filename = download.originalRequest?.url?.lastPathComponent.removingPercentEncoding
            ?? download.originalRequest?.url?.lastPathComponent
            ?? "Download"
        super.init()
        download.delegate = self

        // `Progress` KVO fires on whatever thread updates the download, so
        // hop back to the main actor before touching observed state.
        self.progressObservation = download.progress.observe(
            \.fractionCompleted, options: [.initial, .new]
        ) { [weak self] progress, _ in
            let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            Task { @MainActor [weak self] in
                guard let self, self.phase == .inProgress else { return }
                self.fractionCompleted = fraction
            }
        }
    }

    /// Preview-only fixture: a row in an arbitrary phase with no live
    /// `WKDownload` behind it, so Xcode previews can render every bar state
    /// without starting real transfers.
    private init(previewFilename: String, phase: Phase, fractionCompleted: Double?) {
        self.download = nil
        self.destinationDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        self.filename = previewFilename
        self.phase = phase
        self.fractionCompleted = fractionCompleted
        super.init()
    }

    static func previewFixture(
        filename: String,
        phase: Phase,
        fractionCompleted: Double? = nil
    ) -> BrowserDownload {
        BrowserDownload(
            previewFilename: filename, phase: phase, fractionCompleted: fractionCompleted
        )
    }

    /// Cancels an in-flight download. The phase flips immediately so the
    /// trailing `didFailWithError` callback (WebKit reports user cancellation
    /// as `NSURLErrorCancelled`) doesn't repaint the row as a failure.
    func cancel() {
        guard phase == .inProgress, let download else { return }
        phase = .cancelled
        let partialFile = inProgressURL
        download.cancel { _ in
            // WKDownload leaves the partially-written file at the
            // destination; a cancelled download shouldn't litter ~/Downloads.
            // Deleting in the completion handler guarantees WebKit has
            // stopped writing first.
            if let partialFile {
                try? FileManager.default.removeItem(at: partialFile)
            }
        }
    }

    /// The intermediate path the transfer writes to before being moved onto
    /// its final name — `report.pdf` downloads as `report.pdf.download`.
    private static func inProgressURL(for destination: URL) -> URL {
        destination.appendingPathExtension("download")
    }

    /// Picks a path in `directory` that doesn't collide with an existing
    /// file, Safari-style: `name.ext`, then `name-2.ext`, `name-3.ext`, …
    /// `WKDownload` fails outright when handed a path that already exists,
    /// so this must be checked immediately before starting the write.
    static func uniqueDestinationURL(
        preferredFilename: String,
        in directory: URL,
        fileExists: (URL) -> Bool
    ) -> URL {
        // Defense-in-depth: the suggested name is server-controlled
        // (Content-Disposition / URL path), and `appendingPathComponent`
        // would follow a crafted "../../evil" out of the downloads
        // directory. WebKit sanitizes `suggestedFilename` today, but that's
        // undocumented upstream behavior — strip directory components here
        // too, and reject names that are nothing but path dots.
        let sanitized = (preferredFilename as NSString).lastPathComponent
        let fallback = sanitized.isEmpty || sanitized == "/" || sanitized.allSatisfy { $0 == "." }
            ? "Download"
            : sanitized
        let base = (fallback as NSString).deletingPathExtension
        let ext = (fallback as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fallback)
        var counter = 2
        while fileExists(candidate) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    // MARK: - WKDownloadDelegate

    nonisolated func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        // WebKit invokes download delegate methods on the main thread, same
        // as the navigation/UI delegates wired in BrowserView.
        MainActor.assumeIsolated {
            // A no-op for ~/Downloads; needed when an E2E override points at
            // a temp directory that doesn't exist yet.
            try? FileManager.default.createDirectory(
                at: destinationDirectory, withIntermediateDirectories: true
            )
            // A name is taken when either the final file or another
            // transfer's `.download` intermediate already claims it, so two
            // concurrent downloads of the same name dedup correctly.
            let destination = Self.uniqueDestinationURL(
                preferredFilename: suggestedFilename,
                in: destinationDirectory
            ) { candidate in
                FileManager.default.fileExists(atPath: candidate.path)
                    || FileManager.default.fileExists(atPath: Self.inProgressURL(for: candidate).path)
            }
            filename = destination.lastPathComponent
            destinationURL = destination
            let intermediate = Self.inProgressURL(for: destination)
            inProgressURL = intermediate
            completionHandler(intermediate)
        }
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        MainActor.assumeIsolated {
            if let inProgressURL, let reserved = destinationURL {
                do {
                    // The final name was reserved when the destination was
                    // decided, but a file may have appeared there since —
                    // re-unique rather than fail the finished download.
                    let target = FileManager.default.fileExists(atPath: reserved.path)
                        ? Self.uniqueDestinationURL(
                            preferredFilename: reserved.lastPathComponent,
                            in: destinationDirectory
                        ) { FileManager.default.fileExists(atPath: $0.path) }
                        : reserved
                    try FileManager.default.moveItem(at: inProgressURL, to: target)
                    destinationURL = target
                    filename = target.lastPathComponent
                } catch {
                    phase = .failed(error.localizedDescription)
                    try? FileManager.default.removeItem(at: inProgressURL)
                    return
                }
            }
            phase = .completed
            fractionCompleted = 1
        }
    }

    nonisolated func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        MainActor.assumeIsolated {
            guard phase == .inProgress else { return }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                phase = .cancelled
            } else {
                phase = .failed(error.localizedDescription)
            }
            // Failed and cancelled downloads shouldn't leave a partial file
            // behind at the destination.
            if let inProgressURL {
                try? FileManager.default.removeItem(at: inProgressURL)
            }
        }
    }
}

// MARK: - Downloads Bar

/// Compact bar pinned under the web content listing the tab's downloads.
/// Rows show live progress while downloading; finished rows offer
/// "Show in Finder" (completed) or the failure reason, plus a dismiss
/// button that removes the row (cancelling the download if still running).
struct BrowserDownloadsBar: View {
    let downloads: [BrowserDownload]
    let onRemove: (BrowserDownload) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(downloads) { download in
                BrowserDownloadRow(download: download) {
                    onRemove(download)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Downloads")
    }
}

private struct BrowserDownloadRow: View {
    let download: BrowserDownload
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            statusIcon

            Text(download.filename)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            switch download.phase {
            case .inProgress:
                if let fraction = download.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 160)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 160)
                }
            case .completed:
                Button("Show in Finder") {
                    if let url = download.destinationURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
            case let .failed(message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            case .cancelled:
                Text("Cancelled")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                onRemove()
            } label: {
                Symbols.xmarkCircleFill.image
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(download.phase == .inProgress ? "Cancel download" : "Clear")
            .accessibilityLabel(download.phase == .inProgress ? "Cancel download" : "Clear download")
        }
        .font(.callout)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch download.phase {
        case .inProgress:
            Symbols.arrowDownCircle.image
                .foregroundStyle(.secondary)
        case .completed:
            Symbols.checkmarkCircleFill.image
                .foregroundStyle(.green)
        case .failed:
            Symbols.exclamationmarkCircleFill.image
                .foregroundStyle(.red)
        case .cancelled:
            Symbols.xmarkCircle.image
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Previews

#Preview("BrowserDownloadsBar — all states") {
    BrowserDownloadsBar(
        downloads: [
            .previewFixture(filename: "report.pdf", phase: .inProgress, fractionCompleted: 0.35),
            .previewFixture(filename: "unknown-size.bin", phase: .inProgress),
            .previewFixture(filename: "release-notes-2.txt", phase: .completed),
            .previewFixture(
                filename: "flaky-download.zip",
                phase: .failed("The network connection was lost.")
            ),
            .previewFixture(filename: "cancelled.dmg", phase: .cancelled),
        ],
        onRemove: { _ in }
    )
    .frame(width: 720)
}
