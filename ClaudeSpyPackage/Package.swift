// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Packages only consumed by Apple-platform targets (macOS app, iOS app, E2E,
/// GallagerCLI). They are hidden from the Linux SPM graph so the relay's Docker
/// build doesn't waste time resolving them — and so a future bump that requires
/// a newer Swift toolchain doesn't block deploys. The Linux relay only needs
/// Vapor / VaporAPNS / swift-crypto / swift-log / swift-dependencies / Yams (no,
/// Yams is Apple-only via GallagerCLI) — anything else here would be dead weight
/// on the relay build.
///
/// (ProjectNavigator 1.7.0 was the canary: it required Swift 6.2 while the
/// jammy Docker image then shipped Swift 6.1, blocking `swift package resolve`.
/// The relay now pins swift:6.3-jammy — bumped so swift-dependencies' package
/// traits (declared only in its Swift 6.3 manifest) resolve on Linux too — but
/// the same rule holds: keep Apple-only deps off the Linux graph.)
func macOnlyDependencies() -> [Package.Dependency] {
    #if os(macOS)
        return [
            .package(url: "https://github.com/gpambrozio/SFSymbolsMacro", branch: "swift-syntax-602"),
            .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.13.0"),
            .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
            .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
            .package(url: "https://github.com/mchakravarty/ProjectNavigator", exact: "1.10.1"),
            .package(url: "https://github.com/gonzalezreal/textual", from: "0.5.0"),
            .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
            .package(url: "https://github.com/gpambrozio/GitWorkbench", exact: "1.6.0"),
        ]
    #else
        return []
    #endif
}

/// `#if os(macOS)` does not work *inside* a Target dependency array literal
/// (SPM's manifest parser rejects it as `expected expression in container
/// literal`). So per-target helpers return the slice of Apple-only deps for each
/// consumer; the target's `dependencies:` array concatenates with `+`.
func macOnlyTargetDependencies(for target: String) -> [Target.Dependency] {
    #if os(macOS)
        switch target {
        case "ClaudeSpyCommon":
            return [.sfSymbolsMacro, .swiftTerm]
        case "ClaudeSpyFeature":
            return [.swiftTerm]
        case "ClaudeSpyServerFeature":
            return [.swiftTerm, .sparkle, .textual, .projectNavigator, .files, .gitWorkbench, .gitWorkbenchGitKit]
        case "ClaudeSpyServerFeatureTests":
            return [.swiftTerm]
        case "ClaudeSpyE2E":
            return [.argumentParser]
        case "GallagerCLI":
            return [.argumentParser, .yams]
        default:
            return []
        }
    #else
        return []
    #endif
}

extension Target.Dependency {
    /// Cross-platform packages — needed by the Linux relay deployable.
    static var vapor: Self {
        .product(name: "Vapor", package: "vapor")
    }

    static var vaporAPNS: Self {
        .product(name: "VaporAPNS", package: "apns")
    }

    static var crypto: Self {
        .product(name: "Crypto", package: "swift-crypto")
    }

    static var logging: Self {
        .product(name: "Logging", package: "swift-log")
    }

    static var dependencies: Self {
        .product(name: "Dependencies", package: "swift-dependencies")
    }

    static var dependenciesMacros: Self {
        .product(name: "DependenciesMacros", package: "swift-dependencies")
    }

    static var dependenciesTestSupport: Self {
        .product(name: "DependenciesTestSupport", package: "swift-dependencies")
    }

    static var clocks: Self {
        .product(name: "Clocks", package: "swift-clocks")
    }

    static var concurrencyExtras: Self {
        .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras")
    }

    // Apple-platform-only packages. The static vars are gated behind
    // `#if os(macOS)` so the manifest itself compiles on Linux (where the
    // referenced packages aren't declared in the dependencies graph). Any
    // target dependency arrays that reference these must use the same gate.
    #if os(macOS)
        static var sfSymbolsMacro: Self {
            .product(name: "SFSymbolsMacro", package: "SFSymbolsMacro")
        }

        static var swiftTerm: Self {
            .product(name: "SwiftTerm", package: "SwiftTerm")
        }

        static var sparkle: Self {
            .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))
        }

        static var textual: Self {
            .product(name: "Textual", package: "textual")
        }

        static var argumentParser: Self {
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        }

        static var yams: Self {
            .product(name: "Yams", package: "Yams")
        }

        static var projectNavigator: Self {
            .product(name: "ProjectNavigator", package: "ProjectNavigator")
        }

        static var files: Self {
            .product(name: "Files", package: "ProjectNavigator")
        }

        /// GitWorkbench — the dependency-free SwiftUI git-changes component.
        static var gitWorkbench: Self {
            .product(name: "GitWorkbench", package: "GitWorkbench")
        }

        /// GitWorkbenchGitKit — the ready-made provider backed by the system
        /// `git` CLI (used as the Git tab's `liveValue`).
        static var gitWorkbenchGitKit: Self {
            .product(name: "GitWorkbenchGitKit", package: "GitWorkbench")
        }
    #endif

    static var claudeSpyNetworking: Self {
        "ClaudeSpyNetworking"
    }

    static var gallagerPluginProtocol: Self {
        "GallagerPluginProtocol"
    }

    static var claudeCodePluginCore: Self {
        "ClaudeCodePluginCore"
    }

    static var codexPluginCore: Self {
        "CodexPluginCore"
    }

    static var claudeSpyCommon: Self {
        "ClaudeSpyCommon"
    }

    /// Foundation-only emoji table + keyword search, shared by the picker UI
    /// (ClaudeSpyCommon) and the CLI (Gallager). No resources — the data is
    /// baked into source (no Bundle.module for the bare GallagerCLI copied
    /// into the app bundle). NOTE: because this target is shared by the app
    /// and the CLI executable, Xcode links it as a dynamic framework; the
    /// copy phase adds an rpath so the bundled CLI finds it — see
    /// docs/superpowers/specs/2026-07-03-emoji-data-shipping-design.md
    /// before restructuring.
    static var gallagerEmoji: Self {
        "GallagerEmoji"
    }

    static var claudeSpyEncryption: Self {
        "ClaudeSpyEncryption"
    }

    static var claudeSpyFeature: Self {
        "ClaudeSpyFeature"
    }

    static var claudeSpyServerFeature: Self {
        "ClaudeSpyServerFeature"
    }

    static var claudeSpyExternalServer: Self {
        "ClaudeSpyExternalServer"
    }

    static var claudeSpyExternalServerLib: Self {
        "ClaudeSpyExternalServerLib"
    }

    static var claudeSpyE2ELib: Self {
        "ClaudeSpyE2ELib"
    }
}

/// Products, dependencies, and targets are extracted into typed top-level `let`s
/// so the manifest type-checker can resolve each in isolation. Inlining all three
/// inside the `Package(...)` call exceeds the Linux Swift 6.x type-checker
/// heuristic and fails the relay's Docker build with "the compiler is unable to
/// type-check this expression in reasonable time."
let products: [Product] = [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
        name: "ClaudeSpyNetworking",
        targets: ["ClaudeSpyNetworking"]
    ),
    .library(
        name: "GallagerPluginProtocol",
        targets: ["GallagerPluginProtocol"]
    ),
    .library(
        name: "ClaudeCodePluginCore",
        targets: ["ClaudeCodePluginCore"]
    ),
    .library(
        name: "CodexPluginCore",
        targets: ["CodexPluginCore"]
    ),
    .library(
        name: "ClaudeSpyCommon",
        targets: ["ClaudeSpyCommon"]
    ),
    .library(
        name: "GallagerEmoji",
        targets: ["GallagerEmoji"]
    ),
    .library(
        name: "ClaudeSpyEncryption",
        targets: ["ClaudeSpyEncryption"]
    ),
    .library(
        name: "ClaudeSpyFeature",
        targets: ["ClaudeSpyFeature"]
    ),
    .library(
        name: "ClaudeSpyServerFeature",
        targets: ["ClaudeSpyServerFeature"]
    ),
    .executable(
        name: "ClaudeSpyExternalServer",
        targets: ["ClaudeSpyExternalServer"]
    ),
    .library(
        name: "ClaudeSpyExternalServerLib",
        targets: ["ClaudeSpyExternalServerLib"]
    ),
    .executable(
        name: "ClaudeSpyE2E",
        targets: ["ClaudeSpyE2E"]
    ),
    .executable(
        name: "GallagerCLI",
        targets: ["GallagerCLI"]
    ),
    .executable(
        name: "EchoPluginSidecar",
        targets: ["EchoPluginSidecar"]
    ),
]

let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.53.0"),
    .package(url: "https://github.com/vapor/vapor", from: "4.0.0"),
    .package(url: "https://github.com/vapor/apns.git", from: "4.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    // Only the `Clocks` trait is enabled — the app's sole built-in dependency
    // value is `\.continuousClock` (Clocks gates that). Dropping the default
    // `CombineSchedulers`/`Foundation`/`FoundationNetworking` traits removes the
    // combine-schedulers package from the graph. Requires a Swift 6.3+ toolchain
    // (the only swift-dependencies manifest that declares traits is its 6.3 one);
    // the relay Dockerfile is pinned to swift:6.3 to match.
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.14.1", traits: ["Clocks"]),
    .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.4"),
    .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.0.0"),
] + macOnlyDependencies()

let targets: [Target] = [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.

    // Platform-agnostic networking models (no SwiftUI dependencies)
    // Used by external server on Linux and by Apple platform apps
    .target(
        name: "ClaudeSpyNetworking",
        dependencies: [
            .claudeSpyEncryption,
        ]
    ),
    // The durable plugin contract: PluginCore / PluginHost / IngressFrame /
    // value types / manifest. Cross-platform; depends only on networking models.
    .target(
        name: "GallagerPluginProtocol",
        dependencies: [
            .claudeSpyNetworking,
        ]
    ),
    .target(
        name: "ClaudeSpyCommon",
        dependencies: [
            .claudeSpyNetworking,
            .claudeSpyEncryption,
            .gallagerEmoji,
            .logging,
        ] + macOnlyTargetDependencies(for: "ClaudeSpyCommon")
    ),
    // Foundation-only emoji table + keyword search (issue #630). Shared by the
    // picker UI and the CLI so "trash" → 🗑️ everywhere. Data is generated by
    // scripts/generate-emoji-data.py into EmojiData.swift (no runtime bundle).
    .target(
        name: "GallagerEmoji"
    ),
    // Per-agent plugin cores. Each conforms to PluginCore and owns all
    // agent-specific logic (scanner, installer, translator, keystrokes,
    // settings). Only the registry in ClaudeSpyServerFeature names these
    // concrete types — the dispatcher/runtime stay agent-neutral (spec §4.1).
    .target(
        name: "ClaudeCodePluginCore",
        dependencies: [
            .gallagerPluginProtocol,
            .claudeSpyNetworking,
            .claudeSpyCommon,
            .dependencies,
            .dependenciesMacros,
        ]
    ),
    .target(
        name: "CodexPluginCore",
        dependencies: [
            .gallagerPluginProtocol,
            .claudeSpyNetworking,
            .claudeSpyCommon,
            // Shares the migrated Claude hook-parsing types (HookAction/HookEvent
            // /*Body/ClaudeCodeTool/AnyCodable + AskUserQuestion keystroke helper);
            // Codex hook payloads parse through the same enum (spec §16).
            .claudeCodePluginCore,
            .dependencies,
            .dependenciesMacros,
        ]
    ),
    // End-to-end encryption module using CryptoKit (Apple) / Swift Crypto (Linux)
    .target(
        name: "ClaudeSpyEncryption",
        dependencies: [
            .crypto,
            .dependencies,
            .dependenciesMacros,
        ]
    ),
    .target(
        name: "ClaudeSpyFeature",
        dependencies: [
            .claudeSpyNetworking,
            .claudeSpyCommon,
            .claudeSpyEncryption,
            .dependencies,
            .dependenciesMacros,
        ] + macOnlyTargetDependencies(for: "ClaudeSpyFeature")
    ),
    .target(
        name: "ClaudeSpyServerFeature",
        dependencies: [
            .claudeSpyCommon,
            .claudeSpyEncryption,
            .gallagerPluginProtocol,
            .claudeCodePluginCore,
            .codexPluginCore,
            .vapor,
            .dependencies,
            .dependenciesMacros,
        ] + macOnlyTargetDependencies(for: "ClaudeSpyServerFeature"),
        resources: [
            .process("Resources"),
            // Bundled plugin manifests/assets, copied verbatim so the per-plugin
            // directory structure (plugins/<id>/plugin.json + assets) survives
            // into Gallager.app/Contents/Resources (spec §9). `.copy` (not
            // `.process`) keeps the tree and avoids flattening same-named files.
            .copy("PluginBundles/plugins"),
        ]
    ),
    // External server library (all business logic, importable by tests and E2E)
    .target(
        name: "ClaudeSpyExternalServerLib",
        dependencies: [
            .claudeSpyNetworking,
            .claudeSpyEncryption,
            .vapor,
            .vaporAPNS,
        ]
    ),
    // External server executable (thin wrapper around library)
    .executableTarget(
        name: "ClaudeSpyExternalServer",
        dependencies: [
            .claudeSpyExternalServerLib,
            .vapor,
        ],
        swiftSettings: [
            // Match Docker build flags to catch issues locally before deployment
            .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
        ]
    ),
    // E2E test coordinator library
    .target(
        name: "ClaudeSpyE2ELib",
        dependencies: [
            .claudeSpyNetworking,
            .claudeSpyServerFeature,
            .claudeSpyExternalServerLib,
            // The DSL hook-delivery step builds length-prefixed `IngressFrame`s
            // (and, for the round-trip scenarios, `EchoDirective` payloads) to
            // write to the app's ingress socket — the same codec the app reads.
            .gallagerPluginProtocol,
            .vapor,
            .logging,
        ],
        resources: [
            .copy("Scenarios/Scripts"),
            .copy("Scenarios/SampleFiles"),
        ]
    ),
    // E2E test coordinator executable
    .executableTarget(
        name: "ClaudeSpyE2E",
        dependencies: [
            .claudeSpyE2ELib,
        ] + macOnlyTargetDependencies(for: "ClaudeSpyE2E")
    ),
    // CLI for controlling Gallager from the command line (API + editor).
    // Bundled inside the app and invoked via the VISUAL environment variable.
    .executableTarget(
        name: "GallagerCLI",
        dependencies: [
            .gallagerEmoji,
        ] + macOnlyTargetDependencies(for: "GallagerCLI"),
        path: "Sources/Gallager"
    ),
    // Real out-of-process echo sidecar for integration tests (spec §17.3).
    // Reads Content-Length-framed JSON-RPC on stdin; answers each method and
    // emits notifications to stdout. Not gated by #if DEBUG so it ships in
    // Release builds (the executable is a separate product, not linked into
    // the app). Used by EchoPluginSidecarIntegrationTests to prove the full
    // spawn → transport → RPC pipeline through SidecarSupervisor.
    .executableTarget(
        name: "EchoPluginSidecar",
        dependencies: [.gallagerPluginProtocol, .claudeSpyNetworking, .logging],
        path: "Sources/EchoPluginSidecar"
    ),
    .testTarget(
        name: "ClaudeSpyNetworkingTests",
        dependencies: [
            "ClaudeSpyNetworking",
        ]
    ),
    .testTarget(
        name: "GallagerPluginProtocolTests",
        dependencies: [
            .gallagerPluginProtocol,
            .claudeSpyNetworking,
        ]
    ),
    .testTarget(
        name: "ClaudeCodePluginCoreTests",
        dependencies: [
            .claudeCodePluginCore,
            .gallagerPluginProtocol,
            .dependenciesTestSupport,
        ]
    ),
    .testTarget(
        name: "CodexPluginCoreTests",
        dependencies: [
            .codexPluginCore,
            .claudeCodePluginCore,
            .gallagerPluginProtocol,
            .dependenciesTestSupport,
        ]
    ),
    .testTarget(
        name: "GallagerEmojiTests",
        dependencies: [
            .gallagerEmoji,
        ]
    ),
    .testTarget(
        name: "ClaudeSpyCommonTests",
        dependencies: [
            "ClaudeSpyCommon",
            .dependenciesTestSupport,
            .clocks,
            .concurrencyExtras,
        ]
    ),
    .testTarget(
        name: "ClaudeSpyEncryptionTests",
        dependencies: [
            "ClaudeSpyEncryption",
            .dependenciesTestSupport,
        ]
    ),
    .testTarget(
        name: "ClaudeSpyFeatureTests",
        dependencies: [
            "ClaudeSpyFeature",
            .dependenciesTestSupport,
        ]
    ),
    .testTarget(
        name: "ClaudeSpyServerFeatureTests",
        dependencies: [
            "ClaudeSpyServerFeature",
            .dependenciesTestSupport,
            .clocks,
            .concurrencyExtras,
        ] + macOnlyTargetDependencies(for: "ClaudeSpyServerFeatureTests")
    ),
    .testTarget(
        name: "ClaudeSpyExternalServerTests",
        dependencies: [
            .claudeSpyExternalServerLib,
            .product(name: "VaporTesting", package: "vapor"),
        ]
    ),
    .testTarget(
        name: "ClaudeSpyE2ETests",
        dependencies: [
            .claudeSpyE2ELib,
        ]
    ),
]

let package = Package(
    name: "ClaudeSpyPackage",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: products,
    dependencies: packageDependencies,
    targets: targets
)
