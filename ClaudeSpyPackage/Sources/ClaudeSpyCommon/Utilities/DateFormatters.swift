import Foundation

/// Shared date formatters to avoid repeated allocation
public enum DateFormatters {
    /// Formatter for short time display (e.g., "4:41 PM")
    public static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// ISO8601 formatter for parsing timestamps like "2026-01-03T19:00:56.425838"
    /// Note: nonisolated(unsafe) is safe here because we never mutate the formatter after creation
    public nonisolated(unsafe) static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Parses an ISO8601 timestamp string to Date
    /// - Parameter string: Timestamp in format "2026-01-03T19:00:56.425838"
    /// - Returns: Parsed Date or nil if parsing fails
    public static func parseISO8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        return iso8601WithFractionalSeconds.date(from: string)
    }

    /// Formats a date as relative time for recent events, or time of day for older ones
    public static func relativeTime(for date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 0 {
            // Future date (shouldn't happen, but handle gracefully)
            return shortTime.string(from: date)
        } else if interval < 5 {
            return "just now"
        } else if interval < 60 {
            return "\(Int(interval))s ago"
        } else if interval < 3_600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else {
            return shortTime.string(from: date)
        }
    }
}
