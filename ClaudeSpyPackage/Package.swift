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

    static var claudeSpyNetworking: Self { "ClaudeSpyNetworking" }
    static var claudeSpyCommon: Self { "ClaudeSpyCommon" }
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
        .package(url: "https://github.com/lukepistrol/SFSymbolsMacro.git", from: "0.5.4"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/vapor/vapor", from: "4.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.

        // Platform-agnostic networking models (no SwiftUI dependencies)
        // Used by external server on Linux and by Apple platform apps
        .target(
            name: "ClaudeSpyNetworking",
            dependencies: []
        ),
        .target(
            name: "ClaudeSpyCommon",
            dependencies: [
                .claudeSpyNetworking,
                .sfSymbolsMacro,
            ]
        ),
        .target(
            name: "ClaudeSpyFeature",
            dependencies: [
                .claudeSpyCommon,
            ]
        ),
        .target(
            name: "ClaudeSpyServerFeature",
            dependencies: [
                .claudeSpyCommon,
                .swiftTerm,
                .vapor,
            ]
        ),
        .executableTarget(
            name: "ClaudeSpyExternalServer",
            dependencies: [
                .claudeSpyNetworking,
                .vapor,
            ]
        ),
        .testTarget(
            name: "ClaudeSpyNetworkingTests",
            dependencies: [
                "ClaudeSpyNetworking"
            ]
        ),
        .testTarget(
            name: "ClaudeSpyCommonTests",
            dependencies: [
                "ClaudeSpyCommon"
            ]
        ),
        .testTarget(
            name: "ClaudeSpyFeatureTests",
            dependencies: [
                "ClaudeSpyFeature"
            ]
        ),
        .testTarget(
            name: "ClaudeSpyServerFeatureTests",
            dependencies: [
                "ClaudeSpyServerFeature"
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
