import ClaudeSpyNetworking
import Foundation
import GallagerPluginProtocol

/// Records every `PluginHost` callback so contract tests can assert on what a
/// core drove (spec §17.2). An `actor`, so it is `Sendable` and safe to hand to
/// a core actor.
actor MockPluginHost: PluginHost {
    private(set) var projectsCalls: [[AgentProject]] = []
    private(set) var emittedEvents: [PluginEvent] = []
    private(set) var sentText: [(sessionID: String, text: String)] = []
    private(set) var sentKeys: [(sessionID: String, keys: [PluginTmuxKey])] = []
    private(set) var logLines: [LogLine] = []

    func setProjects(_ projects: [AgentProject]) async {
        projectsCalls.append(projects)
    }

    func emit(_ event: PluginEvent) async {
        emittedEvents.append(event)
    }

    func sendText(sessionID: String, _ text: String) async {
        sentText.append((sessionID, text))
    }

    func sendKeys(sessionID: String, _ keys: [PluginTmuxKey]) async {
        sentKeys.append((sessionID, keys))
    }

    func log(_ line: LogLine) async {
        logLines.append(line)
    }
}
