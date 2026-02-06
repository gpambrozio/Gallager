@_exported import ClaudeSpyCommon
import Foundation
import ObjectiveC

/// iOS-specific extension adding event response tracking to SessionStore.
///
/// This allows the interactive response flow (permission requests, etc.) to persist
/// responses across navigation. macOS viewer mode doesn't need this functionality.
extension SessionStore {
    // MARK: - Event Response Storage

    private static var eventResponsesKey: UInt8 = 0

    /// Access the event responses dictionary, creating it on first access.
    private var eventResponses: EventResponseStorage {
        if let existing = objc_getAssociatedObject(self, &Self.eventResponsesKey) as? EventResponseStorage {
            return existing
        }
        let storage = EventResponseStorage()
        objc_setAssociatedObject(self, &Self.eventResponsesKey, storage, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return storage
    }

    /// Get the stored response for an event, if any
    public func response(for eventId: UUID) -> ResponseType? {
        eventResponses.responses[eventId]
    }

    /// Store a response for an event
    public func setResponse(_ response: ResponseType?, for eventId: UUID) {
        if let response {
            eventResponses.responses[eventId] = response
        } else {
            eventResponses.responses.removeValue(forKey: eventId)
        }
    }
}

/// Storage wrapper for event responses (used via associated objects in the extension).
private final class EventResponseStorage {
    var responses: [UUID: ResponseType] = [:]
}
