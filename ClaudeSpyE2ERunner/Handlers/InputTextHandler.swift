import FlyingFox
import XCTest

@MainActor
struct InputTextHandler: HTTPHandler {
    private let daemonProxy = RunnerDaemonProxy()

    func handleRequest(_ request: FlyingFox.HTTPRequest) async throws -> HTTPResponse {
        guard let inputRequest = try? JSONDecoder().decode(InputTextRequest.self, from: Data(await request.bodyData)) else {
            return errorResponse("Invalid input text request body")
        }

        NSLog("[InputText] Typing: \(inputRequest.text)")
        try await daemonProxy.send(string: inputRequest.text)

        return HTTPResponse(statusCode: .ok)
    }

    private func errorResponse(_ message: String) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(["error": message])) ?? Data()
        return HTTPResponse(statusCode: .badRequest, body: body)
    }
}
