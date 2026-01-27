import Foundation
import Logging

/// Configures the logging system for ClaudeSpy apps.
///
/// Call `bootstrap()` once at app startup, before any Logger instances are created.
/// The log level is determined by the `LOG_LEVEL` environment variable, defaulting to `warning`.
///
/// Valid LOG_LEVEL values: trace, debug, info, notice, warning, error, critical
public enum LoggingConfiguration {
    /// Bootstrap the logging system. Call once at app startup.
    ///
    /// Reads the `LOG_LEVEL` environment variable to determine the minimum log level.
    /// If not set or invalid, defaults to `.warning`.
    ///
    /// - Important: This must be called before any Logger instances are created.
    ///   Typically call this in your App's init() method.
    public static func bootstrap() {
        let level = levelFromEnvironment()
        LoggingSystem.bootstrap { label in
            var handler = OSLogHandler(label: label)
            handler.logLevel = level
            return handler
        }
    }

    /// Reads the LOG_LEVEL environment variable and returns the corresponding level.
    private static func levelFromEnvironment() -> Logging.Logger.Level {
        guard let envValue = ProcessInfo.processInfo.environment["LOG_LEVEL"] else {
            return .warning
        }

        // swift-log's Logger.Level conforms to RawRepresentable with String
        if let level = Logging.Logger.Level(rawValue: envValue.lowercased()) {
            return level
        }

        // Fallback to warning if invalid
        return .warning
    }
}
