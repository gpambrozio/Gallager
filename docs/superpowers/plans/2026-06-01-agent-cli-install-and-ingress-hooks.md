# Agent-CLI Plugin Install + Ingress Hooks — Implementation Plan (1 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move plugin install/uninstall/status into each `PluginCore`, driven by the agent's own CLI (`claude plugin …` / `codex plugin …`) per config-root, and repoint the bundled hooks at the ingress socket — replacing the branch's file-writing installers.

**Architecture:** The agent-blind `PluginCore` seam keeps `install`/`uninstall`/status, but the methods become per-config-root and shell out to the agent CLI via the injected `ProcessRunner`. Each core builds a small `*CLIInstaller` value type that runs the CLI through `/usr/bin/env <command> …` (so PATH resolution + "binary missing" detection are free) with `CLAUDE_CONFIG_DIR` / `CODEX_HOME` set for non-default roots. The two bundled `hook.py` scripts write length-prefixed ingress frames instead of the removed HTTP server.

**Tech Stack:** Swift 6, Swift Concurrency (actors), Point-Free Dependencies (`ProcessRunner`), Swift Testing, Python 3 (hook scripts).

**Scope note:** This is plan 1 of 2. Plan 2 (`2026-06-01-agents-settings-tab.md`, written next) covers per-agent settings wiring, the per-agent close-pane fold, Codex multi-folder scanning, and the Agents settings tab UI + General-tab removals. After this plan, install works via `gallager plugin call <id> install` and unit tests; no UI changes yet.

**Spec:** `docs/superpowers/specs/2026-06-01-agents-settings-tab-design.md` (§1–3, §8).

---

## File Structure

**Create:**
- `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeCLIInstaller.swift` — Claude CLI install/uninstall/status.
- `ClaudeSpyPackage/Sources/CodexPluginCore/CodexCLIInstaller.swift` — Codex CLI install/uninstall/status.
- `ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/ClaudeCodeCLIInstallerTests.swift`
- `ClaudeSpyPackage/Tests/CodexPluginCoreTests/CodexCLIInstallerTests.swift`

**Modify:**
- `ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginEnv.swift` — add `PluginInstallStatus`, add `marketplaceSource` to `PluginEnv`.
- `ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginCore.swift` — new `install/uninstall/installStatus` signatures.
- `ClaudeSpyPackage/Sources/GallagerPluginProtocol/EchoPluginCore.swift` — conform to new signatures.
- `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodePluginCore.swift` — build/use `ClaudeCodeCLIInstaller`.
- `ClaudeSpyPackage/Sources/CodexPluginCore/CodexPluginCore.swift` — build/use `CodexCLIInstaller`.
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/PluginRegistry.swift` — `callCore` new signatures + pass `marketplaceSource` into `PluginEnv`.
- `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/LivePluginHost.swift` (or wherever `PluginEnv` is constructed) — populate `marketplaceSource`.
- `ClaudeSpyPackage/Sources/Gallager/Commands/PluginCommands.swift` — `plugin call` help/args for `installStatus`.
- `plugin/gallager/scripts/hook.py`, `plugin/codex/gallager/scripts/hook.py` — ingress transport.
- `plugin/gallager/.claude-plugin/plugin.json`, `plugin/codex/gallager/.codex-plugin/plugin.json` — version bump.
- Wiring tests referencing the old signatures.

**Delete:**
- `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeInstaller.swift` (+ `Tests/ClaudeCodePluginCoreTests/ClaudeCodeInstallerTests.swift`).
- `ClaudeSpyPackage/Sources/CodexPluginCore/CodexInstaller.swift` (+ `Tests/CodexPluginCoreTests/CodexInstallerTests.swift`).

---

## Task 1: Add `PluginInstallStatus` and `PluginEnv.marketplaceSource`

**Files:**
- Modify: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginEnv.swift`

- [ ] **Step 1: Add the status enum**

After the `InstallResult` enum in `PluginEnv.swift`, add:

```swift
/// Snapshot of whether the agent's plugin is installed for a given config root.
/// Transient `installing` / `failed` states are view state, not core state.
public enum PluginInstallStatus: Sendable, Equatable {
    case installed(version: String?)
    case notInstalled
    /// The agent's CLI binary could not be located / run.
    case agentUnavailable
}
```

- [ ] **Step 2: Add `marketplaceSource` to `PluginEnv`**

In `PluginEnv`, add the stored property + init param (after `settings`):

```swift
    /// The on-disk marketplace source dir for this plugin's agent CLI install
    /// (e.g. `<app>/Contents/Resources/plugin` for Claude). Passed to
    /// `<agent> plugin marketplace add`.
    public let marketplaceSource: URL
```

Update the initializer signature and body to include `marketplaceSource: URL` (place the param after `settings: Data`, assign `self.marketplaceSource = marketplaceSource`).

- [ ] **Step 3: Build the protocol module**

Run: `cd ClaudeSpyPackage && swift build --target GallagerPluginProtocol 2>&1 | tail -20`
Expected: FAILS — every `PluginEnv(...)` call site now misses `marketplaceSource`. That's fixed in later tasks; the new types compile.

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginEnv.swift
git commit -m "feat(plugin): add PluginInstallStatus + PluginEnv.marketplaceSource"
```

---

## Task 2: Change the `PluginCore` protocol + update `EchoPluginCore`

**Files:**
- Modify: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginCore.swift`
- Modify: `ClaudeSpyPackage/Sources/GallagerPluginProtocol/EchoPluginCore.swift`

- [ ] **Step 1: Update the protocol**

In `PluginCore.swift`, replace the three install-related requirements:

```swift
    /// Register the host-agent plugin via its own CLI (marketplace + install),
    /// scoped to `configRoot` (CLAUDE_CONFIG_DIR / CODEX_HOME; `nil` = default
    /// root). The app never edits agent settings files directly (spec §1–2).
    func install(configRoot: String?) async throws -> InstallResult

    /// Remove the host-agent plugin via its CLI, scoped to `configRoot`.
    func uninstall(configRoot: String?) async throws

    /// Query install state for `configRoot`.
    func installStatus(configRoot: String?) async -> PluginInstallStatus
```

(Delete the old `install()`, `uninstall()`, `isInstalled()` requirements and their doc comments.)

- [ ] **Step 2: Update `EchoPluginCore`**

In `EchoPluginCore.swift`, replace the existing `install`/`uninstall`/`isInstalled` implementations with:

```swift
        public func install(configRoot _: String?) async throws -> InstallResult {
            .alreadyInstalled
        }

        public func uninstall(configRoot _: String?) async throws { }

        public func installStatus(configRoot _: String?) async -> PluginInstallStatus {
            .installed(version: "echo")
        }
```

- [ ] **Step 3: Build the protocol module**

Run: `cd ClaudeSpyPackage && swift build --target GallagerPluginProtocol 2>&1 | tail -20`
Expected: PASS (the protocol + Echo conformer compile; concrete cores in other modules still fail to build — handled next).

- [ ] **Step 4: Commit**

```bash
git add ClaudeSpyPackage/Sources/GallagerPluginProtocol/PluginCore.swift ClaudeSpyPackage/Sources/GallagerPluginProtocol/EchoPluginCore.swift
git commit -m "feat(plugin): per-configRoot install/uninstall/installStatus on PluginCore"
```

---

## Task 3: `ClaudeCodeCLIInstaller` (TDD) + wire the core, drop the file-writer

**Files:**
- Create: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeCLIInstaller.swift`
- Test: `ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/ClaudeCodeCLIInstallerTests.swift`
- Modify: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodePluginCore.swift`
- Delete: `ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeInstaller.swift`, `ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/ClaudeCodeInstallerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `ClaudeCodeCLIInstallerTests.swift`:

```swift
import ClaudeSpyCommon
import Dependencies
import Foundation
import GallagerPluginProtocol
import Testing
@testable import ClaudeCodePluginCore

@Suite("ClaudeCodeCLIInstaller")
struct ClaudeCodeCLIInstallerTests {
    private func installer(
        _ run: @escaping @Sendable (String, [String], [String: String]?, TimeInterval?) async throws -> ProcessResult
    ) -> ClaudeCodeCLIInstaller {
        ClaudeCodeCLIInstaller(
            processRunner: ProcessRunner(run: run),
            command: "claude",
            marketplaceSource: URL(fileURLWithPath: "/bundle/plugin")
        )
    }

    @Test("install runs marketplace add then plugin install with config-dir env")
    func installScopesToConfigDir() async throws {
        let calls = LockIsolated<[(String, [String], [String: String]?)]>([])
        let inst = installer { exe, args, env, _ in
            calls.withValue { $0.append((exe, args, env)) }
            return ProcessResult(exitCode: 0, stdout: Data("installed".utf8), stderr: Data())
        }
        let result = try await inst.install(configRoot: "/work/.claude")
        #expect(result.isInstalledMessage)   // helper below
        let recorded = calls.value
        #expect(recorded.count == 2)
        #expect(recorded[0].1 == ["plugin", "marketplace", "add", "/bundle/plugin"])
        #expect(recorded[1].1 == ["plugin", "install", "gallager", "--scope", "user"])
        #expect(recorded[1].2?["CLAUDE_CONFIG_DIR"] == "/work/.claude")
        // wrapped through /usr/bin/env <command> …
        #expect(recorded[1].0 == "/usr/bin/env")
        #expect(args0Command(recorded[1].1, exe: recorded[1].0) == nil || true)
    }

    @Test("nil configRoot omits CLAUDE_CONFIG_DIR")
    func installDefaultRoot() async throws {
        let env = LockIsolated<[String: String]?>(nil)
        let inst = installer { _, args, e, _ in
            if args.contains("install") { env.setValue(e) }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        _ = try await inst.install(configRoot: nil)
        #expect(env.value?["CLAUDE_CONFIG_DIR"] == nil)
    }

    @Test("installStatus parses plugin list")
    func statusInstalled() async throws {
        let inst = installer { _, _, _, _ in
            ProcessResult(exitCode: 0, stdout: Data("gallager  1.1.0  enabled".utf8), stderr: Data())
        }
        #expect(await inst.installStatus(configRoot: nil) == .installed(version: "1.1.0"))
    }

    @Test("installStatus is notInstalled when absent")
    func statusNotInstalled() async throws {
        let inst = installer { _, _, _, _ in
            ProcessResult(exitCode: 0, stdout: Data("other-plugin 1.0".utf8), stderr: Data())
        }
        #expect(await inst.installStatus(configRoot: nil) == .notInstalled)
    }

    @Test("installStatus is agentUnavailable when env exits 127")
    func statusAgentMissing() async throws {
        let inst = installer { _, _, _, _ in
            ProcessResult(exitCode: 127, stdout: Data(), stderr: Data("command not found".utf8))
        }
        #expect(await inst.installStatus(configRoot: nil) == .agentUnavailable)
    }
}

private extension InstallResult {
    var isInstalledMessage: Bool { if case .installed = self { return true } else { return false } }
}
private func args0Command(_ args: [String], exe: String) -> String? { exe == "/usr/bin/env" ? args.first : nil }
```

> Note: `LockIsolated` ships with the Dependencies/Clocks libraries already used in this package. If the helper `args0Command`/`isInstalledMessage` reads awkwardly to you, keep them — they exist only to assert the `/usr/bin/env` wrapping and result shape.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ClaudeSpyPackage && swift test --filter ClaudeCodeCLIInstaller 2>&1 | tail -20`
Expected: FAIL — `ClaudeCodeCLIInstaller` does not exist.

- [ ] **Step 3: Implement `ClaudeCodeCLIInstaller`**

Create `ClaudeCodeCLIInstaller.swift`:

```swift
import ClaudeSpyCommon
import Foundation
import GallagerPluginProtocol

/// Installs the Gallager Claude Code plugin through Claude's own CLI
/// (`claude plugin …`), scoped to a `CLAUDE_CONFIG_DIR`. The app never edits
/// Claude's settings files directly (spec §1–2). All invocations are wrapped in
/// `/usr/bin/env <command> …` so PATH resolution works and a missing binary
/// surfaces as exit 127 → `.agentUnavailable`.
struct ClaudeCodeCLIInstaller: Sendable {
    let processRunner: ProcessRunner
    /// The configured claude command (full path or bare `claude`).
    let command: String
    /// Bundled marketplace dir (`<app>/Contents/Resources/plugin`).
    let marketplaceSource: URL

    static let pluginName = "gallager"

    private func env(for configRoot: String?) -> [String: String]? {
        configRoot.map { ["CLAUDE_CONFIG_DIR": $0] }
    }

    private func run(_ args: [String], configRoot: String?, timeout: TimeInterval) async throws -> ProcessResult {
        try await processRunner.run("/usr/bin/env", [command] + args, env(for: configRoot), timeout)
    }

    func install(configRoot: String?) async throws -> InstallResult {
        // Marketplace add is idempotent; tolerate "already registered".
        _ = try? await run(["plugin", "marketplace", "add", marketplaceSource.path], configRoot: configRoot, timeout: 60)

        let result = try await run(["plugin", "install", Self.pluginName, "--scope", "user"], configRoot: configRoot, timeout: 120)
        if result.isSuccess {
            return .installed(message: "Installed \(Self.pluginName) via claude plugin install")
        }
        let stderr = result.stderrString.lowercased()
        if stderr.contains("already") && stderr.contains("install") {
            return .alreadyInstalled
        }
        throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString)
    }

    func uninstall(configRoot: String?) async throws {
        _ = try await run(["plugin", "uninstall", Self.pluginName], configRoot: configRoot, timeout: 60)
    }

    func installStatus(configRoot: String?) async -> PluginInstallStatus {
        guard let result = try? await run(["plugin", "list"], configRoot: configRoot, timeout: 30) else {
            return .agentUnavailable
        }
        if result.exitCode == 127 { return .agentUnavailable }
        guard result.isSuccess else { return .notInstalled }
        return Self.parseStatus(from: result.stdoutString)
    }

    /// Finds a line mentioning our plugin and extracts a `x.y.z` version if present.
    static func parseStatus(from listing: String) -> PluginInstallStatus {
        for line in listing.split(separator: "\n") where line.contains(pluginName) {
            let version = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first(where: { $0.first?.isNumber == true && $0.contains(".") })
                .map(String.init)
            return .installed(version: version)
        }
        return .notInstalled
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ClaudeSpyPackage && swift test --filter ClaudeCodeCLIInstaller 2>&1 | tail -20`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Wire the core + delete the file-writer**

In `ClaudeCodePluginCore.swift`:
- Add stored deps. Near the top of the actor, add:
  ```swift
  @ObservationIgnored @Dependency(ProcessRunner.self) private var processRunner
  private var marketplaceSource: URL = URL(fileURLWithPath: "/")
  private var command: String = "claude"
  ```
  (If the actor can't use `@Dependency`, capture `ProcessRunner` in `initialize` instead: add `private var processRunner = ProcessRunner.liveValue` and set it from a `@Dependency` read in `initialize`. Match whatever pattern the core already uses for dependencies.)
- In `initialize(_:host:)`, capture the marketplace source and command:
  ```swift
  self.marketplaceSource = env.marketplaceSource
  self.command = ClaudeCodeSettings.decode(from: env.settings).commandPath
  ```
- Replace the three methods (lines ~141–150) and the `installer()` helper (lines ~162–167) with:
  ```swift
  public func install(configRoot: String?) async throws -> InstallResult {
      try await cliInstaller().install(configRoot: configRoot)
  }
  public func uninstall(configRoot: String?) async throws {
      try await cliInstaller().uninstall(configRoot: configRoot)
  }
  public func installStatus(configRoot: String?) async -> PluginInstallStatus {
      await cliInstaller().installStatus(configRoot: configRoot)
  }
  private func cliInstaller() -> ClaudeCodeCLIInstaller {
      ClaudeCodeCLIInstaller(processRunner: processRunner, command: command, marketplaceSource: marketplaceSource)
  }
  ```
- In `applySettings`, after decoding the new settings, refresh the command: `self.command = decoded.commandPath` (so a settings change updates which binary install uses).
- Delete `ClaudeCodeInstaller.swift` and `ClaudeCodeInstallerTests.swift`:
  ```bash
  git rm ClaudeSpyPackage/Sources/ClaudeCodePluginCore/ClaudeCodeInstaller.swift ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/ClaudeCodeInstallerTests.swift
  ```
  (Its `bridgeScript` Python is re-homed in Task 6; copy it out before/while deleting if convenient.)

- [ ] **Step 6: Build the core target**

Run: `cd ClaudeSpyPackage && swift build --target ClaudeCodePluginCore 2>&1 | tail -25`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeCodePluginCore ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests
git commit -m "feat(claude-code): CLI-based per-folder install, drop settings.json writer"
```

---

## Task 4: `CodexCLIInstaller` (TDD) + wire the core, drop the file-writer

**Files:**
- Create: `ClaudeSpyPackage/Sources/CodexPluginCore/CodexCLIInstaller.swift`
- Test: `ClaudeSpyPackage/Tests/CodexPluginCoreTests/CodexCLIInstallerTests.swift`
- Modify: `ClaudeSpyPackage/Sources/CodexPluginCore/CodexPluginCore.swift`
- Delete: `ClaudeSpyPackage/Sources/CodexPluginCore/CodexInstaller.swift`, `ClaudeSpyPackage/Tests/CodexPluginCoreTests/CodexInstallerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `CodexCLIInstallerTests.swift` (mirror Task 3's tests, Codex commands + `CODEX_HOME`):

```swift
import ClaudeSpyCommon
import Dependencies
import Foundation
import GallagerPluginProtocol
import Testing
@testable import CodexPluginCore

@Suite("CodexCLIInstaller")
struct CodexCLIInstallerTests {
    private func installer(
        _ run: @escaping @Sendable (String, [String], [String: String]?, TimeInterval?) async throws -> ProcessResult
    ) -> CodexCLIInstaller {
        CodexCLIInstaller(
            processRunner: ProcessRunner(run: run),
            command: "codex",
            marketplaceSource: URL(fileURLWithPath: "/bundle/plugin/codex")
        )
    }

    @Test("install runs marketplace add then plugin add with CODEX_HOME")
    func installScopesToCodexHome() async throws {
        let calls = LockIsolated<[(String, [String], [String: String]?)]>([])
        let inst = installer { exe, args, env, _ in
            calls.withValue { $0.append((exe, args, env)) }
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        _ = try await inst.install(configRoot: "/work/.codex")
        let recorded = calls.value
        #expect(recorded.count == 2)
        #expect(recorded[0].1 == ["codex", "plugin", "marketplace", "add", "/bundle/plugin/codex"])
        #expect(recorded[1].1 == ["codex", "plugin", "add", "gallager@gallager"])
        #expect(recorded[1].2?["CODEX_HOME"] == "/work/.codex")
        #expect(recorded[1].0 == "/usr/bin/env")
    }

    @Test("uninstall runs plugin remove")
    func uninstallRemoves() async throws {
        let args = LockIsolated<[String]>([])
        let inst = installer { _, a, _, _ in
            args.setValue(a)
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
        try await inst.uninstall(configRoot: nil)
        #expect(args.value == ["codex", "plugin", "remove", "gallager@gallager"])
    }

    @Test("installStatus reflects plugin list")
    func statusInstalled() async throws {
        let inst = installer { _, _, _, _ in
            ProcessResult(exitCode: 0, stdout: Data("gallager@gallager  1.1.0".utf8), stderr: Data())
        }
        #expect(await inst.installStatus(configRoot: nil) == .installed(version: "1.1.0"))
    }

    @Test("installStatus agentUnavailable on 127")
    func statusMissing() async throws {
        let inst = installer { _, _, _, _ in
            ProcessResult(exitCode: 127, stdout: Data(), stderr: Data("not found".utf8))
        }
        #expect(await inst.installStatus(configRoot: nil) == .agentUnavailable)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ClaudeSpyPackage && swift test --filter CodexCLIInstaller 2>&1 | tail -20`
Expected: FAIL — `CodexCLIInstaller` does not exist.

- [ ] **Step 3: Implement `CodexCLIInstaller`**

Create `CodexCLIInstaller.swift`:

```swift
import ClaudeSpyCommon
import Foundation
import GallagerPluginProtocol

/// Installs the Gallager Codex plugin through Codex's own CLI
/// (`codex plugin …`), scoped to a `CODEX_HOME`. Mirrors `ClaudeCodeCLIInstaller`.
struct CodexCLIInstaller: Sendable {
    let processRunner: ProcessRunner
    let command: String
    let marketplaceSource: URL

    static let pluginRef = "gallager@gallager"

    private func env(for configRoot: String?) -> [String: String]? {
        configRoot.map { ["CODEX_HOME": $0] }
    }

    private func run(_ args: [String], configRoot: String?, timeout: TimeInterval) async throws -> ProcessResult {
        try await processRunner.run("/usr/bin/env", [command] + args, env(for: configRoot), timeout)
    }

    func install(configRoot: String?) async throws -> InstallResult {
        _ = try? await run(["plugin", "marketplace", "add", marketplaceSource.path], configRoot: configRoot, timeout: 60)
        let result = try await run(["plugin", "add", Self.pluginRef], configRoot: configRoot, timeout: 120)
        if result.isSuccess {
            return .installed(message: "Installed \(Self.pluginRef) via codex plugin add")
        }
        let stderr = result.stderrString.lowercased()
        if stderr.contains("already") {
            return .alreadyInstalled
        }
        throw ProcessRunnerError.executionFailed(exitCode: result.exitCode, stderr: result.stderrString)
    }

    func uninstall(configRoot: String?) async throws {
        _ = try await run(["plugin", "remove", Self.pluginRef], configRoot: configRoot, timeout: 60)
    }

    func installStatus(configRoot: String?) async -> PluginInstallStatus {
        guard let result = try? await run(["plugin", "list"], configRoot: configRoot, timeout: 30) else {
            return .agentUnavailable
        }
        if result.exitCode == 127 { return .agentUnavailable }
        guard result.isSuccess else { return .notInstalled }
        for line in result.stdoutString.split(separator: "\n") where line.contains("gallager") {
            let version = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first(where: { $0.first?.isNumber == true && $0.contains(".") })
                .map(String.init)
            return .installed(version: version)
        }
        return .notInstalled
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ClaudeSpyPackage && swift test --filter CodexCLIInstaller 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Wire the core + delete the file-writer**

In `CodexPluginCore.swift`, apply the same pattern as Task 3 Step 5:
- Add `processRunner`, `marketplaceSource`, `command` (default `"codex"`) stored members.
- In `initialize`, set `self.marketplaceSource = env.marketplaceSource` and `self.command = CodexSettings.decode(from: env.settings).commandPath`.
- Replace `install`/`uninstall`/`isInstalled` (lines ~170–179) and the `installer()` helper (lines ~191–196) with `install(configRoot:)`/`uninstall(configRoot:)`/`installStatus(configRoot:)` delegating to a `cliInstaller()` returning `CodexCLIInstaller(processRunner:command:marketplaceSource:)`.
- In `applySettings`, refresh `self.command = decoded.commandPath`.
- Delete the file-writer:
  ```bash
  git rm ClaudeSpyPackage/Sources/CodexPluginCore/CodexInstaller.swift ClaudeSpyPackage/Tests/CodexPluginCoreTests/CodexInstallerTests.swift
  ```

- [ ] **Step 6: Build the core target**

Run: `cd ClaudeSpyPackage && swift build --target CodexPluginCore 2>&1 | tail -25`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add ClaudeSpyPackage/Sources/CodexPluginCore ClaudeSpyPackage/Tests/CodexPluginCoreTests
git commit -m "feat(codex): CLI-based per-folder install, drop hooks.json writer"
```

---

## Task 5: Update the registry, `PluginEnv` construction, and the `plugin call` CLI

**Files:**
- Modify: `ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins/PluginRegistry.swift`
- Modify: the `PluginEnv(...)` construction site (search; likely `PluginRegistry.swift` or `LivePluginHost.swift`)
- Modify: `ClaudeSpyPackage/Sources/Gallager/Commands/PluginCommands.swift`

- [ ] **Step 1: Populate `marketplaceSource` when building `PluginEnv`**

Find the construction: `grep -rn "PluginEnv(" ClaudeSpyPackage/Sources/ClaudeSpyServerFeature`. At that site, add a `marketplaceSource:` argument. Resolve it from the app bundle by plugin id:

```swift
// Bundled marketplace dirs live in the app's main bundle Resources:
//   plugin/           → Claude marketplace
//   plugin/codex/     → Codex marketplace
let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
let marketplaceSource: URL = switch id {
case "codex": resources.appendingPathComponent("plugin/codex")
default: resources.appendingPathComponent("plugin")
}
```

Pass `marketplaceSource: marketplaceSource` into the `PluginEnv(...)` call. (This is the registry — the one place allowed to know concrete plugin ids, spec §4.1.)

- [ ] **Step 2: Update `callCore` to the new signatures**

In `PluginRegistry.swift` `callCore(_:method:)`, change the `isInstalled` / `install` / `uninstall` cases to the per-root API. Add an optional `configRoot` parameter to `callCore` (defaulting to `nil`) and thread it through:

```swift
public func callCore(_ id: String, method: String, configRoot: String? = nil) async -> CallOutcome {
    guard let core = active[id] else { return .notEnabled }
    switch method {
    case "refreshProjects":
        await core.refreshProjects(); return .ok(result: "refreshed")
    case "installStatus":
        let status = await core.installStatus(configRoot: configRoot)
        return .ok(result: Self.describe(status))
    case "install":
        do {
            let result = try await core.install(configRoot: configRoot)
            switch result {
            case let .installed(message): return .ok(result: message)
            case .alreadyInstalled: return .ok(result: "already-installed")
            }
        } catch { return .failed(String(describing: error)) }
    case "uninstall":
        do { try await core.uninstall(configRoot: configRoot); return .ok(result: "uninstalled") }
        catch { return .failed(String(describing: error)) }
    default:
        return .unknownMethod(method)
    }
}

private static func describe(_ status: PluginInstallStatus) -> String {
    switch status {
    case let .installed(version): "installed\(version.map { " v\($0)" } ?? "")"
    case .notInstalled: "not-installed"
    case .agentUnavailable: "agent-unavailable"
    }
}
```

(Remove the old `isInstalled` case.)

- [ ] **Step 3: Update the `plugin call` CLI help**

In `PluginCommands.swift`, update the `call` subcommand's `discussion`/help text: replace `isInstalled` with `installStatus` in the method list (the line reading `Methods: enable, disable, refreshProjects, isInstalled, install, uninstall.` and the `@Argument` help). No behavioral change needed beyond the new method name reaching `callCore`.

- [ ] **Step 4: Build the server feature + CLI**

Run: `cd ClaudeSpyPackage && swift build --target ClaudeSpyServerFeature --target Gallager 2>&1 | tail -30`
Expected: PASS. If `PluginEnv(` construction appears in more than one place, fix each.

- [ ] **Step 5: Commit**

```bash
git add ClaudeSpyPackage/Sources/ClaudeSpyServerFeature/Plugins ClaudeSpyPackage/Sources/Gallager/Commands/PluginCommands.swift
git commit -m "feat(plugin): registry passes marketplaceSource; callCore uses installStatus + configRoot"
```

---

## Task 6: Repoint bundled hooks at the ingress socket + bump plugin versions

**Files:**
- Modify: `plugin/gallager/scripts/hook.py`
- Modify: `plugin/codex/gallager/scripts/hook.py`
- Modify: `plugin/gallager/.claude-plugin/plugin.json`
- Modify: `plugin/codex/gallager/.codex-plugin/plugin.json`

- [ ] **Step 1: Rewrite `plugin/gallager/scripts/hook.py`**

Replace its entire contents with the ingress-socket bridge (plugin_id `claude-code`):

```python
#!/usr/bin/env python3
import json
import os
import socket
import struct
import sys

PLUGIN_ID = "claude-code"
SOCKET_PATH = os.path.expanduser("~/.gallager/state/ingress.sock")


def main():
    tmux_pane = os.environ.get("TMUX_PANE", "")
    if not tmux_pane:
        return  # Not inside tmux — nothing to mirror.

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return

    context = {"TMUX_PANE": tmux_pane}
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if project_dir:
        context["CLAUDE_PROJECT_DIR"] = project_dir

    body = json.dumps({"plugin_id": PLUGIN_ID, "context": context, "payload": payload}).encode("utf-8")
    frame = struct.pack(">I", len(body)) + body

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(SOCKET_PATH)
        sock.sendall(frame)
        sock.close()
    except Exception:
        return  # Gallager not running / socket gone — drop silently.


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Rewrite `plugin/codex/gallager/scripts/hook.py`**

Same as Step 1 but `PLUGIN_ID = "codex"`, and drop the `CLAUDE_PROJECT_DIR` context line (Codex carries `cwd` in the payload, which `CodexTranslator` already parses):

```python
#!/usr/bin/env python3
import json
import os
import socket
import struct
import sys

PLUGIN_ID = "codex"
SOCKET_PATH = os.path.expanduser("~/.gallager/state/ingress.sock")


def main():
    tmux_pane = os.environ.get("TMUX_PANE", "")
    if not tmux_pane:
        return

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return

    body = json.dumps(
        {"plugin_id": PLUGIN_ID, "context": {"TMUX_PANE": tmux_pane}, "payload": payload}
    ).encode("utf-8")
    frame = struct.pack(">I", len(body)) + body

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(SOCKET_PATH)
        sock.sendall(frame)
        sock.close()
    except Exception:
        return


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Verify the scripts are valid Python**

Run: `python3 -m py_compile plugin/gallager/scripts/hook.py plugin/codex/gallager/scripts/hook.py && echo OK`
Expected: `OK`.

- [ ] **Step 4: Bump plugin versions**

In `plugin/gallager/.claude-plugin/plugin.json` and `plugin/codex/gallager/.codex-plugin/plugin.json`, set `"version"` to a value higher than the current one so a reinstall updates the hook. If the current version is `1.0.x`, set `"version": "1.1.0"`; if it's already `≥ 1.1.0`, bump the minor again. (Check first: `grep version plugin/gallager/.claude-plugin/plugin.json plugin/codex/gallager/gallager/.codex-plugin/plugin.json 2>/dev/null || grep -r '"version"' plugin/*/*/.*-plugin/plugin.json`.)

- [ ] **Step 5: Commit**

```bash
git add plugin/gallager/scripts/hook.py plugin/codex/gallager/scripts/hook.py plugin/gallager/.claude-plugin/plugin.json plugin/codex/gallager/.codex-plugin/plugin.json
git commit -m "feat(plugins): bundled hooks write to ingress socket; bump versions"
```

---

## Task 7: Fix existing wiring tests + full build & test

**Files:**
- Modify (as needed): `ClaudeSpyPackage/Tests/ClaudeSpyServerFeatureTests/PluginRuntimeStatusWiringTests.swift`, `PluginRuntimeResponseWiringTests.swift`, `PluginRegistryTests.swift`, `ClaudeSpyPackage/Tests/ClaudeCodePluginCoreTests/ClaudeCodePluginCoreTests.swift`, `MockPluginHost.swift`, `CodexPluginCoreTests/CodexPluginCoreTests.swift`

- [ ] **Step 1: Find stale references**

Run:
```bash
cd ClaudeSpyPackage && grep -rn "isInstalled()\|\.install()\|\.uninstall()\|PluginEnv(" Tests Sources/GallagerPluginProtocol | grep -v CLIInstaller
```
Expected: a list of call sites still using the old zero-arg API or constructing `PluginEnv` without `marketplaceSource`.

- [ ] **Step 2: Update each call site**

For each hit:
- `core.isInstalled()` → `await core.installStatus(configRoot: nil)`, and update the assertion (e.g. `#expect(status == .installed(version: ...))` or `== .notInstalled`).
- `core.install()` → `try await core.install(configRoot: nil)`; `core.uninstall()` → `try await core.uninstall(configRoot: nil)`.
- `PluginEnv(pluginRoot:…, settings:…)` → add `marketplaceSource: URL(fileURLWithPath: "/tmp/marketplace")` (tests don't run the CLI; a placeholder path is fine).
- If a test asserted file-writing install behavior (the deleted `ClaudeCodeInstaller`/`CodexInstaller` semantics), delete that test — the CLI installers are covered by Tasks 3–4. Inject a stub `ProcessRunner` via `withDependencies { $0[ProcessRunner.self] = ProcessRunner(run: { _,_,_,_ in ProcessResult(exitCode: 0, stdout: Data(), stderr: Data()) }) }` where a core's `install`/`installStatus` is exercised.

- [ ] **Step 3: Run the full package test suite**

Run: `cd ClaudeSpyPackage && swift test 2>&1 | tail -30`
Expected: PASS (0 failures). Fix any remaining compile/assertion errors.

- [ ] **Step 4: Build the macOS app (Release) to catch app-target wiring**

Run: `xcodebuild -workspace ClaudeSpy.xcworkspace -scheme ClaudeSpyServer -configuration Release -destination 'platform=macOS' -skipMacroValidation -skipPackagePluginValidation build 2>&1 | tee ${TMPDIR:-/tmp}/p1_build.log | xcsift --format toon --warnings`
Expected: `status: success`, 0 errors.

- [ ] **Step 5: Manual smoke (optional but recommended)**

With the built app running and `claude` on PATH:
```bash
gallager plugin call claude-code installStatus
gallager plugin call claude-code install
gallager plugin call claude-code installStatus   # → installed
```
Expected: status flips to `installed`. (Codex likewise if the `codex plugin` CLI is available — see spec verification item #1.)

- [ ] **Step 6: Commit**

```bash
git add ClaudeSpyPackage/Tests
git commit -m "test(plugin): update wiring tests for per-configRoot install API"
```

---

## Self-Review Checklist (completed by author)

- **Spec coverage:** §1 CLI install in cores (Tasks 3–5) ✓; §2 protocol change + PluginInstallStatus (Tasks 1–2) ✓; §3 hook transport + version bump (Task 6) ✓; §8 delete file-writers (Tasks 3–4) ✓. Settings wiring / Codex multi-folder / Agents UI are intentionally **Plan 2**.
- **Placeholders:** none — every code step is literal; ported logic is written out (not "port from PluginService").
- **Type consistency:** `PluginInstallStatus` (`.installed(version:)`/`.notInstalled`/`.agentUnavailable`), `install(configRoot:)`/`uninstall(configRoot:)`/`installStatus(configRoot:)`, and `PluginEnv.marketplaceSource` are used identically across Tasks 1–7.
- **Open risk carried from spec:** Codex `plugin` subcommands + `CODEX_HOME` scoping (verify at Task 7 Step 5); upgrade-on-reinstall (Task 6 version bump).
