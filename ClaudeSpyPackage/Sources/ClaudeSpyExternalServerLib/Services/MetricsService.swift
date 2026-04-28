import Foundation

/// Snapshot of live gauge values queried at scrape time.
/// Computed by the route handler from existing services (no caching).
struct MetricsSnapshot: Sendable {
    let activePairs: Int
    let hostsConnected: Int
    let viewersConnected: Int
    let uptimeSeconds: Int
}

/// Tracks monotonically-increasing counters for the relay server.
/// Gauges are not stored here — they're queried live at render time.
actor MetricsService {
    private(set) var messagesRelayedTotal = 0
    private(set) var pushNotificationsTotal = 0

    func incrementMessagesRelayed() {
        messagesRelayedTotal &+= 1
    }

    func incrementPushNotifications() {
        pushNotificationsTotal &+= 1
    }

    /// Render the full Prometheus text exposition for a scrape.
    func render(snapshot: MetricsSnapshot, buildVersion: String) -> String {
        var lines: [String] = []

        lines.append("# HELP claudespy_messages_relayed_total Total encrypted messages relayed since process start.")
        lines.append("# TYPE claudespy_messages_relayed_total counter")
        lines.append("claudespy_messages_relayed_total \(messagesRelayedTotal)")

        lines.append("# HELP claudespy_push_notifications_total Total push notifications sent to APNs since process start.")
        lines.append("# TYPE claudespy_push_notifications_total counter")
        lines.append("claudespy_push_notifications_total \(pushNotificationsTotal)")

        lines.append("# HELP claudespy_active_pairs Number of currently-paired devices.")
        lines.append("# TYPE claudespy_active_pairs gauge")
        lines.append("claudespy_active_pairs \(snapshot.activePairs)")

        lines.append("# HELP claudespy_ws_connections Active WebSocket connections by device type.")
        lines.append("# TYPE claudespy_ws_connections gauge")
        lines.append("claudespy_ws_connections{device_type=\"host\"} \(snapshot.hostsConnected)")
        lines.append("claudespy_ws_connections{device_type=\"viewer\"} \(snapshot.viewersConnected)")

        lines.append("# HELP claudespy_uptime_seconds Process uptime in seconds.")
        lines.append("# TYPE claudespy_uptime_seconds gauge")
        lines.append("claudespy_uptime_seconds \(snapshot.uptimeSeconds)")

        lines.append("# HELP claudespy_build_info Build version (always 1).")
        lines.append("# TYPE claudespy_build_info gauge")
        lines.append("claudespy_build_info{version=\"\(buildVersion)\"} 1")

        return lines.joined(separator: "\n") + "\n"
    }
}
