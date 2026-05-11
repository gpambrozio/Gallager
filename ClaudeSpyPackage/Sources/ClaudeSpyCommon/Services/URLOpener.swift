import Dependencies
import DependenciesMacros
import Foundation
import os.log

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

/// A dependency for handing URLs off to the system's default handler — i.e.
/// the user's default browser for http/https/ftp, or the registered app for
/// any other scheme.
///
/// The live implementation calls `NSWorkspace.shared.open` on macOS and
/// `UIApplication.shared.open` on iOS. In E2E tests, use `logged(path:)` to
/// redirect calls to an append-only file the orchestrator can read instead of
/// actually launching a browser.
@DependencyClient
public struct URLOpener: Sendable {
    /// Hands the URL to the system's default handler. No-op when called
    /// without a configured implementation.
    public var openInDefaultBrowser: @Sendable (_ url: URL) -> Void
}

// MARK: - File-Backed Implementation (E2E)

public extension URLOpener {
    /// Creates a `URLOpener` that appends each opened URL on its own line to
    /// `path` instead of launching the system browser. Used by E2E tests so
    /// the `.alwaysInDefaultBrowser` flow can be exercised without spawning a
    /// real browser window on every run.
    static func logged(path: String) -> URLOpener {
        let log = URLOpenerLog(path: path)
        return URLOpener(openInDefaultBrowser: { url in
            log.append(url)
        })
    }
}

final private class URLOpenerLog: Sendable {
    private static let logger = Logger(
        subsystem: "com.claudespy",
        category: "URLOpenerLog"
    )

    private let lock = OSAllocatedUnfairLock()
    let path: String

    init(path: String) {
        self.path = path
    }

    func append(_ url: URL) {
        lock.withLock {
            let line = url.absoluteString + "\n"
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    Self.logger.error("Failed to append to URLOpener log at \(self.path): \(error)")
                }
            } else {
                do {
                    try data.write(to: URL(fileURLWithPath: path))
                } catch {
                    Self.logger.error("Failed to create URLOpener log at \(self.path): \(error)")
                }
            }
        }
    }
}

// MARK: - DependencyKey

extension URLOpener: DependencyKey {
    public static var previewValue: URLOpener {
        URLOpener(openInDefaultBrowser: { _ in })
    }

    public static var liveValue: URLOpener {
        #if os(macOS)
            URLOpener(openInDefaultBrowser: { url in
                NSWorkspace.shared.open(url)
            })
        #elseif os(iOS)
            URLOpener(openInDefaultBrowser: { url in
                Task { @MainActor in
                    UIApplication.shared.open(url)
                }
            })
        #endif
    }
}
