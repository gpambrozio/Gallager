import XCTest

final class ClaudeSpyE2ERunnerTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testHTTPServer() async throws {
        let server = E2EHTTPServer()
        NSLog("[ClaudeSpyE2ERunner] Starting HTTP server on port 22087")
        try await server.start()
    }
}
