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
        .library(name: "EditorKit", targets: ["EditorKit"]),
        .library(name: "NovelAI", targets: ["NovelAI"]),
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
        .target(
            name: "EditorKit",
            dependencies: ["NovelCore"]
        ),
        // NovelAI: provider-neutralな送受信契約のみ。原稿モデル・Storage・UIに依存しない。
        .target(
            name: "NovelAI"
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
            name: "EditorKitTests",
            dependencies: ["EditorKit"]
        ),
        .testTarget(
            name: "NovelAITests",
            dependencies: ["NovelAI"]
        ),
        .testTarget(
            name: "NovelUITests",
            dependencies: ["NovelUI"]
        )
    ]
)
