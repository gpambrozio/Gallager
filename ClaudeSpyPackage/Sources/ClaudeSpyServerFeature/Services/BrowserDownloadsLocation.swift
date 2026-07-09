import Dependencies
import Foundation

/// Where browser-tab downloads are saved.
///
/// The live value is the user's `~/Downloads`. E2E runs override it via the
/// `--downloads-dir` launch argument so downloads land in a TCC-free temp
/// directory — writing to the real `~/Downloads` triggers a macOS consent
/// prompt ("Gallager would like to access files in your Downloads folder")
/// that an unattended test app can never answer, wedging the download and
/// the navigation that spawned it.
public struct BrowserDownloadsLocation: Sendable {
    public var directory: @Sendable () -> URL

    public init(directory: @escaping @Sendable () -> URL) {
        self.directory = directory
    }
}

extension BrowserDownloadsLocation: DependencyKey {
    public static var liveValue: BrowserDownloadsLocation {
        BrowserDownloadsLocation {
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }
    }

    /// A fixed directory, used by the `--downloads-dir` E2E override. The
    /// directory itself is created by the download machinery right before
    /// the first write (`BrowserDownload.download(_:decideDestinationUsing:…)`).
    public static func fixed(path: String) -> BrowserDownloadsLocation {
        BrowserDownloadsLocation {
            URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// Whether the `--downloads-dir` launch override may wipe `path` at
    /// startup for deterministic collision-naming assertions. Only
    /// directories inside the system temp directory — where the E2E
    /// orchestrator creates them — qualify; recursively deleting any other
    /// caller-supplied path (say, a hand-typed `--downloads-dir ~/Downloads`)
    /// would destroy real files. Both sides are standardized and
    /// symlink-resolved so `/tmp/…` and `/private/tmp/…` spellings agree.
    public static func isSafeToWipe(
        _ path: String,
        temporaryDirectory: String = NSTemporaryDirectory()
    ) -> Bool {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL
            .resolvingSymlinksInPath().path
        let tempRoot = URL(fileURLWithPath: temporaryDirectory, isDirectory: true).standardizedFileURL
            .resolvingSymlinksInPath().path
        return resolved.hasPrefix(tempRoot + "/")
    }
}
