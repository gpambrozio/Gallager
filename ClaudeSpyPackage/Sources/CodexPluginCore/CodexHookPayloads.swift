import ClaudeCodePluginCore
import Foundation

// MARK: - CodexHookPayloads

/// Re-exports of the legacy `HookEvent`/`HookAction` Codable types that
/// now live (publicly) inside `ClaudeCodePluginCore`. Codex's hook event
/// set is a subset of Claude's plus `PostCompact` and `SubagentStart`
/// (per Spec §17.2 footnote), so the translator decodes the same wire
/// shape — these typealiases keep the local naming consistent with the
/// Codex-side translator code.
enum CodexHookPayloads {
    // No nested types yet — the typealiases below are flat so the
    // translator can refer to them without an enum-namespace prefix.
}

// Internal aliases. Translator code reads/writes these names; the
// implementations all currently come from `ClaudeSpyNetworking`.
typealias HookActionPayload = HookAction
typealias HookCommonFields = CommonHookFields
typealias SessionStartPayload = SessionStartBody
typealias PreToolUsePayload = PreToolUseBody
typealias PostToolUsePayload = PostToolUseBody
typealias PostToolUseFailurePayload = PostToolUseFailureBody
typealias SessionEndPayload = SessionEndBody
typealias PermissionRequestPayload = PermissionRequestBody
typealias NotificationPayload = NotificationBody
typealias UserPromptSubmitPayload = UserPromptSubmitBody
typealias StopPayload = StopBody
typealias SubagentStartPayload = SubagentStartBody
typealias TeammateIdlePayload = TeammateIdleBody
typealias TaskCompletedPayload = TaskCompletedBody
typealias StopFailurePayload = StopFailureBody
typealias UserPromptExpansionPayload = UserPromptExpansionBody
typealias ElicitationPayload = ElicitationBody
typealias TaskCreatedPayload = TaskCreatedBody
