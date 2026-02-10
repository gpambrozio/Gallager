import ArgumentParser
import ClaudeSpyE2ELib
import Foundation

@main
struct ClaudeSpyE2ECommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ClaudeSpyE2E",
        abstract: "E2E test coordinator for ClaudeSpy"
    )

    @Option(name: .long, help: "Path to built ClaudeSpy.app (iOS simulator)")
    var iosAppPath: String

    @Option(name: .long, help: "Path to built ClaudeSpyServer.app (macOS)")
    var macosAppPath: String

    @Option(name: .long, help: "Simulator device name")
    var simName = "iPhone 16"

    @Option(name: .long, help: "Port for test server")
    var serverPort = 8_765

    @Option(name: .long, help: "Run specific scenario by name")
    var scenario: String?

    @Option(name: .long, help: "Directory for screenshots")
    var screenshotsDir = "/tmp/e2e-screenshots"

    func run() async throws {
        print("ClaudeSpy E2E Test Coordinator")
        print("==============================")
        print("iOS app:     \(iosAppPath)")
        print("macOS app:   \(macosAppPath)")
        print("Simulator:   \(simName)")
        print("Server port: \(serverPort)")
        print("Screenshots: \(screenshotsDir)")
        print()

        let orchestrator = TestOrchestrator(
            iosAppPath: iosAppPath,
            macOSAppPath: macosAppPath,
            simulatorName: simName,
            serverPort: serverPort,
            screenshotsDir: screenshotsDir
        )

        // Collect available scenarios
        let allScenarios: [TestScenario] = [
            FreshPairingScenario.scenario,
            NewTerminalScenario.scenario,
        ]

        // Filter if a specific scenario is requested
        let scenariosToRun: [TestScenario]
        if let scenarioName = scenario {
            scenariosToRun = allScenarios.filter { $0.name == scenarioName }
            if scenariosToRun.isEmpty {
                print("ERROR: No scenario named '\(scenarioName)'")
                print("Available: \(allScenarios.map(\.name).joined(separator: ", "))")
                throw ExitCode.failure
            }
        } else {
            scenariosToRun = allScenarios
        }

        print("Running \(scenariosToRun.count) scenario(s)...")
        print()

        let results = await orchestrator.runAll(scenariosToRun)

        // Print summary
        print()
        print("Results")
        print("-------")

        var allPassed = true
        for result in results {
            let status = result.success ? "PASS" : "FAIL"
            let duration = String(format: "%.1fs", result.duration)
            print("  [\(status)] \(result.scenarioName) (\(duration))")

            if let error = result.error, let step = result.failedStep {
                print("         Failed at step \(step): \(error)")
                allPassed = false
            }
        }

        print()
        if allPassed {
            print("All scenarios passed!")
        } else {
            print("Some scenarios failed.")
            throw ExitCode.failure
        }
    }
}
