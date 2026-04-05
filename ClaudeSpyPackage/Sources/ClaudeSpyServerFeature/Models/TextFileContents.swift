import Files
import Foundation

/// A simple text-based payload conforming to `FileContents` for the file browser.
/// Non-UTF-8 files are represented with a placeholder message.
public struct TextFileContents: FileContents {
    public var text: String

    public init(text: String) {
        self.text = text
    }

    public init(name: String, data: Data) throws {
        self.text = String(data: data, encoding: .utf8) ?? "[Binary file]"
    }

    public func data() throws -> Data {
        return Data(text.utf8)
    }

    public mutating func flush() throws { }
}
