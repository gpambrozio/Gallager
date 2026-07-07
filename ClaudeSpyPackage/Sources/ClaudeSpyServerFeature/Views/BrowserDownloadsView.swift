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
    /// Where the file is being written. Set when the destination is decided;
    /// `nil` until then and for downloads that never got that far.
    private(set) var destinationURL: URL?
    private(set) var phase: Phase = .inProgress
    /// Download progress in `0...1`, or `nil` while the total size is
    /// unknown (server sent no Content-Length) so the bar can render an
    /// indeterminate spinner instead of a stuck-at-zero gauge.
    private(set) var fractionCompleted: Double?

    @ObservationIgnored private let download: WKDownload
    @ObservationIgnored private let destinationDirectory: URL
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

    /// Cancels an in-flight download. The phase flips immediately so the
    /// trailing `didFailWithError` callback (WebKit reports user cancellation
    /// as `NSURLErrorCancelled`) doesn't repaint the row as a failure.
    func cancel() {
        guard phase == .inProgress else { return }
        phase = .cancelled
        let partialFile = destinationURL
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

    /// Picks a path in `directory` that doesn't collide with an existing
    /// file, Safari-style: `name.ext`, then `name-2.ext`, `name-3.ext`, …
    /// `WKDownload` fails outright when handed a path that already exists,
    /// so this must be checked immediately before starting the write.
    static func uniqueDestinationURL(
        preferredFilename: String,
        in directory: URL,
        fileExists: (URL) -> Bool
    ) -> URL {
        let fallback = preferredFilename.isEmpty ? "Download" : preferredFilename
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
            let destination = Self.uniqueDestinationURL(
                preferredFilename: suggestedFilename,
                in: destinationDirectory
            ) { FileManager.default.fileExists(atPath: $0.path) }
            filename = destination.lastPathComponent
            destinationURL = destination
            completionHandler(destination)
        }
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        MainActor.assumeIsolated {
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
            if let destinationURL {
                try? FileManager.default.removeItem(at: destinationURL)
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
