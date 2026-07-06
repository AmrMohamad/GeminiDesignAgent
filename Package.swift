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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0")
    ],
    targets: [
        .target(
            name: "CSQLite",
            path: "CSQLite",
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
                "CSQLite",
                .product(name: "AsyncHTTPClient", package: "async-http-client")
            ]
        ),
        .executableTarget(
            name: "gda",
            dependencies: [
                "GeminiDesignAgentCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "GeminiDesignAgentCoreTests",
            dependencies: ["GeminiDesignAgentCore"]
        )
    ]
)
