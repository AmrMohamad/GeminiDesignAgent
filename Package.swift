// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GeminiDesignAgent",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "gda", targets: ["gda"]),
        .library(name: "GeminiDesignAgentCore", targets: ["GeminiDesignAgentCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "CSQLite",
            path: "CSQLite",
            exclude: ["sqlite3-amalgamation.c"],
            publicHeadersPath: ".",
            cSettings: [
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_JSON1"),
                .define("SQLITE_THREADSAFE", to: "1")
            ]
        ),
        .target(
            name: "GeminiDesignAgentCore",
            dependencies: [
                "CSQLite"
            ]
        ),
        .target(
            name: "GDAPlatformSupport",
            dependencies: ["GeminiDesignAgentCore"],
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "gda",
            dependencies: [
                "GeminiDesignAgentCore",
                "GDAPlatformSupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "GeminiDesignAgentCoreTests",
            dependencies: ["GeminiDesignAgentCore"]
        ),
        .testTarget(
            name: "GDAPlatformSupportTests",
            dependencies: ["GDAPlatformSupport"]
        )
    ]
)
