import FlyingFox
import Foundation

enum Route: String, CaseIterable {
    case viewHierarchy
    case touch
    case swipe
    case inputText
    case customAction
    case screenshot
    case status

    func toHTTPRoute() -> HTTPRoute {
        HTTPRoute(rawValue)
    }
}

struct E2EHTTPServer {
    private let port: UInt16 = 22087

    func start() async throws {
        let server = try HTTPServer(
            address: .inet(ip4: "127.0.0.1", port: port),
            timeout: 100
        )

        for route in Route.allCases {
            let handler = await RouteHandlerFactory.createRouteHandler(route: route)
            await server.appendRoute(route.toHTTPRoute(), to: handler)
        }

        NSLog("[E2EHTTPServer] Listening on 127.0.0.1:\(port)")
        try await server.run()
    }
}
