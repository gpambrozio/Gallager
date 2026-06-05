# Agents Tab + Per-Agent Settings + Codex Multi-Folder — Implementation Plan (2 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the legacy "Plugin" settings tab with an "Agents" tab whose per-agent settings (command, auto-run, log level, per-agent close-pane, and a per-folder install list with Install/Uninstall buttons) are wired live to the plugin cores; remove the now-dead per-agent controls from the General tab; and give Codex the same multi-folder (`CODEX_HOME`) support Claude already has.

**Architecture:** The Agents tab edits each plugin's own `settings.json` (under `~/.gallager/state/plugins/<id>/`) and calls `core.applySettings(...)` for live pickup — via thin `AppCoordinator` methods that own all registry/core access. Per-folder install reuses Plan-1's `installStatus/install/uninstall(configRoot:)`. The close-pane preference folds into each core (the app drops its own check). Codex's core scans `{default} ∪ additionalConfigFolders`, mirroring Claude.

**Tech Stack:** Swift 6, SwiftUI (MV pattern, `@Environment`/`@State`/`@Observable`), Swift Concurrency (actors), Point-Free Dependencies, Swift Testing, FSEvents watchers.

**Builds on:** Plan 1 (`2026-06-01-agent-cli-install-and-ingress-hooks.md`, merged). **Spec:** `docs/superpowers/specs/2026-06-01-agents-settings-tab-design.md` (§4–7 + §5).

**Decisions already made (spec):** segmented (Claude/Codex) Agents tab; close-pane is per-agent; install stays CLI-driven in the cores (Plan 1); app never edits agent settings files (it edits its OWN per-plugin settings.json).

**Carried-forward notes from Plan-1 final review:**
- `core.install/installStatus` require an **enabled** core. Plugins are enabled at app startup (`AppCoordinator` setup), so the Agents tab normally sees enabled cores; the `AppCoordinator` helpers below still enable-on-demand defensively and surface `.agentUnavailable`/not-enabled gracefully.
- Two spec **Verification items** remain (Task 8 smoke): does `codex plugin …` honor `CODEX_HOME` per-folder; do `install`/`add` update an existing older `gallager` (else uninstall-then-install).

---

## File Structure

**Modify (logic):**
- `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeSettings.swift` — add `closePaneOnSessionEnd`.
- `ClaudeSpyPackage/Sources/CodexPluginCore/CodexSettings.swift` — add `closePaneOnSessionEnd` + `additionalConfigFolders`.
- `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeTranslator.swift` + `ClaudeCodePluginCore.swift` — thread close-pane pref into `.sessionEnded`.
- `ClaudeSpyPackage/Sources/CodexPluginCore/CodexTranslator.swift` + `CodexPluginCore.swift` — same; plus multi-folder scan/watch.
- `ClaudeSpyPackage/Sources/CodexPluginCore/CodexScanner.swift` — already supports a single root; add a multi-root convenience.
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift` — drop the app-side close-pane check; add Agents-tab support methods; extend `PluginSettingsMigration` call.
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/PluginSettingsMigration.swift` — seed new fields from raw UserDefaults.
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Models/Settings.swift` (`AppSettings`) — delete the per-agent fields.
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/SettingsView.swift` — rename tab; remove General per-agent sections; drop the deleted helpers.

**Create:**
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/AgentsSettingsView.swift` — the new tab (segmented + per-agent form + folder rows).

**Delete:**
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/PluginSettingsView.swift`
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Services/PluginService.swift`
- The `ClaudeFolderRow` + `CustomFolderPluginSetupView` views (currently in `SettingsView.swift` / their own files) and `PluginFailureDetailsButton.swift`.

**Tests:** new/updated under `ClaudeCodePluginCoreTests`, `CodexPluginCoreTests`, `ClaudeSpyServerFeatureTests`, plus an e2e scenario in `ClaudeSpyE2ELib`.

---

## Task 1: Add settings fields (closePane both; additionalConfigFolders for Codex)

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeSettings.swift`, `ClaudeSpyPackage/Sources/CodexPluginCore/CodexSettings.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/ClaudeCodeSettingsTests.swift`, `ClaudeSpyPackage/Tests/CodexPluginCoreTests/CodexSettingsTests.swift`

- [ ] **Step 1: Write failing round-trip tests.** In each settings test file add a case asserting the new key(s) decode with the documented snake_case name and default, and survive an encode→decode round-trip:
  - Claude: `close_pane_on_session_end` (default `false`).
  - Codex: `close_pane_on_session_end` (default `false`) and `additional_config_folders` (default `[]`).
  Assert decoding empty data yields the defaults, and decoding JSON with the keys present yields the values.

- [ ] **Step 2: Run** `cd ClaudeSpyPackage && swift test --filter ClaudeCodeSettings 2>&1 | tail -15` and `--filter CodexSettings` → FAIL (members don't exist).

- [ ] **Step 3: Implement.** In `ClaudeCodeSettings`, add the property, init param (default `false`), `CodingKeys` case, and `decodeIfPresent` line:
  ```swift
  /// When true (and the agent exited cleanly at the prompt), the pane closes
  /// on session end. Per-agent; the app honors the core's eligibility flag.
  public var closePaneOnSessionEnd: Bool
  ```
  `CodingKeys`: `case closePaneOnSessionEnd = "close_pane_on_session_end"`. Init: `closePaneOnSessionEnd: Bool = false`. Decoder: `self.closePaneOnSessionEnd = try container.decodeIfPresent(Bool.self, forKey: .closePaneOnSessionEnd) ?? false`.
  In `CodexSettings`, add the SAME `closePaneOnSessionEnd`, PLUS:
  ```swift
  /// Extra `CODEX_HOME` roots to scan/install beyond the default. Mirrors
  /// ClaudeCodeSettings.additionalConfigFolders.
  public var additionalConfigFolders: [String]
  ```
  `CodingKeys`: `case additionalConfigFolders = "additional_config_folders"`. Init: `additionalConfigFolders: [String] = []`. Decoder: `?? []`.

- [ ] **Step 4: Run the two filters** → PASS.

- [ ] **Step 5: Commit** `git commit -m "feat(settings): per-agent closePaneOnSessionEnd + Codex additionalConfigFolders"`.

---

## Task 2: Fold the close-pane pref into the cores

**Context:** Today `ClaudeCodeTranslator.appActions(...)` and `CodexTranslator.appActions(...)` emit `.sessionEnded(sessionID:, closePaneEligible: body.reason == .promptInputExit)`, and the app ANDs the user pref at `AppCoordinator.swift:880` (`guard closePaneEligible, settings.closePaneOnSessionEnd`). We move the pref into the core and make the app honor the flag alone.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeTranslator.swift`, `ClaudeCodePluginCore.swift`
- Modify: `ClaudeSpyPackage/Sources/CodexPluginCore/CodexTranslator.swift`, `CodexPluginCore.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift`
- Test: `ClaudeCodeTranslatorTests`, `CodexTranslatorTests`

- [ ] **Step 1: Write failing tests.** In each translator test, add cases: with `closePaneOnSessionEnd: true` AND a clean prompt-exit session-end → `.sessionEnded(closePaneEligible: true)`; with `closePaneOnSessionEnd: false` and the same clean exit → `.sessionEnded(closePaneEligible: false)`; with `true` but a non-clean reason → `closePaneEligible: false`.

- [ ] **Step 2: Run** the two translator filters → FAIL (no closePane param yet).

- [ ] **Step 3: Implement.** Thread a `closePaneOnSessionEnd: Bool` argument from the core into the translator. In each translator:
  - Add `closePaneOnSessionEnd: Bool` to the `appActions(for:sessionID:projectPath:)` signature (→ `appActions(for:sessionID:projectPath:closePaneOnSessionEnd:)`) and to the `translate(...)` entrypoint that calls it.
  - Change the emission to:
    ```swift
    return [.sessionEnded(
        sessionID: sessionID,
        closePaneEligible: body.reason == .promptInputExit && closePaneOnSessionEnd
    )]
    ```
  In each core's `translate(...)` call site (e.g. `ClaudeCodePluginCore.swift:79`), pass `closePaneOnSessionEnd: settings.closePaneOnSessionEnd`.

- [ ] **Step 4: Drop the app-side pref check.** In `AppCoordinator.swift` (~line 880) change:
  ```swift
  guard closePaneEligible, settings.closePaneOnSessionEnd else { return }
  ```
  to:
  ```swift
  guard closePaneEligible else { return }
  ```
  (Keep the yolo-reset that happens for every session-end, before this guard, unchanged.)

- [ ] **Step 5: Run** the translator filters → PASS, then `swift build --target ClaudeSpyServerFeature` → PASS.

- [ ] **Step 6: Commit** `git commit -m "feat(plugin): per-agent close-pane folds into core eligibility; app honors flag"`.

---

## Task 3: Codex multi-folder scanning + watching

**Context:** `ClaudeCodePluginCore` already scans `settings.additionalConfigFolders` (see its scanner call). `CodexPluginCore.refreshProjects` scans only `CodexScanner.defaultSessionsRoot()`, and watches one root. Generalize to `{default} ∪ settings.additionalConfigFolders` (each folder is a `CODEX_HOME` root; its sessions live at `<root>/sessions`).

**Files:**
- Modify: `ClaudeSpyPackage/Sources/CodexPluginCore/CodexScanner.swift` (add a multi-root helper), `CodexPluginCore.swift` (scan + watch each root)
- Test: `ClaudeSpyPackage/Tests/CodexPluginCoreTests/CodexScannerTests.swift` (or a new `CodexMultiFolderTests`)

- [ ] **Step 1: Write a failing test.** Build two temp fixture roots, each with `sessions/YYYY/MM/DD/rollout-*.jsonl` referencing distinct `cwd`s, and assert that scanning the SET of roots returns the union of projects (deduped by path, most-recently-used wins when the same project appears in both). Use the existing `CodexScanner.scan(sessionsRoot:home:)` per root and merge, OR the new helper from Step 3.

- [ ] **Step 2: Run** `swift test --filter CodexScanner` (or your new suite) → FAIL.

- [ ] **Step 3: Add a multi-root helper to `CodexScanner`:**
  ```swift
  /// Scans several CODEX_HOME roots and merges their projects (dedup by path,
  /// most-recently-used wins). `roots` are CODEX_HOME dirs; sessions are at
  /// `<root>/sessions`.
  func scan(codexHomeRoots roots: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentProject] {
      var byPath: [String: AgentProject] = [:]
      for root in roots {
          let sessions = root.appendingPathComponent("sessions")
          for project in scan(sessionsRoot: sessions, home: home) {
              if let existing = byPath[project.path] {
                  if shouldReplace(existing: existing, with: project) { byPath[project.path] = project }
              } else {
                  byPath[project.path] = project
              }
          }
      }
      return byPath.values.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
  }
  ```
  (Reuse the existing private `shouldReplace`/sort logic — match the single-root `scan`'s ordering. If `shouldReplace` is `private`, keep this helper in the same file/type so it can call it.)

- [ ] **Step 4: Wire `CodexPluginCore`.** Compute the root set and use the helper:
  ```swift
  private func codexHomeRoots() -> [URL] {
      let defaultHome = CodexScanner.defaultCodexHome()   // see note below
      let extras = settings.additionalConfigFolders.map { URL(fileURLWithPath: $0) }
      return [defaultHome] + extras
  }
  ```
  - `refreshProjects`: `let projects = scanner.scan(codexHomeRoots: codexHomeRoots())` then `await host.setProjects(projects)`.
  - Watching: where the core currently starts one `CodexSessionsWatcher` on `defaultSessionsRoot()`, start one per root (`<root>/sessions`), all firing the same debounced `refreshProjects`. Keep an array of watchers; restart them in `applySettings` if `additionalConfigFolders` changed (compare old vs new before reassigning `settings`).
  - Add `CodexScanner.defaultCodexHome()` returning `$CODEX_HOME` or `~/.codex` (factor it out of the existing `defaultSessionsRoot()`, which can then be `defaultCodexHome().appendingPathComponent("sessions")`).

- [ ] **Step 5: Run** `swift test --filter Codex` → PASS; `swift build --target CodexPluginCore` → PASS.

- [ ] **Step 6: Commit** `git commit -m "feat(codex): scan + watch default ∪ additionalConfigFolders roots"`.

---

## Task 4: AppCoordinator support API for the Agents tab

The Agents tab (a SwiftUI view) must list plugins, read/write each plugin's `settings.json` with live `applySettings`, and drive per-folder install/status — all through `AppCoordinator` (the one type holding the registry). Add these `@MainActor` methods.

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Coordinators/AppCoordinator.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/AgentsSettingsSupportTests.swift` (new)

- [ ] **Step 1: Write failing tests** for the settings load/save round-trip and the install-status passthrough, using an in-memory registry/core. Minimum: `pluginSettingsData(id:)` returns what `setPluginSettings(id:_:)` wrote; `installStatus(id:configRoot:)` returns the enabled core's status. (If wiring a full registry in a unit test is heavy, assert the smaller, pure pieces — e.g. the plugin-list accessor sorts/maps correctly — and rely on the e2e scenario in Task 8 for the integration path. Prefer at least one real round-trip test for `setPluginSettings`→`pluginSettingsData`.)

- [ ] **Step 2: Run** the new filter → FAIL.

- [ ] **Step 3: Implement** (place near the other plugin helpers in `AppCoordinator`):
  ```swift
  // MARK: - Agents settings tab support

  /// Display rows for the segmented agent picker: (id, displayName), sorted.
  public func agentPluginList() -> [(id: String, name: String)] {
      guard let registry = pluginRegistry else { return [] }
      return registry.registeredIDs
          .filter { $0 != "echo" }                         // echo is a test-only plugin
          .map { (id: $0, name: registry.manifest($0)?.name ?? $0) }
  }

  /// Raw settings.json bytes for a plugin (empty if none yet).
  public func pluginSettingsData(id: String) -> Data {
      (try? Data(contentsOf: paths.pluginSettingsPath(id))) ?? Data()
  }

  /// Persist a plugin's settings.json and push it live to the enabled core.
  public func setPluginSettings(id: String, _ data: Data) async {
      let url = paths.pluginSettingsPath(id)
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: url, options: .atomic)
      _ = await pluginRegistry?.core(id)?.applySettings(data)
  }

  /// Ensure a plugin's core is enabled, then query install status for a root.
  public func pluginInstallStatus(id: String, configRoot: String?) async -> PluginInstallStatus {
      guard let core = await enabledCore(id) else { return .agentUnavailable }
      return await core.installStatus(configRoot: configRoot)
  }

  /// Install / uninstall for a root via the enabled core. Returns an error string on failure.
  public func installPlugin(id: String, configRoot: String?) async -> String? {
      guard let core = await enabledCore(id) else { return "Plugin not available" }
      do { _ = try await core.install(configRoot: configRoot); return nil }
      catch { return String(describing: error) }
  }

  public func uninstallPlugin(id: String, configRoot: String?) async -> String? {
      guard let core = await enabledCore(id) else { return "Plugin not available" }
      do { try await core.uninstall(configRoot: configRoot); return nil }
      catch { return String(describing: error) }
  }

  /// The enabled core for `id`, enabling it on demand (plugins are normally
  /// enabled at startup; this is defensive).
  private func enabledCore(_ id: String) async -> (any PluginCore)? {
      guard let registry = pluginRegistry else { return nil }
      if let core = registry.core(id) { return core }
      _ = await enablePluginViaCLI(id)   // reuses the existing enable path (builds host+env)
      return registry.core(id)
  }
  ```
  Notes: confirm `PluginManifest` exposes a display name (`name`/`displayName`); use whichever exists. `applySettings` returns `SettingsResult` — the UI can later surface `.error`; for now discard. Keep `paths` (the existing `GallagerPaths`) as already stored on the coordinator.

- [ ] **Step 4: Run** the new filter → PASS; `swift build --target ClaudeSpyServerFeature` → PASS.

- [ ] **Step 5: Commit** `git commit -m "feat(plugin): AppCoordinator API for Agents tab settings + per-folder install"`.

---

## Task 5: The Agents settings tab (segmented + per-agent form + folder rows)

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/AgentsSettingsView.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/SettingsView.swift` (tab enum + the tab item)
- Reference (read, don't keep): the existing `PluginSettingsView.swift` and `ClaudeFolderRow` for patterns (status badges, install button states).

- [ ] **Step 1: Rename the tab.** In `SettingsView.swift`, rename `SettingsTab.plugin` → `.agents`, change the tab `Label("Plugin", symbol: .puzzlepiece)` → `Label("Agents", symbol: .puzzlepiece)` (keep the symbol or pick another existing one from `Symbols`), and the `.tag(SettingsTab.plugin)` → `.tag(SettingsTab.agents)`. Point the tab's content at `AgentsSettingsView()` instead of `PluginSettingsView()`.

- [ ] **Step 2: Build `AgentsSettingsView`.** A macOS-only (`#if os(macOS)`) view using `@Environment(AppCoordinator.self)`:
  - A segmented `Picker` over `coordinator.agentPluginList()` bound to `@State private var selectedAgent: String` (default the first id).
  - Below it, a `PluginAgentForm(pluginID: selectedAgent)` subview (the "form switching on plugin id"). Decode the plugin's settings into a local `@State` struct on appear (`coordinator.pluginSettingsData(id:)`), and on every edit, re-encode + `await coordinator.setPluginSettings(id:, data)` (debounce with a short `.task(id:)` or a trailing write — match how other settings views persist; a direct write-on-change is acceptable here since the file write is cheap).
  - `PluginAgentForm` renders, per agent:
    - An agent-binary banner when `installStatus(id, configRoot: nil) == .agentUnavailable` ("<Agent> CLI not found").
    - **Command** `TextField` + Browse button (reuse an `NSOpenPanel` helper like the existing `browseForClaude`), **Auto-run** `Toggle`, **Log level** `Picker` over `LogLevel.allCases`, **Close pane when <agent> exits** `Toggle`. Each bound to the local settings struct → persisted via `setPluginSettings`.
    - A **Config folders** section: rows for the default root (label `~/.claude` or `~/.codex`, not removable) + each `additionalConfigFolders` entry. Each row shows the path, an install-status view, and an Install/Uninstall button; non-default rows have a remove (minus) button that edits `additionalConfigFolders` (→ persisted). An **Add Folder…** button appends a browsed folder.
  - The folder row is a small subview owning `@State var status: PluginInstallStatus = .notInstalled` and `@State var busy = false`; `.task(id:)` calls `coordinator.pluginInstallStatus(id:configRoot:)`; the Install button sets `busy`, calls `coordinator.installPlugin(...)`, then re-queries status; Uninstall mirrors it. This generalizes today's `ClaudeFolderRow` but is driven by `AppCoordinator`/the core, not `PluginService`. Map statuses to UI: `.installed(v)` → green "Installed v…" + Uninstall; `.notInstalled` → Install button; `.agentUnavailable` → "Agent not found" (disabled). Surface install errors inline (reuse the structured failure presentation pattern from `PluginFailureDetailsButton` if you keep a slimmed copy, or a simple `.help`/inline `Text`).
  - Use `Symbols.*` for any SF Symbols (never string literals) — add new cases to `Symbols.swift` if needed.

- [ ] **Step 3: Build the macOS app target** to typecheck the view: `swift build --target ClaudeSpyServerFeature 2>&1 | tail -20` → PASS. (SwiftUI views are validated by compilation + the e2e scenario in Task 8; no unit test required for the view itself.)

- [ ] **Step 4: Commit** `git commit -m "feat(agents): new Agents settings tab (segmented, per-agent settings + per-folder install)"`.

---

## Task 6: Remove General-tab per-agent sections + delete legacy plugin UI/service

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Views/SettingsView.swift`
- Delete: `PluginSettingsView.swift`, `Services/PluginService.swift`, `Views/PluginFailureDetailsButton.swift`, and the `ClaudeFolderRow` + `CustomFolderPluginSetupView` views (wherever they live).

- [ ] **Step 1: Remove General sections.** In `SettingsView.swift`'s General tab, delete the `Section("Claude Code")`, `Section("Codex CLI")`, and `Section("Project Folders")` blocks (and the `ClaudeFolderRow`/`CustomFolderPluginSetupView` usages + `pluginSetupFolder`/`pluginStatusRefreshID` state and the `browseForClaudeFolder`/`browseForClaude`/`browseForCodex` helpers if now unused). Keep the tmux/terminal/other General sections. If `browseForClaude`/`browseForCodex` are reused by the Agents tab, MOVE them to `AgentsSettingsView.swift` instead of deleting.

- [ ] **Step 2: Delete legacy files.** `git rm` `PluginSettingsView.swift`, `PluginService.swift`, `PluginFailureDetailsButton.swift`, and the `ClaudeFolderRow`/`CustomFolderPluginSetupView` definitions/files. Remove any remaining references (e.g. the `PluginService` environment injection if one exists — search `PluginService(` and `pluginService`).

- [ ] **Step 3: Build** `swift build --target ClaudeSpyServerFeature 2>&1 | tail -20` → PASS. Fix every reference the deletions surface (this is the integration step for the UI removal).

- [ ] **Step 4: Commit** `git commit -m "refactor(settings): remove General per-agent sections + legacy plugin UI/service"`.

---

## Task 7: Migration of new fields + delete AppSettings agent fields

**Context:** With the General-tab bindings gone (Task 6), the `AppSettings` per-agent fields are unused. Delete them and have the one-shot migration seed the new per-plugin fields directly from the raw legacy UserDefaults keys (so deletion doesn't break the seeding).

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/PluginSettingsMigration.swift`, `AppCoordinator.swift` (the migration call site ~line 388), `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Models/Settings.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginSettingsMigrationTests.swift`

- [ ] **Step 1: Update the migration test.** Assert that, given legacy UserDefaults keys (claude/codex command path + auto-run, `additionalClaudeFolders`, `closePaneOnSessionEnd`), `runIfNeeded` seeds `ClaudeCodeSettings(commandPath, autoRun, closePaneOnSessionEnd, additionalConfigFolders)` and `CodexSettings(commandPath, autoRun, closePaneOnSessionEnd)` into the respective settings.json (still guarded by the done-flag, still `writeIfAbsent`). Run → FAIL.

- [ ] **Step 2: Implement.** Change `PluginSettingsMigration.runIfNeeded` to read the legacy values from `preferences` by RAW KEY (not via `AppSettings` properties, which are being deleted) — use the existing `AppSettings.Keys.*` raw string constants (keep those constants, or inline the literals if the Keys enum is also removed). Seed:
  - `ClaudeCodeSettings(commandPath: …, autoRun: …, closePaneOnSessionEnd: …, additionalConfigFolders: <decoded additionalClaudeFolders>)`
  - `CodexSettings(commandPath: …, autoRun: …, closePaneOnSessionEnd: …)`
  Update the `AppCoordinator` call site (~388) to pass the raw-read values (or have `runIfNeeded` read `preferences` itself — preferred, so the coordinator no longer threads agent fields).

- [ ] **Step 3: Delete the AppSettings agent fields.** In `Settings.swift` remove `claudeCommandPath`, `autoRunClaudeInProjects`, `codexCommandPath`, `autoRunCodexInProjects`, `closePaneOnSessionEnd`, `additionalClaudeFolders` (properties, `didSet`s, init loads, `CodingKeys`, and the `addClaudeFolder`/`removeClaudeFolder` helpers if now unused). Keep the raw `Keys` constants the migration still needs (or move those literals into the migration). Confirm nothing else in `Sources/` reads these (grep first).

- [ ] **Step 4: Build + test** `swift build --target ClaudeSpyServerFeature` and `swift test --filter PluginSettingsMigration` → PASS. Fix any remaining references.

- [ ] **Step 5: Commit** `git commit -m "feat(settings): migrate new per-agent fields; delete legacy AppSettings agent fields"`.

---

## Task 8: e2e scenario + full build/test + Release

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeSpyE2ELib/Scenarios/AgentsSettingsTabScenario.swift` (+ register in `allScenarios`)
- Verify: full `swift test`, e2e suite, Release build.

- [ ] **Step 1: Write an Agents-tab e2e scenario** (follow the e2e DSL patterns; use the `e2e-testing` skill conventions). Cover: open Settings → Agents tab; segmented switch Claude↔Codex; the per-agent settings render; a config-folder row shows install status and the Install button drives a (faked) install that flips the row to installed; and the General tab no longer shows the removed Claude/Codex/Project-Folders sections. Drive install via the `ProcessRunner` dependency stubbed in e2e mode so no real `claude`/`codex` runs. Take screenshots at key points. Register the scenario.

- [ ] **Step 2: Run the new scenario** `./scripts/e2e-test.sh --scenario AgentsSettingsTab` (or the repo's invocation) and visually verify each screenshot per the project's e2e rules (no `compare:false`; verify baselines). Iterate until green.

- [ ] **Step 3: Full unit suite** `cd ClaudeSpyPackage && swift test 2>&1 | tail -20` → 0 failures.

- [ ] **Step 4: macOS Release build** `xcodebuild -workspace ClaudeSpy.xcworkspace -scheme ClaudeSpyServer -configuration Release -destination 'platform=macOS' -skipMacroValidation -skipPackagePluginValidation build 2>&1 | tee ${TMPDIR:-/tmp}/p2_build.log | xcsift --format toon --warnings` → success, 0 errors.

- [ ] **Step 5: Verification items (spec).** With a real `claude`/`codex` on PATH (if available): from the Agents tab (or `gallager plugin call codex install --config-root <tmp CODEX_HOME>`), confirm (a) Codex install honors `CODEX_HOME` (the plugin lands under the chosen root); (b) reinstalling over an older `gallager` actually updates to `1.1.0`. If either fails, file a follow-up and (for upgrade) add the uninstall-then-install fallback in the relevant `*CLIInstaller.install`.

- [ ] **Step 6: Commit** `git commit -m "test(e2e): Agents settings tab scenario; verify full suite + Release"`.

---

## Self-Review Checklist (author)

- **Spec coverage:** §4 Agents tab structure (Tasks 4–6) ✓; §4 per-agent settings wired via applySettings (Tasks 1,4,5) ✓; §4 per-agent close-pane (Tasks 1–2) ✓; §5 Codex multi-folder (Tasks 1,3) ✓; §6 General-tab removal (Task 6) ✓; §7 migration + AppSettings deletion (Task 7) ✓; iOS untouched (no iOS tasks) ✓.
- **Placeholders:** logic tasks (1–4, 7) carry literal code; the SwiftUI tab (5–6) is specified structurally with exact bindings/calls + a named pattern to adapt (`ClaudeFolderRow`), which is the practical altitude for a view refactor — the implementer reads the current files.
- **Type/name consistency:** `closePaneOnSessionEnd` (both settings, snake_case `close_pane_on_session_end`), `additionalConfigFolders` (`additional_config_folders`), `AppCoordinator` methods (`agentPluginList`/`pluginSettingsData`/`setPluginSettings`/`pluginInstallStatus`/`installPlugin`/`uninstallPlugin`) used identically across tasks. `SettingsTab.agents`.
- **Ordering/coupling:** UI (5–6) precedes the `AppSettings` field deletion (7) so the General bindings are gone before the fields are; migration reads raw UserDefaults so deletion is safe.
- **Open risks:** confirm `PluginManifest` display-name field name (Task 4/5); confirm `CodexSessionsWatcher` supports per-root instances (Task 3); both surfaced as build-time, not silent.
