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
        case .postToolUseFailure:
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
        case .taskCompleted:
            .checkmarkCircleFill
        case .preCompact,
             .postCompact:
            .arrowDownRightAndArrowUpLeft
        case .instructionsLoaded:
            .docTextFill
        case .stopFailure:
            .exclamationmarkCircleFill
        case .configChange:
            .docBadgeGearshapeFill
        case .cwdChanged:
            .folderBadgeGearshape
        case .fileChanged:
            .docTextFill
        case .elicitation,
             .elicitationResult:
            .bubbleLeftAndExclamationmarkBubbleRight
        case .worktreeCreate:
            .arrowTriangleBranch
        case .worktreeRemove:
            .arrowTriangleBranch
        case .taskCreated:
            .folderBadgePlus
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
        case .postToolUseFailure:
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
        case .taskCompleted:
            .green
        case .preCompact,
             .postCompact:
            .indigo
        case .instructionsLoaded:
            .teal
        case .stopFailure:
            .red
        case .configChange:
            .orange
        case .cwdChanged:
            .brown
        case .fileChanged:
            .mint
        case .elicitation,
             .elicitationResult:
            .purple
        case .worktreeCreate:
            .green
        case .worktreeRemove:
            .red
        case .taskCreated:
            .green
        case .unknown:
            .gray
        }
    }
}
