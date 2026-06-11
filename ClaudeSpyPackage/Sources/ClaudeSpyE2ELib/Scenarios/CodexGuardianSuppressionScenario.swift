import Foundation

/// E2E scenario: Codex guardian (auto-review) posture suppresses permission
/// notifications and forms (#585).
///
/// When `approvals_reviewer = "auto_review"` in the session's CODEX_HOME
/// `config.toml`, Codex routes tool approvals to its guardian subagent — no
/// TUI prompt ever exists, so ClaudeSpy must stay silent (an actionable form
/// would keystroke into the composer). Verifies:
/// 1. A guardian-reviewable `PermissionRequest` (`Bash`,
///    `permission_mode: "default"`) produces NO iOS response form, NO push,
///    and the session stays Working.
/// 2. `AskUserQuestion` still notifies and opens its form (the guardian never
///    reviews it — a real TUI prompt exists).
/// 3. `permission_mode: "bypassPermissions"` events still notify (guardian
///    routing is off under `never` policy; a real prompt follows).
/// 4. Rewriting `config.toml` flips the behavior live in BOTH directions —
///    the posture is read fresh per permission request, so the very next
///    event honors it with no new SessionStart (the Codex TUI persists every
///    "Approve for me" toggle to this file).
///
/// The scratch CODEX_HOME lives inside the per-scenario
/// `--gallager-state-root`; the pre-seeded codex `settings.json` lists it in
/// `additional_config_folders`, and each hook's `transcript_path` attributes
/// the session to it. Each phase uses a distinct tool (`Bash`, `apply_patch`,
/// `mcp__…`) so the append-only push-log assertions stay unambiguous.
public enum CodexGuardianSuppressionScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Codex Guardian Suppression",
        tags: ["hooks", "codex", "sessions"]
    ) {
        // ══════════════════════════════════════════════════════════════
        // Phase 1: Pre-seed plugin state BEFORE the app launches:
        //          a guardian-posture config.toml in a scratch CODEX_HOME,
        //          and codex settings pointing additional_config_folders at it.
        // ══════════════════════════════════════════════════════════════
        TestStep.writeFile(
            path: "${gallagerStateRoot}/codex-home/config.toml",
            content: "approvals_reviewer = \"auto_review\"\n"
        )
        TestStep.writeFile(
            path: "${gallagerStateRoot}/plugins/codex/settings.json",
            content: """
            {"additional_config_folders": ["${gallagerStateRoot}/codex-home"], "log_level": "debug"}
            """
        )

        // ══════════════════════════════════════════════════════════════
        // Phase 2: Pair + a Codex session on its own pane.
        // ══════════════════════════════════════════════════════════════
        FreshPairingScenario.scenario
        TestStep.tmuxCreateSession(name: "codex-guardian", width: 80, height: 24)
        TestStep.tmuxStorePaneId(target: "codex-guardian:0.0", storeAs: "codexGuardianPane")
        TestStep.iosWaitForElement(.labelContains("codex-guardian"), timeout: 15)

        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "e2e-codex-guardian",
                "cwd": "/Users/test/CodexGuardian",
                "transcript_path": "${gallagerStateRoot}/codex-home/sessions/2026/06/10/rollout-e2e-guardian.jsonl",
                "timestamp": "2026-06-10T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${codexGuardianPane}"
        )
        TestStep.iosWaitForElement(.labelContains("CodexGuardian"), timeout: 10)
        TestStep.iosTap(.labelContains("CodexGuardian"))
        TestStep.iosWaitForElement(.labelContains("Reply to the agent"), timeout: 10)

        // Open the Panes window deterministically and select the session so the
        // status text ("Working" / "Permission") is visible for assertions.
        Shortcut.openPanesWindow()
        TestStep.macClickButton(titled: "codex-guardian")

        // ══════════════════════════════════════════════════════════════
        // Phase 3: Guardian posture — an auto-approvable PermissionRequest
        //          is SILENT: session stays Working, no iOS form, no push.
        // ══════════════════════════════════════════════════════════════
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-codex-guardian",
                "cwd": "/Users/test/CodexGuardian",
                "transcript_path": "${gallagerStateRoot}/codex-home/sessions/2026/06/10/rollout-e2e-guardian.jsonl",
                "permission_mode": "default",
                "timestamp": "2026-06-10T10:01:00.000000Z",
                "tool_name": "Bash",
                "tool_input": {
                    "command": "npm install",
                    "description": "Install dependencies"
                }
            }
            """,
            tmuxPane: "${codexGuardianPane}"
        )

        // Mac first: "Working" proves the event WAS processed (so the iOS
        // absence checks below aren't racing the round-trip), and the
        // "Permission" status never appears.
        TestStep.macWaitForElement(titled: "Working", timeout: 10)
        TestStep.macWaitForElementToDisappear(titled: "Permission", timeout: 5)
        TestStep.macScreenshot(label: "mac-guardian-suppressed-working")

        // No iOS response UI (neither the Accept button nor the form's
        // command description ever appear).
        TestStep.iosWaitForElementToDisappear(.labelContains("Accept"), timeout: 5)
        TestStep.iosWaitForElementToDisappear(.labelContains("npm install"), timeout: 3)
        TestStep.iosScreenshot(label: "ios-guardian-no-response-ui")

        // No push notification for the guardian-handled permission.
        TestStep.readFile(path: "${pushLogPath}", storeAs: "pushLogAfterGuardianBash")
        TestStep.assertStoredNotContains(
            key: "pushLogAfterGuardianBash",
            substring: "Permission: Bash|${codexGuardianPane}"
        )

        // ══════════════════════════════════════════════════════════════
        // Phase 4: AskUserQuestion is never guardian-reviewed — still
        //          notifies and opens its form even in guardian posture.
        // ══════════════════════════════════════════════════════════════
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-codex-guardian",
                "cwd": "/Users/test/CodexGuardian",
                "transcript_path": "${gallagerStateRoot}/codex-home/sessions/2026/06/10/rollout-e2e-guardian.jsonl",
                "permission_mode": "default",
                "timestamp": "2026-06-10T10:02:00.000000Z",
                "tool_name": "AskUserQuestion",
                "tool_input": {
                    "questions": [
                        {
                            "question": "Which database should Codex use?",
                            "header": "Database",
                            "options": [
                                {"label": "Postgres", "description": "Relational"},
                                {"label": "Mongo", "description": "Document"}
                            ],
                            "multiSelect": false
                        }
                    ]
                }
            }
            """,
            tmuxPane: "${codexGuardianPane}"
        )
        TestStep.iosWaitForElement(.labelContains("Which database should Codex use"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-guardian-question-still-shows")
        TestStep.readFile(path: "${pushLogPath}", storeAs: "pushLogAfterQuestion")
        TestStep.assertStoredContains(
            key: "pushLogAfterQuestion",
            substring: "Codex wants answers|${codexGuardianPane}"
        )

        // Answer the question to clear the form.
        TestStep.iosTap(.labelContains("Postgres"))
        TestStep.wait(seconds: 1)
        TestStep.iosTap(.labelContains("Confirm"))
        TestStep.iosWaitForElement(.labelContains("All questions answered"), timeout: 5)

        // ══════════════════════════════════════════════════════════════
        // Phase 5: bypassPermissions — guardian routing is off under the
        //          `never` policy, so the hook firing at all means a REAL
        //          prompt follows: must still notify and form, even for the
        //          same Bash tool that Phase 3 suppressed.
        // ══════════════════════════════════════════════════════════════
        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-codex-guardian",
                "cwd": "/Users/test/CodexGuardian",
                "transcript_path": "${gallagerStateRoot}/codex-home/sessions/2026/06/10/rollout-e2e-guardian.jsonl",
                "permission_mode": "bypassPermissions",
                "timestamp": "2026-06-10T10:03:00.000000Z",
                "tool_name": "Bash",
                "tool_input": {
                    "command": "npm run e2e",
                    "description": "Run the e2e suite"
                }
            }
            """,
            tmuxPane: "${codexGuardianPane}"
        )
        // The form's command description is unique on screen (the phase-4
        // "All questions answered" feedback is still visible until replaced).
        TestStep.iosWaitForElement(.labelContains("npm run e2e"), timeout: 10)
        TestStep.iosScreenshot(label: "ios-guardian-bypass-still-shows")
        TestStep.readFile(path: "${pushLogPath}", storeAs: "pushLogAfterBypass")
        TestStep.assertStoredContains(
            key: "pushLogAfterBypass",
            substring: "Permission: Bash|${codexGuardianPane}"
        )
        // Exact label: the answered-state feedback "Permission accepted"
        // also contains "accept", so a contains-match would be ambiguous.
        TestStep.iosTap(.label("Accept"))
        TestStep.iosWaitForElement(.labelContains("Permission accepted"), timeout: 5)

        // ══════════════════════════════════════════════════════════════
        // Phase 6: Flip config.toml to the user reviewer (what the Codex
        //          TUI does when toggling "Approve for me" off). The posture
        //          is read fresh per permission request, so the very next
        //          event notifies and forms. No new SessionStart, no waits.
        // ══════════════════════════════════════════════════════════════
        TestStep.writeFile(
            path: "${gallagerStateRoot}/codex-home/config.toml",
            content: "approvals_reviewer = \"user\"\n"
        )

        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-codex-guardian",
                "cwd": "/Users/test/CodexGuardian",
                "transcript_path": "${gallagerStateRoot}/codex-home/sessions/2026/06/10/rollout-e2e-guardian.jsonl",
                "permission_mode": "default",
                "timestamp": "2026-06-10T10:04:00.000000Z",
                "tool_name": "apply_patch",
                "tool_input": {
                    "command": "*** Begin Patch"
                }
            }
            """,
            tmuxPane: "${codexGuardianPane}"
        )
        // The apply_patch form title proves the NEW form arrived (the
        // lingering "Permission accepted" feedback from Phase 5 would also
        // match a bare "Accept" contains-query). apply_patch is otherwise
        // guardian-reviewable, so only the user posture explains the form.
        TestStep.iosWaitForElement(.labelContains("apply_patch"), timeout: 10)
        TestStep.macWaitForElement(titled: "Permission", timeout: 10)
        TestStep.iosScreenshot(label: "ios-user-posture-form-shows")
        TestStep.readFile(path: "${pushLogPath}", storeAs: "pushLogAfterUserFlip")
        TestStep.assertStoredContains(
            key: "pushLogAfterUserFlip",
            substring: "Permission: apply_patch|${codexGuardianPane}"
        )
        TestStep.iosTap(.label("Accept"))
        TestStep.iosWaitForElement(.labelContains("Permission accepted"), timeout: 5)

        // ══════════════════════════════════════════════════════════════
        // Phase 7: Flip back to auto_review — suppression resumes on the
        //          very next event, again with no new SessionStart. An MCP
        //          tool exercises the namespaced arm of the
        //          guardian-reviewable vocabulary.
        // ══════════════════════════════════════════════════════════════
        TestStep.writeFile(
            path: "${gallagerStateRoot}/codex-home/config.toml",
            content: "approvals_reviewer = \"auto_review\"\n"
        )

        TestStep.macSendHookEvent(
            pluginID: "codex",
            json: """
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "e2e-codex-guardian",
                "cwd": "/Users/test/CodexGuardian",
                "transcript_path": "${gallagerStateRoot}/codex-home/sessions/2026/06/10/rollout-e2e-guardian.jsonl",
                "permission_mode": "default",
                "timestamp": "2026-06-10T10:05:00.000000Z",
                "tool_name": "mcp__memory__create_entities",
                "tool_input": {
                    "server": "memory",
                    "tool": "create_entities",
                    "input": {}
                }
            }
            """,
            tmuxPane: "${codexGuardianPane}"
        )

        // The mac "Permission" status from Phase 6 gives way to "Working":
        // a real transition proving the suppressed event replaced the state.
        TestStep.macWaitForElement(titled: "Working", timeout: 10)
        TestStep.macWaitForElementToDisappear(titled: "Permission", timeout: 5)
        TestStep.macScreenshot(label: "mac-guardian-suppressed-again")

        // The MCP form never appears on iOS, and no push went out.
        TestStep.iosWaitForElementToDisappear(.labelContains("create_entities"), timeout: 5)
        TestStep.readFile(path: "${pushLogPath}", storeAs: "pushLogAfterGuardianMCP")
        TestStep.assertStoredNotContains(
            key: "pushLogAfterGuardianMCP",
            substring: "Permission: mcp__memory__create_entities|${codexGuardianPane}"
        )
    }
}
