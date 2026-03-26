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
        case .preCompact:
            .arrowDownRightAndArrowUpLeft
        case .instructionsLoaded:
            .docOnClipboard
        case .stopFailure:
            .exclamationmarkCircleFill
        case .configChange:
            .gearshape
        case .cwdChanged:
            .folder
        case .fileChanged:
            .pencilLine
        case .worktreeCreate:
            .macwindowBadgePlus
        case .worktreeRemove:
            .xmarkCircle
        case .postCompact:
            .arrowDownRightAndArrowUpLeft
        case .elicitation:
            .ellipsisCircle
        case .elicitationResult:
            .checkmarkCircle
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
        case .instructionsLoaded,
             .configChange,
             .fileChanged,
             .worktreeRemove:
            .gray
        case .stopFailure:
            .red
        case .cwdChanged,
             .worktreeCreate:
            .blue
        case .elicitation:
            .orange
        case .elicitationResult:
            .green
        case .unknown:
            .gray
        }
    }
}
