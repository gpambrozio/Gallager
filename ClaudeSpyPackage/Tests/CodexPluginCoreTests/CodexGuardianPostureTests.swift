import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol
import Testing
@testable import CodexPluginCore

/// Guardian (auto-review) posture matrix for issue #585: when Codex's
/// `approvals_reviewer = "auto_review"` guardian — not the user — will decide
/// a permission request, `handleIngress` must translate it to plain `working`
/// with NO notification and NO response form (a form would keystroke into the
/// composer: no TUI prompt exists in this posture). Everything else —
/// non-guardian-reviewable tools, `bypassPermissions` events, `user` posture,
/// unattributable sessions — keeps today's notify-and-form behavior.
///
/// The posture is read fresh per permission request from a real `config.toml`
/// in a temp CODEX_HOME listed in `additionalConfigFolders`; sessions are
/// attributed to it via the hook's `transcript_path` (the rollout file lives
/// under `<CODEX_HOME>/sessions/`).
///
/// `approvals_reviewer` is a GLOBAL file but a PER-SESSION runtime value
/// (Codex loads it at session start; a TUI toggle overrides only the toggling
/// session while persisting globally), so suppression additionally requires
/// the fresh file value to agree with the session's start snapshot — captured
/// from the SessionStart hook, or reconstructed from file timestamps when the
/// app launched mid-session. Disagreement means SOME session toggled and the
/// toggler can't be attributed → fail safe to notifying.
@Suite("CodexGuardianPosture")
struct CodexGuardianPostureTests {
    // MARK: - Helpers

    /// Runs `body` against an initialized core whose settings list a temp
    /// CODEX_HOME (holding `configTOML`) in `additionalConfigFolders`. Always
    /// shuts the core down afterwards (stopping its FSEvents watchers and the
    /// session-end monitor task) and removes the temp directories, pass or
    /// fail.
    private func withCore<T: Sendable>(
        configTOML: String?,
        _ body: (CodexPluginCore, MockPluginHost, URL) async throws -> T
    ) async throws -> T {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallager-cx-guardian-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        if let configTOML {
            try Data(configTOML.utf8).write(to: codexHome.appendingPathComponent("config.toml"))
        }

        let host = MockPluginHost()
        let correlationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallager-cx-corr-guardian-\(UUID().uuidString)")
        let stateDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gallager-cx-guardian-state-\(UUID().uuidString)")
        let core = CodexPluginCore(correlation: CodexSessionCorrelation(root: correlationRoot))
        let settingsData = try JSONEncoder().encode(
            CodexSettings(additionalConfigFolders: [codexHome.path])
        )
        let env = PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: stateDir,
            appVersion: "1.0",
            settings: settingsData,
            marketplaceSource: URL(fileURLWithPath: "/")
        )
        try await core.initialize(env, host: host)

        do {
            let result = try await body(core, host, codexHome)
            await core.shutdown()
            cleanUp([codexHome, correlationRoot, stateDir])
            return result
        } catch {
            await core.shutdown()
            cleanUp([codexHome, correlationRoot, stateDir])
            throw error
        }
    }

    private func cleanUp(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A realistic rollout path under the temp CODEX_HOME, attributing the
    /// session to that root.
    private func transcript(in codexHome: URL) -> String {
        codexHome
            .appendingPathComponent("sessions/2026/06/10/rollout-2026-06-10-abc.jsonl")
            .path
    }

    /// A SessionStart hook for the session — the moment the core snapshots the
    /// root's reviewer posture (what Codex itself just loaded).
    private func sessionStartJSON(
        transcriptPath: String,
        sessionID: String = "sess-guardian"
    ) -> String {
        """
        {
            "hook_event_name": "SessionStart",
            "session_id": "\(sessionID)",
            "cwd": "/Users/test/MyProject",
            "transcript_path": "\(transcriptPath)"
        }
        """
    }

    private func permissionJSON(
        transcriptPath: String?,
        sessionID: String = "sess-guardian",
        permissionMode: String? = "default",
        toolName: String? = "Bash",
        toolInput: String = #"{ "command": "rm -rf build", "description": "clean" }"#
    ) -> String {
        var fields = [
            #""hook_event_name": "PermissionRequest""#,
            "\"session_id\": \"\(sessionID)\"",
            #""cwd": "/Users/test/MyProject""#,
            "\"tool_input\": \(toolInput)",
        ]
        if let toolName {
            fields.append("\"tool_name\": \"\(toolName)\"")
        }
        if let transcriptPath {
            fields.append("\"transcript_path\": \"\(transcriptPath)\"")
        }
        if let permissionMode {
            fields.append("\"permission_mode\": \"\(permissionMode)\"")
        }
        return "{ \(fields.joined(separator: ", ")) }"
    }

    private func frame(_ json: String, pane: String = "%1") -> IngressFrame {
        IngressFrame(
            pluginID: CodexPluginCore.pluginID,
            context: ["TMUX_PANE": pane],
            payload: Data(json.utf8)
        )
    }

    private let autoReviewTOML = "approvals_reviewer = \"auto_review\"\n"
    private let userTOML = "approvals_reviewer = \"user\"\n"

    // MARK: - Suppression in guardian posture

    @Test("guardian posture: a Bash approval is silent — working, no form, no notification")
    func guardianSuppressesPlainPermission() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            let json = permissionJSON(transcriptPath: transcript(in: codexHome))
            _ = await core.handleIngress(
                frame(sessionStartJSON(transcriptPath: transcript(in: codexHome)))
            )

            let event = try #require(await core.handleIngress(frame(json)))
            #expect(event.state == .working)
            #expect(event.state?.needsAttention == false)
            #expect(event.state?.openForm == nil)
            #expect(event.notification == nil)
            #expect(event.appActions.isEmpty)
        }
    }

    @Test("legacy guardian_subagent spelling also suppresses")
    func guardianSubagentSpellingSuppresses() async throws {
        try await withCore(
            configTOML: "approvals_reviewer = \"guardian_subagent\"\n"
        ) { core, _, codexHome in
            let json = permissionJSON(transcriptPath: transcript(in: codexHome))
            _ = await core.handleIngress(
                frame(sessionStartJSON(transcriptPath: transcript(in: codexHome)))
            )

            let event = try #require(await core.handleIngress(frame(json)))
            #expect(event.state == .working)
            #expect(event.notification == nil)
        }
    }

    @Test("guardian posture: apply_patch and MCP approvals are also guardian-reviewable")
    func guardianSuppressesPatchAndMCP() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            _ = await core.handleIngress(
                frame(sessionStartJSON(transcriptPath: transcript(in: codexHome)))
            )
            let patch = permissionJSON(
                transcriptPath: transcript(in: codexHome),
                toolName: "apply_patch",
                toolInput: #"{ "command": "*** Begin Patch" }"#
            )
            let patchEvent = try #require(await core.handleIngress(frame(patch)))
            #expect(patchEvent.state == .working)
            #expect(patchEvent.notification == nil)

            let mcp = permissionJSON(
                transcriptPath: transcript(in: codexHome),
                toolName: "mcp__memory__create_entities",
                toolInput: #"{ "server": "memory", "tool": "create_entities", "input": {} }"#
            )
            let mcpEvent = try #require(await core.handleIngress(frame(mcp)))
            #expect(mcpEvent.state == .working)
            #expect(mcpEvent.notification == nil)
        }
    }

    // MARK: - Fail-closed tool identification

    @Test("a tool outside the guardian-reviewable vocabulary still notifies (fail closed)")
    func unknownToolFailsClosed() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            _ = await core.handleIngress(
                frame(sessionStartJSON(transcriptPath: transcript(in: codexHome)))
            )
            // A hypothetical future prompt-style tool must never be silently
            // suppressed: only positively-identified approval shapes are.
            let json = permissionJSON(
                transcriptPath: transcript(in: codexHome),
                toolName: "request_user_consent",
                toolInput: #"{ "anything": true }"#
            )

            let event = try #require(await core.handleIngress(frame(json)))
            #expect(event.state?.openForm != nil)
            #expect(event.notification != nil)
        }
    }

    @Test("a missing tool_name still notifies (fail closed)")
    func missingToolNameFailsClosed() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            _ = await core.handleIngress(
                frame(sessionStartJSON(transcriptPath: transcript(in: codexHome)))
            )
            let json = permissionJSON(
                transcriptPath: transcript(in: codexHome),
                toolName: nil
            )

            let event = try #require(await core.handleIngress(frame(json)))
            #expect(event.state?.openForm != nil)
            #expect(event.notification != nil)
        }
    }

    // MARK: - Forms the guardian never reviews keep working

    @Test("guardian posture: AskUserQuestion still notifies and opens its form")
    func askUserQuestionStillForms() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            _ = await core.handleIngress(
                frame(sessionStartJSON(transcriptPath: transcript(in: codexHome)))
            )
            let json = permissionJSON(
                transcriptPath: transcript(in: codexHome),
                toolName: "AskUserQuestion",
                toolInput: """
                {
                    "questions": [
                        {
                            "question": "Pick one",
                            "header": "Pick",
                            "options": [ {"label": "A", "description": ""} ],
                            "multiSelect": false
                        }
                    ]
                }
                """
            )

            let event = try #require(await core.handleIngress(frame(json)))
            #expect(event.state?.needsAttention == true)
            let form = try #require(event.state?.openForm)
            guard case .askUserQuestion = form.request else {
                Issue.record("expected .askUserQuestion, got \(form.request)")
                return
            }
            #expect(event.notification != nil)
        }
    }

    @Test("guardian posture: ExitPlanMode still opens the plan-approval form")
    func exitPlanModeStillForms() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            _ = await core.handleIngress(
                frame(sessionStartJSON(transcriptPath: transcript(in: codexHome)))
            )
            let json = permissionJSON(
                transcriptPath: transcript(in: codexHome),
                toolName: "ExitPlanMode",
                toolInput: #"{ "plan": "1. Do the thing" }"#
            )

            let event = try #require(await core.handleIngress(frame(json)))
            let form = try #require(event.state?.openForm)
            guard case .approvePlan = form.request else {
                Issue.record("expected .approvePlan, got \(form.request)")
                return
            }
        }
    }

    // MARK: - Postures that must stay untouched

    @Test("bypassPermissions events are never suppressed (a real user prompt follows)")
    func bypassPermissionsUnchanged() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            _ = await core.handleIngress(
                frame(sessionStartJSON(transcriptPath: transcript(in: codexHome)))
            )
            let json = permissionJSON(
                transcriptPath: transcript(in: codexHome),
                permissionMode: "bypassPermissions"
            )

            let event = try #require(await core.handleIngress(frame(json)))
            let form = try #require(event.state?.openForm)
            guard case .permission = form.request else {
                Issue.record("expected .permission, got \(form.request)")
                return
            }
            #expect(event.notification != nil)
        }
    }

    @Test("user reviewer posture: every permission request notifies, unchanged")
    func userPostureUnchanged() async throws {
        try await withCore(configTOML: userTOML) { core, _, codexHome in
            let json = permissionJSON(transcriptPath: transcript(in: codexHome))

            let event = try #require(await core.handleIngress(frame(json)))
            #expect(event.state?.openForm != nil)
            #expect(event.notification != nil)
        }
    }

    @Test("missing permission_mode fails safe to notifying even in guardian posture")
    func missingPermissionModeFailsSafe() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            _ = await core.handleIngress(
                frame(sessionStartJSON(transcriptPath: transcript(in: codexHome)))
            )
            let json = permissionJSON(
                transcriptPath: transcript(in: codexHome),
                permissionMode: nil
            )

            let event = try #require(await core.handleIngress(frame(json)))
            #expect(event.state?.openForm != nil)
            #expect(event.notification != nil)
        }
    }

    @Test("no transcript_path → no positive attribution → notifies")
    func missingTranscriptFailsSafe() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, _ in
            let json = permissionJSON(transcriptPath: nil)

            let event = try #require(await core.handleIngress(frame(json)))
            #expect(event.state?.openForm != nil)
            #expect(event.notification != nil)
        }
    }

    @Test("transcript under an untracked CODEX_HOME → notifies")
    func unknownHomeFailsSafe() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, _ in
            let foreign = FileManager.default.temporaryDirectory
                .appendingPathComponent("gallager-cx-foreign-\(UUID().uuidString)")
                .appendingPathComponent("sessions/2026/06/10/rollout-x.jsonl")
            let json = permissionJSON(transcriptPath: foreign.path)

            let event = try #require(await core.handleIngress(frame(json)))
            #expect(event.state?.openForm != nil)
            #expect(event.notification != nil)
        }
    }

    // MARK: - Mid-session toggles (the file is global; each session keeps its own posture)

    @Test("toggling guardian off notifies on the very next event; toggling back restores suppression")
    func configToggleHealsBothWays() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            let configURL = codexHome.appendingPathComponent("config.toml")
            let json = permissionJSON(transcriptPath: transcript(in: codexHome))
            _ = await core.handleIngress(
                frame(sessionStartJSON(transcriptPath: transcript(in: codexHome)))
            )

            // Guardian at session start → suppressed.
            let first = try #require(await core.handleIngress(frame(json)))
            #expect(first.state == .working)
            #expect(first.notification == nil)

            // "Approve for me" toggled off (the TUI persists `user`): the file
            // no longer matches this session's snapshot → notify on the very
            // next event. Correct for the toggling session; fail-safe for any
            // other session sharing the root.
            try Data(userTOML.utf8).write(to: configURL)

            let second = try #require(await core.handleIngress(frame(json)))
            #expect(second.state?.openForm != nil)
            #expect(second.notification != nil)

            // Toggled back on: the file agrees with the session's snapshot
            // again → suppression resumes, no new SessionStart needed.
            try Data(autoReviewTOML.utf8).write(to: configURL)

            let third = try #require(await core.handleIngress(frame(json)))
            #expect(third.state == .working)
            #expect(third.notification == nil)
        }
    }

    @Test("a session started under `user` keeps notifying after the file flips to auto_review")
    func guardianOnMidSessionCannotBeAttributed() async throws {
        try await withCore(configTOML: userTOML) { core, _, codexHome in
            let configURL = codexHome.appendingPathComponent("config.toml")
            let json = permissionJSON(transcriptPath: transcript(in: codexHome))
            _ = await core.handleIngress(
                frame(sessionStartJSON(transcriptPath: transcript(in: codexHome)))
            )

            let first = try #require(await core.handleIngress(frame(json)))
            #expect(first.state?.openForm != nil)

            // The file flips to auto_review. THIS session may be the toggler
            // (truly guardian now) or another live session may have toggled
            // (this one still presents real TUI prompts) — indistinguishable
            // from hooks and files, so fail safe: keep notifying. Eating a
            // real prompt would be worse than the toggler's transient noise.
            try Data(autoReviewTOML.utf8).write(to: configURL)

            let second = try #require(await core.handleIngress(frame(json)))
            #expect(second.state?.openForm != nil)
            #expect(second.notification != nil)
        }
    }

    @Test("two sessions diverge: one file value, opposite per-session outcomes")
    func multiSessionDivergence() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            let configURL = codexHome.appendingPathComponent("config.toml")
            let transcriptA = transcript(in: codexHome)
            let transcriptB = codexHome
                .appendingPathComponent("sessions/2026/06/10/rollout-2026-06-10-bbb.jsonl")
                .path

            // Session A starts while the file says auto_review → suppressed.
            _ = await core.handleIngress(frame(sessionStartJSON(transcriptPath: transcriptA)))
            let a1 = try #require(
                await core.handleIngress(frame(permissionJSON(transcriptPath: transcriptA)))
            )
            #expect(a1.state == .working)
            #expect(a1.notification == nil)

            // Someone switches a session to ask-mode (the TUI persists `user`)
            // and session B starts under that value → B notifies.
            try Data(userTOML.utf8).write(to: configURL)
            _ = await core.handleIngress(frame(
                sessionStartJSON(transcriptPath: transcriptB, sessionID: "sess-guardian-b"),
                pane: "%2"
            ))
            let b1 = try #require(await core.handleIngress(frame(
                permissionJSON(transcriptPath: transcriptB, sessionID: "sess-guardian-b"),
                pane: "%2"
            )))
            #expect(b1.state?.openForm != nil)

            // Some session toggles guardian back on — the file says
            // auto_review but B's runtime posture is still `user` (Codex never
            // re-reads the file mid-session). B's real prompts must never be
            // eaten: snapshot (user) ≠ file (auto_review) → notify.
            try Data(autoReviewTOML.utf8).write(to: configURL)
            let b2 = try #require(await core.handleIngress(frame(
                permissionJSON(transcriptPath: transcriptB, sessionID: "sess-guardian-b"),
                pane: "%2"
            )))
            #expect(b2.state?.openForm != nil)
            #expect(b2.notification != nil)

            // A's snapshot (auto_review) agrees with the file again → A's
            // guardian-handled requests stay silent. Same file, same instant,
            // opposite outcomes — posture is per-session.
            let a2 = try #require(
                await core.handleIngress(frame(permissionJSON(transcriptPath: transcriptA)))
            )
            #expect(a2.state == .working)
            #expect(a2.notification == nil)
        }
    }

    // MARK: - Snapshot reconstruction (app launched mid-session — no SessionStart seen)

    @Test("reconstruction adopts the file value when config.toml predates the session's rollout")
    func reconstructionAdoptsFileWhenConfigOlder() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            // The rollout exists on disk and config.toml hasn't been touched
            // since before the session began → the current file value is
            // exactly what the session loaded at startup → suppress.
            let rollout = URL(fileURLWithPath: transcript(in: codexHome))
            try FileManager.default.createDirectory(
                at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("{}".utf8).write(to: rollout)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -600)],
                ofItemAtPath: codexHome.appendingPathComponent("config.toml").path
            )

            let event = try #require(
                await core.handleIngress(frame(permissionJSON(transcriptPath: rollout.path)))
            )
            #expect(event.state == .working)
            #expect(event.notification == nil)
        }
    }

    @Test("reconstruction fails safe when config.toml was rewritten during the session")
    func reconstructionFailsSafeWhenConfigNewer() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            // config.toml was modified AFTER the rollout was created: a toggle
            // happened somewhere during this session's lifetime and the
            // session's start posture is unknowable → notify.
            let rollout = URL(fileURLWithPath: transcript(in: codexHome))
            try FileManager.default.createDirectory(
                at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("{}".utf8).write(to: rollout)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: 600)],
                ofItemAtPath: codexHome.appendingPathComponent("config.toml").path
            )

            let event = try #require(
                await core.handleIngress(frame(permissionJSON(transcriptPath: rollout.path)))
            )
            #expect(event.state?.openForm != nil)
            #expect(event.notification != nil)
        }
    }

    @Test("reconstruction fails safe when the rollout can't be dated (missing on disk)")
    func reconstructionFailsSafeWithoutRollout() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            // No SessionStart was seen and the transcript path doesn't exist:
            // the session can't be dated against the config file → notify.
            let event = try #require(await core.handleIngress(
                frame(permissionJSON(transcriptPath: transcript(in: codexHome)))
            ))
            #expect(event.state?.openForm != nil)
            #expect(event.notification != nil)
        }
    }

    // MARK: - Snapshot lifecycle

    @Test("the pane poll's orphan reconcile must not wipe a live session's snapshot")
    func orphanReconcileKeepsSnapshot() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            let transcriptPath = transcript(in: codexHome)
            _ = await core.handleIngress(frame(sessionStartJSON(transcriptPath: transcriptPath)))

            // First monitor tick: the pane runs no codex process (the mock
            // host reports none — same as synthetic E2E sessions), so its
            // correlation is reconciled as an orphan. The snapshot recorded
            // seconds ago must survive: orphan correlations belong to a
            // previous app run, not to this session.
            await core.pollSessionEnds()
            await core.pollSessionEnds()

            let event = try #require(
                await core.handleIngress(frame(permissionJSON(transcriptPath: transcriptPath)))
            )
            #expect(event.state == .working)
            #expect(event.notification == nil)
        }
    }

    @Test("a SessionEnd hook drops the session's snapshot")
    func sessionEndClearsSnapshot() async throws {
        try await withCore(configTOML: autoReviewTOML) { core, _, codexHome in
            let transcriptPath = transcript(in: codexHome)
            _ = await core.handleIngress(frame(sessionStartJSON(transcriptPath: transcriptPath)))
            let suppressed = try #require(
                await core.handleIngress(frame(permissionJSON(transcriptPath: transcriptPath)))
            )
            #expect(suppressed.state == .working)

            // After the session ends, a request reusing the same id has no
            // snapshot and no datable rollout on disk → fail-safe notify.
            let endJSON = """
            {
                "hook_event_name": "SessionEnd",
                "session_id": "sess-guardian",
                "cwd": "/Users/test/MyProject"
            }
            """
            _ = await core.handleIngress(frame(endJSON))

            let after = try #require(
                await core.handleIngress(frame(permissionJSON(transcriptPath: transcriptPath)))
            )
            #expect(after.state?.openForm != nil)
            #expect(after.notification != nil)
        }
    }
}
