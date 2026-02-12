import FlyingFox
import Foundation

enum RouteHandlerFactory {
    @MainActor
    static func createRouteHandler(route: Route) -> HTTPHandler {
        switch route {
        case .viewHierarchy:
            ViewHierarchyHandler()
        case .touch:
            TouchHandler()
        case .swipe:
            SwipeHandler()
        case .inputText:
            InputTextHandler()
        case .customAction:
            CustomActionHandler()
        case .status:
            StatusHandler()
        }
    }
}
