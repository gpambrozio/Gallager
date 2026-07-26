#if os(macOS)
    import ClaudeSpyCommon
    import Clocks
    import ConcurrencyExtras
    import Dependencies
    import Foundation
    import GallagerPluginProtocol
    import Testing
    @testable import ClaudeSpyServerFeature

    // MARK: - Harness

    /// Records every callback the manager fires and holds the in-memory registry
    /// file the closures read/write.
    @MainActor
    final class UpdateHarness {
        var registry: PluginRegistryFile
        /// Updates the stub checker reports (filtered to the entries it is given).
        var updates: [PluginUpdate] = []
        /// Plugin ids whose single-entry (manual) check throws.
        var failingChecks: Set<String> = []
        /// When false, the batch checker reports that no manifest fetch
        /// completed (offline pass).
        var batchFetchSucceeds = true
        /// Keyed by manifest-URL string; unset URLs succeed with the id parsed
        /// from the URL path (matching `urlEntry`'s manifest-URL shape).
        var installResults: [String: Result<PluginInstaller.InstallOutcome, InstallError>] = [:]
        var activePlugins: Set<String> = []
        /// Plugin ids reported as live-disabled by `isPluginEnabled`.
        var disabledPlugins: Set<String> = []
        /// Plugin ids whose `enablePlugin` reports a failed re-enable.
        var enableFailures: Set<String> = []
        /// Plugin ids whose `installBridge` reports an error.
        var bridgeFailures: Set<String> = []
        /// id -> set of roots ("default" or the folder path) with the bridge installed.
        var installedRoots: [String: Set<String>] = [:]
        var additionalFolders: [String: [String]] = [:]
        var log: [String] = []
        var notifications: [String] = []

        /// When true, `installBridge`/`checkUpdates` suspend on an unstructured
        /// gate instead of returning immediately, so a test can observe what
        /// runs (or doesn't) while a scheduled op is mid-flight.
        var gateBridge = false
        var gateChecks = false
        private var bridgeGate: CheckedContinuation<Void, Never>?
        private var checkGate: CheckedContinuation<Void, Never>?

        func releaseBridgeGate() {
            bridgeGate?.resume()
            bridgeGate = nil
        }

        func releaseCheckGate() {
            checkGate?.resume()
            checkGate = nil
        }

        init(entries: [PluginRegistryEntry]) {
            registry = PluginRegistryFile(schemaVersion: 1, plugins: entries)
        }

        func makeManager(automaticTriggers: Bool = false) -> PluginUpdateManager {
            PluginUpdateManager(
                callbacks: PluginUpdateManager.Callbacks(
                    loadRegistry: { self.registry },
                    saveRegistry: { self.registry = $0 },
                    checkUpdates: { entries in
                        self.log.append("check:\(entries.map(\.id).sorted().joined(separator: ","))")
                        if self.gateChecks {
                            await withCheckedContinuation { self.checkGate = $0 }
                        }
                        let updates = self.updates.filter { update in entries.contains { $0.id == update.id } }
                        return (updates, self.batchFetchSucceeds)
                    },
                    checkUpdate: { entry in
                        self.log.append("checkOne:\(entry.id)")
                        if self.failingChecks.contains(entry.id) {
                            throw InstallError.invalidSchema
                        }
                        return self.updates.first { $0.id == entry.id }
                    },
                    installFromURL: { url in
                        self.log.append("install:\(url.absoluteString)")
                        if let result = self.installResults[url.absoluteString] {
                            return result
                        }
                        // urlEntry manifests look like https://example.com/<id>/plugin.json;
                        // echo the id back so the mismatch guard passes by default.
                        let id = url.pathComponents.count > 1 ? url.pathComponents[1] : "stub"
                        return .success(.installed(id: id))
                    },
                    hasActiveSessions: { self.activePlugins.contains($0) },
                    isPluginEnabled: { !self.disabledPlugins.contains($0) },
                    disablePlugin: { self.log.append("disable:\($0)") },
                    enablePlugin: { id in
                        self.log.append("enable:\(id)")
                        return !self.enableFailures.contains(id)
                    },
                    installStatus: { id, root in
                        self.installedRoots[id]?.contains(root ?? "default") == true
                            ? .installed(version: nil)
                            : .notInstalled
                    },
                    installBridge: { id, root in
                        self.log.append("bridge:\(id):\(root ?? "default")")
                        if self.gateBridge {
                            await withCheckedContinuation { self.bridgeGate = $0 }
                        }
                        return self.bridgeFailures.contains(id) ? "bridge write failed" : nil
                    },
                    additionalConfigFolders: { self.additionalFolders[$0] ?? [] },
                    displayName: { $0.capitalized },
                    currentAppVersion: { "2.0.0" },
                    notify: { self.notifications.append($0) }
                ),
                automaticTriggersEnabled: automaticTriggers
            )
        }
    }

    func urlEntry(
        id: String,
        version: String,
        autoUpdate: Bool = true,
        needsBridgeRefresh: Bool = false
    ) -> PluginRegistryEntry {
        PluginRegistryEntry(
            id: id, version: version, source: .url, runtime: .sidecar, enabled: true,
            manifestURL: URL(string: "https://example.com/\(id)/plugin.json"),
            bundleURL: URL(string: "https://cdn.example.com/\(id).zip"),
            bundleSHA256: "abc", autoUpdate: autoUpdate, needsBridgeRefresh: needsBridgeRefresh
        )
    }

    // MARK: - Accessors

    @Suite("PluginUpdateManager accessors")
    @MainActor
    struct PluginUpdateManagerAccessorTests {
        @Test("isUpdatable is true only for url entries with a manifestURL")
        func isUpdatableFiltersSources() throws {
            let folderEntry = PluginRegistryEntry(
                id: "dev", version: "1.0.0", source: .folder, runtime: .sidecar, enabled: true,
                manifestURL: nil, bundleURL: nil, bundleSHA256: nil
            )
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0"), folderEntry])
                let manager = harness.makeManager()
                #expect(manager.isUpdatable("pi") == true)
                #expect(manager.isUpdatable("dev") == false)
                #expect(manager.isUpdatable("missing") == false)
            }
        }

        @Test("setAutoUpdate persists through the registry file")
        func setAutoUpdatePersists() throws {
            withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: {
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                let manager = harness.makeManager()
                #expect(manager.autoUpdateEnabled("pi") == true)
                manager.setAutoUpdate("pi", enabled: false)
                #expect(manager.autoUpdateEnabled("pi") == false)
                #expect(harness.registry.plugins.first?.autoUpdate == false)
            }
        }
    }

    // MARK: - Apply

    @Suite("PluginUpdateManager applyUpdate")
    @MainActor
    struct PluginUpdateManagerApplyTests {
        func makeUpdate(id: String = "pi", newVersion: String = "2.0.0", sourceChanged: Bool = false) -> PluginUpdate {
            PluginUpdate(id: id, currentVersion: "1.0.0", newVersion: newVersion, sourceChanged: sourceChanged)
        }

        @Test("idle plugin: install, then disable→enable, then bridges refreshed only where installed")
        func idlePluginHotRestartsAndRefreshesBridges() async throws {
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                harness.additionalFolders["pi"] = ["/proj/a", "/proj/b"]
                harness.installedRoots["pi"] = ["default", "/proj/b"] // /proj/a never opted in
                let manager = harness.makeManager()

                let result = await manager.applyUpdate(makeUpdate())

                #expect(result == .applied(needsAppRestart: false))
                #expect(harness.log == [
                    "install:https://example.com/pi/plugin.json",
                    "disable:pi",
                    "enable:pi",
                    "bridge:pi:default",
                    "bridge:pi:/proj/b",
                ])
                #expect(harness.registry.plugins.first?.needsBridgeRefresh == false)
                #expect(manager.restartNotices == [
                    PluginRestartNotice(pluginID: "pi", displayName: "Pi", newVersion: "2.0.0", needsAppRestart: false),
                ])
                #expect(manager.inlineStatus["pi"] == .updated(version: "2.0.0", needsAppRestart: false))
            }
        }

        @Test("busy plugin: install only, needsBridgeRefresh persisted, app restart required")
        func busyPluginDefersBridgeRefresh() async throws {
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                harness.activePlugins = ["pi"]
                harness.installedRoots["pi"] = ["default"]
                let manager = harness.makeManager()

                let result = await manager.applyUpdate(makeUpdate())

                #expect(result == .applied(needsAppRestart: true))
                #expect(harness.log == ["install:https://example.com/pi/plugin.json"]) // no disable/enable/bridge
                #expect(harness.registry.plugins.first?.needsBridgeRefresh == true)
                #expect(manager.restartNotices.first?.needsAppRestart == true)
            }
        }

        @Test("sourceChanged update is never installed")
        func sourceChangedSkipped() async throws {
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                let manager = harness.makeManager()

                let result = await manager.applyUpdate(makeUpdate(sourceChanged: true))

                #expect(result == .skippedSourceChanged)
                #expect(harness.log.isEmpty)
                #expect(manager.inlineStatus["pi"] == .updateAvailableNewSource(version: "2.0.0"))
                #expect(manager.restartNotices.isEmpty)
            }
        }

        @Test("install failure reports failed and leaves no notice")
        func installFailureReported() async throws {
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                harness.installResults["https://example.com/pi/plugin.json"] = .failure(.hashMismatch)
                let manager = harness.makeManager()

                let result = await manager.applyUpdate(makeUpdate())

                guard case .failed = result else {
                    Issue.record("expected .failed, got \(result)")
                    return
                }
                #expect(manager.restartNotices.isEmpty)
                #expect(harness.registry.plugins.first?.needsBridgeRefresh == false)
            }
        }

        @Test("boot sweep refreshes bridges for flagged entries and clears the flag")
        func sweepRefreshesAndClearsFlag() async throws {
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "2.0.0", needsBridgeRefresh: true)])
                harness.installedRoots["pi"] = ["default"]
                let manager = harness.makeManager(automaticTriggers: false)

                manager.start()
                await manager.waitForPendingRuns()

                #expect(harness.log == ["bridge:pi:default"])
                #expect(harness.registry.plugins.first?.needsBridgeRefresh == false)
            }
        }

        @Test("failed re-enable after the hot swap reports failed and flags the bridge refresh")
        func enableFailureSurfaces() async throws {
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                harness.installedRoots["pi"] = ["default"]
                harness.enableFailures = ["pi"]
                let manager = harness.makeManager()

                let result = await manager.applyUpdate(makeUpdate())

                guard case .failed = result else {
                    Issue.record("expected .failed, got \(result)")
                    return
                }
                // Install and the disable→enable attempt ran, but no bridge
                // touch and no celebratory notice for a sidecar that isn't up.
                #expect(harness.log == [
                    "install:https://example.com/pi/plugin.json",
                    "disable:pi",
                    "enable:pi",
                ])
                #expect(manager.restartNotices.isEmpty)
                #expect(harness.registry.plugins.first?.needsBridgeRefresh == true)
            }
        }

        @Test("failed bridge re-install keeps the update applied but flags a retry")
        func bridgeFailureFlagsRetry() async throws {
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                harness.installedRoots["pi"] = ["default"]
                harness.bridgeFailures = ["pi"]
                let manager = harness.makeManager()

                let result = await manager.applyUpdate(makeUpdate())

                #expect(result == .applied(needsAppRestart: false))
                #expect(harness.registry.plugins.first?.needsBridgeRefresh == true)
            }
        }

        @Test("a sweep whose bridge re-install fails keeps the flag for the next launch")
        func failedSweepKeepsFlag() async throws {
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "2.0.0", needsBridgeRefresh: true)])
                harness.installedRoots["pi"] = ["default"]
                harness.bridgeFailures = ["pi"]
                let manager = harness.makeManager(automaticTriggers: false)

                manager.start()
                await manager.waitForPendingRuns()

                #expect(harness.log == ["bridge:pi:default"])
                #expect(harness.registry.plugins.first?.needsBridgeRefresh == true)
            }
        }

        @Test("an installed id that differs from the update's id is refused")
        func manifestIDMismatchRefused() async throws {
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                harness.installResults["https://example.com/pi/plugin.json"] =
                    .success(.installed(id: "impostor"))
                let manager = harness.makeManager()

                let result = await manager.applyUpdate(makeUpdate())

                guard case let .failed(message) = result else {
                    Issue.record("expected .failed, got \(result)")
                    return
                }
                #expect(message.contains("impostor"))
                // No hot-restart steps ran against the mismatched plugin.
                #expect(harness.log == ["install:https://example.com/pi/plugin.json"])
                #expect(manager.restartNotices.isEmpty)
            }
        }

        @Test("a live-disabled plugin is not respawned — the update defers like a busy one")
        func disabledPluginDefersInsteadOfRespawning() async throws {
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                harness.disabledPlugins = ["pi"]
                let manager = harness.makeManager()

                let result = await manager.applyUpdate(makeUpdate())

                #expect(result == .applied(needsAppRestart: true))
                #expect(harness.log == ["install:https://example.com/pi/plugin.json"]) // no disable/enable
                #expect(harness.registry.plugins.first?.needsBridgeRefresh == true)
            }
        }
    }

    // MARK: - Manual check

    @Suite("PluginUpdateManager manual check")
    @MainActor
    struct PluginUpdateManagerCheckTests {
        @Test("checkNow on an up-to-date plugin reports upToDate and stamps lastCheckDate")
        func checkNowUpToDate() async throws {
            let fixedNow = Date(timeIntervalSince1970: 1_000_000)
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0.date = .constant(fixedNow)
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                let manager = harness.makeManager()

                manager.checkNow("pi")
                #expect(manager.inlineStatus["pi"] == .checking)
                await manager.waitForPendingRuns()

                #expect(manager.inlineStatus["pi"] == .upToDate)
                #expect(manager.lastCheckDate == fixedNow)
                #expect(harness.notifications.isEmpty)
            }
        }

        @Test("checkNow works even when autoUpdate is off, applies, and notifies")
        func checkNowIgnoresToggle() async throws {
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0", autoUpdate: false)])
                harness.updates = [PluginUpdate(id: "pi", currentVersion: "1.0.0", newVersion: "2.0.0", sourceChanged: false)]
                let manager = harness.makeManager()

                manager.checkNow("pi")
                await manager.waitForPendingRuns()

                #expect(manager.inlineStatus["pi"] == .updated(version: "2.0.0", needsAppRestart: false))
                #expect(harness.notifications.count == 1)
                #expect(harness.log.contains("checkOne:pi"))
            }
        }

        @Test("checkNow surfaces fetch errors inline")
        func checkNowSurfacesError() async throws {
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                harness.failingChecks = ["pi"]
                let manager = harness.makeManager()

                manager.checkNow("pi")
                await manager.waitForPendingRuns()

                guard case let .failed(message) = manager.inlineStatus["pi"] else {
                    Issue.record("expected .failed, got \(String(describing: manager.inlineStatus["pi"]))")
                    return
                }
                // User-facing copy, not a String(describing:) enum dump.
                #expect(message == "Invalid plugin manifest format")
                // A failed fetch is not a completed check — the staleness
                // trigger must stay armed.
                #expect(manager.lastCheckDate == nil)
                #expect(harness.notifications.isEmpty)
            }
        }
    }

    // MARK: - Automatic triggers

    @Suite("PluginUpdateManager triggers")
    @MainActor
    struct PluginUpdateManagerTriggerTests {
        func checksRun(_ harness: UpdateHarness) -> Int {
            harness.log.filter { $0.hasPrefix("check:") }.count
        }

        @Test("first launch (no stored version) checks immediately and stores the version")
        func firstLaunchChecks() async throws {
            await withMainSerialExecutor {
                let prefs = PreferencesService.inMemory()
                await withDependencies {
                    $0[PreferencesService.self] = prefs
                    $0.continuousClock = TestClock()
                    $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
                } operation: { @MainActor in
                    let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                    let manager = harness.makeManager(automaticTriggers: true)
                    manager.start()
                    await manager.waitForPendingRuns()
                    #expect(checksRun(harness) == 1)
                    #expect(prefs.string(PluginUpdateManager.Keys.lastRunAppVersion) == "2.0.0")
                    manager.stop()
                }
            }
        }

        @Test("same version + recent check does not trigger")
        func sameVersionRecentCheckSkips() async throws {
            await withMainSerialExecutor {
                let now = Date(timeIntervalSince1970: 1_000_000)
                let prefs = PreferencesService.inMemory()
                prefs.setString("2.0.0", PluginUpdateManager.Keys.lastRunAppVersion)
                prefs.setDouble(now.timeIntervalSince1970 - 3600, PluginUpdateManager.Keys.lastCheckAt) // 1h ago
                await withDependencies {
                    $0[PreferencesService.self] = prefs
                    $0.continuousClock = TestClock()
                    $0.date = .constant(now)
                } operation: { @MainActor in
                    let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                    let manager = harness.makeManager(automaticTriggers: true)
                    manager.start()
                    await manager.waitForPendingRuns()
                    #expect(checksRun(harness) == 0)
                    manager.stop()
                }
            }
        }

        @Test("same version but stale (>24h) check triggers the daily check")
        func staleCheckTriggersDaily() async throws {
            await withMainSerialExecutor {
                let now = Date(timeIntervalSince1970: 1_000_000)
                let prefs = PreferencesService.inMemory()
                prefs.setString("2.0.0", PluginUpdateManager.Keys.lastRunAppVersion)
                prefs.setDouble(now.timeIntervalSince1970 - 25 * 3600, PluginUpdateManager.Keys.lastCheckAt)
                await withDependencies {
                    $0[PreferencesService.self] = prefs
                    $0.continuousClock = TestClock()
                    $0.date = .constant(now)
                } operation: { @MainActor in
                    let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                    let manager = harness.makeManager(automaticTriggers: true)
                    manager.start()
                    await manager.waitForPendingRuns()
                    #expect(checksRun(harness) == 1)
                    manager.stop()
                }
            }
        }

        @Test("automatic checks include only autoUpdate-enabled url entries")
        func automaticChecksFilterByToggle() async throws {
            await withMainSerialExecutor {
                await withDependencies {
                    $0[PreferencesService.self] = .inMemory()
                    $0.continuousClock = TestClock()
                    $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
                } operation: { @MainActor in
                    let harness = UpdateHarness(entries: [
                        urlEntry(id: "pi", version: "1.0.0"),
                        urlEntry(id: "opencode", version: "1.0.0", autoUpdate: false),
                    ])
                    let manager = harness.makeManager(automaticTriggers: true)
                    manager.start()
                    await manager.waitForPendingRuns()
                    #expect(harness.log.contains("check:pi"))
                    #expect(!harness.log.contains { $0.contains("opencode") })
                    manager.stop()
                }
            }
        }

        @Test("automatic checks skip live-disabled plugins entirely")
        func automaticChecksSkipDisabledPlugins() async throws {
            await withMainSerialExecutor {
                await withDependencies {
                    $0[PreferencesService.self] = .inMemory()
                    $0.continuousClock = TestClock()
                    $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
                } operation: { @MainActor in
                    let harness = UpdateHarness(entries: [
                        urlEntry(id: "pi", version: "1.0.0"),
                        urlEntry(id: "opencode", version: "1.0.0"),
                    ])
                    harness.disabledPlugins = ["opencode"]
                    let manager = harness.makeManager(automaticTriggers: true)
                    manager.start()
                    await manager.waitForPendingRuns()
                    #expect(harness.log.contains("check:pi"))
                    #expect(!harness.log.contains { $0.contains("opencode") })
                    manager.stop()
                }
            }
        }

        @Test("a pass where every fetch failed does not stamp lastCheckDate")
        func allFailedPassDoesNotStamp() async throws {
            await withMainSerialExecutor {
                await withDependencies {
                    $0[PreferencesService.self] = .inMemory()
                    $0.continuousClock = TestClock()
                    $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
                } operation: { @MainActor in
                    let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                    harness.batchFetchSucceeds = false
                    let manager = harness.makeManager(automaticTriggers: true)
                    manager.start()
                    await manager.waitForPendingRuns()
                    // The check ran but offline — the staleness trigger must
                    // stay armed instead of reporting "last checked just now".
                    #expect(checksRun(harness) == 1)
                    #expect(manager.lastCheckDate == nil)
                    manager.stop()
                }
            }
        }

        @Test("the 24h loop re-checks after the clock advances a day")
        func dailyLoopReChecks() async throws {
            await withMainSerialExecutor {
                let clock = TestClock()
                await withDependencies {
                    $0[PreferencesService.self] = .inMemory()
                    $0.continuousClock = clock
                    $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
                } operation: { @MainActor in
                    let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                    let manager = harness.makeManager(automaticTriggers: true)
                    manager.start()
                    await manager.waitForPendingRuns()
                    #expect(checksRun(harness) == 1) // version-change check

                    await clock.advance(by: .seconds(PluginUpdateManager.checkInterval))
                    await Task.yield()
                    await manager.waitForPendingRuns()
                    #expect(checksRun(harness) == 2)
                    manager.stop()
                }
            }
        }

        @Test("automatic pass with two updates emits one combined notification")
        func automaticBatchNotification() async throws {
            try await withMainSerialExecutor {
                try await withDependencies {
                    $0[PreferencesService.self] = .inMemory()
                    $0.continuousClock = TestClock()
                    $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
                } operation: { @MainActor in
                    let harness = UpdateHarness(entries: [
                        urlEntry(id: "pi", version: "1.0.0"),
                        urlEntry(id: "opencode", version: "1.0.0"),
                    ])
                    harness.updates = [
                        PluginUpdate(id: "pi", currentVersion: "1.0.0", newVersion: "2.0.0", sourceChanged: false),
                        PluginUpdate(id: "opencode", currentVersion: "1.0.0", newVersion: "3.0.0", sourceChanged: false),
                    ]
                    harness.activePlugins = ["opencode"] // busy → app-restart wording
                    let manager = harness.makeManager(automaticTriggers: true)
                    manager.start()
                    await manager.waitForPendingRuns()

                    #expect(harness.notifications.count == 1)
                    let body = try #require(harness.notifications.first)
                    #expect(body.contains("Pi 2.0.0"))
                    #expect(body.contains("restart your Pi sessions"))
                    #expect(body.contains("restart Gallager and any Opencode sessions"))
                    manager.stop()
                }
            }
        }

        @Test("automaticTriggersEnabled=false runs only the sweep")
        func disabledTriggersOnlySweep() async throws {
            await withMainSerialExecutor {
                await withDependencies {
                    $0[PreferencesService.self] = .inMemory()
                    $0.continuousClock = TestClock()
                    $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
                } operation: { @MainActor in
                    let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                    let manager = harness.makeManager(automaticTriggers: false)
                    manager.start()
                    await manager.waitForPendingRuns()
                    #expect(checksRun(harness) == 0)
                    manager.stop()
                }
            }
        }
    }

    // MARK: - CLI apply serialization

    @Suite("PluginUpdateManager CLI apply serialization")
    @MainActor
    struct PluginUpdateManagerCLISerializationTests {
        /// Proves `applyUpdateSerialized` (the CLI path) chains behind whatever
        /// check/apply is already in flight, and that the in-flight chain itself
        /// stays properly ordered — a CLI apply must never start installing
        /// while an automatic check (or the sweep ahead of it) is still running,
        /// since two concurrent `PluginInstaller.install` runs for one id would
        /// race on the shared deterministic staging dir.
        @Test("CLI apply waits for an in-flight automatic check, which itself waits for the boot sweep")
        func cliApplyWaitsForInFlightChain() async throws {
            await withMainSerialExecutor {
                await withDependencies {
                    $0[PreferencesService.self] = .inMemory()
                    $0.continuousClock = TestClock()
                    $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
                } operation: { @MainActor in
                    let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0", needsBridgeRefresh: true)])
                    harness.installedRoots["pi"] = ["default"]
                    harness.gateBridge = true
                    harness.gateChecks = true
                    let manager = harness.makeManager(automaticTriggers: true)

                    // start() schedules two chained ops: the boot sweep (gated in
                    // installBridge, since "pi" needs a bridge refresh) then the
                    // automatic check (gated in checkUpdates, first launch).
                    manager.start()
                    await Task.megaYield()

                    // If scheduleRun's `await prior?.value` were dropped, the
                    // automatic check would start concurrently with the sweep
                    // instead of waiting for it, and "check:pi" would already be
                    // in the log here.
                    #expect(harness.log == ["bridge:pi:default"])

                    let update = PluginUpdate(id: "pi", currentVersion: "1.0.0", newVersion: "2.0.0", sourceChanged: false)
                    let applyTask = Task { await manager.applyUpdateSerialized(update) }
                    await Task.megaYield()

                    // If applyUpdateSerialized's own `await prior?.value` were
                    // dropped, the CLI apply would skip straight to
                    // installFromURL and "install:..." would already be logged
                    // here, even though the sweep is still mid-flight.
                    #expect(harness.log == ["bridge:pi:default"])

                    harness.releaseBridgeGate() // sweep finishes -> automatic check starts and blocks
                    await Task.megaYield()

                    #expect(harness.log == ["bridge:pi:default", "check:pi"])
                    // Still nothing installed: the CLI apply is still chained
                    // behind the now-running automatic check.

                    // Only the boot sweep's bridge call should gate; let the CLI
                    // apply's own post-install bridge refresh finish normally.
                    harness.gateBridge = false
                    harness.releaseCheckGate() // automatic check finishes -> CLI apply proceeds
                    let result = await applyTask.value

                    #expect(result == .applied(needsAppRestart: false))
                    #expect(harness.log == [
                        "bridge:pi:default",
                        "check:pi",
                        "install:https://example.com/pi/plugin.json",
                        "disable:pi",
                        "enable:pi",
                        "bridge:pi:default",
                    ])
                    manager.stop()
                }
            }
        }
    }
#endif
