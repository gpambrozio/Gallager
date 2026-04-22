import ClaudeSpyCommon
import ClaudeSpyEncryption
import ClaudeSpyFeature
import ClaudeSpyNetworking
import Dependencies
import SwiftUI

@main
struct ClaudeSpyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegateHandler.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Bootstrap logging FIRST, before any Logger instances are created
        // Log level is determined by LOG_LEVEL env var (default: warning)
        LoggingConfiguration.bootstrap()

        // E2E test support: override reported app version and min required partner version
        if let idx = CommandLine.arguments.firstIndex(of: "--app-version"),
           idx + 1 < CommandLine.arguments.count
        {
            VersionCompatibility.appVersionOverride = CommandLine.arguments[idx + 1]
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--min-required-partner-version"),
           idx + 1 < CommandLine.arguments.count
        {
            VersionCompatibility.minRequiredPartnerVersionOverride = CommandLine.arguments[idx + 1]
        }

        // E2E test support: use in-memory storage to avoid polluting real UserDefaults/Keychain
        if CommandLine.arguments.contains("--e2e-test") {
            let prefs = PreferencesService.inMemory()

            // E2E test support: override server URL via launch argument
            if let idx = CommandLine.arguments.firstIndex(of: "--server-url"),
               idx + 1 < CommandLine.arguments.count
            {
                prefs.setString(CommandLine.arguments[idx + 1], IOSSettings.Keys.externalServerURL.rawValue)
            }

            prepareDependencies {
                $0[PreferencesService.self] = prefs
                $0[SecretsService.self] = .inMemory()
            }

            #if DEBUG
                TestAccessibilityServer.startIfNeeded()
            #endif
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
