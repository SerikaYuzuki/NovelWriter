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
        .library(name: "NovelLibrary", targets: ["NovelLibrary"]),
        .library(name: "NovelSyncTesting", targets: ["NovelSyncTesting"]),
        .library(name: "NovelSyncCloudKit", targets: ["NovelSyncCloudKit"]),
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
        // CloudKitやUI、NovelStorageを依存へ追加しない。
        // D-059／D-061の旧revision経路は履歴として残し、D-071のNoteSyncがlive domain。
        .target(
            name: "NovelSync",
            dependencies: ["NovelCore"]
        ),
        // Shared local-library state and attestation models. Filesystem roots,
        // CloudKit, and platform UI remain in the app adapters.
        .target(
            name: "NovelLibrary",
            dependencies: ["NovelCore", "NovelSync"]
        ),
        // 決定論的fake transport。製品targetからはlinkせず、同期契約testで使う。
        .target(
            name: "NovelSyncTesting",
            dependencies: ["NovelSync", "NovelCore"]
        ),
        // Apple private CloudKit adapter。CloudKit型とchange tagをNovelSyncへ漏らさない。
        .target(
            name: "NovelSyncCloudKit",
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
            dependencies: ["NovelSync", "NovelSyncTesting", "NovelCore"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "NovelLibraryTests",
            dependencies: ["NovelLibrary", "NovelCore", "NovelSync"]
        ),
        .testTarget(
            name: "NovelSyncCloudKitTests",
            dependencies: ["NovelSyncCloudKit", "NovelSync", "NovelCore"]
        ),
        .testTarget(
            name: "EditorKitTests",
            dependencies: ["EditorKit"]
        ),
        .testTarget(
            name: "NovelUITests",
            dependencies: ["NovelUI"]
        )
    ]
)
