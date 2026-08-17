// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnapshotSyncV2Migration",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SnapshotSyncV2Migration", targets: ["SnapshotSyncV2Migration"]),
        .executable(name: "snapshot-sync-v2-export", targets: ["SnapshotSyncV2Export"]),
        .executable(name: "snapshot-sync-v2-authority-builder", targets: ["SnapshotSyncV2AuthorityBuilder"]),
        .library(name: "SnapshotSyncV2MigrationCore", targets: ["SnapshotSyncV2MigrationCore"]),
        .executable(name: "snapshot-sync-v2-migration", targets: ["SnapshotSyncV2MigrationCLI"])
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
                .product(name: "NovelSync", package: "NovelKit"),
                .product(name: "NovelSyncV2", package: "NovelKit"),
                .product(name: "NovelSyncV2PortableBridge", package: "NovelKit")
            ]
        ),
        .executableTarget(
            name: "SnapshotSyncV2Export",
            dependencies: ["SnapshotSyncV2Migration"]
        ),
        .executableTarget(
            name: "SnapshotSyncV2AuthorityBuilder",
            dependencies: ["SnapshotSyncV2MigrationCore"]
        ),
        .target(
            name: "SnapshotSyncV2MigrationCore",
            dependencies: [
                "SnapshotSyncV2Migration",
                .product(name: "NovelCore", package: "NovelKit"),
                .product(name: "NovelStorage", package: "NovelKit"),
                .product(name: "NovelSync", package: "NovelKit"),
                .product(name: "NovelSyncV2", package: "NovelKit"),
                .product(name: "NovelSyncV2PortableBridge", package: "NovelKit"),
                .product(name: "NovelSyncV2Store", package: "NovelKit")
            ]
        ),
        .executableTarget(
            name: "SnapshotSyncV2MigrationCLI",
            dependencies: [
                "SnapshotSyncV2MigrationCore",
                .product(name: "NovelSyncV2Store", package: "NovelKit"),
                .product(name: "NovelSyncV2", package: "NovelKit")
            ]
        ),
        .testTarget(
            name: "SnapshotSyncV2MigrationTests",
            dependencies: [
                "SnapshotSyncV2Migration",
                "SnapshotSyncV2MigrationCore",
                .product(name: "NovelCore", package: "NovelKit"),
                .product(name: "NovelSync", package: "NovelKit"),
                .product(name: "NovelStorage", package: "NovelKit"),
                .product(name: "NovelSyncV2", package: "NovelKit"),
                .product(name: "NovelSyncV2Store", package: "NovelKit")
            ]
        )
    ]
)
