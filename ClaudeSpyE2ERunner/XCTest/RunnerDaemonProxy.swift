import Foundation

@MainActor
final class RunnerDaemonProxy {
    private let proxy: NSObject

    init() {
        guard let clazz = NSClassFromString("XCTRunnerDaemonSession") else {
            fatalError("XCTRunnerDaemonSession not found — XCTest private API may have changed")
        }
        let selector = NSSelectorFromString("sharedSession")
        let imp = clazz.method(for: selector)
        typealias Method = @convention(c) (AnyClass, Selector) -> NSObject
        let method = unsafeBitCast(imp, to: Method.self)
        let session = method(clazz, selector)

        guard let daemonProxy = session
            .perform(NSSelectorFromString("daemonProxy"))?
            .takeUnretainedValue() as? NSObject
        else {
            fatalError("XCTRunnerDaemonSession.daemonProxy not found — XCTest private API may have changed")
        }
        proxy = daemonProxy
    }

    func send(string: String, typingFrequency: Int = 10) async throws {
        let selector = NSSelectorFromString("_XCT_sendString:maximumFrequency:completion:")
        let imp = proxy.method(for: selector)
        typealias Method = @convention(c) (NSObject, Selector, NSString, Int, @escaping @Sendable (Error?) -> Void) -> Void
        let method = unsafeBitCast(imp, to: Method.self)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            method(proxy, selector, string as NSString, typingFrequency) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func synthesize(eventRecord: EventRecord) async throws {
        let selector = NSSelectorFromString("_XCT_synthesizeEvent:completion:")
        let imp = proxy.method(for: selector)
        typealias Method = @convention(c) (NSObject, Selector, NSObject, @escaping @Sendable (Error?) -> Void) -> Void
        let method = unsafeBitCast(imp, to: Method.self)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            method(proxy, selector, eventRecord.eventRecord) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
