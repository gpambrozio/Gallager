import ClaudeSpyFeature
import SwiftUI

@main
struct ClaudeSpyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegateHandler.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

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
