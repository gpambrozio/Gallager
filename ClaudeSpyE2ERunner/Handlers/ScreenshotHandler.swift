import FlyingFox
import XCTest

@MainActor
struct ScreenshotHandler: HTTPHandler {
    func handleRequest(_: FlyingFox.HTTPRequest) async throws -> HTTPResponse {
        NSLog("[Screenshot] Taking screenshot")
        let screenshot = XCUIScreen.main.screenshot()
        let pngData = screenshot.pngRepresentation
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "image/png"],
            body: pngData
        )
    }
}
