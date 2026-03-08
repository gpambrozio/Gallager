#if os(macOS)
    import ClaudeSpyNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation

    /// Logs push notification sends for E2E test verification.
    ///
    /// In production this is a no-op. In E2E tests it writes to a log file
    /// so scenarios can assert on which push notifications were (or were not) sent.
    @DependencyClient
    public struct PushNotificationLogService: Sendable {
        /// Log that a push notification was sent for a hook event.
        public var logPushSent: @Sendable (
            _ eventType: String,
            _ paneId: String?
        ) -> Void
    }

    // MARK: - E2E Test Support

    public extension PushNotificationLogService {
        /// Factory for E2E tests — appends push sends to a log file.
        /// Format: `eventType|paneId\n`
        static func e2eTest(logPath: String) -> PushNotificationLogService {
            PushNotificationLogService(
                logPushSent: { eventType, paneId in
                    let entry = "\(eventType)|\(paneId ?? "none")\n"
                    let data = Data(entry.utf8)

                    if let handle = FileHandle(forWritingAtPath: logPath) {
                        defer { handle.closeFile() }
                        handle.seekToEndOfFile()
                        handle.write(data)
                    } else {
                        FileManager.default.createFile(atPath: logPath, contents: data)
                    }
                }
            )
        }
    }

    // MARK: - DependencyKey

    extension PushNotificationLogService: DependencyKey {
        public static var previewValue: PushNotificationLogService {
            PushNotificationLogService(logPushSent: { _, _ in })
        }

        public static var liveValue: PushNotificationLogService {
            PushNotificationLogService(logPushSent: { _, _ in })
        }
    }
#endif
