import ClaudeSpyNetworking
import Foundation

// MARK: - CodexHookPayloads

/// Re-exports of the legacy `HookEvent`/`HookAction` Codable types from
/// `ClaudeSpyNetworking/Models/HookModels.swift` under a name that signals
/// "internal Codex sidecar parsing shape" — the rest of the Mac app is being
/// migrated off the legacy public types, and once Task 21 deletes them this
/// file can host private mirrors. For now we just alias.
///
/// Codex's hook event set is a subset of Claude's plus `PostCompact` and
/// `SubagentStart` (per Spec §17.2 footnote). The translator therefore
/// uses the same `HookAction` discriminator; only the dispatch logic
/// changes.
///
/// Task 21 deletes the legacy types from `ClaudeSpyNetworking`. When that
/// happens, port the struct definitions verbatim into this file as
/// `internal` types so the Codex translator keeps decoding the same wire
/// shape without leaking the legacy public API.
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
