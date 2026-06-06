import SwiftUI

/// Custom (non-system) SF Symbols bundled in this module's asset catalog
/// (`Resources/Assets.xcassets`).
///
/// System symbols go through ``Symbols`` (the `@SFSymbol` macro) in
/// ClaudeSpyCommon; that macro can only name symbols Apple ships, so an
/// imported `.symbolset` template can't live there. Such symbols are loaded by
/// name from `Bundle.module`, so they must be referenced from *this* module.
/// Keeping every custom-symbol name here means call sites never hard-code the
/// asset string — the same "no string literals" discipline ``Symbols`` enforces
/// for system symbols.
enum CustomSymbol: String {
    /// The Git brand mark — "Git Logo" by Jason Long, licensed under Creative
    /// Commons Attribution (CC BY); full credit and version live in the
    /// `git.logo.svg` template (https://git-scm.com/downloads/logos). Shipped
    /// monochrome so it tints as a template symbol like the other tab-bar
    /// icons. Used by the Git tab.
    case gitLogo = "git.logo"

    /// The symbol as a template ``Image``, loaded from this module's bundle.
    var image: Image { Image(rawValue, bundle: .module) }
}
