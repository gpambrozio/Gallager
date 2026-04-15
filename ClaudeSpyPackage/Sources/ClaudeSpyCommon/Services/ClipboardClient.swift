import Dependencies
import DependenciesMacros
import Foundation

/// A dependency for reading and writing the system clipboard.
///
/// The live implementation uses NSPasteboard (macOS) or UIPasteboard (iOS).
/// In E2E tests, use `fileBacked(path:)` to isolate each app instance's
/// clipboard to a file — the E2E runner reads the same file to verify.
@DependencyClient
public struct ClipboardClient: Sendable {
    /// Returns the current string on the clipboard, or nil if empty.
    public var getString: @Sendable () -> String? = { nil }

    /// Sets a string value on the clipboard.
    public var setString: @Sendable (_ value: String) -> Void

    /// Clears the clipboard.
    public var clear: @Sendable () -> Void
}

// MARK: - File-Backed Implementation (E2E)

public extension ClipboardClient {
    /// Creates a `ClipboardClient` backed by a file on disk.
    ///
    /// Each app instance gets its own file path (derived from instance number),
    /// so two instances on the same machine have isolated clipboards. The E2E
    /// runner reads from the same file to verify clipboard contents.
    static func fileBacked(path: String) -> ClipboardClient {
        let store = FileBackedClipboard(path: path)
        return ClipboardClient(
            getString: { store.read() },
            setString: { value in store.write(value) },
            clear: { store.clear() }
        )
    }
}

final private class FileBackedClipboard: @unchecked Sendable {
    private let lock = NSLock()
    let path: String

    init(path: String) {
        self.path = path
    }

    func read() -> String? {
        lock.withLock {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            let value = String(data: data, encoding: .utf8)
            return value?.isEmpty == true ? nil : value
        }
    }

    func write(_ value: String) {
        lock.withLock {
            try? value.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func clear() {
        lock.withLock {
            try? "".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - DependencyKey

extension ClipboardClient: DependencyKey {
    public static var previewValue: ClipboardClient {
        let store = InMemoryClipboard()
        return ClipboardClient(
            getString: { store.value },
            setString: { value in store.value = value },
            clear: { store.value = nil }
        )
    }

    public static var liveValue: ClipboardClient {
        #if os(macOS)
            ClipboardClient(
                getString: {
                    NSPasteboard.general.string(forType: .string)
                },
                setString: { value in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                },
                clear: {
                    NSPasteboard.general.clearContents()
                }
            )
        #elseif os(iOS)
            ClipboardClient(
                getString: {
                    UIPasteboard.general.string
                },
                setString: { value in
                    UIPasteboard.general.string = value
                },
                clear: {
                    UIPasteboard.general.string = ""
                }
            )
        #endif
    }
}

final private class InMemoryClipboard: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?

    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif
