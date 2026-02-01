import SwiftUI

public struct CheckForUpdatesView: View {
    private let updaterController: UpdaterController

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
