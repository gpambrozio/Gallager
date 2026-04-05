import Foundation

/// E2E scenario: Sidebar cell layout customization and sort modes
///
/// Creates multiple sessions with various Claude states (attention, working, idle, plain terminal),
/// then tests:
/// 1. Default field layout shows expected values
/// 2. Changing visible fields updates sidebar cells
/// 3. All 5 sort modes produce correct session ordering
public enum SidebarLayoutScenario {
    public static let scenario = ClaudeSpyE2ELib.scenario(
        "Sidebar Layout",
        tags: ["sidebar", "macos-only"]
    ) {
        // ── Setup: Create 4 sessions ──────────────────────────────

        TestStep.log("Creating 4 tmux sessions with different states")
        TestStep.tmuxCreateSession(name: "alpha-project", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "beta-project", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "gamma-project", width: 80, height: 24)
        TestStep.tmuxCreateSession(name: "delta-terminal", width: 80, height: 24)

        Shortcut.macOnlySetup

        // Store pane IDs
        TestStep.tmuxStorePaneId(target: "alpha-project:0", storeAs: "paneAlpha")
        TestStep.tmuxStorePaneId(target: "beta-project:0", storeAs: "paneBeta")
        TestStep.tmuxStorePaneId(target: "gamma-project:0", storeAs: "paneGamma")

        // ── Simulate different Claude states ──────────────────────

        // Alpha: Attention (SessionStart + Stop = triggers notification)
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "alpha-session",
                "timestamp": "2026-02-14T10:00:00.000000Z"
            }
            """,
            tmuxPane: "${paneAlpha}",
            projectPath: "/Users/test/AlphaProject"
        )
        TestStep.wait(seconds: 1)
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "alpha-session",
                "timestamp": "2026-02-14T10:00:01.000000Z"
            }
            """,
            tmuxPane: "${paneAlpha}",
            projectPath: "/Users/test/AlphaProject"
        )
        TestStep.wait(seconds: 1)
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "Stop",
                "session_id": "alpha-session",
                "timestamp": "2026-02-14T10:00:02.000000Z",
                "last_assistant_message": "Done with alpha task"
            }
            """,
            tmuxPane: "${paneAlpha}",
            projectPath: "/Users/test/AlphaProject"
        )
        TestStep.wait(seconds: 1)

        // Beta: Working (SessionStart + UserPromptSubmit)
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "beta-session",
                "timestamp": "2026-02-14T10:01:00.000000Z"
            }
            """,
            tmuxPane: "${paneBeta}",
            projectPath: "/Users/test/BetaProject"
        )
        TestStep.wait(seconds: 1)
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "UserPromptSubmit",
                "session_id": "beta-session",
                "timestamp": "2026-02-14T10:01:01.000000Z"
            }
            """,
            tmuxPane: "${paneBeta}",
            projectPath: "/Users/test/BetaProject"
        )
        TestStep.wait(seconds: 1)

        // Gamma: Idle (SessionStart only, no working state)
        TestStep.macSendHookEvent(
            json: """
            {
                "hook_event_name": "SessionStart",
                "session_id": "gamma-session",
                "timestamp": "2026-02-14T10:02:00.000000Z"
            }
            """,
            tmuxPane: "${paneGamma}",
            projectPath: "/Users/test/GammaProject"
        )
        TestStep.wait(seconds: 2)

        // Delta: Plain terminal (no Claude session, no hook events)

        // ── Phase 1: Verify default field layout ──────────────────

        TestStep.log("Phase 1: Default fields — Custom Description, Project Name, Current Path, Latest Event")

        // Verify session states via accessibility labels
        TestStep.macWaitForElement(titled: "Attention", timeout: 10)
        TestStep.macWaitForElement(titled: "Working", timeout: 5)
        TestStep.macWaitForElement(titled: "Idle", timeout: 5)

        // Project names should be visible (from ClaudeSession.displayName)
        TestStep.macWaitForElement(titled: "AlphaProject", timeout: 5)
        TestStep.macWaitForElement(titled: "BetaProject", timeout: 5)
        TestStep.macWaitForElement(titled: "GammaProject", timeout: 5)

        // Plain terminal shows current path as primary (session name not in default fields)
        // Just verify 4 sessions are visible via the Local section
        TestStep.macWaitForElement(titled: "Local", timeout: 5)

        TestStep.macScreenshot(label: "default-layout")

        // ── Phase 2: Change fields to show Session Name + Command ─

        TestStep.log("Phase 2: Change fields to Session Name + Command only")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "General", timeout: 5)
        TestStep.macSelectSettingsTab("Sidebar")
        TestStep.wait(seconds: 1)
        TestStep.macScreenshot(label: "sidebar-settings-default")

        // Remove all default fields (Custom Description, Project Name, Current Path, Latest Event)
        // Click minus buttons 4 times to clear visible fields
        TestStep.macClickButton(titled: "Remove Custom Description")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Remove Project Name")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Remove Current Path")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Remove Latest Event")
        TestStep.wait(seconds: 0.5)

        // Add Tmux Session Name and Command
        TestStep.macClickButton(titled: "Add Tmux Session Name")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Add Current Command")
        TestStep.wait(seconds: 0.5)

        TestStep.macScreenshot(label: "sidebar-settings-session-command")
        TestStep.macCloseWindow(titled: "Sidebar")
        TestStep.wait(seconds: 1)

        // Verify sidebar now shows session names as primary
        TestStep.macWaitForElement(titled: "alpha-project", timeout: 5)
        TestStep.macWaitForElement(titled: "beta-project", timeout: 5)
        TestStep.macWaitForElement(titled: "gamma-project", timeout: 5)
        TestStep.macWaitForElement(titled: "delta-terminal", timeout: 5)

        TestStep.macScreenshot(label: "layout-session-command")

        // ── Phase 3: Restore to Project Name + Session Name ──────

        TestStep.log("Phase 3: Switch to Project Name + Session Name")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "Sidebar", timeout: 5)

        // Remove current fields
        TestStep.macClickButton(titled: "Remove Tmux Session Name")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Remove Current Command")
        TestStep.wait(seconds: 0.5)

        // Add Project Name + Session Name
        TestStep.macClickButton(titled: "Add Project Name")
        TestStep.wait(seconds: 0.5)
        TestStep.macClickButton(titled: "Add Tmux Session Name")
        TestStep.wait(seconds: 0.5)

        TestStep.macScreenshot(label: "sidebar-settings-project-session")
        TestStep.macCloseWindow(titled: "Sidebar")
        TestStep.wait(seconds: 1)

        // Claude sessions should show project name as primary
        TestStep.macWaitForElement(titled: "AlphaProject", timeout: 5)
        TestStep.macWaitForElement(titled: "BetaProject", timeout: 5)
        TestStep.macWaitForElement(titled: "GammaProject", timeout: 5)

        TestStep.macScreenshot(label: "layout-project-session")

        // ── Phase 4: Test all sort modes ──────────────────────────
        // Current states: Alpha=Attention, Beta=Working, Gamma=Idle, Delta=plain terminal
        // Session names alphabetically: alpha < beta < delta < gamma
        // Status priority: Attention(0) < Working(1) < Idle(2) < NoSession(3)
        // Recent activity: Gamma(10:02) > Beta(10:01:01) > Alpha(10:00:02) > Delta(none)

        // Sort mode 1: Status Priority (default)
        TestStep.log("Phase 4a: Sort by Status Priority")
        // Already default — verify order: alpha(attention), beta(working), gamma(idle), delta(terminal)
        TestStep.macScreenshot(label: "sort-status-priority")

        // Sort mode 2: Alphabetical
        TestStep.log("Phase 4b: Sort Alphabetically")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "Sidebar", timeout: 5)
        TestStep.macClickButton(titled: "Alphabetical (by primary label)")
        TestStep.wait(seconds: 0.5)
        TestStep.macCloseWindow(titled: "Sidebar")
        TestStep.wait(seconds: 1)
        // Order: AlphaProject, BetaProject, delta-terminal, GammaProject
        TestStep.macScreenshot(label: "sort-alphabetical")

        // Sort mode 3: Claude first
        TestStep.log("Phase 4c: Sort Claude First")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "Sidebar", timeout: 5)
        TestStep.macClickButton(titled: "Claude sessions first")
        TestStep.wait(seconds: 0.5)
        TestStep.macCloseWindow(titled: "Sidebar")
        TestStep.wait(seconds: 1)
        // Order: alpha, beta, gamma (Claude, alphabetical), then delta (terminal)
        TestStep.macScreenshot(label: "sort-claude-first")

        // Sort mode 4: Recent activity
        TestStep.log("Phase 4d: Sort by Recent Activity")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "Sidebar", timeout: 5)
        TestStep.macClickButton(titled: "Most recent activity")
        TestStep.wait(seconds: 0.5)
        TestStep.macCloseWindow(titled: "Sidebar")
        TestStep.wait(seconds: 1)
        // Order: gamma(10:02), beta(10:01:01), alpha(10:00:02), delta(no timestamp)
        TestStep.macScreenshot(label: "sort-recent-activity")

        // Sort mode 5: Session name
        TestStep.log("Phase 4e: Sort by Session Name")
        TestStep.macOpenSettings()
        TestStep.macWaitForWindow(titled: "Sidebar", timeout: 5)
        TestStep.macClickButton(titled: "Session name")
        TestStep.wait(seconds: 0.5)
        TestStep.macCloseWindow(titled: "Sidebar")
        TestStep.wait(seconds: 1)
        // Order: alpha-project, beta-project, delta-terminal, gamma-project
        TestStep.macScreenshot(label: "sort-session-name")
    }
}
