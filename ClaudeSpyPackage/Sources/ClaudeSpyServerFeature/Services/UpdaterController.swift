#if canImport(Sparkle)
    import Combine
    import Foundation
    import Sparkle

    /// A controller class that manages the Sparkle updater for the application.
    /// This class wraps SPUStandardUpdaterController and provides SwiftUI-friendly bindings.
    @Observable
    @MainActor
    final public class UpdaterController {
        private let updaterController: SPUStandardUpdaterController
        private var cancellable: AnyCancellable?

        /// Whether the user can check for updates (not currently checking)
        public private(set) var canCheckForUpdates = false

        /// The date of the last update check, if any
        public var lastUpdateCheckDate: Date? {
            updaterController.updater.lastUpdateCheckDate
        }

        /// - Parameter startUpdater: Pass `false` to skip starting the Sparkle updater
        ///   (e.g. during E2E tests where update dialogs would interfere).
        public init(startUpdater: Bool = true) {
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: startUpdater,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )

            guard startUpdater else { return }

            // Use Combine's sink to observe canCheckForUpdates changes
            // This is the pattern recommended by Sparkle's documentation for SwiftUI
            self.cancellable = updaterController.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newValue in
                    self?.canCheckForUpdates = newValue
                }
        }

        /// Trigger a user-initiated update check
        public func checkForUpdates() {
            updaterController.checkForUpdates(nil)
        }

        /// Whether to automatically check for updates
        public var automaticallyChecksForUpdates: Bool {
            get { updaterController.updater.automaticallyChecksForUpdates }
            set { updaterController.updater.automaticallyChecksForUpdates = newValue }
        }
    }
#endif
