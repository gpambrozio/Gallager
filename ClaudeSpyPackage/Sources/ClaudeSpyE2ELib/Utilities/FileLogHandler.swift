import Foundation
import Logging

/// A swift-log handler that writes plain-text log lines to a file.
/// Used by the E2E coordinator to redirect verbose logs away from the terminal
/// when the `TerminalReporter` is active.
struct FileLogHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    private let label: String
    private let fileHandle: FileHandle

    init(label: String, fileHandle: FileHandle) {
        self.label = label
        self.fileHandle = fileHandle
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let timestamp = Self.formatter.string(from: Date())
        let line = "\(timestamp) \(event.level) \(label): \(event.message)\n"
        fileHandle.write(Data(line.utf8))
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// Bootstraps swift-log to write all output to the given file path.
/// Returns the path for display purposes.
public enum E2ELogging {
    public static func bootstrapFileLogging(to path: String) {
        // Create or truncate the log file
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            // Fall back to default stderr logging if file can't be opened
            return
        }
        handle.seekToEndOfFile()

        LoggingSystem.bootstrap { label in
            FileLogHandler(label: label, fileHandle: handle)
        }
    }
}
