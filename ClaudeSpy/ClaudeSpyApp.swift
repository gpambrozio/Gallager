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
