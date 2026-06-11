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
/// AskUserQuestion / ExitPlanMode, `bypassPermissions` events, `user`
/// posture, unattributable sessions — keeps today's notify-and-form behavior.
///
/// The posture is read from a real `config.toml` in a temp CODEX_HOME listed
/// in `additionalConfigFolders`; sessions are attributed to it via the hook's
/// `transcript_path` (the rollout file lives under `<CODEX_HOME>/sessions/`).
@Suite("CodexGuardianPosture")
struct CodexGuardianPostureTests {
    // MARK: - Helpers

    /// A temp CODEX_HOME holding `configTOML`, and a core whose settings list
    /// it in `additionalConfigFolders` so the posture read covers it.
    private func makeCore(
        configTOML: String?
    ) async throws -> (core: CodexPluginCore, host: MockPluginHost, codexHome: URL) {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallager-cx-guardian-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        if let configTOML {
            try Data(configTOML.utf8).write(to: codexHome.appendingPathComponent("config.toml"))
        }

        let host = MockPluginHost()
        let correlationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallager-cx-corr-guardian-\(UUID().uuidString)")
        let core = CodexPluginCore(correlation: CodexSessionCorrelation(root: correlationRoot))
        let settingsData = try JSONEncoder().encode(
            CodexSettings(additionalConfigFolders: [codexHome.path])
        )
        let env = PluginEnv(
            pluginRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
            stateDir: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("gallager-cx-guardian-state-\(UUID().uuidString)"),
            appVersion: "1.0",
            settings: settingsData,
            marketplaceSource: URL(fileURLWithPath: "/")
        )
        try await core.initialize(env, host: host)
        return (core, host, codexHome)
    }

    /// A realistic rollout path under the temp CODEX_HOME, attributing the
    /// session to that root.
    private func transcript(in codexHome: URL) -> String {
        codexHome
            .appendingPathComponent("sessions/2026/06/10/rollout-2026-06-10-abc.jsonl")
            .path
    }

    private func permissionJSON(
        transcriptPath: String?,
        permissionMode: String? = "default",
        toolName: String = "Bash",
        toolInput: String = #"{ "command": "rm -rf build", "description": "clean" }"#
    ) -> String {
        var fields = [
            #""hook_event_name": "PermissionRequest""#,
            #""session_id": "sess-guardian""#,
            #""cwd": "/Users/test/MyProject""#,
            "\"tool_name\": \"\(toolName)\"",
            "\"tool_input\": \(toolInput)",
        ]
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

    @Test("guardian posture: auto-approvable permission is silent — working, no form, no notification")
    func guardianSuppressesPlainPermission() async throws {
        let (core, _, codexHome) = try await makeCore(configTOML: autoReviewTOML)
        let json = permissionJSON(transcriptPath: transcript(in: codexHome))

        let event = try #require(await core.handleIngress(frame(json)))
        #expect(event.state == .working)
        #expect(event.state?.needsAttention == false)
        #expect(event.state?.openForm == nil)
        #expect(event.notification == nil)
        #expect(event.appActions.isEmpty)
    }

    @Test("legacy guardian_subagent spelling also suppresses")
    func guardianSubagentSpellingSuppresses() async throws {
        let (core, _, codexHome) = try await makeCore(
            configTOML: "approvals_reviewer = \"guardian_subagent\"\n"
        )
        let json = permissionJSON(transcriptPath: transcript(in: codexHome))

        let event = try #require(await core.handleIngress(frame(json)))
        #expect(event.state == .working)
        #expect(event.notification == nil)
    }

    // MARK: - Forms the guardian never reviews keep working

    @Test("guardian posture: AskUserQuestion still notifies and opens its form")
    func askUserQuestionStillForms() async throws {
        let (core, _, codexHome) = try await makeCore(configTOML: autoReviewTOML)
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

    @Test("guardian posture: ExitPlanMode still opens the plan-approval form")
    func exitPlanModeStillForms() async throws {
        let (core, _, codexHome) = try await makeCore(configTOML: autoReviewTOML)
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

    // MARK: - Postures that must stay untouched

    @Test("bypassPermissions events are never suppressed (a real user prompt follows)")
    func bypassPermissionsUnchanged() async throws {
        let (core, _, codexHome) = try await makeCore(configTOML: autoReviewTOML)
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

    @Test("user reviewer posture: every permission request notifies, unchanged")
    func userPostureUnchanged() async throws {
        let (core, _, codexHome) = try await makeCore(configTOML: userTOML)
        let json = permissionJSON(transcriptPath: transcript(in: codexHome))

        let event = try #require(await core.handleIngress(frame(json)))
        #expect(event.state?.openForm != nil)
        #expect(event.notification != nil)
    }

    @Test("missing permission_mode fails safe to notifying even in guardian posture")
    func missingPermissionModeFailsSafe() async throws {
        let (core, _, codexHome) = try await makeCore(configTOML: autoReviewTOML)
        let json = permissionJSON(
            transcriptPath: transcript(in: codexHome),
            permissionMode: nil
        )

        let event = try #require(await core.handleIngress(frame(json)))
        #expect(event.state?.openForm != nil)
        #expect(event.notification != nil)
    }

    @Test("no transcript_path → no positive attribution → notifies")
    func missingTranscriptFailsSafe() async throws {
        let (core, _, _) = try await makeCore(configTOML: autoReviewTOML)
        let json = permissionJSON(transcriptPath: nil)

        let event = try #require(await core.handleIngress(frame(json)))
        #expect(event.state?.openForm != nil)
        #expect(event.notification != nil)
    }

    @Test("transcript under an untracked CODEX_HOME → notifies")
    func unknownHomeFailsSafe() async throws {
        let (core, _, _) = try await makeCore(configTOML: autoReviewTOML)
        let foreign = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallager-cx-foreign-\(UUID().uuidString)")
            .appendingPathComponent("sessions/2026/06/10/rollout-x.jsonl")
        let json = permissionJSON(transcriptPath: foreign.path)

        let event = try #require(await core.handleIngress(frame(json)))
        #expect(event.state?.openForm != nil)
        #expect(event.notification != nil)
    }

    // MARK: - Mid-session toggles (config.toml is the live source of truth)

    @Test("rewriting config.toml flips suppression in both directions after a posture refresh")
    func configToggleFlipsBothWays() async throws {
        let (core, _, codexHome) = try await makeCore(configTOML: userTOML)
        let configURL = codexHome.appendingPathComponent("config.toml")
        let json = permissionJSON(transcriptPath: transcript(in: codexHome))

        // user → notifies.
        let first = try #require(await core.handleIngress(frame(json)))
        #expect(first.state?.openForm != nil)

        // Toggle "Approve for me" (the TUI persists it to config.toml).
        try Data("approvals_reviewer = \"auto_review\"\n".utf8).write(to: configURL)
        await core.refreshReviewerPosture()

        let second = try #require(await core.handleIngress(frame(json)))
        #expect(second.state == .working)
        #expect(second.state?.openForm == nil)
        #expect(second.notification == nil)

        // Toggle back to Default → notifies again, no new SessionStart needed.
        try Data("approvals_reviewer = \"user\"\n".utf8).write(to: configURL)
        await core.refreshReviewerPosture()

        let third = try #require(await core.handleIngress(frame(json)))
        #expect(third.state?.openForm != nil)
        #expect(third.notification != nil)
    }
}
