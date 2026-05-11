import ClaudeSpyCommon
import ClaudeSpyNetworking
import Foundation

/// Pending confirmation that the user wants to close a session/window that
/// still has running processes. Wraps the target plus the running processes
/// shown in the alert body.
struct CloseConfirmation {
    enum Target {
        case session(String)
        case window(LocalTmuxWindow)
        case remoteWindow(TmuxWindow, hostId: String)
        case remoteSession(sessionName: String, hostId: String)
    }

    let target: Target
    let runningProcesses: [RunningProcessInfo]

    /// Create from local TmuxService processes
    init(target: Target, localProcesses: [TmuxService.RunningProcess]) {
        self.target = target
        self.runningProcesses = localProcesses.map {
            RunningProcessInfo(paneIndex: $0.paneIndex, name: $0.name, isForeground: $0.isForeground)
        }
    }

    /// Create from remote RunningProcessInfo (already in wire format)
    init(target: Target, runningProcesses: [RunningProcessInfo]) {
        self.target = target
        self.runningProcesses = runningProcesses
    }

    var title: String {
        switch target {
        case .session,
             .remoteSession: "Close Session?"
        case .window,
             .remoteWindow: "Close Window?"
        }
    }

    var targetName: String {
        switch target {
        case let .session(name): name
        case let .window(window): windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)
        case let .remoteWindow(window, _): windowTabLabel(windowName: window.windowName, windowIndex: window.windowIndex)
        case let .remoteSession(name, _): name
        }
    }

    var message: String {
        let grouped = Dictionary(grouping: runningProcesses) { $0.paneIndex }
        let descriptions = grouped.sorted(by: { $0.key < $1.key }).map { paneIndex, processes in
            let names = Set(processes.map(\.name)).sorted().joined(separator: ", ")
            return "Pane \(paneIndex): \(names)"
        }
        return "The following processes are still running:\n\(descriptions.joined(separator: "\n"))"
    }
}
