// swift-tools-version:6.0
import PackageDescription

// Tally's logic lives here, deliberately split in two so the storage choice is a
// structural boundary rather than a convention:
//
//   TallyCore  — models, store protocols, goal math, LLM parsing, routing. No dependencies.
//   TallyStore — the GRDB/SQLite conformances of those protocols. The only target that
//                links GRDB, so feature code cannot reach a database type by accident.
//
// Swapping SQLite for something else (SwiftData, plain files) means adding a target
// alongside TallyStore; nothing in TallyCore or the app's feature code changes.
let package = Package(
    name: "Tally",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TallyCore", targets: ["TallyCore"]),
        .library(name: "TallyStore", targets: ["TallyStore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "TallyCore"),
        .target(
            name: "TallyStore",
            dependencies: [
                "TallyCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "TallyCoreTests", dependencies: ["TallyCore"]),
        .testTarget(name: "TallyStoreTests", dependencies: ["TallyStore", "TallyCore"]),
    ]
)
