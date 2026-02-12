import FlyingFox
import XCTest

@MainActor
struct TouchHandler: HTTPHandler {
    private let daemonProxy = RunnerDaemonProxy()

    func handleRequest(_ request: FlyingFox.HTTPRequest) async throws -> HTTPResponse {
        guard let touchRequest = try? JSONDecoder().decode(TouchRequest.self, from: Data(request.body)) else {
            return errorResponse("Invalid touch request body")
        }

        let point = CGPoint(x: touchRequest.x, y: touchRequest.y)
        NSLog("[Touch] Tap at (\(point.x), \(point.y))")

        let eventRecord = EventRecord()
            .addPointerTouchEvent(at: point, touchUpAfter: touchRequest.duration)

        try await daemonProxy.synthesize(eventRecord: eventRecord)

        return HTTPResponse(statusCode: .ok)
    }

    private func errorResponse(_ message: String) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(["error": message])) ?? Data()
        return HTTPResponse(statusCode: .badRequest, body: body)
    }
}
