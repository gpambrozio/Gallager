import SwiftUI

public struct CheckForUpdatesView: View {
    @ObservedObject private var updaterController: UpdaterController

    public init(updaterController: UpdaterController) {
        self.updaterController = updaterController
    }

    public var body: some View {
        Button("Check for Updates...") {
            updaterController.checkForUpdates()
        }
        .disabled(!updaterController.canCheckForUpdates)
    }
}
