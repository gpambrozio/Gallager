import FlyingFox

struct StatusHandler: HTTPHandler {
    func handleRequest(_: FlyingFox.HTTPRequest) async throws -> HTTPResponse {
        let body = try JSONEncoder().encode(["status": "ok"])
        return HTTPResponse(statusCode: .ok, body: body)
    }
}
