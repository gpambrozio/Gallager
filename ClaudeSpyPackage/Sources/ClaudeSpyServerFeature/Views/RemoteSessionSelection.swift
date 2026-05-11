import Foundation

/// Identifies a selected remote session by host and session name.
struct RemoteSessionSelection: Equatable, Hashable {
    let hostId: String
    let hostName: String
    let sessionName: String

    /// Returns the auto-resize key for the active pane in a given window
    func resizeKey(paneId: String) -> String {
        "remote-\(hostId)-\(paneId)"
    }
}
