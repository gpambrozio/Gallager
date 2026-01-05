import ClaudeSpyCommon
import Foundation
import Vapor

// Re-export common types for convenience
public typealias HookEvent = ClaudeSpyCommon.HookEvent
public typealias HookAction = ClaudeSpyCommon.HookAction
public typealias ClaudeSession = ClaudeSpyCommon.ClaudeSession

// MARK: - Hook Request Query Parameters

struct HookQueryParams: Content {
    let projectPath: String?
    let tmuxPane: String?

    enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
        case tmuxPane = "tmux_pane"
    }
}

// MARK: - Hook Response

struct HookResponse: Content {
    let decision: HookDecision
    let reason: String?

    enum HookDecision: String, Codable, Sendable {
        case approve
        case block
    }

    init(decision: HookDecision = .approve, reason: String? = nil) {
        self.decision = decision
        self.reason = reason
    }

    static let approved = HookResponse(decision: .approve)
}
