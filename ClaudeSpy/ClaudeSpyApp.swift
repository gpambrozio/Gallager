import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyFeature
import SwiftUI

@main
struct ClaudeSpyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegateHandler.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let iosSettings: IOSSettings
    private let keyManager: (any KeychainStorable)?

    init() {
        // Bootstrap logging FIRST, before any Logger instances are created
        // Log level is determined by LOG_LEVEL env var (default: warning)
        LoggingConfiguration.bootstrap()

        // E2E test mode: use in-memory storage to avoid polluting developer's real data
        let isE2ETest = CommandLine.arguments.contains("--e2e-test")

        if isE2ETest {
            let defaults = InMemoryDefaults()
            let settings = IOSSettings(defaults: defaults)
            iosSettings = settings
            keyManager = InMemoryKeyManager()
        } else {
            iosSettings = .shared
            keyManager = nil
        }

        // E2E test support: override server URL via launch argument
        if let idx = CommandLine.arguments.firstIndex(of: "--server-url"),
           idx + 1 < CommandLine.arguments.count
        {
            iosSettings.externalServerURL = CommandLine.arguments[idx + 1]
        }
    }

    var body: some Scene {
        WindowGroup {
            if let keyManager {
                ContentView(settings: iosSettings)
                    .keychainStorage(keyManager)
            } else {
                ContentView(settings: iosSettings)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                PushNotificationService.shared.clearBadge()
            }
        }
    }
}
