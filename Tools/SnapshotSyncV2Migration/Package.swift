// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnapshotSyncV2Migration",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SnapshotSyncV2Migration", targets: ["SnapshotSyncV2Migration"]),
        .executable(name: "snapshot-sync-v2-export", targets: ["SnapshotSyncV2Export"])
    ],
    dependencies: [
        .package(path: "../../NovelKit")
    ],
    targets: [
        .target(
            name: "SnapshotSyncV2Migration",
            dependencies: [
                .product(name: "NovelCore", package: "NovelKit"),
                .product(name: "NovelStorage", package: "NovelKit"),
                .product(name: "NovelSync", package: "NovelKit")
            ]
        ),
        .executableTarget(
            name: "SnapshotSyncV2Export",
            dependencies: ["SnapshotSyncV2Migration"]
        ),
        .testTarget(
            name: "SnapshotSyncV2MigrationTests",
            dependencies: [
                "SnapshotSyncV2Migration",
                .product(name: "NovelCore", package: "NovelKit"),
                .product(name: "NovelSync", package: "NovelKit"),
                .product(name: "NovelStorage", package: "NovelKit")
            ]
        )
    ]
)
