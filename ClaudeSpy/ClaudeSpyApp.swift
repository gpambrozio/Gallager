import ClaudeSpyCommon
import ClaudeSpyFeature
import SwiftUI

@main
struct ClaudeSpyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegateHandler.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Bootstrap logging FIRST, before any Logger instances are created
        // Log level is determined by LOG_LEVEL env var (default: warning)
        LoggingConfiguration.bootstrap()

        // E2E test support: override server URL via launch argument
        if let idx = CommandLine.arguments.firstIndex(of: "--server-url"),
           idx + 1 < CommandLine.arguments.count
        {
            IOSSettings.shared.externalServerURL = CommandLine.arguments[idx + 1]
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                PushNotificationService.shared.clearBadge()
            }
        }
    }
}
