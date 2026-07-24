import Foundation

/// A single third-party dependency credited in the in-app acknowledgements
/// (macOS Settings → About, iOS Settings → Licenses).
///
/// The full license texts live in each project's linked repository; this only
/// carries what the UI needs to render an attribution row.
public struct ThirdPartyLicense: Identifiable, Hashable, Sendable {
    /// Where in the project a dependency is used. The acknowledgement views
    /// render one section per case, in `allCases` order, with the raw value
    /// as the section title.
    public enum Usage: String, CaseIterable, Sendable {
        case apps = "Apps & Relay"
        case buildTools = "Build Tools"
        case website = "Website"
    }

    /// Display name of the project (matches the label in `THIRD_PARTY_LICENSES.md`).
    public let name: String
    /// Short SPDX-style license identifier shown in the UI (for example `MIT`).
    public let license: String
    /// Canonical repository / homepage URL where the full license text lives.
    public let url: URL
    /// Where the dependency is used, deciding the section it appears under.
    public let usage: Usage

    public var id: String {
        name
    }

    public init(name: String, license: String, url: URL, usage: Usage = .apps) {
        self.name = name
        self.license = license
        self.url = url
        self.usage = usage
    }
}

public extension ThirdPartyLicense {
    /// Introductory blurb shown above the acknowledgement rows on both
    /// platforms (mirrors the opening paragraph of `THIRD_PARTY_LICENSES.md`).
    static let intro = "Gallager is built on these open-source projects. Each is used under its own license; full texts live in the linked repositories. Thank you to all of their authors and contributors."

    // swiftlint:disable custom_no_number_decimals
    // (License identifiers below are version-like SPDX strings such as
    // "Apache-2.0", not decimal literals the numeric rule should flag.)
    /// Every third-party project Gallager uses — in the apps and relay, as
    /// build tooling, or on the website — credited regardless of whether it
    /// ships in a binary.
    ///
    /// Source of truth is [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md);
    /// keep this list in sync with the tables there.
    static let all: [ThirdPartyLicense] = [
        ThirdPartyLicense(name: "SwiftTerm", license: "MIT", url: URL(staticString: "https://github.com/migueldeicaza/SwiftTerm")),
        ThirdPartyLicense(name: "Sparkle", license: "MIT", url: URL(staticString: "https://github.com/sparkle-project/Sparkle")),
        ThirdPartyLicense(name: "Vapor", license: "MIT", url: URL(staticString: "https://github.com/vapor/vapor")),
        ThirdPartyLicense(name: "vapor/apns (APNSwift)", license: "MIT / Apache-2.0", url: URL(staticString: "https://github.com/vapor/apns")),
        ThirdPartyLicense(name: "async-http-client", license: "Apache-2.0", url: URL(staticString: "https://github.com/swift-server/async-http-client")),
        ThirdPartyLicense(name: "swift-crypto", license: "Apache-2.0", url: URL(staticString: "https://github.com/apple/swift-crypto")),
        ThirdPartyLicense(name: "swift-log", license: "Apache-2.0", url: URL(staticString: "https://github.com/apple/swift-log")),
        ThirdPartyLicense(name: "swift-argument-parser", license: "Apache-2.0", url: URL(staticString: "https://github.com/apple/swift-argument-parser")),
        ThirdPartyLicense(name: "swift-dependencies", license: "MIT", url: URL(staticString: "https://github.com/pointfreeco/swift-dependencies")),
        ThirdPartyLicense(name: "swift-clocks", license: "MIT", url: URL(staticString: "https://github.com/pointfreeco/swift-clocks")),
        ThirdPartyLicense(name: "swift-concurrency-extras", license: "MIT", url: URL(staticString: "https://github.com/pointfreeco/swift-concurrency-extras")),
        ThirdPartyLicense(name: "ProjectNavigator", license: "Apache-2.0", url: URL(staticString: "https://github.com/mchakravarty/ProjectNavigator")),
        ThirdPartyLicense(name: "textual", license: "MIT", url: URL(staticString: "https://github.com/gonzalezreal/textual")),
        ThirdPartyLicense(name: "Yams", license: "MIT", url: URL(staticString: "https://github.com/jpsim/Yams")),
        ThirdPartyLicense(name: "SFSymbolsMacro", license: "MIT", url: URL(staticString: "https://github.com/gpambrozio/SFSymbolsMacro")),
        ThirdPartyLicense(name: "GitWorkbench", license: "MIT", url: URL(staticString: "https://github.com/gpambrozio/GitWorkbench")),
        ThirdPartyLicense(name: "Unicode CLDR emoji data", license: "Unicode License", url: URL(staticString: "https://cldr.unicode.org")),
        ThirdPartyLicense(name: "SwiftFormat", license: "MIT", url: URL(staticString: "https://github.com/nicklockwood/SwiftFormat"), usage: .buildTools),
        ThirdPartyLicense(name: "Astro", license: "MIT", url: URL(staticString: "https://github.com/withastro/astro"), usage: .website),
        ThirdPartyLicense(name: "@astrojs/sitemap", license: "MIT", url: URL(staticString: "https://github.com/withastro/astro/tree/main/packages/integrations/sitemap"), usage: .website),
    ]
    // swiftlint:enable custom_no_number_decimals

    /// The credited projects used in `usage`, in declaration order.
    static func all(in usage: Usage) -> [ThirdPartyLicense] {
        all.filter { $0.usage == usage }
    }
}
