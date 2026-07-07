# NovelWriter

macOS 向けの小説執筆アプリ。長編・中編小説を快適に書くことを目的とする。

- **UI**: SwiftUI(アプリシェル) + AppKit の `NSTextView`(本文エディタ実体、`NSViewRepresentable` 経由)
- **テキストエンジン**: TextKit 2
- **保存形式**: `.novelpkg`(フォルダパッケージ。`manifest.json` + `chapters/*.md` + `attachments/`)

詳細な設計方針・技術選定の理由は [docs/DESIGN.md](docs/DESIGN.md) と [docs/DECISIONS.md](docs/DECISIONS.md) を参照。

## ステータス

**Phase 0(開発基盤構築中)**。git / CI / lint / テンプレートなど、開発を進めるための土台を整えている段階。アプリとしての機能はまだない([docs/DESIGN.md 8章 開発ロードマップ](docs/DESIGN.md)を参照)。

## モジュール構成

本体は `NovelKit` というローカル Swift Package(SwiftPM)としてまとめている。Xcode アプリターゲット(`NovelApp`)はこのパッケージに依存する形で後から追加する。

| モジュール | 役割 | 依存 |
| --- | --- | --- |
| `NovelCore` | データモデル・ID型・保存層の抽象プロトコル | なし |
| `NovelStorage` | `.novelpkg` の読み書き | `NovelCore` |
| `EditorKit` | 本文エディタ(`NSTextView` アダプタ、入力プラグイン基盤) | `NovelCore` |
| `NovelUI` | 再利用可能な SwiftUI 部品 | `NovelCore` |
| `PreviewSupport` | SwiftUI Preview 用の固定データ | `NovelCore` |

依存方向・プラットフォーム依存の閉じ込め方など、実装上守るべきルールは [docs/DESIGN.md 9章「実装ルール」](docs/DESIGN.md) にまとめている。

## ビルド・テスト

検証はすべてローカルで行う(GitHub Actions などのクラウド CI は使わない → docs/DECISIONS.md D-014)。マージ前に必ず以下を実行する:

```bash
./Scripts/check.sh
```

内容: SwiftFormat(lint)→ SwiftLint → `swift test`(swift-testing)→ iOS 向けコンパイルチェック(共有コードへの AppKit 混入検出。ビルドのみ、iOS アプリ本体は未実装)。

必要なツール: Xcode、`brew install swiftformat swiftlint`。個別に実行したい場合はスクリプト内のコマンドを参照。

## 開発方針

- まずは macOS 版の執筆体験を最優先で作り込む。iOS / iPadOS 対応やAI支援などは後続フェーズ
- Issue / PR を作る際は [.github/ISSUE_TEMPLATE](.github/ISSUE_TEMPLATE) / [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md) を使う
