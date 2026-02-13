import FlyingFox
import XCTest

@MainActor
struct SwipeHandler: HTTPHandler {
    private let daemonProxy = RunnerDaemonProxy()

    func handleRequest(_ request: FlyingFox.HTTPRequest) async throws -> HTTPResponse {
        guard let swipeRequest = try? JSONDecoder().decode(SwipeRequest.self, from: Data(await request.bodyData)) else {
            return errorResponse("Invalid swipe request body")
        }

        let start = CGPoint(x: swipeRequest.startX, y: swipeRequest.startY)
        let end = CGPoint(x: swipeRequest.endX, y: swipeRequest.endY)
        NSLog("[Swipe] from (\(start.x), \(start.y)) to (\(end.x), \(end.y)) duration=\(swipeRequest.duration)")

        let eventRecord = EventRecord()
            .addSwipeEvent(start: start, end: end, duration: swipeRequest.duration)

        try await daemonProxy.synthesize(eventRecord: eventRecord)

        return HTTPResponse(statusCode: .ok)
    }

    private func errorResponse(_ message: String) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(["error": message])) ?? Data()
        return HTTPResponse(statusCode: .badRequest, body: body)
    }
}
