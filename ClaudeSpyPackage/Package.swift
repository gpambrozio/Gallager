// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

extension Target.Dependency {
    static var sfSymbolsMacro: Self {
        .product(name: "SFSymbolsMacro", package: "SFSymbolsMacro")
    }

    static var swiftTerm: Self {
        .product(name: "SwiftTerm", package: "SwiftTerm")
    }

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

    static var sparkle: Self {
        .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))
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

    static var claudeSpyNetworking: Self { "ClaudeSpyNetworking" }
    static var claudeSpyCommon: Self { "ClaudeSpyCommon" }
    static var claudeSpyEncryption: Self { "ClaudeSpyEncryption" }
    static var claudeSpyFeature: Self { "ClaudeSpyFeature" }
    static var claudeSpyServerFeature: Self { "ClaudeSpyServerFeature" }
    static var claudeSpyExternalServer: Self { "ClaudeSpyExternalServer" }
    static var claudeSpyExternalServerLib: Self { "ClaudeSpyExternalServerLib" }
    static var claudeSpyE2ELib: Self { "ClaudeSpyE2ELib" }

    static var argumentParser: Self {
        .product(name: "ArgumentParser", package: "swift-argument-parser")
    }
}

let package = Package(
    name: "ClaudeSpyPackage",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "ClaudeSpyNetworking",
            targets: ["ClaudeSpyNetworking"]
        ),
        .library(
            name: "ClaudeSpyCommon",
            targets: ["ClaudeSpyCommon"]
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
    ],
    dependencies: [
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.53.0"),
        .package(url: "https://github.com/gpambrozio/SFSymbolsMacro", branch: "swift-syntax-602"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.10.1"),
        .package(url: "https://github.com/vapor/vapor", from: "4.0.0"),
        .package(url: "https://github.com/vapor/apns.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
    ],
    targets: [
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
        .target(
            name: "ClaudeSpyCommon",
            dependencies: [
                .claudeSpyNetworking,
                .claudeSpyEncryption,
                .sfSymbolsMacro,
                .logging,
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
                .swiftTerm,
            ]
        ),
        .target(
            name: "ClaudeSpyServerFeature",
            dependencies: [
                .claudeSpyCommon,
                .claudeSpyEncryption,
                .swiftTerm,
                .vapor,
                .sparkle,
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
                .claudeSpyExternalServerLib,
                .vapor,
                .logging,
            ]
        ),
        // E2E test coordinator executable
        .executableTarget(
            name: "ClaudeSpyE2E",
            dependencies: [
                .claudeSpyE2ELib,
                .argumentParser,
            ]
        ),
        .testTarget(
            name: "ClaudeSpyNetworkingTests",
            dependencies: [
                "ClaudeSpyNetworking",
            ]
        ),
        .testTarget(
            name: "ClaudeSpyCommonTests",
            dependencies: [
                "ClaudeSpyCommon",
                .dependenciesTestSupport,
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
            ]
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
)
