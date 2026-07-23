# Third-party licenses

Gallager is built on these open-source projects. Each is used under its own
license; full texts live in the linked repositories. Thank you to all of their
authors and contributors.

> **Maintainers:** the apps surface this list in-app (macOS Settings → About,
> iOS Settings → Licenses). When you change the "Swift packages" or "Data" rows
> below, mirror the change in `ThirdPartyLicense.all`
> (`ClaudeSpyPackage/Sources/ClaudeSpyCommon/Constants/ThirdPartyLicenses.swift`).

## Swift packages (apps + relay)

| Project | License |
|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | MIT (bundles permissively licensed components; see its LICENSE) |
| [Vapor](https://github.com/vapor/vapor) | MIT |
| [vapor/apns](https://github.com/vapor/apns) (APNSwift) | MIT / Apache-2.0 |
| [async-http-client](https://github.com/swift-server/async-http-client) | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | Apache-2.0 |
| [swift-log](https://github.com/apple/swift-log) | Apache-2.0 |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 |
| [swift-dependencies](https://github.com/pointfreeco/swift-dependencies) | MIT |
| [swift-clocks](https://github.com/pointfreeco/swift-clocks) | MIT |
| [swift-concurrency-extras](https://github.com/pointfreeco/swift-concurrency-extras) | MIT |
| [ProjectNavigator](https://github.com/mchakravarty/ProjectNavigator) | Apache-2.0 |
| [textual](https://github.com/gonzalezreal/textual) | MIT |
| [Yams](https://github.com/jpsim/Yams) | MIT |
| [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) (build tool) | MIT |
| [SFSymbolsMacro](https://github.com/gpambrozio/SFSymbolsMacro) (fork of [lukepistrol/SFSymbolsMacro](https://github.com/lukepistrol/SFSymbolsMacro)) | MIT |
| [GitWorkbench](https://github.com/gpambrozio/GitWorkbench) | MIT |

Transitive dependencies from the Apple, Vapor, and Point-Free ecosystems are
Apache-2.0 or MIT; the pinned set is in
[`ClaudeSpyPackage/Package.resolved`](ClaudeSpyPackage/Package.resolved).

## Website

| Project | License |
|---|---|
| [Astro](https://github.com/withastro/astro) | MIT |
| [@astrojs/sitemap](https://github.com/withastro/astro/tree/main/packages/integrations/sitemap) | MIT |

## Data

Emoji keyword data is generated from the
[Unicode CLDR](https://cldr.unicode.org) annotations (Unicode License).
