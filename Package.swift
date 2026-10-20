// swift-tools-version:6.1

import PackageDescription

let package = Package(
    name: "apple-calendar-mcp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "apple-calendar-mcp", targets: ["apple-calendar-mcp"]),
        .executable(name: "CalendarMCPBar", targets: ["CalendarMCPBar"]),
        .library(name: "CalendarStore", targets: ["CalendarStore"]),
        .library(name: "CalendarMCPKit", targets: ["CalendarMCPKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.1"),  // the SDK's own; for `Transport`
    ],
    targets: [
        // Calendar data: the models, EventKit, the in-memory store for tests, the bridge to the menu bar app,
        // free-time and statistics, iCalendar files.
        .target(name: "CalendarStore"),
        // MCP tool surface, configuration, approvals, undo and activity journal.
        .target(
            name: "CalendarMCPKit",
            dependencies: [
                "CalendarStore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // A week of made-up events, for tests, screenshots and demos.
        .target(name: "CalendarFixtures", dependencies: ["CalendarStore"]),
        .executableTarget(name: "apple-calendar-mcp", dependencies: ["CalendarMCPKit", "CalendarFixtures"]),
        .executableTarget(name: "CalendarMCPBar", dependencies: ["CalendarStore", "CalendarMCPKit", "CalendarFixtures"]),
        .testTarget(name: "CalendarStoreTests", dependencies: ["CalendarStore", "CalendarFixtures"]),
        .testTarget(
            name: "CalendarMCPKitTests",
            dependencies: ["CalendarMCPKit", "CalendarFixtures", .product(name: "MCP", package: "swift-sdk")]
        ),
    ]
)
