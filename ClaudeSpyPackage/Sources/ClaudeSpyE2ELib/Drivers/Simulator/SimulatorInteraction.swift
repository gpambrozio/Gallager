import CoreGraphics
import Foundation
import Logging

/// Low-level interaction with the iOS Simulator (tap, type, swipe)
enum SimulatorInteraction {
    private static let logger = Logger(label: "e2e.sim-interaction")
    private static let processRunner = ProcessRunner()

    /// Tap at absolute screen coordinates using CGEvent
    static func tap(at point: CGPoint) async throws {
        logger.info("Tapping at screen coordinates: (\(point.x), \(point.y))")

        let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )

        mouseDown?.post(tap: .cghidEventTap)
        // Small delay between down and up for reliability
        try await Task.sleep(for: .milliseconds(50))
        mouseUp?.post(tap: .cghidEventTap)
    }

    /// Type text into the Simulator using AppleScript keystroke
    static func type(text: String, slow: Bool = false) async throws {
        logger.info("Typing text: \"\(text)\" (slow: \(slow))")

        // Activate Simulator first
        let activateScript = """
        tell application "Simulator" to activate
        delay 0.3
        """
        try await runAppleScript(activateScript)

        if slow {
            // Type one character at a time with delay
            for char in text {
                let charScript = """
                tell application "System Events"
                    keystroke "\(escapeForAppleScript(String(char)))"
                end tell
                delay 0.1
                """
                try await runAppleScript(charScript)
            }
        } else {
            let typeScript = """
            tell application "System Events"
                keystroke "\(escapeForAppleScript(text))"
            end tell
            """
            try await runAppleScript(typeScript)
        }
    }

    /// Perform a swipe gesture (using mouse drag)
    static func swipe(from start: CGPoint, to end: CGPoint, duration: TimeInterval = 0.3) async throws {
        logger.info("Swiping from (\(start.x), \(start.y)) to (\(end.x), \(end.y))")

        let steps = Int(duration / 0.016) // ~60fps
        let dx = (end.x - start.x) / CGFloat(steps)
        let dy = (end.y - start.y) / CGFloat(steps)

        // Mouse down at start
        let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: start,
            mouseButton: .left
        )
        mouseDown?.post(tap: .cghidEventTap)

        // Drag through intermediate points
        for i in 1...steps {
            let point = CGPoint(
                x: start.x + dx * CGFloat(i),
                y: start.y + dy * CGFloat(i)
            )
            let drag = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: point,
                mouseButton: .left
            )
            drag?.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(16))
        }

        // Mouse up at end
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: end,
            mouseButton: .left
        )
        mouseUp?.post(tap: .cghidEventTap)
    }

    /// Ensure Simulator is in Point Accurate mode (Cmd+2) for 1:1 coordinate mapping
    static func ensurePointAccurateMode() async throws {
        let script = """
        tell application "Simulator" to activate
        delay 0.3
        tell application "System Events"
            keystroke "2" using command down
        end tell
        delay 0.3
        """
        try await runAppleScript(script)
    }

    // MARK: - Private Helpers

    static func runAppleScript(_ source: String) async throws {
        let result = try await processRunner.run(
            "/usr/bin/osascript",
            arguments: ["-e", source]
        )
        if !result.isSuccess {
            let message = result.stderrString.isEmpty ? "Unknown osascript error" : result.stderrString
            logger.error("AppleScript error: \(message)")
            throw SimulatorDriverError.appleScriptFailed(message)
        }
    }

    private static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Errors specific to the Simulator driver
public enum SimulatorDriverError: Error, LocalizedError {
    case simulatorNotRunning
    case appNotInstalled(bundleId: String)
    case appleScriptFailed(String)
    case elementNotFound(ElementQuery)
    case noContentGroup
    case screenshotFailed(String)

    public var errorDescription: String? {
        switch self {
        case .simulatorNotRunning:
            "iOS Simulator is not running"
        case let .appNotInstalled(bundleId):
            "App not installed: \(bundleId)"
        case let .appleScriptFailed(message):
            "AppleScript failed: \(message)"
        case let .elementNotFound(query):
            "Element not found: \(query)"
        case .noContentGroup:
            "Could not find iOS content group in Simulator"
        case let .screenshotFailed(reason):
            "Screenshot failed: \(reason)"
        }
    }
}
