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
            name: "EditorKitTests",
            dependencies: ["EditorKit"]
        )
    ]
)
