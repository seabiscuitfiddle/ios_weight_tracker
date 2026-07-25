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
        // Floor is 7.11.1, not 7.0.0, on purpose. Earlier 7.x releases compile GRDB's
        // snapshot API on Linux, where Ubuntu's libsqlite3 is built without
        // SQLITE_ENABLE_SNAPSHOT — so linking fails with undefined references to
        // sqlite3_snapshot_*. 7.11.1's manifest guards that with
        // `.define("SQLITE_DISABLE_SNAPSHOT", .when(platforms: [.linux]))`.
        //
        // The subtlety worth knowing: GRDB's manifest requires swift-tools-version 6.1, and
        // SPM silently skips dependency versions whose tools-version exceeds the toolchain.
        // On a Swift 6.0 toolchain, resolution therefore walks *backwards* to 7.8.0 and the
        // link fails. With this floor it fails loudly at resolution instead, saying the
        // toolchain is too old — which is a far better error than a screen of undefined
        // symbols in someone else's package. Requires Swift 6.1+.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
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
