import Files
import Foundation

/// A simple text-based payload conforming to `FileContents` for the file browser.
/// Non-UTF-8 files are represented with a placeholder message.
struct TextFileContents: FileContents {
    var text: String

    init(text: String) {
        self.text = text
    }

    init(name: String, data: Data) throws {
        self.text = String(data: data, encoding: .utf8) ?? "[Binary file]"
    }

    func data() throws -> Data {
        return Data(text.utf8)
    }

    mutating func flush() throws { }
}
