import Foundation
import Logging
import os

/// LogHandler that forwards swift-log messages to Apple's os.Logger.
///
/// This bridges the swift-log API to the unified logging system,
/// preserving Console.app integration and system-level log management.
struct OSLogHandler: LogHandler {
    private let osLogger: os.Logger

    var logLevel: Logging.Logger.Level = .trace
    var metadata: Logging.Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    init(label: String) {
        // Convert label to subsystem/category
        // Labels like "com.claudespy.sessionstore" become subsystem "com.claudespy", category "sessionstore"
        let subsystem = "com.claudespy"
        let category = label.replacingOccurrences(of: "com.claudespy.", with: "")
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
    }

    func log(event: LogEvent) {
        let osLevel = event.level.osLogType
        let formattedMessage = formatMessage(event.message, metadata: event.metadata)
        osLogger.log(level: osLevel, "\(formattedMessage, privacy: .public)")
    }

    private func formatMessage(_ message: Logging.Logger.Message, metadata: Logging.Logger.Metadata?) -> String {
        var result = message.description

        let allMetadata = self.metadata.merging(metadata ?? [:]) { _, new in new }
        if !allMetadata.isEmpty {
            let metaString = allMetadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            result += " [\(metaString)]"
        }

        return result
    }
}

extension Logging.Logger.Level {
    var osLogType: OSLogType {
        switch self {
        case .trace: return .debug
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .default
        case .error: return .error
        case .critical: return .fault
        }
    }
}
