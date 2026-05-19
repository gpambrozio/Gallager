import FlyingFox
import XCTest

/// Terminates the iOS app under test via `XCUIApplication.terminate()` so
/// XCTest's accessibility tracking observes the process death; using `simctl
/// terminate` instead leaves XCTest pointed at a dead PID and breaks the next
/// snapshot taken after relaunch.
@MainActor
struct TerminateAppHandler: HTTPHandler {
    func handleRequest(_ request: FlyingFox.HTTPRequest) async throws -> HTTPResponse {
        guard let terminateRequest = try? JSONDecoder().decode(TerminateAppRequest.self, from: Data(await request.bodyData)) else {
            return errorResponse("Invalid terminate app request body")
        }

        NSLog("[TerminateApp] Terminating \(terminateRequest.bundleId)")
        let app = XCUIApplication(bundleIdentifier: terminateRequest.bundleId)
        app.terminate()

        return HTTPResponse(statusCode: .ok)
    }

    private func errorResponse(_ message: String) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(["error": message])) ?? Data()
        return HTTPResponse(statusCode: .badRequest, body: body)
    }
}
