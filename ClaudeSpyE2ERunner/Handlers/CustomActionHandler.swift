import FlyingFox
import XCTest

@MainActor
struct CustomActionHandler: HTTPHandler {
    func handleRequest(_ request: FlyingFox.HTTPRequest) async throws -> HTTPResponse {
        guard let actionRequest = try? JSONDecoder().decode(CustomActionRequest.self, from: Data(request.body)) else {
            return errorResponse("Invalid custom action request body")
        }

        NSLog("[CustomAction] action=\(actionRequest.action) label=\(actionRequest.label ?? "nil") identifier=\(actionRequest.identifier ?? "nil")")

        guard let app = RunningApp.getForegroundApp() else {
            return errorResponse("No foreground app")
        }

        // Find the element
        let element: XCUIElement? = if let identifier = actionRequest.identifier {
            app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        } else if let label = actionRequest.label {
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", label)
            ).firstMatch
        } else if let labelContains = actionRequest.labelContains {
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", labelContains)
            ).firstMatch
        } else {
            nil
        }

        guard let element, element.exists else {
            return errorResponse("Element not found")
        }

        // Try to find and invoke the named custom action
        // Use the XCUIElement's accessibility custom actions
        let snapshot = try element.snapshot()
        let customActions = snapshot.customActions
        guard let targetAction = customActions.first(where: { $0.name == actionRequest.action }) else {
            return errorResponse("Custom action '\(actionRequest.action)' not found. Available: \(customActions.map(\.name))")
        }

        targetAction.activate()
        NSLog("[CustomAction] Activated '\(actionRequest.action)'")

        return HTTPResponse(statusCode: .ok)
    }

    private func errorResponse(_ message: String) -> HTTPResponse {
        NSLog("[CustomAction] Error: \(message)")
        let body = (try? JSONEncoder().encode(["error": message])) ?? Data()
        return HTTPResponse(statusCode: .badRequest, body: body)
    }
}
