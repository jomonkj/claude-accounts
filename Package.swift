// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeAccounts",
    platforms: [.macOS(.v14)],
    targets: [
        // Logic with no UI: models, engine client, derived state. Tested by CoreTests.
        .target(name: "ClaudeAccountsCore"),
        // The menu bar app.
        .executableTarget(name: "ClaudeAccounts", dependencies: ["ClaudeAccountsCore"]),
        // Test runner. XCTest and swift-testing need Xcode, so tests run as a program:
        //   swift run CoreTests
        .executableTarget(name: "CoreTests", dependencies: ["ClaudeAccountsCore"], path: "tests/CoreTests"),
    ]
)
