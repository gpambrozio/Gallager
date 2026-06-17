#if os(macOS)
    import ClaudeSpyNetworking
    import Foundation
    import Testing
    @testable import ClaudeSpyServerFeature

    /// Tests for the durable cross-session usage aggregation store (issue #598):
    /// per-session delta accounting, project/day attribution, the overview rollup,
    /// and persistence across "restarts" (a fresh store over the same file).
    struct UsageAggregationStoreTests {
        /// A fixed UTC calendar so day keys are deterministic regardless of the
        /// machine's timezone.
        private var utc: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }

        private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = hour
            return utc.date(from: components)!
        }

        /// A telemetry snapshot carrying the cumulative fields the store reads.
        private func telemetry(
            tokens: Int = 0,
            cost: Double = 0,
            commits: Int = 0,
            activeTime: Int = 0,
            linesAdded: Int = 0,
            linesRemoved: Int = 0
        ) -> SessionTelemetry {
            SessionTelemetry(
                tokensUsed: tokens,
                costUSD: cost,
                activeTimeSeconds: activeTime,
                linesAdded: linesAdded,
                linesRemoved: linesRemoved,
                commitCount: commits
            )
        }

        private func tempFile() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("usage-test-\(UUID().uuidString).json")
        }

        private func makeStore(_ url: URL) -> UsageAggregationStore {
            UsageAggregationStore(fileURL: url, calendar: utc)
        }

        @Test("Records only the delta of cumulative snapshots")
        func accumulatesDeltas() async {
            let url = tempFile()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = makeStore(url)
            let day = date(2_026, 6, 16)

            await store.record(projectPath: "/proj/a", sessionID: "s1", telemetry: telemetry(tokens: 100, cost: 1), date: day)
            await store.record(projectPath: "/proj/a", sessionID: "s1", telemetry: telemetry(tokens: 250, cost: 2.5), date: day)

            let overview = await store.overview(asOf: day)
            // Cumulative latest is 250 / $2.50, reached via deltas 100 + 150.
            #expect(overview.todayTokens == 250)
            #expect(overview.todayCostUSD == 2.5)
            #expect(overview.todaySessionCount == 1)
        }

        @Test("Today totals and project ranking aggregate across sessions")
        func aggregatesAcrossSessionsAndProjects() async {
            let url = tempFile()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = makeStore(url)
            let day = date(2_026, 6, 16)

            await store.record(projectPath: "/proj/a", sessionID: "s1", telemetry: telemetry(tokens: 100, cost: 1, commits: 1), date: day)
            await store.record(projectPath: "/proj/a", sessionID: "s2", telemetry: telemetry(tokens: 50, cost: 0.5), date: day)
            await store.record(projectPath: "/proj/b", sessionID: "s3", telemetry: telemetry(tokens: 200, cost: 2), date: day)

            let overview = await store.overview(asOf: day)
            #expect(overview.todaySessionCount == 3)
            #expect(overview.todayCostUSD == 3.5)
            #expect(overview.todayCommits == 1)
            #expect(overview.todayTokens == 350)

            // Ranked by cost: b ($2.00) before a ($1.50).
            #expect(overview.projects.map(\.projectName) == ["b", "a"])
            let projectA = overview.projects.first { $0.projectName == "a" }
            #expect(projectA?.sessionCount == 2)
            #expect(projectA?.commits == 1)
        }

        @Test("Deltas attribute to the day they are observed")
        func attributesDeltasPerDay() async {
            let url = tempFile()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = makeStore(url)

            await store.record(projectPath: "/proj/a", sessionID: "s1", telemetry: telemetry(tokens: 100, cost: 1), date: date(2_026, 6, 15))
            // Same session continues the next day; only the new $2.00 lands on 6/16.
            await store.record(projectPath: "/proj/a", sessionID: "s1", telemetry: telemetry(tokens: 400, cost: 3), date: date(2_026, 6, 16))

            let overview = await store.overview(asOf: date(2_026, 6, 16))
            #expect(overview.todayCostUSD == 2)
            #expect(overview.todayTokens == 300)

            let byDay = Dictionary(uniqueKeysWithValues: overview.days.map { ($0.day, $0.costUSD) })
            #expect(byDay["2026-06-15"] == 1)
            #expect(byDay["2026-06-16"] == 2)
        }

        @Test("Aggregates persist across a restart and don't double-count")
        func persistsAcrossRestartWithoutDoubleCounting() async {
            let url = tempFile()
            defer { try? FileManager.default.removeItem(at: url) }
            let day = date(2_026, 6, 16)

            let first = makeStore(url)
            await first.record(projectPath: "/proj/a", sessionID: "s1", telemetry: telemetry(tokens: 100, cost: 1), date: day)

            // Fresh store over the same file == an app restart: records and the
            // per-session baseline are reloaded.
            let restarted = makeStore(url)
            let afterLoad = await restarted.overview(asOf: day)
            #expect(afterLoad.todayCostUSD == 1)

            // The same session continues post-restart. Because the baseline was
            // restored, only the $0.50 increment is added — not the full $1.50.
            await restarted.record(projectPath: "/proj/a", sessionID: "s1", telemetry: telemetry(tokens: 150, cost: 1.5), date: day)
            let afterContinue = await restarted.overview(asOf: day)
            #expect(afterContinue.todayCostUSD == 1.5)
            #expect(afterContinue.todayTokens == 150)
        }

        @Test("evictSession drops the baseline; the record totals remain")
        func evictDropsBaselineKeepsRecords() async {
            let url = tempFile()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = makeStore(url)
            let day = date(2_026, 6, 16)

            await store.record(projectPath: "/proj/a", sessionID: "s1", telemetry: telemetry(tokens: 100, cost: 1), date: day)
            await store.evictSession("s1")

            // Accrued total survives the evict.
            #expect(await store.overview(asOf: day).todayCostUSD == 1)

            // The baseline is gone, so re-recording the same cumulative counts
            // fresh (a new session reusing the id) — proving the evict cleared it.
            await store.record(projectPath: "/proj/a", sessionID: "s1", telemetry: telemetry(tokens: 100, cost: 1), date: day)
            #expect(await store.overview(asOf: day).todayTokens == 200)
        }

        @Test("Blank project path or session id is ignored")
        func ignoresBlankKeys() async {
            let url = tempFile()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = makeStore(url)
            let day = date(2_026, 6, 16)

            await store.record(projectPath: "   ", sessionID: "s1", telemetry: telemetry(tokens: 100, cost: 1), date: day)
            await store.record(projectPath: "/proj/a", sessionID: "", telemetry: telemetry(tokens: 100, cost: 1), date: day)

            #expect(await store.overview(asOf: day).isEmpty)
        }

        @Test("A counter that goes backwards never subtracts from totals")
        func clampsBackwardCounter() async {
            let url = tempFile()
            defer { try? FileManager.default.removeItem(at: url) }
            let store = makeStore(url)
            let day = date(2_026, 6, 16)

            await store.record(projectPath: "/proj/a", sessionID: "s1", telemetry: telemetry(tokens: 100, cost: 1), date: day)
            // A spurious lower cumulative (reset / reused id): clamp the delta at 0.
            await store.record(projectPath: "/proj/a", sessionID: "s1", telemetry: telemetry(tokens: 10, cost: 0.1), date: day)

            #expect(await store.overview(asOf: day).todayCostUSD == 1)
        }
    }
#endif
