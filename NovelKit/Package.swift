// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NovelKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "NovelCore", targets: ["NovelCore"]),
        .library(name: "NovelStorage", targets: ["NovelStorage"]),
        .library(name: "NovelExport", targets: ["NovelExport"]),
        .library(name: "NovelSyncV2", targets: ["NovelSyncV2"]),
        .library(name: "NovelSyncV2Store", targets: ["NovelSyncV2Store"]),
        .library(name: "NovelSyncV2Application", targets: ["NovelSyncV2Application"]),
        .library(name: "NovelSyncV2Runtime", targets: ["NovelSyncV2Runtime"]),
        .library(name: "NovelSyncV2PortableBridge", targets: ["NovelSyncV2PortableBridge"]),
        .library(name: "NovelAuth", targets: ["NovelAuth"]),
        .library(name: "NovelAuthApple", targets: ["NovelAuthApple"]),
        .library(name: "EditorKit", targets: ["EditorKit"]),
        .library(name: "NovelUI", targets: ["NovelUI"]),
        .library(name: "PreviewSupport", targets: ["PreviewSupport"])
    ],
    targets: [
        // NovelCore: 依存なし。他モジュール・UIに依存してはならない(DESIGN.md 9.1)。
        .target(
            name: "NovelCore"
        ),
        .target(
            name: "NovelStorage",
            dependencies: ["NovelCore"]
        ),
        .target(
            name: "NovelExport",
            dependencies: ["NovelCore"]
        ),
        // OS / transport independent snapshot contracts.
        .target(
            name: "NovelSyncV2",
            dependencies: ["NovelCore"]
        ),
        .target(
            name: "NovelSyncV2Store",
            dependencies: ["NovelCore", "NovelSyncV2", "CSQLite"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "NovelSyncV2Application",
            dependencies: ["NovelCore", "NovelSyncV2", "NovelAuth"]
        ),
        .target(
            name: "NovelSyncV2Runtime",
            dependencies: [
                "NovelCore",
                "NovelSyncV2",
                "NovelSyncV2Store",
                "NovelSyncV2Application",
                "NovelAuth"
            ]
        ),
        // Explicit-only bridge between validated `.novelpkg` transfer and
        // the v2 snapshot projection. The live v2 application/runtime never
        // depends on NovelStorage, preserving SQLite as sole authority.
        .target(
            name: "NovelSyncV2PortableBridge",
            dependencies: ["NovelCore", "NovelStorage", "NovelSyncV2"]
        ),
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        // Provider-neutral auth/session domain. Apple is the only v1 adapter;
        // adding another provider must not change sync's AccountID contract.
        .target(
            name: "NovelAuth"
        ),
        .target(
            name: "NovelAuthApple",
            dependencies: ["NovelAuth"]
        ),
        .target(
            name: "EditorKit",
            dependencies: ["NovelCore"]
        ),
        .target(
            name: "NovelUI",
            dependencies: ["NovelCore"]
        ),
        .target(
            name: "PreviewSupport",
            dependencies: ["NovelCore"]
        ),
        .testTarget(
            name: "NovelCoreTests",
            dependencies: ["NovelCore"]
        ),
        .testTarget(
            name: "NovelStorageTests",
            dependencies: ["NovelStorage", "NovelCore"]
        ),
        .testTarget(
            name: "NovelExportTests",
            dependencies: ["NovelExport", "NovelCore"]
        ),
        .testTarget(
            name: "NovelSyncV2Tests",
            dependencies: ["NovelSyncV2", "NovelCore"]
        ),
        .testTarget(
            name: "NovelSyncV2StoreTests",
            dependencies: ["NovelSyncV2Store", "NovelSyncV2", "NovelCore", "CSQLite"]
        ),
        .testTarget(
            name: "NovelSyncV2ApplicationTests",
            dependencies: [
                "NovelSyncV2Application",
                "NovelSyncV2Runtime",
                "NovelSyncV2Store",
                "NovelSyncV2",
                "NovelCore",
                "NovelAuth"
            ]
        ),
        .testTarget(
            name: "NovelSyncV2PortableBridgeTests",
            dependencies: ["NovelSyncV2PortableBridge", "NovelStorage", "NovelSyncV2", "NovelCore"]
        ),
        .testTarget(
            name: "NovelAuthTests",
            dependencies: ["NovelAuth", "NovelAuthApple"]
        ),
        .testTarget(
            name: "EditorKitTests",
            dependencies: ["EditorKit"]
        ),
        .testTarget(
            name: "NovelUITests",
            dependencies: ["NovelUI"]
        ),
        .testTarget(
            name: "NovelAuthConformanceTests"
        )
    ]
)
