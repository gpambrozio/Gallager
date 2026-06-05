import ClaudeSpyNetworking
import Testing
@testable import ClaudeSpyExternalServerLib

@Suite("MetricsService")
struct MetricsServiceTests {
    @Test("New service has zero counters")
    func zeroOnInit() async {
        let service = MetricsService()
        #expect(await service.messagesRelayedTotal == 0)
        #expect(await service.pushNotificationsTotal == 0)
    }

    @Test("incrementMessagesRelayed increments by one")
    func incrementMessagesRelayed() async {
        let service = MetricsService()
        await service.incrementMessagesRelayed()
        await service.incrementMessagesRelayed()
        #expect(await service.messagesRelayedTotal == 2)
    }

    @Test("incrementPushNotifications increments by one")
    func incrementPushNotifications() async {
        let service = MetricsService()
        await service.incrementPushNotifications()
        #expect(await service.pushNotificationsTotal == 1)
    }

    @Test("render escapes \\, \", and newline in buildVersion label value")
    func renderEscapesBuildVersion() async {
        let service = MetricsService()
        let snapshot = MetricsSnapshot(
            activePairs: 0,
            hostsConnected: 0,
            viewersConnected: 0,
            uptimeSeconds: 0
        )
        // Hostile input: every char that would break the Prometheus label syntax.
        let body = await service.render(snapshot: snapshot, buildVersion: #"a"b\c\#nd"#)
        #expect(body.contains(#"claudespy_build_info{version="a\"b\\c\nd"} 1"#))
    }

    @Test("render returns Prometheus text format with all metrics")
    func renderFormat() async {
        let service = MetricsService()
        await service.incrementMessagesRelayed()
        await service.incrementPushNotifications()
        let snapshot = MetricsSnapshot(
            activePairs: 3,
            hostsConnected: 2,
            viewersConnected: 1,
            uptimeSeconds: 42
        )
        let body = await service.render(snapshot: snapshot, buildVersion: "test-v1")

        #expect(body.contains("# HELP claudespy_messages_relayed_total"))
        #expect(body.contains("# TYPE claudespy_messages_relayed_total counter"))
        #expect(body.contains("claudespy_messages_relayed_total 1"))
        #expect(body.contains("claudespy_push_notifications_total 1"))
        #expect(body.contains("claudespy_active_pairs 3"))
        #expect(body.contains("claudespy_ws_connections{device_type=\"host\"} 2"))
        #expect(body.contains("claudespy_ws_connections{device_type=\"viewer\"} 1"))
        #expect(body.contains("claudespy_uptime_seconds 42"))
        #expect(body.contains("claudespy_build_info{version=\"test-v1\"} 1"))
    }
}

@Suite("ConnectionHub aggregate counts")
struct ConnectionHubCountsTests {
    @Test("connectionCounts returns zero for empty hub")
    func emptyHub() async {
        let hub = ConnectionHub()
        let counts = await hub.connectionCounts()
        #expect(counts.host == 0)
        #expect(counts.viewer == 0)
    }
}
