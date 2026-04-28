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
        let body = await service.render(snapshot: snapshot, buildVersion: "test-1.0")

        #expect(body.contains("# HELP claudespy_messages_relayed_total"))
        #expect(body.contains("# TYPE claudespy_messages_relayed_total counter"))
        #expect(body.contains("claudespy_messages_relayed_total 1"))
        #expect(body.contains("claudespy_push_notifications_total 1"))
        #expect(body.contains("claudespy_active_pairs 3"))
        #expect(body.contains("claudespy_ws_connections{device_type=\"host\"} 2"))
        #expect(body.contains("claudespy_ws_connections{device_type=\"viewer\"} 1"))
        #expect(body.contains("claudespy_uptime_seconds 42"))
        #expect(body.contains("claudespy_build_info{version=\"test-1.0\"} 1"))
    }
}
