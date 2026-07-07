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

    /// A fixed directory, created on first use. Used by the `--downloads-dir`
    /// E2E override.
    public static func fixed(path: String) -> BrowserDownloadsLocation {
        BrowserDownloadsLocation {
            URL(fileURLWithPath: path, isDirectory: true)
        }
    }
}
