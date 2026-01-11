# Swift Patterns Reference

Code examples and patterns used in ClaudeSpy. Reference this when implementing new features.

## SwiftUI State Management (MV Pattern)

### @Observable with @State

```swift
@Observable
class UserSettings {
    var theme: Theme = .light
    var fontSize: Double = 16.0
}

@MainActor
struct SettingsView: View {
    @State private var settings = UserSettings()

    var body: some View {
        VStack {
            Text("Font Size: \(settings.fontSize)")

            // For bindings, use @Bindable
            @Bindable var settings = settings
            Slider(value: $settings.fontSize, in: 10...30)
        }
    }
}
```

### Environment Sharing

```swift
@MainActor
struct ContentView: View {
    @State private var userSettings = UserSettings()

    var body: some View {
        NavigationStack {
            MainView()
                .environment(userSettings)
        }
    }
}

@MainActor
struct MainView: View {
    @Environment(UserSettings.self) private var settings

    var body: some View {
        Text("Current theme: \(settings.theme)")
    }
}
```

### Async Operations with .task

```swift
@Observable
class DataModel {
    var items: [Item] = []
    var isLoading = false

    func loadData() async throws {
        isLoading = true
        defer { isLoading = false }

        try await Task.sleep(for: .seconds(1))
        items = try await fetchItems()
    }
}

@MainActor
struct ItemListView: View {
    @State private var model = DataModel()

    var body: some View {
        List(model.items) { item in
            Text(item.name)
        }
        .overlay {
            if model.isLoading {
                ProgressView()
            }
        }
        .task {
            // Automatically cancels when view disappears
            do {
                try await model.loadData()
            } catch {
                // Handle error
            }
        }
        .refreshable {
            try? await model.loadData()
        }
    }
}
```

## Sendable Conformance (Swift 6)

### Value Types

```swift
struct UserData: Sendable {
    let id: UUID
    let name: String
}
```

### Classes (must be final with immutable properties)

```swift
final class Configuration: Sendable {
    let apiKey: String
    let endpoint: URL

    init(apiKey: String, endpoint: URL) {
        self.apiKey = apiKey
        self.endpoint = endpoint
    }
}
```

### @Observable with Sendable

```swift
@Observable
final class UserModel: Sendable {
    var name: String = ""
    var age: Int = 0
}
```

### Thread-safe @unchecked Sendable

```swift
final class Cache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    func get(_ key: String) -> Any? {
        lock.withLock { storage[key] }
    }
}
```

### @Sendable Closures

```swift
func processInBackground(completion: @Sendable @escaping (Result<Data, Error>) -> Void) {
    Task {
        completion(.success(data))
    }
}
```

## Testing Patterns (Swift Testing)

```swift
import Testing

@Test func userCanLogin() async throws {
    let service = AuthService()
    let result = try await service.login(username: "test", password: "pass")
    #expect(result.isSuccess)
    #expect(result.user.name == "Test User")
}

@Test("User sees error with invalid credentials")
func invalidLogin() async throws {
    let service = AuthService()
    await #expect(throws: AuthError.self) {
        try await service.login(username: "", password: "")
    }
}
```

**Key features:**
- `@Test` - marks test functions
- `@Suite` - groups related tests
- `#expect` - validates conditions
- `#require` - stops on failure
- Parameterized tests with arguments

## Cursor Positioning Strategy

`capturePaneWithPositioning()` generates ANSI escape sequences:

```swift
positionedContent += "\u{1b}[H"  // Home
for (index, line) in lines {
    positionedContent += "\u{1b}[\(index + 1);1H"  // Row, column 1
    positionedContent += "\u{1b}[2K"  // Clear line
    positionedContent += line
}
positionedContent += "\u{1b}[\(cursorY + 1);\(cursorX + 1)H"  // Final cursor
```

## Entitlements Reference

| Capability | Key | Value |
|------------|-----|-------|
| HealthKit | `com.apple.developer.healthkit` | `<true/>` |
| CloudKit | `com.apple.developer.icloud-services` | `<array><string>CloudKit</string></array>` |
| Push | `aps-environment` | `development` or `production` |
| App Groups | `com.apple.security.application-groups` | `<array><string>group.id</string></array>` |
| Keychain | `keychain-access-groups` | `<array><string>$(AppIdentifierPrefix)bundle.id</string></array>` |
| Background | `com.apple.developer.background-modes` | `<array><string>mode-name</string></array>` |

Edit `Config/ClaudeSpy.entitlements` to add capabilities.
