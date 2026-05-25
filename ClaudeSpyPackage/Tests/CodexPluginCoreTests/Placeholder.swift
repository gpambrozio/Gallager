// Placeholder so SPM resolves the CodexPluginCoreTests bundle even when
// the real tests below are excluded by a `#if` guard. Will be deleted in a
// follow-up commit once the actual tests land.
import Testing

@Suite("CodexPluginCorePlaceholder")
struct CodexPluginCorePlaceholderTests {
    @Test("module exists")
    func moduleExists() { }
}
