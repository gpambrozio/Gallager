import ClaudeSpyNetworking
import SwiftUI

/// UI-related extensions for HookAction
public extension HookAction {
    /// The SF Symbol representing this action type
    var symbol: Symbols {
        switch self {
        case .sessionStart:
            .playFill
        case .sessionEnd:
            .stopFill
        case .preToolUse,
             .postToolUse:
            .wrenchAndScrewdriver
        case .postToolUseFailure,
             .stopFailure:
            .exclamationmarkTriangle
        case .permissionRequest:
            .lockFill
        case .notification:
            .bellFill
        case .userPromptSubmit:
            .textBubbleFill
        case .stop,
             .subagentStop:
            .stopCircleFill
        case .subagentStart:
            .playFill
        case .teammateIdle:
            .pauseCircleFill
        case .taskCreated:
            .listBulletClipboard
        case .taskCompleted:
            .checkmarkCircleFill
        case .elicitation:
            .personBubbleFill
        case .elicitationResult:
            .checkmarkCircle
        case .configChange:
            .docBadgeGearshapeFill
        case .worktreeCreate,
             .worktreeRemove:
            .folderBadgeGearshape
        case .instructionsLoaded:
            .docTextFill
        case .fileChanged:
            .pencilLine
        case .cwdChanged:
            .folder
        case .preCompact,
             .postCompact:
            .arrowDownRightAndArrowUpLeft
        case .unknown:
            .questionmark
        }
    }

    /// The color associated with this action type
    var symbolColor: Color {
        switch self {
        case .sessionStart:
            .green
        case .sessionEnd:
            .red
        case .preToolUse,
             .postToolUse:
            .blue
        case .postToolUseFailure,
             .stopFailure:
            .red
        case .permissionRequest:
            .orange
        case .notification:
            .purple
        case .userPromptSubmit:
            .cyan
        case .stop,
             .subagentStop:
            .red
        case .subagentStart:
            .blue
        case .teammateIdle:
            .yellow
        case .taskCreated:
            .blue
        case .taskCompleted:
            .green
        case .elicitation:
            .orange
        case .elicitationResult:
            .green
        case .configChange,
             .instructionsLoaded:
            .secondary
        case .worktreeCreate,
             .worktreeRemove:
            .secondary
        case .fileChanged,
             .cwdChanged:
            .secondary
        case .preCompact,
             .postCompact:
            .indigo
        case .unknown:
            .gray
        }
    }
}
