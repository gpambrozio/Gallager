import Foundation

public struct PluginRootLayout: Sendable {
    public let pluginRoot: URL
    public let stateDir: URL
    public let logDir: URL
    public let ingressSocketPath: String
    public let appVersion: String

    public init(
        pluginRoot: URL,
        stateDir: URL,
        logDir: URL,
        ingressSocketPath: String,
        appVersion: String
    ) {
        self.pluginRoot = pluginRoot
        self.stateDir = stateDir
        self.logDir = logDir
        self.ingressSocketPath = ingressSocketPath
        self.appVersion = appVersion
    }
}
