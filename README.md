# NovelWriter

macOS 向けの小説執筆アプリ。長編・中編小説を快適に書くことを目的とする。

- **UI**: SwiftUI(アプリシェル) + AppKit の `NSTextView`(本文エディタ実体、`NSViewRepresentable` 経由)
- **テキストエンジン**: TextKit 2
- **保存形式**: `.novelpkg`(フォルダパッケージ。`manifest.json` + `chapters/*.md` + `attachments/`)

詳細な設計方針・技術選定の理由は [docs/DESIGN.md](docs/DESIGN.md) と [docs/DECISIONS.md](docs/DECISIONS.md) を参照。

> AI エージェント(Codex / Claude Code など)で開発する場合は、まず [AGENTS.md](AGENTS.md) を読むこと。

## ステータス

**UI-FIX-1〜5まで完了**。章／話の階層管理、本文編集、話メモ、キャラクター管理、登場話ジャンプ、プロットカード、伏線管理、資料添付、文字数表示、話内検索、スナップショット保存・復元、作品の新規・開く・別名保存、`.novelpkg` v3への自動保存とCmd+Q時の終了前保存が動く。Editorプラグイン基盤と日本語小説向け自動字下げ(改行で全角スペース、`「`/`『`で字下げ解除、IME変換中は不介入)も実装済み。UIは3列NavigationSplitViewと一段native toolbarのワークベンチになった。

保存状態、作品ライフサイクル、Chapter / Episode移行と出力仕様を整備済みです。次は[Phase 4.5 / Phase 5 実行計画](docs/PHASE5.md)に従い、プレーンテキスト / Markdown / EPUB / PDFの出力へ進みます。

## モジュール構成

本体は `NovelKit` というローカル Swift Package(SwiftPM)としてまとめている。Xcode アプリターゲット(`NovelApp`)はこのパッケージに依存する形で構成している(D-008)。

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

内容: SwiftFormat(lint)→ SwiftLint → `swift test`(swift-testing)→ iOS 向けコンパイルチェック(共有コードへの AppKit 混入検出。ビルドのみ、iOS アプリ本体は未実装)→ `NovelApp`(macOS アプリ)のビルドチェック。

必要なツール: Xcode、`brew install swiftformat swiftlint xcodegen`。個別に実行したい場合はスクリプト内のコマンドを参照。

## アプリの生成と実行

Xcode プロジェクト(`NovelWriter.xcodeproj`)は [XcodeGen](https://github.com/yonaskolb/XcodeGen) で `project.yml` から生成する生成物であり、リポジトリにはコミットしない(正は常に `project.yml`。D-008)。

```bash
brew install xcodegen
xcodegen generate
open NovelWriter.xcodeproj
```

Xcode 上でスキーム `NovelApp` を選択し Run すれば起動する。`project.yml` を変更したときは `xcodegen generate` を再実行してプロジェクトを作り直すこと。

## 開発方針

- まずは macOS 版の執筆体験を最優先で作り込む。iOS / iPadOS 対応やAI支援などは後続フェーズ
- Issue / PR を作る際は [.github/ISSUE_TEMPLATE](.github/ISSUE_TEMPLATE) / [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md) を使う
