import Foundation

/// Protocol abstracting UserDefaults-style key-value persistence.
///
/// Both `UserDefaults` and ``InMemoryDefaults`` conform to this protocol,
/// allowing E2E tests to inject in-memory storage so they never touch the
/// developer's real UserDefaults.
public protocol UserDefaultsStorable: Sendable {
    func string(forKey defaultName: String) -> String?
    func integer(forKey defaultName: String) -> Int
    func double(forKey defaultName: String) -> Double
    func bool(forKey defaultName: String) -> Bool
    func data(forKey defaultName: String) -> Data?
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}
