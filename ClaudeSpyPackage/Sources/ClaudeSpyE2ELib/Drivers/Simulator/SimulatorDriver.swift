import Foundation
import Logging

/// Drives the iOS Simulator: boot, install, launch, UI interaction
public actor SimulatorDriver {
    private let processRunner = ProcessRunner()
    private let logger = Logger(label: "e2e.simulator-driver")

    private var udid: String?
    private var simulatorPID: pid_t?
    private var appBundleId: String?
    private var cachedContentOrigin: CGPoint?

    public init() { }

    // MARK: - Simulator Lifecycle

    /// Boot a simulator by name, returning its UDID
    @discardableResult
    public func bootSimulator(name: String) async throws -> String {
        logger.info("Booting simulator: \(name)")

        // Find the device UDID
        let listResult = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "available", "-j"]
        )

        let json = try JSONSerialization.jsonObject(with: listResult.stdout) as? [String: Any]
        let devices = json?["devices"] as? [String: [[String: Any]]] ?? [:]

        var foundUDID: String?
        for (_, deviceList) in devices {
            for device in deviceList {
                if
                    let deviceName = device["name"] as? String,
                    deviceName == name,
                    let deviceUDID = device["udid"] as? String {
                    foundUDID = deviceUDID
                    // Check if already booted
                    if let state = device["state"] as? String, state == "Booted" {
                        logger.info("Simulator already booted: \(deviceUDID)")
                        self.udid = deviceUDID
                        try await findSimulatorPID()
                        return deviceUDID
                    }
                    break
                }
            }
            if foundUDID != nil { break }
        }

        guard let udid = foundUDID else {
            throw SimulatorDriverError.simulatorNotRunning
        }

        // Boot the simulator
        _ = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: ["simctl", "boot", udid]
        )

        // Open Simulator.app to show the UI
        _ = try await processRunner.run(
            "/usr/bin/open",
            arguments: ["-a", "Simulator"]
        )

        // Wait for it to be ready
        try await Task.sleep(for: .seconds(3))

        self.udid = udid
        try await findSimulatorPID()

        // Ensure Point Accurate mode
        try await SimulatorInteraction.ensurePointAccurateMode()

        return udid
    }

    /// Install an app in the simulator
    public func installApp(appPath: String) async throws {
        guard let udid else {
            throw SimulatorDriverError.simulatorNotRunning
        }

        logger.info("Installing app: \(appPath)")
        _ = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: ["simctl", "install", udid, appPath]
        )
    }

    /// Launch an app in the simulator
    public func launchApp(bundleId: String, arguments: [String] = []) async throws {
        guard let udid else {
            throw SimulatorDriverError.simulatorNotRunning
        }

        logger.info("Launching app: \(bundleId)")
        var args = ["simctl", "launch", udid, bundleId]
        args.append(contentsOf: arguments)

        _ = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: args
        )

        appBundleId = bundleId
        // Give the app time to launch
        try await Task.sleep(for: .seconds(2))
    }

    /// Terminate a running app
    public func terminateApp(bundleId: String? = nil) async throws {
        guard let udid else { return }
        let bid = bundleId ?? appBundleId ?? ""
        guard !bid.isEmpty else { return }

        logger.info("Terminating app: \(bid)")
        _ = try await processRunner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "terminate", udid, bid]
        )
    }

    /// Uninstall an app from the simulator
    public func uninstallApp(bundleId: String? = nil) async throws {
        guard let udid else { return }
        let bid = bundleId ?? appBundleId ?? ""
        guard !bid.isEmpty else { return }

        logger.info("Uninstalling app: \(bid)")
        _ = try await processRunner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "uninstall", udid, bid]
        )
    }

    // MARK: - UI Inspection

    /// Describe the current UI tree
    public func describeUI(maxDepth: Int = 15) async -> [UIElement] {
        guard var pid = simulatorPID else {
            logger.warning("No Simulator PID available")
            return []
        }

        var (elements, origin) = SimulatorAccessibility.describeUI(
            simulatorPID: pid,
            maxDepth: maxDepth
        )

        // If content group wasn't found, refresh PID and retry once
        if origin == nil {
            logger.info("Content group not found, refreshing Simulator PID and retrying...")
            try? await findSimulatorPID()
            if let newPid = simulatorPID, newPid != pid {
                pid = newPid
                (elements, origin) = SimulatorAccessibility.describeUI(
                    simulatorPID: pid,
                    maxDepth: maxDepth
                )
            }
        }

        if let origin {
            cachedContentOrigin = origin
        }

        return elements
    }

    /// Find the first element matching a query
    public func findElement(matching query: ElementQuery) async -> UIElement? {
        let elements = await describeUI()
        return query.findFirst(in: elements)
    }

    /// Wait for an element to appear
    public func waitForElement(
        matching query: ElementQuery,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.5
    ) async throws -> UIElement {
        try await Polling.waitFor(
            description: "element matching \(query)",
            timeout: timeout,
            pollInterval: pollInterval
        ) {
            await self.findElement(matching: query)
        }
    }

    // MARK: - Interaction

    /// Tap on a UI element
    public func tap(element: UIElement) throws {
        guard let contentOrigin = cachedContentOrigin else {
            throw SimulatorDriverError.noContentGroup
        }

        let screenPoint = SimulatorWindow.toScreenCoordinates(
            point: element.center,
            contentOrigin: contentOrigin
        )
        SimulatorInteraction.tap(at: screenPoint)
    }

    /// Tap at raw iOS coordinates
    public func tap(x: CGFloat, y: CGFloat) throws {
        guard let contentOrigin = cachedContentOrigin else {
            throw SimulatorDriverError.noContentGroup
        }

        let screenPoint = SimulatorWindow.toScreenCoordinates(
            point: CGPoint(x: x, y: y),
            contentOrigin: contentOrigin
        )
        SimulatorInteraction.tap(at: screenPoint)
    }

    /// Type text (sends keystrokes to Simulator)
    public func type(text: String, slow: Bool = false) async throws {
        try await SimulatorInteraction.type(text: text, slow: slow)
    }

    /// Take a screenshot
    public func screenshot(output: String) async throws -> String {
        guard let udid else {
            throw SimulatorDriverError.simulatorNotRunning
        }

        _ = try await processRunner.runOrThrow(
            "/usr/bin/xcrun",
            arguments: ["simctl", "io", udid, "screenshot", output]
        )

        logger.info("Screenshot saved: \(output)")
        return output
    }

    // MARK: - Private

    private func findSimulatorPID() async throws {
        let result = try await processRunner.run(
            "/usr/bin/pgrep",
            arguments: ["-x", "Simulator"]
        )

        if result.isSuccess, let pid = Int32(result.stdoutString) {
            simulatorPID = pid
            logger.info("Simulator PID: \(pid)")
        }
    }
}
