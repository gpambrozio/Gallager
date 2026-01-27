import Foundation
#if canImport(Sparkle)
    import Sparkle
#endif

/// A controller class that manages the Sparkle updater for the application.
/// This class wraps SPUStandardUpdaterController and provides SwiftUI-friendly bindings.
@MainActor
final public class UpdaterController: ObservableObject {
    #if canImport(Sparkle)
        private let updaterController: SPUStandardUpdaterController

        /// Whether the user can check for updates (not currently checking)
        @Published public private(set) var canCheckForUpdates = false

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
            updaterController.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
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
    #else
        // Stub implementation for non-macOS platforms
        @Published public private(set) var canCheckForUpdates = false
        public var lastUpdateCheckDate: Date? { nil }
        public init() { }
        public func checkForUpdates() { }
        // swiftlint:disable unused_setter_value
        public var automaticallyChecksForUpdates: Bool {
            get { false }
            set { }
        }

        public var updateCheckInterval: TimeInterval {
            get { 0 }
            set { }
        }

        public var automaticallyDownloadsUpdates: Bool {
            get { false }
            set { }
        }
        // swiftlint:enable unused_setter_value
    #endif
}
