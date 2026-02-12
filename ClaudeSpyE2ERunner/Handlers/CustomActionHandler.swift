import FlyingFox
import XCTest

@MainActor
struct CustomActionHandler: HTTPHandler {
    func handleRequest(_ request: FlyingFox.HTTPRequest) async throws -> HTTPResponse {
        guard let actionRequest = try? JSONDecoder().decode(CustomActionRequest.self, from: Data(await request.bodyData)) else {
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

        // Get the snapshot and cast to NSObject so we can use ObjC runtime
        let snapshot = try element.snapshot()
        guard let snapshotObj = snapshot as? NSObject else {
            return errorResponse("Snapshot is not an NSObject")
        }

        // Try to invoke the custom action via ObjC runtime.
        // XCUIElementSnapshot's customActions property is not in the public protocol
        // but exists on the concrete class.
        let customActionsSelector = NSSelectorFromString("customActions")
        if snapshotObj.responds(to: customActionsSelector),
           let customActions = snapshotObj.perform(customActionsSelector)?.takeUnretainedValue() as? [NSObject]
        {
            let nameSelector = NSSelectorFromString("name")
            let activateSelector = NSSelectorFromString("activate")
            for action in customActions {
                if action.responds(to: nameSelector),
                   let name = action.perform(nameSelector)?.takeUnretainedValue() as? String,
                   name == actionRequest.action,
                   action.responds(to: activateSelector)
                {
                    action.perform(activateSelector)
                    NSLog("[CustomAction] Activated '\(actionRequest.action)' via ObjC runtime")
                    return HTTPResponse(statusCode: .ok)
                }
            }

            let available = customActions.compactMap { action -> String? in
                guard action.responds(to: nameSelector) else { return nil }
                return action.perform(nameSelector)?.takeUnretainedValue() as? String
            }
            return errorResponse("Custom action '\(actionRequest.action)' not found. Available: \(available)")
        }

        return errorResponse("No custom actions available on element")
    }

    private func errorResponse(_ message: String) -> HTTPResponse {
        NSLog("[CustomAction] Error: \(message)")
        let body = (try? JSONEncoder().encode(["error": message])) ?? Data()
        return HTTPResponse(statusCode: .badRequest, body: body)
    }
}
