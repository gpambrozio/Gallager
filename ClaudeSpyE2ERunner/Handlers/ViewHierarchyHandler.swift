import FlyingFox
import XCTest

@MainActor
struct ViewHierarchyHandler: HTTPHandler {
    private let springboardApplication = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let snapshotMaxDepth = 60

    func handleRequest(_ request: FlyingFox.HTTPRequest) async throws -> HTTPResponse {
        do {
            // Parse optional bundleId from request body
            let viewRequest = try? JSONDecoder().decode(ViewHierarchyRequest.self, from: Data(await request.bodyData))

            let foregroundApp: XCUIApplication? = if let bundleId = viewRequest?.bundleId {
                RunningApp.getApp(bundleId: bundleId)
            } else {
                RunningApp.getForegroundApp()
            }

            guard let foregroundApp else {
                NSLog("[ViewHierarchy] No foreground app found, returning springboard hierarchy")
                let springboardHierarchy = try elementHierarchy(xcuiElement: springboardApplication)
                let viewHierarchy = ViewHierarchy(axElement: springboardHierarchy, depth: springboardHierarchy.depth())
                let body = try JSONEncoder().encode(viewHierarchy)
                return HTTPResponse(statusCode: .ok, body: body)
            }

            NSLog("[ViewHierarchy] Snapshot for \(foregroundApp)")
            let appHierarchy = try getHierarchyWithFallback(foregroundApp)

            let statusBars = fullStatusBars(springboardApplication) ?? []
            let rootElement = AXElement(children: [appHierarchy, AXElement(children: statusBars)])
            let viewHierarchy = ViewHierarchy(axElement: rootElement, depth: rootElement.depth())

            let body = try JSONEncoder().encode(viewHierarchy)
            NSLog("[ViewHierarchy] Done, depth=\(viewHierarchy.depth)")
            return HTTPResponse(statusCode: .ok, body: body)
        } catch {
            NSLog("[ViewHierarchy] Error: \(error)")
            let errorBody = try JSONEncoder().encode(["error": error.localizedDescription])
            return HTTPResponse(statusCode: .internalServerError, body: errorBody)
        }
    }

    private func getHierarchyWithFallback(_ element: XCUIElement) throws -> AXElement {
        do {
            let hierarchy = try elementHierarchy(xcuiElement: element)
            if hierarchy.depth() < snapshotMaxDepth {
                return hierarchy
            }

            let count = try element.snapshot().children.count
            var children: [AXElement] = []
            for i in 0 ..< count {
                let child = element.descendants(matching: .other).element(boundBy: i).firstMatch
                try children.append(getHierarchyWithFallback(child))
            }
            var result = hierarchy
            result.children = children
            return result
        } catch {
            guard error.localizedDescription.contains("Error kAXErrorIllegalArgument") else {
                throw error
            }

            NSLog("[ViewHierarchy] kAXErrorIllegalArgument, applying maxDepth swizzle")
            AXClientSwizzler.overwriteDefaultParameters["maxDepth"] = snapshotMaxDepth

            let recoveryElement = try findRecoveryElement(element.children(matching: .any).firstMatch)
            let hierarchy = try getHierarchyWithFallback(recoveryElement)

            if let app = element as? XCUIApplication {
                let keyboard = keyboardHierarchy(app)
                let alerts = alertHierarchy(app)
                return AXElement(children: [keyboard, alerts, hierarchy].compactMap { $0 })
            }

            return hierarchy
        }
    }

    private func findRecoveryElement(_ element: XCUIElement) throws -> XCUIElement {
        if try element.snapshot().children.count > 1 {
            return element
        }
        let firstOther = element.children(matching: .other).firstMatch
        if firstOther.exists {
            return try findRecoveryElement(firstOther)
        }
        return element
    }

    private func keyboardHierarchy(_ app: XCUIApplication) -> AXElement? {
        guard app.keyboards.firstMatch.exists else { return nil }
        return try? elementHierarchy(xcuiElement: app.keyboards.firstMatch)
    }

    private func alertHierarchy(_ app: XCUIApplication) -> AXElement? {
        guard app.alerts.firstMatch.exists else { return nil }
        return try? elementHierarchy(xcuiElement: app.alerts.firstMatch)
    }

    private func fullStatusBars(_ app: XCUIApplication) -> [AXElement]? {
        guard app.statusBars.firstMatch.exists else { return nil }
        return try? app.statusBars.allElementsBoundByIndex.map { try elementHierarchy(xcuiElement: $0) }
    }

    private func elementHierarchy(xcuiElement: XCUIElement) throws -> AXElement {
        let snapshotDictionary = try xcuiElement.snapshot().dictionaryRepresentation
        return AXElement(snapshotDictionary)
    }
}
