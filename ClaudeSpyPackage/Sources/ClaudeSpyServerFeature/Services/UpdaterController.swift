#if canImport(Sparkle)
    import Foundation
    import Sparkle

    /// A controller class that manages the Sparkle updater for the application.
    /// This class wraps SPUStandardUpdaterController and provides SwiftUI-friendly bindings.
    @Observable
    @MainActor
    final public class UpdaterController {
        private let updaterController: SPUStandardUpdaterController

        /// Whether the user can check for updates (not currently checking)
        public private(set) var canCheckForUpdates = false

        /// The date of the last update check, if any
        public var lastUpdateCheckDate: Date? {
            updaterController.updater.lastUpdateCheckDate
        }

        public init() {
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )

            // Observe canCheckForUpdates using async/await
            // Use .initial to get the current value immediately, not just changes
            let stream = updaterController.updater.publisher(for: \.canCheckForUpdates, options: [.initial]).values
            Task { [weak self] in
                for await value in stream {
                    // Check self and cancellation on each iteration to allow deallocation
                    guard let self, !Task.isCancelled else { break }
                    self.canCheckForUpdates = value
                }
            }
        }

        public func checkForUpdates() {
            updaterController.checkForUpdates(nil)
        }

        public var automaticallyChecksForUpdates: Bool {
            get { updaterController.updater.automaticallyChecksForUpdates }
            set { updaterController.updater.automaticallyChecksForUpdates = newValue }
        }

        public var updateCheckInterval: TimeInterval {
            get { updaterController.updater.updateCheckInterval }
            set { updaterController.updater.updateCheckInterval = newValue }
        }

        public var automaticallyDownloadsUpdates: Bool {
            get { updaterController.updater.automaticallyDownloadsUpdates }
            set { updaterController.updater.automaticallyDownloadsUpdates = newValue }
        }
    }
#endif
