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
            // Observe canCheckForUpdates using async/await with Combine's .values
            // Task uses [weak self] so it will exit when this object is deallocated
            Task { [weak self] in
                guard let self else { return }
                for await value in updaterController.updater.publisher(for: \.canCheckForUpdates).values {
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
