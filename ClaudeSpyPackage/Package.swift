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

    static var claudeSpyNetworking: Self { "ClaudeSpyNetworking" }
    static var claudeSpyCommon: Self { "ClaudeSpyCommon" }
    static var claudeSpyEncryption: Self { "ClaudeSpyEncryption" }
    static var claudeSpyFeature: Self { "ClaudeSpyFeature" }
    static var claudeSpyServerFeature: Self { "ClaudeSpyServerFeature" }
    static var claudeSpyExternalServer: Self { "ClaudeSpyExternalServer" }
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
    ],
    dependencies: [
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.53.0"),
        .package(url: "https://github.com/gpambrozio/SFSymbolsMacro", branch: "swift-syntax-602"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "8840e3596739adfe9599c0e7fff89f4fa88bedcf"), // v1.9.0
        .package(url: "https://github.com/vapor/vapor", from: "4.0.0"),
        .package(url: "https://github.com/vapor/apns.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
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
                .sfSymbolsMacro,
                .logging,
            ]
        ),
        // End-to-end encryption module using CryptoKit (Apple) / Swift Crypto (Linux)
        .target(
            name: "ClaudeSpyEncryption",
            dependencies: [
                .crypto,
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
        .executableTarget(
            name: "ClaudeSpyExternalServer",
            dependencies: [
                .claudeSpyNetworking,
                .claudeSpyEncryption,
                .vapor,
                .vaporAPNS,
            ],
            swiftSettings: [
                // Match Docker build flags to catch issues locally before deployment
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
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
            ]
        ),
        .testTarget(
            name: "ClaudeSpyEncryptionTests",
            dependencies: [
                "ClaudeSpyEncryption",
            ]
        ),
        .testTarget(
            name: "ClaudeSpyFeatureTests",
            dependencies: [
                "ClaudeSpyFeature",
            ]
        ),
        .testTarget(
            name: "ClaudeSpyServerFeatureTests",
            dependencies: [
                "ClaudeSpyServerFeature",
            ]
        ),
        .testTarget(
            name: "ClaudeSpyExternalServerTests",
            dependencies: [
                .claudeSpyExternalServer,
                .product(name: "VaporTesting", package: "vapor"),
            ]
        ),
    ]
)
