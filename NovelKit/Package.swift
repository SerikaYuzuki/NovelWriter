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
        .library(name: "NovelSync", targets: ["NovelSync"]),
        .library(name: "NovelSyncV2", targets: ["NovelSyncV2"]),
        .library(name: "NovelSyncV2Store", targets: ["NovelSyncV2Store"]),
        .library(name: "NovelSyncV2Application", targets: ["NovelSyncV2Application"]),
        .library(name: "NovelSyncV2Runtime", targets: ["NovelSyncV2Runtime"]),
        .library(name: "NovelSyncLegacy", targets: ["NovelSyncLegacy"]),
        .library(name: "NovelLibrary", targets: ["NovelLibrary"]),
        .library(name: "NovelLocalStore", targets: ["NovelLocalStore"]),
        .library(name: "NovelAuth", targets: ["NovelAuth"]),
        .library(name: "NovelAuthApple", targets: ["NovelAuthApple"]),
        .library(name: "NovelSyncTesting", targets: ["NovelSyncTesting"]),
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
        // NovelSync: OS / transport 非依存のentity同期domain。
        // UIやNovelStorageを依存へ追加しない。
        // D-059／D-061の旧revision経路は履歴として残し、D-071のNoteSyncがlive domain。
        .target(
            name: "NovelSync",
            dependencies: ["NovelCore"]
        ),
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
            dependencies: ["NovelCore", "NovelSyncV2"]
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
        // D-076 R5: filesystem journals for the retired Episode/Work
        // protocols are kept in a compatibility target. The target depends
        // on the live domain only for its public journal contracts and IDs.
        .target(
            name: "NovelSyncLegacy",
            dependencies: ["NovelSync", "NovelCore"]
        ),
        // Shared local-library state and attestation models. Filesystem roots
        // and platform UI remain in the app adapters.
        .target(
            name: "NovelLibrary",
            dependencies: ["NovelCore", "NovelSync"]
        ),
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        // D-077 R1: SQLite is the local canonical store. The package codec
        // remains an import/export boundary and is deliberately not a
        // dependency of this target.
        .target(
            name: "NovelLocalStore",
            dependencies: ["NovelCore", "NovelSync", "NovelAuth", "CSQLite"]
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
        // 決定論的fake transport。製品targetからはlinkせず、同期契約testで使う。
        .target(
            name: "NovelSyncTesting",
            dependencies: ["NovelSync", "NovelCore"]
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
            name: "NovelSyncTests",
            dependencies: ["NovelSync", "NovelSyncLegacy", "NovelSyncTesting", "NovelCore"],
            resources: [.process("Fixtures")]
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
            name: "NovelLibraryTests",
            dependencies: ["NovelLibrary", "NovelCore", "NovelSync"]
        ),
        .testTarget(
            name: "NovelLocalStoreTests",
            dependencies: ["NovelLocalStore", "NovelCore", "NovelSync"]
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
            name: "NovelConformanceTests"
        )
    ]
)
