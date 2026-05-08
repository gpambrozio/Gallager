import Dependencies
import DependenciesMacros
import Foundation
import os.log

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

/// Image encoding format for a `ClipboardImage`. Determines the file
/// extension when the image is wrapped as a synthetic `DroppedFile` for
/// the relay-forward image-paste flow.
public enum ImageFormat: String, Sendable, Equatable {
    case png
    case tiff

    /// Filename extension to use when saving the clipboard image to disk.
    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .tiff: "tiff"
        }
    }
}

/// Image bytes plus the format they're encoded in.
public struct ClipboardImage: Sendable, Equatable {
    public let data: Data
    public let format: ImageFormat

    public init(data: Data, format: ImageFormat) {
        self.data = data
        self.format = format
    }
}

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

    /// Sets rich text (RTF data + plain text fallback) on the clipboard (macOS only).
    public var setRichText: @Sendable (_ rtfData: Data, _ plainText: String) -> Void

    /// Copies a file URL to the clipboard for Finder paste (macOS only).
    public var setFileURL: @Sendable (_ url: URL) -> Void

    /// Returns true if the clipboard contains image data (macOS only).
    public var hasImage: @Sendable () -> Bool = { false }

    /// Returns the current image on the clipboard, or nil if there is none
    /// (macOS only). Prefers PNG when available, falls back to TIFF.
    public var getImage: @Sendable () -> ClipboardImage? = { nil }
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
            clear: { store.clear() },
            setRichText: { _, plainText in store.write(plainText) },
            setFileURL: { _ in },
            hasImage: { store.readImage() != nil },
            getImage: { store.readImage() }
        )
    }
}

final private class FileBackedClipboard: Sendable {
    private static let logger = Logger(
        subsystem: "com.claudespy",
        category: "FileBackedClipboard"
    )

    private let lock = OSAllocatedUnfairLock()
    let path: String

    init(path: String) {
        self.path = path
    }

    /// Path used to persist binary image bytes. Sibling to the text file so
    /// the E2E runner and tests can read and write images via a deterministic
    /// path without having to pry into the binary clipboard format.
    private var imagePath: String {
        path + ".image"
    }

    /// Path used to persist the image format alongside the bytes.
    private var imageFormatPath: String {
        path + ".image.format"
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
            do {
                try value.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                Self.logger.error("Failed to write clipboard file at \(self.path): \(error)")
            }
        }
    }

    func clear() {
        lock.withLock {
            do {
                try "".write(toFile: path, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(atPath: imagePath)
                try? FileManager.default.removeItem(atPath: imageFormatPath)
            } catch {
                Self.logger.error("Failed to clear clipboard file at \(self.path): \(error)")
            }
        }
    }

    func readImage() -> ClipboardImage? {
        lock.withLock {
            guard let data = FileManager.default.contents(atPath: imagePath), !data.isEmpty else {
                return nil
            }
            let formatData = FileManager.default.contents(atPath: imageFormatPath) ?? Data()
            let formatString = String(data: formatData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let format = ImageFormat(rawValue: formatString) ?? .png
            return ClipboardImage(data: data, format: format)
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
            clear: { store.value = nil },
            setRichText: { _, plainText in store.value = plainText },
            setFileURL: { _ in },
            hasImage: { false },
            getImage: { nil }
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
                },
                setRichText: { rtfData, plainText in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(rtfData, forType: .rtf)
                    NSPasteboard.general.setString(plainText, forType: .string)
                },
                setFileURL: { url in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                },
                hasImage: {
                    let pb = NSPasteboard.general
                    return pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil
                },
                getImage: {
                    let pb = NSPasteboard.general
                    if let png = pb.data(forType: .png) {
                        return ClipboardImage(data: png, format: .png)
                    }
                    if let tiff = pb.data(forType: .tiff) {
                        return ClipboardImage(data: tiff, format: .tiff)
                    }
                    return nil
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
                },
                setRichText: { _, _ in },
                setFileURL: { _ in },
                hasImage: { false },
                getImage: { nil }
            )
        #endif
    }
}

final private class InMemoryClipboard: Sendable {
    private let lock = OSAllocatedUnfairLock<String?>(initialState: nil)

    var value: String? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
