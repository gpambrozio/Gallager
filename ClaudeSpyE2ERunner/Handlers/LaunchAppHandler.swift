import FlyingFox
import XCTest

/// Launches the iOS app under test via `XCUIApplication.launch()` rather than
/// `simctl launch`. Going through XCTest keeps its internal accessibility
/// tracking bound to the new process — `simctl`-driven launches across a
/// long-lived runner leave the tracking pointed at a dead PID, which makes
/// `snapshot()` return a stale (or empty) hierarchy and breaks every AX query
/// from the second scenario onward.
@MainActor
struct LaunchAppHandler: HTTPHandler {
    func handleRequest(_ request: FlyingFox.HTTPRequest) async throws -> HTTPResponse {
        guard let launchRequest = try? JSONDecoder().decode(LaunchAppRequest.self, from: Data(await request.bodyData)) else {
            return errorResponse("Invalid launch app request body")
        }

        NSLog("[LaunchApp] Launching \(launchRequest.bundleId) with args: \(launchRequest.arguments ?? [])")
        let app = XCUIApplication(bundleIdentifier: launchRequest.bundleId)
        app.launchArguments = launchRequest.arguments ?? []
        // `launch()` terminates the app first if it is already running, so
        // callers don't need a separate terminate step before relaunch.
        app.launch()

        return HTTPResponse(statusCode: .ok)
    }

    private func errorResponse(_ message: String) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(["error": message])) ?? Data()
        return HTTPResponse(statusCode: .badRequest, body: body)
    }
}
