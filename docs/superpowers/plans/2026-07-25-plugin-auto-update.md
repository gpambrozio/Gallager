# Sidecar Plugin Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** URL-installed sidecar plugins check for updates automatically (on Gallager version change + daily), install them, refresh agent-side bridge files, and tell the user what to restart — with a per-plugin toggle and manual Check Now button.

**Architecture:** A new `@MainActor @Observable PluginUpdateManager` (init-injected callbacks struct) orchestrates the existing, already-tested `PluginUpdateChecker` + `PluginInstaller` pipeline. Two new persisted fields on `PluginRegistryEntry` (`autoUpdate`, `needsBridgeRefresh`) survive every registry rewrite via a shared merge helper. Post-install: hot-restart the sidecar only when the plugin has no active sessions, then re-run the `install` RPC wherever the bridge is already installed; if busy, a persisted flag defers the bridge refresh to the next launch.

**Tech Stack:** Swift 6.3, SwiftUI (MV), Swift Concurrency, swift-dependencies (Clocks trait), Swift Testing, UserNotifications.

**Spec:** `docs/superpowers/specs/2026-07-25-plugin-auto-update-design.md` (read it first).

## Global Constraints

- Branch: `plugin-auto-update` (already created; the spec commit is on it).
- Build/test ONLY via XcodeBuildTools skills: `swift-package` skill for package tests (package path `ClaudeSpyPackage`), `xcodebuild` skill (scheme `ClaudeSpyServer`) for app builds. Never raw `swift`/`xcodebuild` commands outside the skill wrappers.
- Swift Testing (`@Suite`/`@Test`/`#expect`/`#require`), NOT XCTest.
- All new files in `ClaudeSpyServerFeature` wrap their contents in `#if os(macOS)` … `#endif` (match `PluginUpdateChecker.swift`).
- No ViewModels. `@Observable` model + `@Environment(AppCoordinator.self)` in views.
- No new SF Symbol string literals — reuse existing `Symbols` cases (`.exclamationmarkTriangle`, `.exclamationmarkCircleFill`).
- `TestClock` + `@MainActor` tests MUST wrap in `withMainSerialExecutor` (known flake otherwise).
- Registry JSON back-compat: new fields decode with `decodeIfPresent` defaults (`autoUpdate` → `true`, `needsBridgeRefresh` → `false`).
- Never `setenv` in unit tests (posix_spawn EFAULT flake).
- A `PostToolUse` swiftformat hook reformats edits; don't fight it.
- Commit after every task (working code only).

## File Map

| File | Role |
|---|---|
| `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/PluginRegistryStore.swift` | Modify: add `autoUpdate` + `needsBridgeRefresh` to `PluginRegistryEntry` |
| `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginInstaller.swift` | Modify: shared `registryEntry(cliEntry:manifest:prior:)` merge helper; use in `persistRegistry`/`persistRegistryExcluding` |
| `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift` | Modify: boot rewrite uses merge helper; create/expose `pluginUpdateManager`; CLI apply path through manager |
| `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/PluginUpdateNotificationService.swift` | Create: `@DependencyClient` desktop notification (mirrors `LicenseNotificationService`) |
| `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginUpdateManager.swift` | Create: the orchestrator (`@MainActor @Observable`) |
| `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/AgentsSettingsView.swift` | Modify: Updates section in `PluginAgentForm`; restart banner; Review… flow |
| `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/AddPluginSheet.swift` | Modify: `initialURLString` init param |
| `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRegistryStoreTests.swift` | Modify: new-field decode/round-trip tests |
| `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginInstallerTests.swift` | Modify: merge-helper tests |
| `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginUpdateManagerTests.swift` | Create: manager unit tests |
| `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/AgentsPluginAutoUpdateScenario.swift` | Create: E2E scenario (Task 12) |
| `docs/plugins/sidecar-authoring.md`, `CLAUDE.md` | Modify: document auto-update (Task 11) |

---

### Task 1: Registry fields `autoUpdate` + `needsBridgeRefresh`

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/PluginRegistryStore.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRegistryStoreTests.swift`

**Interfaces:**
- Produces: `PluginRegistryEntry.autoUpdate: Bool` (var, default `true`), `PluginRegistryEntry.needsBridgeRefresh: Bool` (var, default `false`); memberwise init gains `autoUpdate: Bool = true, needsBridgeRefresh: Bool = false` trailing params so existing call sites compile unchanged.

- [ ] **Step 1: Write the failing tests** — append to the existing suite in `PluginRegistryStoreTests.swift`:

```swift
@Test("legacy registry JSON without update fields decodes with defaults")
func legacyEntryDecodesWithUpdateDefaults() throws {
    let json = """
    {"schemaVersion":1,"plugins":[{"id":"pi","version":"1.0.0","source":"url","runtime":"sidecar","enabled":true,"manifestURL":"https://example.com/pi/plugin.json","bundleURL":"https://cdn.example.com/pi.zip","bundleSHA256":"abc"}]}
    """
    let file = try JSONDecoder().decode(PluginRegistryFile.self, from: Data(json.utf8))
    let entry = try #require(file.plugins.first)
    #expect(entry.autoUpdate == true)
    #expect(entry.needsBridgeRefresh == false)
}

@Test("autoUpdate=false and needsBridgeRefresh=true survive a save/load round-trip")
func updateFieldsRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("registry-roundtrip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("registry.json")

    let entry = PluginRegistryEntry(
        id: "pi", version: "1.0.0", source: .url, runtime: .sidecar, enabled: true,
        manifestURL: URL(string: "https://example.com/pi/plugin.json"),
        bundleURL: URL(string: "https://cdn.example.com/pi.zip"),
        bundleSHA256: "abc",
        autoUpdate: false,
        needsBridgeRefresh: true
    )
    try PluginRegistryStore.save(PluginRegistryFile(schemaVersion: 1, plugins: [entry]), to: url)
    let loaded = PluginRegistryStore.load(url)
    let roundTripped = try #require(loaded.plugins.first)
    #expect(roundTripped.autoUpdate == false)
    #expect(roundTripped.needsBridgeRefresh == true)
}
```

- [ ] **Step 2: Run to verify failure** — swift-package skill, test, filter `PluginRegistryStoreTests`. Expected: compile error "extra arguments 'autoUpdate:needsBridgeRefresh:' in call".

- [ ] **Step 3: Implement** — in `PluginRegistryStore.swift`, add the two `var` properties after `bundleSHA256`, extend the memberwise init with defaulted params, and add a custom decoder (synthesized `CodingKeys` and `encode(to:)` remain):

```swift
    /// Host-side preference: include this plugin in automatic update checks.
    /// Only meaningful for `.url` entries; defaults to true.
    public var autoUpdate: Bool
    /// Set when an update installed while the plugin had active sessions, so
    /// agent-side bridge files still need re-installing (done at next launch).
    public var needsBridgeRefresh: Bool
```

Init signature becomes:

```swift
    public init(
        id: String,
        version: String,
        source: Source,
        runtime: Runtime,
        enabled: Bool,
        manifestURL: URL?,
        bundleURL: URL?,
        bundleSHA256: String?,
        autoUpdate: Bool = true,
        needsBridgeRefresh: Bool = false
    ) {
```

(assign both in the body). Custom decoder inside the struct:

```swift
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.version = try c.decode(String.self, forKey: .version)
        self.source = try c.decode(Source.self, forKey: .source)
        self.runtime = try c.decode(Runtime.self, forKey: .runtime)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.manifestURL = try c.decodeIfPresent(URL.self, forKey: .manifestURL)
        self.bundleURL = try c.decodeIfPresent(URL.self, forKey: .bundleURL)
        self.bundleSHA256 = try c.decodeIfPresent(String.self, forKey: .bundleSHA256)
        self.autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
        self.needsBridgeRefresh = try c.decodeIfPresent(Bool.self, forKey: .needsBridgeRefresh) ?? false
    }
```

- [ ] **Step 4: Run to verify pass** — swift-package skill, filter `PluginRegistryStoreTests`. Expected: PASS (all suite tests, not just the new two).

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add autoUpdate + needsBridgeRefresh to PluginRegistryEntry"`

---

### Task 2: Preserve the new fields across every registry rewrite

Three code paths rebuild `registry.json` from the in-memory registry and would silently reset the new fields: `PluginInstaller.persistRegistry` (:977), `PluginInstaller.persistRegistryExcluding` (:999), and the AppCoordinator boot rewrite (:704-726). Extract one pure merge helper and use it in all three.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginInstaller.swift:977-1017`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift:704-726`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginInstallerTests.swift`

**Interfaces:**
- Consumes: Task 1's fields.
- Produces: `PluginInstaller.registryEntry(cliEntry: PluginRegistry.CLIEntry, manifest: PluginManifest, prior: PluginRegistryEntry?) -> PluginRegistryEntry` (static, internal).

- [ ] **Step 1: Write the failing tests** — append to `PluginInstallerTests.swift`. Reuse the file's existing manifest-JSON helper if one exists; otherwise add this local helper (same shape as `PluginUpdateCheckerTests.makeManifestData`):

```swift
private func decodeManifest(id: String, version: String, withDistribution: Bool) throws -> PluginManifest {
    let distribution = withDistribution ? """
    "manifest_url": "https://example.com/\(id)/plugin.json",
    "bundle_url": "https://cdn.example.com/\(id).zip",
    "bundle_sha256": "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
    """ : ""
    let json = """
    {
      "schema_version": 1,
      "id": "\(id)",
      "display_name": "Test Plugin",
      "short_name": "TP",
      "version": "\(version)",
      "runtime": "sidecar",
      "sidecar": {"executable": "bin/sidecar"},
      \(distribution)
      "process_names": [],
      "ui": {}
    }
    """
    return try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
}

@Suite("PluginInstaller.registryEntry merge")
struct RegistryEntryMergeTests {
    @Test("prior .url entry rediscovered as folder keeps source, urls, and update fields")
    func urlEntryPreservedAcrossFolderRediscovery() throws {
        let manifest = try decodeManifest(id: "pi", version: "1.0.0", withDistribution: false)
        let prior = PluginRegistryEntry(
            id: "pi", version: "1.0.0", source: .url, runtime: .sidecar, enabled: true,
            manifestURL: URL(string: "https://example.com/pi/plugin.json"),
            bundleURL: URL(string: "https://cdn.example.com/pi.zip"),
            bundleSHA256: "abc", autoUpdate: false, needsBridgeRefresh: true
        )
        let cliEntry = PluginRegistry.CLIEntry(id: "pi", version: "1.0.0", enabled: true, source: "folder")
        let merged = PluginInstaller.registryEntry(cliEntry: cliEntry, manifest: manifest, prior: prior)
        #expect(merged.source == .url)
        #expect(merged.manifestURL == prior.manifestURL)
        #expect(merged.bundleURL == prior.bundleURL)
        #expect(merged.bundleSHA256 == "abc")
        #expect(merged.autoUpdate == false)
        #expect(merged.needsBridgeRefresh == true)
    }

    @Test("no prior entry produces defaults (autoUpdate on, no pending refresh)")
    func noPriorEntryProducesDefaults() throws {
        let manifest = try decodeManifest(id: "new", version: "0.1.0", withDistribution: true)
        let cliEntry = PluginRegistry.CLIEntry(id: "new", version: "0.1.0", enabled: true, source: "url")
        let merged = PluginInstaller.registryEntry(cliEntry: cliEntry, manifest: manifest, prior: nil)
        #expect(merged.source == .url)
        #expect(merged.autoUpdate == true)
        #expect(merged.needsBridgeRefresh == false)
        #expect(merged.manifestURL == URL(string: "https://example.com/new/plugin.json"))
    }

    @Test("bundled source is never upgraded to url")
    func bundledStaysBundled() throws {
        let manifest = try decodeManifest(id: "claude-code", version: "1.0.0", withDistribution: false)
        let prior = PluginRegistryEntry(
            id: "claude-code", version: "1.0.0", source: .url, runtime: .sidecar, enabled: true,
            manifestURL: URL(string: "https://example.com/x.json"), bundleURL: nil, bundleSHA256: nil
        )
        let cliEntry = PluginRegistry.CLIEntry(id: "claude-code", version: "1.0.0", enabled: true, source: "bundled")
        let merged = PluginInstaller.registryEntry(cliEntry: cliEntry, manifest: manifest, prior: prior)
        #expect(merged.source == .bundled)
        #expect(merged.manifestURL == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** — filter `RegistryEntryMergeTests`. Expected: compile error "type 'PluginInstaller' has no member 'registryEntry'".

- [ ] **Step 3: Implement the helper** in `PluginInstaller.swift` (next to `resolveRegistryEntry`, :130). Logic copied from the AppCoordinator boot merge so all rewrites behave identically:

```swift
        /// Build the persisted registry entry for one plugin, carrying forward
        /// URL-install metadata and host-side update preferences from the prior
        /// persisted entry. Every registry.json rewrite goes through this so a
        /// rewrite can never downgrade a `.url` entry to `.folder`, strip its
        /// urls, or reset `autoUpdate` / `needsBridgeRefresh`.
        static func registryEntry(
            cliEntry: PluginRegistry.CLIEntry,
            manifest: PluginManifest,
            prior: PluginRegistryEntry?
        ) -> PluginRegistryEntry {
            let source = PluginRegistryEntry.Source(rawValue: cliEntry.source) ?? .bundled
            let effectiveSource: PluginRegistryEntry.Source =
                (prior?.source == .url && source != .bundled) ? .url : source
            let manifestURL = effectiveSource == .url ? (manifest.manifestURL ?? prior?.manifestURL) : nil
            let bundleURL = effectiveSource == .url ? (manifest.bundleURL ?? prior?.bundleURL) : nil
            let bundleSHA256 = effectiveSource == .url ? (manifest.bundleSHA256 ?? prior?.bundleSHA256) : nil
            return PluginRegistryEntry(
                id: cliEntry.id,
                version: cliEntry.version,
                source: effectiveSource,
                runtime: manifest.runtime,
                enabled: cliEntry.enabled,
                manifestURL: manifestURL,
                bundleURL: bundleURL,
                bundleSHA256: bundleSHA256,
                autoUpdate: prior?.autoUpdate ?? true,
                needsBridgeRefresh: prior?.needsBridgeRefresh ?? false
            )
        }
```

Rewrite `persistRegistry` (:977) to load the prior file and delegate:

```swift
        @MainActor
        static func persistRegistry(registry: PluginRegistry, paths: GallagerPaths) {
            let prior = PluginRegistryStore.load(paths.registryPath)
            let entries = registry.listEntries().compactMap { cliEntry -> PluginRegistryEntry? in
                guard let manifest = registry.manifest(cliEntry.id) else { return nil }
                return registryEntry(
                    cliEntry: cliEntry,
                    manifest: manifest,
                    prior: prior.plugins.first { $0.id == cliEntry.id }
                )
            }
            let registryFile = PluginRegistryFile(schemaVersion: 1, plugins: entries)
            try? PluginRegistryStore.save(registryFile, to: paths.registryPath)
        }
```

`persistRegistryExcluding` (:999): same body with `.filter { $0.id != id }` after `listEntries()`.

In `AppCoordinator.swift` :704-724, replace the body of the boot-rewrite `compactMap` with:

```swift
            let entries = cliEntries.compactMap { cliEntry -> PluginRegistryEntry? in
                guard let manifest = registry.manifest(cliEntry.id) else { return nil }
                return PluginInstaller.registryEntry(
                    cliEntry: cliEntry,
                    manifest: manifest,
                    prior: loadedRegistry.plugins.first(where: { $0.id == cliEntry.id })
                )
            }
```

- [ ] **Step 4: Run to verify pass** — filter `RegistryEntryMergeTests`, then run the whole `ClaudeSpyServerFeatureTests` target (existing `PluginInstallFlowTests` / `PluginZipInstallTests` / `PluginFolderDropTests` exercise the rewritten persist paths). Expected: PASS.

- [ ] **Step 5: Commit** — `git commit -am "refactor: single registryEntry merge helper preserves update fields across registry rewrites"`

---

### Task 3: PluginUpdateNotificationService

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/PluginUpdateNotificationService.swift`

**Interfaces:**
- Produces: `PluginUpdateNotificationService.showUpdateNotification(_ body: String)` — `@DependencyClient`, resolved via `@Dependency(PluginUpdateNotificationService.self)`.

No unit test — pure side-effect wrapper, same as `LicenseNotificationService` (untested precedent). Build-verify only.

- [ ] **Step 1: Implement** — mirror `Services/LicenseNotificationService.swift` exactly (same actor + `ensurePermission()` body — copy it verbatim from `LiveLicenseNotificationHandler`, including the `ForegroundNotificationDelegate` installation):

```swift
// ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/PluginUpdateNotificationService.swift
#if os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation
    import Logging
    import UserNotifications

    /// Posts "plugin updates installed — restart …" desktop notifications.
    /// Mirrors LicenseNotificationService's live handler (permission request +
    /// UNUserNotificationCenter add).
    @DependencyClient
    public struct PluginUpdateNotificationService: Sendable {
        public var showUpdateNotification: @Sendable (_ body: String) -> Void
    }

    extension PluginUpdateNotificationService: DependencyKey {
        public static var previewValue: PluginUpdateNotificationService {
            PluginUpdateNotificationService(showUpdateNotification: { _ in })
        }

        public static var liveValue: PluginUpdateNotificationService {
            let handler = LivePluginUpdateNotificationHandler()
            return PluginUpdateNotificationService(showUpdateNotification: { body in
                Task {
                    await handler.show(body: body)
                }
            })
        }
    }

    /// Actor managing UNUserNotificationCenter permission + delivery. The
    /// ensurePermission() body is identical to LiveLicenseNotificationHandler's.
    private actor LivePluginUpdateNotificationHandler {
        private let logger = Logger(label: "com.claudespy.pluginupdatenotification")
        private var isAuthorized = false
        private var hasRequestedPermission = false
        private var hasInstalledDelegate = false

        func show(body: String) async {
            await ensurePermission()
            guard isAuthorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "Plugin updates installed"
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "plugin-update-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                logger.warning("Failed to deliver plugin-update notification: \(error)")
            }
        }

        // ensurePermission(): copy verbatim from LiveLicenseNotificationHandler
        // (Services/LicenseNotificationService.swift) — notDetermined/authorized/
        // denied handling + ForegroundNotificationDelegate installation.
    }
#endif
```

- [ ] **Step 2: Build to verify** — swift-package skill, build the `ClaudeSpyServerFeature` product (or run the test target build). Expected: compiles clean.

- [ ] **Step 3: Commit** — `git add -A && git commit -m "feat: PluginUpdateNotificationService for update desktop notifications"`

---

### Task 4: PluginUpdateManager — types, registry accessors, test harness

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginUpdateManager.swift`
- Create: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginUpdateManagerTests.swift`

**Interfaces:**
- Consumes: `PluginRegistryFile`/`PluginRegistryEntry` (Tasks 1-2), `PluginUpdate`, `PluginInstaller.InstallOutcome`, `InstallError`, `PluginInstallStatus`, `PreferencesService`.
- Produces (used by Tasks 5-10; exact names matter):
  - `PluginUpdateInlineStatus` enum: `.checking`, `.upToDate`, `.updated(version: String, needsAppRestart: Bool)`, `.updateAvailableNewSource(version: String)`, `.failed(String)`
  - `PluginRestartNotice`: `pluginID`, `displayName`, `newVersion`, `needsAppRestart` (Identifiable by `pluginID`)
  - `PluginUpdateManager.ApplyResult`: `.applied(needsAppRestart: Bool)`, `.skippedSourceChanged`, `.failed(String)`
  - `PluginUpdateManager.Callbacks` struct (all closures `@MainActor`, async where noted)
  - `init(callbacks:automaticTriggersEnabled:)`, `isUpdatable(_:)`, `autoUpdateEnabled(_:)`, `setAutoUpdate(_:enabled:)`, `manifestURL(_:)`, observable `restartNotices`, `inlineStatus`, `lastCheckDate`
  - internal `waitForPendingRuns()` (test support)

- [ ] **Step 1: Write the failing tests** — create `PluginUpdateManagerTests.swift` with the shared harness plus accessor tests:

```swift
#if os(macOS)
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
        /// Keyed by manifest-URL string; unset URLs succeed.
        var installResults: [String: Result<PluginInstaller.InstallOutcome, InstallError>] = [:]
        var activePlugins: Set<String> = []
        /// id -> set of roots ("default" or the folder path) with the bridge installed.
        var installedRoots: [String: Set<String>] = [:]
        var additionalFolders: [String: [String]] = [:]
        var log: [String] = []
        var notifications: [String] = []

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
                        return self.updates.filter { update in entries.contains { $0.id == update.id } }
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
                        return self.installResults[url.absoluteString] ?? .success(.installed(id: "stub"))
                    },
                    hasActiveSessions: { self.activePlugins.contains($0) },
                    disablePlugin: { self.log.append("disable:\($0)") },
                    enablePlugin: { self.log.append("enable:\($0)") },
                    installStatus: { id, root in
                        self.installedRoots[id]?.contains(root ?? "default") == true
                            ? .installed(version: nil)
                            : .notInstalled
                    },
                    installBridge: { id, root in
                        self.log.append("bridge:\(id):\(root ?? "default")")
                        return nil
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
            try withDependencies {
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
            try withDependencies {
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
#endif
```

Note: `withDependencies` around *construction* because the manager resolves `PreferencesService`, the clock, and `\.date` via `@Dependency` at init. If the compiler rejects `try withDependencies` with a non-throwing closure, drop the `try`.

- [ ] **Step 2: Run to verify failure** — filter `PluginUpdateManagerAccessorTests`. Expected: compile error, `PluginUpdateManager` not found.

- [ ] **Step 3: Implement the manager skeleton** — create `Distribution/PluginUpdateManager.swift`:

```swift
#if os(macOS)
    import ClaudeSpyCommon
    import Dependencies
    import Foundation
    import GallagerPluginProtocol
    import Logging
    import Observation

    // MARK: - PluginUpdateInlineStatus

    /// Per-plugin inline status shown in the Agents settings "Updates" section.
    public enum PluginUpdateInlineStatus: Sendable, Equatable {
        case checking
        case upToDate
        case updated(version: String, needsAppRestart: Bool)
        case updateAvailableNewSource(version: String)
        case failed(String)
    }

    // MARK: - PluginRestartNotice

    /// One "restart to finish updating" line in the Agents settings banner.
    public struct PluginRestartNotice: Sendable, Equatable, Identifiable {
        public let pluginID: String
        public let displayName: String
        public let newVersion: String
        /// true when the sidecar could not be hot-swapped (plugin had active
        /// sessions), so restarting Gallager is required too.
        public let needsAppRestart: Bool
        public var id: String { pluginID }
    }

    // MARK: - PluginUpdateManager

    /// Orchestrates automatic + manual plugin update checks (spec
    /// 2026-07-25-plugin-auto-update-design). Owns the triggers, applies updates
    /// through the PluginInstaller pipeline, hot-restarts idle sidecars, refreshes
    /// agent-side bridges, and exposes banner/notice state to the settings UI.
    /// Init-injected callbacks (not @DependencyClient): @Observable class with
    /// many wired callbacks, per CLAUDE.md.
    @MainActor
    @Observable
    public final class PluginUpdateManager {
        // MARK: Types

        /// Outcome of applying one update (also consumed by the CLI apply path).
        public enum ApplyResult: Sendable, Equatable {
            case applied(needsAppRestart: Bool)
            case skippedSourceChanged
            case failed(String)
        }

        /// Wired callbacks into AppCoordinator / the install pipeline.
        public struct Callbacks {
            public var loadRegistry: @MainActor () -> PluginRegistryFile
            public var saveRegistry: @MainActor (PluginRegistryFile) -> Void
            /// Batch, best-effort check (automatic passes) — fetch errors skip
            /// the entry, matching PluginUpdateChecker.check.
            public var checkUpdates: @MainActor ([PluginRegistryEntry]) async -> [PluginUpdate]
            /// Single-entry check for the manual Check Now path. THROWS on fetch
            /// errors so the UI can surface them inline (spec: manual failures
            /// are visible; automatic ones stay silent).
            public var checkUpdate: @MainActor (PluginRegistryEntry) async throws -> PluginUpdate?
            public var installFromURL: @MainActor (URL) async -> Result<PluginInstaller.InstallOutcome, InstallError>
            public var hasActiveSessions: @MainActor (String) -> Bool
            public var disablePlugin: @MainActor (String) async -> Void
            public var enablePlugin: @MainActor (String) async -> Void
            public var installStatus: @MainActor (String, String?) async -> PluginInstallStatus
            public var installBridge: @MainActor (String, String?) async -> String?
            public var additionalConfigFolders: @MainActor (String) -> [String]
            public var displayName: @MainActor (String) -> String
            public var currentAppVersion: @MainActor () -> String
            public var notify: @MainActor (String) -> Void

            public init(
                loadRegistry: @escaping @MainActor () -> PluginRegistryFile,
                saveRegistry: @escaping @MainActor (PluginRegistryFile) -> Void,
                checkUpdates: @escaping @MainActor ([PluginRegistryEntry]) async -> [PluginUpdate],
                checkUpdate: @escaping @MainActor (PluginRegistryEntry) async throws -> PluginUpdate?,
                installFromURL: @escaping @MainActor (URL) async -> Result<PluginInstaller.InstallOutcome, InstallError>,
                hasActiveSessions: @escaping @MainActor (String) -> Bool,
                disablePlugin: @escaping @MainActor (String) async -> Void,
                enablePlugin: @escaping @MainActor (String) async -> Void,
                installStatus: @escaping @MainActor (String, String?) async -> PluginInstallStatus,
                installBridge: @escaping @MainActor (String, String?) async -> String?,
                additionalConfigFolders: @escaping @MainActor (String) -> [String],
                displayName: @escaping @MainActor (String) -> String,
                currentAppVersion: @escaping @MainActor () -> String,
                notify: @escaping @MainActor (String) -> Void
            ) {
                self.loadRegistry = loadRegistry
                self.saveRegistry = saveRegistry
                self.checkUpdates = checkUpdates
                self.checkUpdate = checkUpdate
                self.installFromURL = installFromURL
                self.hasActiveSessions = hasActiveSessions
                self.disablePlugin = disablePlugin
                self.enablePlugin = enablePlugin
                self.installStatus = installStatus
                self.installBridge = installBridge
                self.additionalConfigFolders = additionalConfigFolders
                self.displayName = displayName
                self.currentAppVersion = currentAppVersion
                self.notify = notify
            }
        }

        // MARK: Observable state

        public private(set) var restartNotices: [PluginRestartNotice] = []
        public private(set) var inlineStatus: [String: PluginUpdateInlineStatus] = [:]
        public private(set) var lastCheckDate: Date?

        // MARK: Private

        private let callbacks: Callbacks
        private let automaticTriggersEnabled: Bool
        private let logger = Logger(label: "com.claudespy.pluginupdatemanager")
        @ObservationIgnored @Dependency(PreferencesService.self) private var preferences
        @ObservationIgnored @Dependency(\.continuousClock) private var clock
        @ObservationIgnored @Dependency(\.date) private var date
        private var loopTask: Task<Void, Never>?
        /// Serializes check/apply work — a new request awaits the prior one.
        private var currentRun: Task<Void, Never>?

        static let checkInterval: TimeInterval = 24 * 60 * 60

        enum Keys {
            static let lastRunAppVersion = "pluginUpdateLastRunAppVersion"
            static let lastCheckAt = "pluginUpdateLastCheckAt"
        }

        public init(callbacks: Callbacks, automaticTriggersEnabled: Bool = true) {
            self.callbacks = callbacks
            self.automaticTriggersEnabled = automaticTriggersEnabled
            lastCheckDate = preferences
                .optionalDouble(Keys.lastCheckAt)
                .map(Date.init(timeIntervalSince1970:))
        }

        // MARK: - UI queries

        /// Whether the Updates section renders for `id`: URL-installed with a
        /// manifest URL (bundled and folder-dropped plugins can't update).
        public func isUpdatable(_ id: String) -> Bool {
            entry(id).map { $0.source == .url && $0.manifestURL != nil } ?? false
        }

        public func autoUpdateEnabled(_ id: String) -> Bool {
            entry(id)?.autoUpdate ?? true
        }

        public func setAutoUpdate(_ id: String, enabled: Bool) {
            mutateEntry(id) { $0.autoUpdate = enabled }
        }

        public func manifestURL(_ id: String) -> URL? {
            entry(id)?.manifestURL
        }

        // MARK: - Registry helpers

        private func entry(_ id: String) -> PluginRegistryEntry? {
            callbacks.loadRegistry().plugins.first { $0.id == id }
        }

        private func mutateEntry(_ id: String, _ change: (inout PluginRegistryEntry) -> Void) {
            var file = callbacks.loadRegistry()
            guard let index = file.plugins.firstIndex(where: { $0.id == id }) else { return }
            change(&file.plugins[index])
            callbacks.saveRegistry(file)
        }

        // MARK: - Test support

        /// Await completion of any scheduled check/apply run (tests only).
        func waitForPendingRuns() async {
            await currentRun?.value
        }
    }
#endif
```

- [ ] **Step 4: Run to verify pass** — filter `PluginUpdateManagerAccessorTests`. Expected: PASS.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: PluginUpdateManager skeleton — types, registry accessors, test harness"`

---

### Task 5: applyUpdate + bridge refresh + boot sweep

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginUpdateManager.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginUpdateManagerTests.swift`

**Interfaces:**
- Produces: `applyUpdate(_ update: PluginUpdate) async -> ApplyResult` (public — the CLI path calls it in Task 9); private `refreshBridges(_:)`, `sweepPendingBridgeRefreshes()`.
- `applyUpdate` records `restartNotices` + `inlineStatus` itself (so the CLI path lights the banner too); desktop notifications are NOT sent here — the check flows (Tasks 6-7) batch them.

- [ ] **Step 1: Write the failing tests** — append a suite:

```swift
    @Suite("PluginUpdateManager applyUpdate")
    @MainActor
    struct PluginUpdateManagerApplyTests {
        func makeUpdate(id: String = "pi", newVersion: String = "2.0.0", sourceChanged: Bool = false) -> PluginUpdate {
            PluginUpdate(id: id, currentVersion: "1.0.0", newVersion: newVersion, sourceChanged: sourceChanged)
        }

        @Test("idle plugin: install, then disable→enable, then bridges refreshed only where installed")
        func idlePluginHotRestartsAndRefreshesBridges() async throws {
            try await withDependencies {
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
            try await withDependencies {
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
            try await withDependencies {
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
            try await withDependencies {
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
            try await withDependencies {
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
    }
```

(If `InstallError.hashMismatch` has an associated value, use the actual case shape from `PluginInstaller.swift:9` — adjust to e.g. `.failure(.hashMismatch(expected: "a", actual: "b"))`.)

- [ ] **Step 2: Run to verify failure** — filter `PluginUpdateManagerApplyTests`. Expected: compile error, no `applyUpdate`.

- [ ] **Step 3: Implement** — add to `PluginUpdateManager`:

```swift
        // MARK: - Apply

        /// Apply one update through the installer pipeline, then hot-restart the
        /// sidecar if the plugin is idle and refresh agent-side bridges. Records
        /// the restart notice + inline status. Also the CLI apply path's engine.
        public func applyUpdate(_ update: PluginUpdate) async -> ApplyResult {
            let result = await applyUpdateCore(update)
            switch result {
            case let .applied(needsAppRestart):
                let notice = PluginRestartNotice(
                    pluginID: update.id,
                    displayName: callbacks.displayName(update.id),
                    newVersion: update.newVersion,
                    needsAppRestart: needsAppRestart
                )
                restartNotices.removeAll { $0.pluginID == update.id }
                restartNotices.append(notice)
                inlineStatus[update.id] = .updated(version: update.newVersion, needsAppRestart: needsAppRestart)
            case .skippedSourceChanged:
                inlineStatus[update.id] = .updateAvailableNewSource(version: update.newVersion)
            case let .failed(message):
                inlineStatus[update.id] = .failed(message)
            }
            return result
        }

        private func applyUpdateCore(_ update: PluginUpdate) async -> ApplyResult {
            // A changed bundle host needs the manual trust flow — never auto-install.
            guard !update.sourceChanged else { return .skippedSourceChanged }
            guard let manifestURL = entry(update.id)?.manifestURL else {
                return .failed("no manifestURL in registry")
            }
            switch await callbacks.installFromURL(manifestURL) {
            case let .failure(error):
                logger.warning("Plugin update failed for '\(update.id)': \(error)")
                return .failed(String(describing: error))
            case .success(.needsTrust):
                // installFromURL is always called trustConfirmed on this path.
                return .failed("unexpected trust prompt")
            case .success(.installed):
                if callbacks.hasActiveSessions(update.id) {
                    // Live sessions would lose sidecar state on a hot swap; the
                    // old process keeps running and the bridge refresh happens on
                    // next launch (sweepPendingBridgeRefreshes).
                    mutateEntry(update.id) { $0.needsBridgeRefresh = true }
                    return .applied(needsAppRestart: true)
                }
                // Explicit disable-first: enable() early-returns for an active
                // core, so a bare enable would leave the old process running.
                await callbacks.disablePlugin(update.id)
                await callbacks.enablePlugin(update.id)
                await refreshBridges(update.id)
                return .applied(needsAppRestart: false)
            }
        }

        /// Re-run the sidecar's `install` RPC in every location whose bridge is
        /// currently installed (default root + additional config folders). Must
        /// only run while the NEW sidecar is up — the RPC writes the bridge
        /// template shipped in the bundle.
        private func refreshBridges(_ id: String) async {
            let roots: [String?] = [nil] + callbacks.additionalConfigFolders(id)
            for root in roots {
                if case .installed = await callbacks.installStatus(id, root) {
                    _ = await callbacks.installBridge(id, root)
                }
            }
        }

        /// Boot-time sweep: finish bridge refreshes deferred because the plugin
        /// was busy when its update landed. The app has restarted since, so the
        /// running sidecar is the new one.
        private func sweepPendingBridgeRefreshes() async {
            for entry in callbacks.loadRegistry().plugins where entry.needsBridgeRefresh {
                await refreshBridges(entry.id)
                mutateEntry(entry.id) { $0.needsBridgeRefresh = false }
            }
        }
```

And a minimal `start()` (extended in Task 6) plus the run-serialization helper:

```swift
        // MARK: - Triggers

        /// Called once at boot, after all plugins are enabled.
        public func start() {
            scheduleRun { await self.sweepPendingBridgeRefreshes() }
        }

        private func scheduleRun(_ op: @escaping @MainActor () async -> Void) {
            let prior = currentRun
            currentRun = Task {
                await prior?.value
                await op()
            }
        }
```

- [ ] **Step 4: Run to verify pass** — filter `PluginUpdateManagerApplyTests` (and re-run `PluginUpdateManagerAccessorTests`). Expected: PASS.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: PluginUpdateManager apply flow — idle hot-restart, bridge refresh, deferred sweep"`

---

### Task 6: Manual check flow — PluginUpdateChecker.checkOne + checkNow

The batch `PluginUpdateChecker.check` silently skips fetch errors (best-effort by design), but the spec requires the manual button to surface errors inline. Add a throwing single-entry `checkOne`, refactor `check` onto it, and build the manual path on it.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginUpdateChecker.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginUpdateManager.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginUpdateCheckerTests.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginUpdateManagerTests.swift`

**Interfaces:**
- Produces: `PluginUpdateChecker.checkOne(_ entry: PluginRegistryEntry, session: any URLSessionProtocol) async throws -> PluginUpdate?` (public); `PluginUpdateManager.checkNow(_ id: String)` (public); private `runManualCheck(_:)`, `stampLastCheck()`; static `notificationBody(_ notices: [PluginRestartNotice]) -> String` (internal, tested via Task 7).

- [ ] **Step 1: Write the failing checker tests** — append to `PluginUpdateCheckerTests.swift` (reuse its `UpdateStubSession`, `makeManifestData`, `makeEntry` helpers):

```swift
        @Test("checkOne throws on a fetch failure instead of swallowing it")
        func checkOneThrowsOnFetchFailure() async throws {
            let manifestURL = try #require(URL(string: "https://example.com/broken/plugin.json"))
            let entry = makeEntry(id: "broken", version: "1.0.0", manifestURL: manifestURL)
            let session = UpdateStubSession(responses: [:]) // empty body → decode failure

            await #expect(throws: (any Error).self) {
                _ = try await PluginUpdateChecker.checkOne(entry, session: session)
            }
        }

        @Test("checkOne returns nil when up to date and the update when newer")
        func checkOneReturnsUpdateOrNil() async throws {
            let manifestURL = try #require(URL(string: "https://example.com/test-plugin/plugin.json"))
            let entry = makeEntry(id: "test-plugin", version: "1.0.0", manifestURL: manifestURL)

            let sameSession = UpdateStubSession(
                responses: [manifestURL: makeManifestData(id: "test-plugin", version: "1.0.0")]
            )
            let same = try await PluginUpdateChecker.checkOne(entry, session: sameSession)
            #expect(same == nil)

            let newerSession = UpdateStubSession(
                responses: [manifestURL: makeManifestData(id: "test-plugin", version: "1.1.0")]
            )
            let newer = try await PluginUpdateChecker.checkOne(entry, session: newerSession)
            #expect(newer == PluginUpdate(
                id: "test-plugin", currentVersion: "1.0.0", newVersion: "1.1.0", sourceChanged: false
            ))
        }
```

- [ ] **Step 2: Run to verify failure** — filter `PluginUpdateCheckerTests`. Expected: compile error, no `checkOne`.

- [ ] **Step 3: Implement `checkOne` and refactor `check`** in `PluginUpdateChecker.swift`:

```swift
        /// Check a single entry, propagating fetch/decode errors (the manual
        /// Check Now path surfaces them inline; the batch `check` stays
        /// best-effort). Returns nil for non-URL entries and when already up to
        /// date.
        public static func checkOne(
            _ entry: PluginRegistryEntry,
            session: any URLSessionProtocol
        ) async throws -> PluginUpdate? {
            guard entry.source == .url, let manifestURL = entry.manifestURL else { return nil }
            let (fetched, _) = try await PluginInstaller.fetchManifest(manifestURL, session: session)
            guard isNewer(fetched.version, than: entry.version) else { return nil }
            let sourceChanged = bundleHostChanged(
                existingBundleURL: entry.bundleURL,
                fetchedBundleURL: fetched.bundleURL
            )
            return PluginUpdate(
                id: entry.id,
                currentVersion: entry.version,
                newVersion: fetched.version,
                sourceChanged: sourceChanged
            )
        }
```

and reduce `check`'s loop body to:

```swift
            for entry in entries {
                if let update = try? await checkOne(entry, session: session) {
                    updates.append(update)
                }
            }
```

Run filter `PluginUpdateCheckerTests` — the new tests AND all pre-existing ones must pass (the refactor must not change `check`'s behavior).

- [ ] **Step 4: Write the failing manager tests:**

```swift
    @Suite("PluginUpdateManager manual check")
    @MainActor
    struct PluginUpdateManagerCheckTests {
        @Test("checkNow on an up-to-date plugin reports upToDate and stamps lastCheckDate")
        func checkNowUpToDate() async throws {
            let fixedNow = Date(timeIntervalSince1970: 1_000_000)
            try await withDependencies {
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
            try await withDependencies {
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
            try await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
            } operation: { @MainActor in
                let harness = UpdateHarness(entries: [urlEntry(id: "pi", version: "1.0.0")])
                harness.failingChecks = ["pi"]
                let manager = harness.makeManager()

                manager.checkNow("pi")
                await manager.waitForPendingRuns()

                guard case .failed = manager.inlineStatus["pi"] else {
                    Issue.record("expected .failed, got \(String(describing: manager.inlineStatus["pi"]))")
                    return
                }
                #expect(harness.notifications.isEmpty)
            }
        }
    }
```

(If `$0.date = .constant(...)` doesn't compile, use `$0.date.now = fixedNow`.)

- [ ] **Step 5: Run to verify failure** — filter `PluginUpdateManagerCheckTests`. Expected: compile error, no `checkNow`.

- [ ] **Step 6: Implement the manual path** in `PluginUpdateManager`:

```swift
        // MARK: - Checks

        /// Manual per-plugin check (the Check Now button). Ignores the
        /// autoUpdate toggle and applies any found update — the press is consent.
        public func checkNow(_ id: String) {
            inlineStatus[id] = .checking
            scheduleRun { [weak self] in
                await self?.runManualCheck(id)
            }
        }

        private func runManualCheck(_ id: String) async {
            guard let entry = entry(id) else {
                inlineStatus[id] = .failed("Plugin is not installed")
                return
            }
            let update: PluginUpdate?
            do {
                update = try await callbacks.checkUpdate(entry)
            } catch {
                stampLastCheck()
                inlineStatus[id] = .failed(String(describing: error))
                return
            }
            stampLastCheck()
            guard let update else {
                inlineStatus[id] = .upToDate
                return
            }
            if case .applied = await applyUpdate(update),
               let notice = restartNotices.first(where: { $0.pluginID == id }) {
                callbacks.notify(Self.notificationBody([notice]))
            }
        }

        static func notificationBody(_ notices: [PluginRestartNotice]) -> String {
            notices.map { notice in
                let action = notice.needsAppRestart
                    ? "restart Gallager and any \(notice.displayName) sessions"
                    : "restart your \(notice.displayName) sessions"
                return "\(notice.displayName) \(notice.newVersion) — \(action)"
            }
            .joined(separator: "; ")
        }

        private func stampLastCheck() {
            let now = date.now
            lastCheckDate = now
            preferences.setDouble(now.timeIntervalSince1970, Keys.lastCheckAt)
        }
```

- [ ] **Step 7: Run to verify pass** — filters `PluginUpdateCheckerTests` and `PluginUpdateManagerCheckTests` + previous suites. Expected: PASS.

- [ ] **Step 8: Commit** — `git add -A && git commit -m "feat: manual plugin update check with inline error surfacing (checkOne)"`

---

### Task 7: Automatic triggers — version change, daily threshold, 24h loop

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Distribution/PluginUpdateManager.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginUpdateManagerTests.swift`

**Interfaces:**
- Produces: full `start()` (sweep + triggers + loop), `stop()` (cancels the loop; tests and teardown).

- [ ] **Step 1: Write the failing tests:**

```swift
    @Suite("PluginUpdateManager triggers")
    @MainActor
    struct PluginUpdateManagerTriggerTests {
        func checksRun(_ harness: UpdateHarness) -> Int {
            harness.log.filter { $0.hasPrefix("check:") }.count
        }

        @Test("first launch (no stored version) checks immediately and stores the version")
        func firstLaunchChecks() async throws {
            try await withMainSerialExecutor {
                let prefs = PreferencesService.inMemory()
                try await withDependencies {
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
            try await withMainSerialExecutor {
                let now = Date(timeIntervalSince1970: 1_000_000)
                let prefs = PreferencesService.inMemory()
                prefs.setString("2.0.0", PluginUpdateManager.Keys.lastRunAppVersion)
                prefs.setDouble(now.timeIntervalSince1970 - 3600, PluginUpdateManager.Keys.lastCheckAt) // 1h ago
                try await withDependencies {
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
            try await withMainSerialExecutor {
                let now = Date(timeIntervalSince1970: 1_000_000)
                let prefs = PreferencesService.inMemory()
                prefs.setString("2.0.0", PluginUpdateManager.Keys.lastRunAppVersion)
                prefs.setDouble(now.timeIntervalSince1970 - 25 * 3600, PluginUpdateManager.Keys.lastCheckAt)
                try await withDependencies {
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
            try await withMainSerialExecutor {
                try await withDependencies {
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

        @Test("the 24h loop re-checks after the clock advances a day")
        func dailyLoopReChecks() async throws {
            try await withMainSerialExecutor {
                let clock = TestClock()
                try await withDependencies {
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
            try await withMainSerialExecutor {
                try await withDependencies {
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
```

Notes: `PreferencesService.inMemory()` is created OUTSIDE `withDependencies` when the test pre-seeds keys. `Keys` is `enum Keys` (internal) — visible via `@testable`. If `checkInterval` access control blocks the test, it is `static let` internal — fine with `@testable`.

- [ ] **Step 2: Run to verify failure** — filter `PluginUpdateManagerTriggerTests`. Expected: failures (start() currently only sweeps → `firstLaunchChecks` fails; `stop()` missing → compile error).

- [ ] **Step 3: Implement** — replace `start()` and add `stop()`:

```swift
        /// Called once at boot, after all plugins are enabled. Finishes any
        /// deferred bridge refreshes, then runs the automatic triggers:
        /// app-version change (plugin releases usually ride app releases),
        /// >24h-stale fallback, and a daily re-check loop while running.
        public func start() {
            scheduleRun { [weak self] in
                await self?.sweepPendingBridgeRefreshes()
            }
            guard automaticTriggersEnabled else { return }

            let current = callbacks.currentAppVersion()
            let lastRun = preferences.string(Keys.lastRunAppVersion)
            preferences.setString(current, Keys.lastRunAppVersion)
            let stale = lastCheckDate.map { date.now.timeIntervalSince($0) > Self.checkInterval } ?? true
            if lastRun != current || stale {
                scheduleRun { [weak self] in
                    await self?.runAutomaticCheck()
                }
            }

            loopTask = Task { [weak self] in
                while let clock = self?.clock {
                    try? await clock.sleep(for: .seconds(Self.checkInterval))
                    if Task.isCancelled { return }
                    self?.scheduleRun { [weak self] in
                        await self?.runAutomaticCheck()
                    }
                }
            }
        }

        /// Cancel the daily loop (tests / teardown).
        public func stop() {
            loopTask?.cancel()
            loopTask = nil
        }

        /// One automatic (best-effort, silent-on-error) pass over every
        /// autoUpdate-enabled entry, with a single combined notification for
        /// everything that applied.
        private func runAutomaticCheck() async {
            let entries = callbacks.loadRegistry().plugins.filter(\.autoUpdate)
            let updates = await callbacks.checkUpdates(entries)
            stampLastCheck()

            var applied: [PluginRestartNotice] = []
            for update in updates {
                if case .applied = await applyUpdate(update),
                   let notice = restartNotices.first(where: { $0.pluginID == update.id }) {
                    applied.append(notice)
                }
            }
            if !applied.isEmpty {
                callbacks.notify(Self.notificationBody(applied))
            }
        }
```

(`checkUpdates`' real implementation — `PluginUpdateChecker.check` — already skips non-`.url`/no-manifestURL entries, so `runAutomaticCheck` only filters the toggle.)

- [ ] **Step 4: Run to verify pass** — filter `PluginUpdateManagerTriggerTests`, then the full `PluginUpdateManagerTests` file. If `dailyLoopReChecks` flakes on the `advance`, add a second `await Task.yield()` after it (known TestClock+MainActor sequencing; `withMainSerialExecutor` is already in place).

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: PluginUpdateManager automatic triggers (version change + daily loop)"`

---### Task 8: AppCoordinator wiring

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift`

**Interfaces:**
- Consumes: everything from Tasks 3-7.
- Produces: `AppCoordinator.pluginUpdateManager: PluginUpdateManager?` (`public private(set)`), created + `start()`ed at the end of the plugin boot section; automatic triggers disabled under `--e2e-test`.

Thin wiring — not unit-tested directly (same stated precedent as `installPluginFromURL`, :927).

- [ ] **Step 1: Add the property** near `lastInstalledPluginID` (:133):

```swift
        /// Orchestrates plugin auto-update checks/installs. Created during plugin
        /// boot; nil only before startup completes.
        public private(set) var pluginUpdateManager: PluginUpdateManager?
```

- [ ] **Step 2: Create + start the manager** at the end of the plugin boot section, immediately after the `try? PluginRegistryStore.save(registryFile, to: paths.registryPath)` line (:726):

```swift
            // Plugin auto-update orchestration (spec 2026-07-25). Automatic
            // triggers are off in e2e so scenarios drive checks deterministically.
            let updateManager = PluginUpdateManager(
                callbacks: PluginUpdateManager.Callbacks(
                    loadRegistry: { [weak self] in
                        guard let paths = self?.gallagerPaths else {
                            return PluginRegistryFile(schemaVersion: 1, plugins: [])
                        }
                        return PluginRegistryStore.load(paths.registryPath)
                    },
                    saveRegistry: { [weak self] file in
                        guard let paths = self?.gallagerPaths else { return }
                        try? PluginRegistryStore.save(file, to: paths.registryPath)
                    },
                    checkUpdates: { entries in
                        await PluginUpdateChecker.check(entries, session: URLSession.shared)
                    },
                    checkUpdate: { entry in
                        try await PluginUpdateChecker.checkOne(entry, session: URLSession.shared)
                    },
                    installFromURL: { [weak self] url in
                        guard let self else { return .failure(.invalidSchema) }
                        return await self.installPluginFromURL(url, trustConfirmed: true)
                    },
                    hasActiveSessions: { [weak self] id in
                        self?.windowManager.sortedSessions.contains { $0.pluginID == id } ?? false
                    },
                    disablePlugin: { [weak self] id in
                        _ = await self?.disablePluginViaCLI(id)
                    },
                    enablePlugin: { [weak self] id in
                        _ = await self?.enablePluginViaCLI(id)
                    },
                    installStatus: { [weak self] id, root in
                        await self?.pluginInstallStatus(id: id, configRoot: root) ?? .agentUnavailable
                    },
                    installBridge: { [weak self] id, root in
                        await self?.installPlugin(id: id, configRoot: root)
                    },
                    additionalConfigFolders: { [weak self] id in
                        guard let self else { return [] }
                        return SidecarPluginSettings.decode(from: self.pluginSettingsData(id))
                            .additionalConfigFolders
                    },
                    displayName: { [weak self] id in
                        self?.pluginRegistry?.manifest(id)?.displayName ?? id
                    },
                    currentAppVersion: { VersionCompatibility.currentAppVersion },
                    notify: { body in
                        @Dependency(PluginUpdateNotificationService.self) var notificationService
                        notificationService.showUpdateNotification(body)
                    }
                ),
                automaticTriggersEnabled: !isE2ETest
            )
            pluginUpdateManager = updateManager
            updateManager.start()
```

Note: `isE2ETest` already exists as a private let (:1284) — if it is declared *after* this use site in the file, that's fine (type-scope member). `trustConfirmed: true` is correct here: automatic updates only ever flow through a `manifestURL` already pinned in the registry from a user-confirmed install, and source-changed updates were filtered out before `installFromURL` is reached.

- [ ] **Step 3: Build + full test pass** — xcodebuild skill, scheme `ClaudeSpyServer` (build only), then swift-package skill full `ClaudeSpyServerFeatureTests`. Expected: builds clean, all tests pass.

- [ ] **Step 4: Commit** — `git commit -am "feat: wire PluginUpdateManager into AppCoordinator boot"`

---

### Task 9: CLI apply path routes through the manager

Today `gallager plugin update --apply` re-installs but never reloads the running sidecar and never refreshes bridges. Route it through `applyUpdate` so CLI and automatic behavior match (banner/inline state light up too; no desktop notification on the CLI path — the user is reading CLI output).

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift` (the `onPluginUpdate` closure, ~:2552)

**Interfaces:**
- Consumes: `PluginUpdateManager.applyUpdate` (Task 5).
- Produces: unchanged JSON envelope (`id`, `currentVersion`, `newVersion`, `sourceChanged`, `applied`, optional `note`) — the `gallager` CLI and its tests keep working.

- [ ] **Step 1: Replace the apply branch** of `onPluginUpdate` (everything from `guard let paths = await self.gallagerPaths` through the end of the `for update in filtered` loop) with:

```swift
                    guard let manager = await self.pluginUpdateManager else { return [] }
                    var results: [[String: JSONValue]] = []

                    for update in filtered {
                        var row: [String: JSONValue] = [
                            "id": .string(update.id),
                            "currentVersion": .string(update.currentVersion),
                            "newVersion": .string(update.newVersion),
                            "sourceChanged": .bool(update.sourceChanged),
                        ]
                        switch await manager.applyUpdate(update) {
                        case let .applied(needsAppRestart):
                            row["applied"] = .bool(true)
                            if needsAppRestart {
                                row["note"] = .string("restart Gallager to load the new sidecar")
                            }
                        case .skippedSourceChanged:
                            row["applied"] = .bool(false)
                            row["note"] = .string("source-changed: needs manual re-install to trust new source")
                        case let .failed(message):
                            row["applied"] = .bool(false)
                            row["note"] = .string(message)
                        }
                        results.append(row)
                    }
                    return results
```

(The old path's "no manifestURL in registry" note is preserved — `applyUpdate` returns `.failed("no manifestURL in registry")` for that case.)

- [ ] **Step 2: Build + run related tests** — swift-package skill: full `ClaudeSpyServerFeatureTests`; also build the CLI target (`swift-package` skill, build product `GallagerCLI` if separate). Grep `Tests/` for `onPluginUpdate`/`plugin.update` router tests and run those filters too. Expected: green.

- [ ] **Step 3: Commit** — `git commit -am "refactor: CLI plugin update --apply goes through PluginUpdateManager"`

---

### Task 10: Settings UI — Updates section, restart banner, Review… flow

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/AgentsSettingsView.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/AddPluginSheet.swift`

**Interfaces:**
- Consumes: `coordinator.pluginUpdateManager` (Task 8) — `isUpdatable`, `autoUpdateEnabled`, `setAutoUpdate`, `checkNow`, `inlineStatus`, `lastCheckDate`, `restartNotices`, `manifestURL`.
- Produces accessibility identifiers (E2E contract): `agentAutoUpdate-<id>`, `agentCheckUpdates-<id>`, `agentUpdateStatus-<id>`, `pluginRestartBanner`.

- [ ] **Step 1: AddPluginSheet prefill** — change the init (`AddPluginSheet.swift:56`):

```swift
        init(source: InstallSource = .url, initialURLString: String? = nil) {
            self.source = source
            _urlText = State(initialValue: initialURLString ?? "")
            // A zip source has no entry field — start by peeking the manifest.
            _phase = State(initialValue: source == .url ? .entry : .fetching)
        }
```

(The `#if DEBUG` phase-seam init is unaffected.)

- [ ] **Step 2: Restart banner** — in `AgentsSettingsView.body`, insert at the top of the outer `VStack(spacing: 0)` (before the picker):

```swift
                // Restart-required banner: one line per applied update, until
                // the app restarts (restarting IS the remedy — state is in-memory).
                if let updateManager = coordinator.pluginUpdateManager,
                   !updateManager.restartNotices.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(updateManager.restartNotices) { notice in
                            Label(restartText(notice), symbol: .exclamationmarkTriangle)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .accessibilityIdentifier("pluginRestartBanner")
                }
```

with a helper on `AgentsSettingsView`:

```swift
    private func restartText(_ notice: PluginRestartNotice) -> String {
        notice.needsAppRestart
            ? "\(notice.displayName) updated to \(notice.newVersion) — restart Gallager and your \(notice.displayName) sessions"
            : "\(notice.displayName) updated to \(notice.newVersion) — restart your \(notice.displayName) sessions"
    }
```

- [ ] **Step 3: Review… plumbing** — add `case urlPrefilled(String)` to `AddPluginPresentation` (`id: "url:\(string)"` in its `id` switch); extend the `.sheet(item:)` switch with:

```swift
                case let .urlPrefilled(urlString):
                    AddPluginSheet(initialURLString: urlString)
```

Add a parameter to `PluginAgentForm` after `onRemove`:

```swift
        /// Invoked from the source-changed "Review…" button with the plugin's
        /// manifest URL; the parent presents the trust sheet prefilled.
        let onReviewUpdate: (URL) -> Void
```

and update the call site:

```swift
                    PluginAgentForm(
                        pluginID: selectedAgentID,
                        onRemove: {
                            pluginToRemove = selectedAgentID
                            showRemoveConfirmation = true
                        },
                        onReviewUpdate: { url in
                            addPlugin = .urlPrefilled(url.absoluteString)
                        }
                    )
```

- [ ] **Step 4: Updates section** — inside `PluginAgentForm.body`'s `Form`, after the "Behaviour" `Section` and before the config-folders `Section`:

```swift
                // Updates (URL-installed plugins only — bundled and
                // folder-dropped plugins have no update source)
                if let updateManager = coordinator.pluginUpdateManager,
                   updateManager.isUpdatable(pluginID) {
                    Section("Updates") {
                        Toggle(
                            "Check for updates automatically",
                            isOn: Binding(
                                get: { updateManager.autoUpdateEnabled(pluginID) },
                                set: { updateManager.setAutoUpdate(pluginID, enabled: $0) }
                            )
                        )
                        .accessibilityIdentifier("agentAutoUpdate-\(pluginID)")

                        HStack(spacing: 8) {
                            Button("Check Now") {
                                updateManager.checkNow(pluginID)
                            }
                            .disabled(updateManager.inlineStatus[pluginID] == .checking)
                            .accessibilityIdentifier("agentCheckUpdates-\(pluginID)")

                            if updateManager.inlineStatus[pluginID] == .checking {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Spacer()

                            if let lastCheck = updateManager.lastCheckDate {
                                Text("Last checked \(lastCheck, format: .relative(presentation: .named))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        updateStatusRow(updateManager)
                    }
                }
```

and the status row helper on `PluginAgentForm`:

```swift
        @ViewBuilder
        private func updateStatusRow(_ updateManager: PluginUpdateManager) -> some View {
            switch updateManager.inlineStatus[pluginID] {
            case .upToDate:
                Text("Up to date")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agentUpdateStatus-\(pluginID)")
            case let .updated(version, needsAppRestart):
                Text(
                    needsAppRestart
                        ? "Updated to \(version) — restart Gallager and your \(agentDisplayName) sessions"
                        : "Updated to \(version) — restart your \(agentDisplayName) sessions"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("agentUpdateStatus-\(pluginID)")
            case let .updateAvailableNewSource(version):
                HStack(spacing: 8) {
                    Label(
                        "Update \(version) is served from a new source",
                        symbol: .exclamationmarkTriangle
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Button("Review…") {
                        if let url = updateManager.manifestURL(pluginID) {
                            onReviewUpdate(url)
                        }
                    }
                    .accessibilityIdentifier("agentReviewUpdate-\(pluginID)")
                }
                .accessibilityIdentifier("agentUpdateStatus-\(pluginID)")
            case let .failed(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("agentUpdateStatus-\(pluginID)")
            case .checking, nil:
                EmptyView()
            }
        }
```

(`agentDisplayName` already exists on `PluginAgentForm` — it drives "Auto-run \(agentDisplayName)…".)

- [ ] **Step 5: Build** — xcodebuild skill, scheme `ClaudeSpyServer`. Expected: clean build. Note: `isUpdatable` reads registry.json from disk per render — acceptable for a settings pane; do not cache prematurely.

- [ ] **Step 6: Commit** — `git commit -am "feat: plugin Updates section, restart banner, and source-changed Review flow in Agents settings"`

---

### Task 11: Documentation

**Files:**
- Modify: `docs/plugins/sidecar-authoring.md` (the distribution/update section, around :516-524)
- Modify: `CLAUDE.md` (the sidecar-authoring reference bullet)

- [ ] **Step 1: sidecar-authoring.md** — extend the update section with the auto-update contract for plugin AUTHORS (keep the existing CLI docs). Cover exactly these facts:
  - URL-installed plugins are checked automatically when Gallager first launches after an app update and at most daily thereafter; per-plugin opt-out toggle in Settings → Agents (`autoUpdate` in `registry.json`, default true).
  - Updates install through the same manifest-fetch → SHA-256 → zip-validation pipeline; a changed bundle host (`sourceChanged`) is never auto-installed and requires the manual trust flow.
  - After an update, Gallager hot-restarts the sidecar only when the plugin has no active sessions, then re-invokes the `install` RPC for every config root whose `install_status` reports installed — so **a sidecar's `install` handler must be idempotent and atomic** (the pi/opencode `os.replace` pattern). If the plugin was busy, the refresh is deferred to the next app launch via `needsBridgeRefresh` in `registry.json`.
  - Recommendation: bake the plugin version into the bridge file at install time so a stale bridge is diagnosable.

- [ ] **Step 2: CLAUDE.md** — append one sentence to the sidecar-authoring bullet: auto-update for URL-installed plugins (checks on app-version change + daily, per-plugin toggle + Check Now in Settings → Agents, idle hot-restart + bridge re-install via `PluginUpdateManager`; source-changed updates require the manual trust flow).

- [ ] **Step 3: Commit** — `git commit -am "docs: sidecar plugin auto-update"`

---

### Task 12: E2E scenario

An e2e-deterministic path: under `--e2e-test` the coordinator wires stub callbacks (real network/HTTPS is impossible in e2e — the pipeline is HTTPS-only by design). The echo plugin is presented as URL-installed with one pending update; the scenario drives Check Now and verifies the section, inline status, and banner.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift` (e2e wiring inside the Task 8 block)
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/AgentsPluginAutoUpdateScenario.swift`
- Modify: the `allScenarios` registry (find it: `grep -rn "allScenarios" ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/`)

**REQUIRED SUB-SKILL for this task:** invoke the repo's `e2e-testing` skill before writing the scenario — it owns the DSL details, run script, and baseline rules. The step contents below are the target behavior; defer to the skill on step-type spellings.

- [ ] **Step 1: E2E stub wiring** — in the Task 8 callbacks block, make three closures e2e-aware (guarded by `isE2ETest`; production paths unchanged):
  - `loadRegistry`: after loading the real file, when `isE2ETest`, upsert an entry for `"echo"` — `source: .url`, `manifestURL: URL(string: "https://e2e.invalid/echo/plugin.json")`, `version: "1.0.0"` — preserving any `autoUpdate`/`needsBridgeRefresh` already persisted for it (so the toggle and busy-defer still round-trip through the real file).
  - `checkUpdates` AND `checkUpdate`: when `isE2ETest`, report `PluginUpdate(id: "echo", currentVersion: "1.0.0", newVersion: "9.9.9", sourceChanged: false)` for the echo entry when it is in the passed scope (batch: filtered list; single: the update or nil), never touching the network.
  - `installFromURL`: when `isE2ETest`, return `.success(.installed(id: "echo"))` without touching the network.
- [ ] **Step 2: Scenario** — model on `AgentsInstallZipAutoSelectScenario` (`macOnlySetup`, `macOpenSettings`, `macSelectSettingsTab("Agents")`); tags `["plugin", "sidecar", "agents", "settings", "macos-only"]`. Flow: select the Echo segment in the agents picker → wait for "Check for updates automatically" → screenshot `mac-agents-updates-section` → click "Check Now" → wait for "Updated to 9.9.9 — restart your Echo sessions" (full string; substring waits get shadowed by sibling text) → wait for the banner ("Echo updated to 9.9.9 — restart your Echo sessions") → screenshot `mac-agents-update-applied`. Register in `allScenarios`.
- [ ] **Step 3: Run locally 2-3×** via `./scripts/e2e-test.sh` (per the e2e-testing skill) and **visually verify every screenshot**. Do NOT commit locally-generated baselines for pre-existing scenarios — if other Agents-tab scenarios' screenshots change (echo now shows an Updates section), `git rm` those baseline dirs and let CI regenerate.
- [ ] **Step 4: Commit** — `git add -A && git commit -m "test: e2e scenario for plugin auto-update UI"`

---

## Final verification (after all tasks)

- [ ] Full package test run (swift-package skill, all of `ClaudeSpyServerFeatureTests`).
- [ ] macOS app build (xcodebuild skill, scheme `ClaudeSpyServer`).
- [ ] Manual smoke: launch the app with a URL-installed plugin present (e.g. re-install `pi` from its published manifest), open Settings → Agents → pi, confirm the Updates section renders with the toggle on and "Check Now" reports "Up to date".
- [ ] Use superpowers:verification-before-completion, then superpowers:finishing-a-development-branch (PR per repo convention; the `gh pr create` hook injects the post-PR checklist).
