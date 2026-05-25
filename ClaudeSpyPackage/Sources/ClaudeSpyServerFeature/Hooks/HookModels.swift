import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation
import Vapor

// Re-export common types for convenience
public typealias HookEvent = ClaudeSpyCommon.HookEvent
public typealias HookAction = ClaudeSpyCommon.HookAction
public typealias AgentSession = ClaudeSpyCommon.AgentSession

// MARK: - Hook Request Query Parameters

struct HookQueryParams: Content {
    let projectPath: String?
    let tmuxPane: String?
    /// Which coding agent posted the hook. Optional on the wire so
    /// older bridge scripts keep working — absent means `claude-code`.
    let agent: String?

    enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
        case tmuxPane = "tmux_pane"
        case agent
    }

    /// Resolves the `agent` query param to a `CodingAgent`, defaulting to
    /// `.claudeCode` when the value is missing or unrecognized.
    func resolvedAgent() -> CodingAgent {
        guard let raw = agent, let parsed = CodingAgent(rawValue: raw) else {
            return .claudeCode
        }
        return parsed
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
