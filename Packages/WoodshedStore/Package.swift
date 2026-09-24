// swift-tools-version: 6.0

import PackageDescription

// Issue #3: the persistence layer.
//
// WoodshedStore is the GRDB/SQLite data layer for Woodshed: schema v1,
// a frozen DatabaseMigrator with a committed fixture database, repository
// protocols with GRDB implementations and in-memory fakes
// (WoodshedStoreTestSupport), and a storage-usage query for a future
// settings screen.
//
// GRDB is pinned to an EXACT version in the spirit of toolchain.json: CI
// must never resolve a different GRDB than was verified. 7.10+ officially
// supports Linux (system libsqlite3 via GRDB's systemLibrary target; the
// CI Linux job installs libsqlite3-dev), so store tests run both on the
// macOS CI lane and the Linux container lane — the sibling-proven recipe
// (carelabel CareStore, rise-log RiseKit).
//
// The ledger tables are insert-only AT THE REPOSITORY LAYER: the protocol
// surface exposes append + fetch (+ a single audited correction insert),
// never UPDATE or DELETE, preserving the append-only promise from #2.
let package = Package(
    name: "WoodshedStore",
    platforms: [
        .iOS("26.0"),
        .macOS(.v15),
    ],
    products: [
        .library(name: "WoodshedStore", targets: ["WoodshedStore"]),
        .library(name: "WoodshedStoreTestSupport", targets: ["WoodshedStoreTestSupport"]),
    ],
    dependencies: [
        .package(path: "../WoodshedKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "WoodshedStore",
            dependencies: [
                .product(name: "WoodshedKit", package: "WoodshedKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "WoodshedStoreTestSupport",
            dependencies: [
                "WoodshedStore",
                .product(name: "WoodshedKit", package: "WoodshedKit"),
            ]
        ),
        // Regenerates Tests/WoodshedStoreTests/Fixtures/v1.sqlite via
        // Scripts/make_fixture_db.py (v1 is frozen; see that script).
        .executableTarget(
            name: "fixture-seed",
            dependencies: [
                "WoodshedStore",
                .product(name: "WoodshedKit", package: "WoodshedKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tools/fixture-seed"
        ),
        .testTarget(
            name: "WoodshedStoreTests",
            dependencies: [
                "WoodshedStore",
                "WoodshedStoreTestSupport",
                .product(name: "WoodshedKit", package: "WoodshedKit"),
            ]
        ),
    ]
)
