// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WoodshedKit",
    platforms: [
        .iOS("26.0"),
        .macOS(.v15),
    ],
    products: [
        .library(name: "WoodshedKit", targets: ["WoodshedKit"]),
    ],
    targets: [
        .target(name: "WoodshedKit"),
        .testTarget(name: "WoodshedKitTests", dependencies: ["WoodshedKit"]),
    ]
)
