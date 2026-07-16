# NovelWriter

macOS ファーストのマルチプラットフォーム小説執筆アプリ。長編・中編小説を快適に書き、同じ `.novelpkg` をmacOSとWindowsで安全に扱えることを目指す。

- **macOS UI**: SwiftUI(アプリシェル) + AppKit の `NSTextView`(本文エディタ実体、`NSViewRepresentable` 経由)
- **Windows UI(計画)**: WinUI 3 + C# / .NET。同一リポジトリの `Windows/` 配下へ実装する
- **macOSテキストエンジン**: TextKit 2
- **保存形式**: `.novelpkg` v3(フォルダパッケージ。`manifest.json` + `episodes/*.md` + `attachments/`)
- **書き出し**: プレーンテキスト / Markdown / EPUB 3

詳細な設計方針・技術選定の理由は [docs/DESIGN.md](docs/DESIGN.md) と [docs/DECISIONS.md](docs/DECISIONS.md)、OS間互換とWindows実装は [docs/CROSS_PLATFORM.md](docs/CROSS_PLATFORM.md) を参照。

> AI エージェント(Codex / Claude Code など)で開発する場合は、まず [AGENTS.md](AGENTS.md) を読むこと。

## ステータス

**Phase 5まで完了(PDFは延期)**。章／話の階層管理、本文編集、話メモ、キャラクター管理、登場話ジャンプ、プロットカード、伏線管理、資料添付、文字数表示、話内検索、スナップショット保存・復元、作品の新規・開く・別名保存、`.novelpkg` v3への自動保存とCmd+Q時の終了前保存が動く。Editorプラグイン基盤と日本語小説向け自動字下げ(改行で全角スペース、`「`/`『`で字下げ解除、IME変換中は不介入)も実装済み。UIは3列NavigationSplitViewと一段native toolbarのワークベンチになった。

プレーンテキスト / Markdown / EPUB 3は、Fileメニューまたはツールバーから現在の原稿スナップショットを書き出せる。次はPhase 6のAI支援設計・実装へ進み、PDFはその後のPhase 6.5で実装する(D-037)。

Windows並行トラックはW0として、言語非依存schema・golden fixture・portable filename契約の固定から始める。W0完了後、Windows上でWinUI版のCore / Storage実装へ進む(D-036)。

## モジュール構成

現行macOS本体は `NovelKit` というローカル Swift Package(SwiftPM)としてまとめている。Xcode アプリターゲット(`NovelApp`)はこのパッケージに依存する形で構成している(D-008)。Windows版は同じ依存方向を .NET class libraryで再実装し、Swiftソースは直接共有しない。

| モジュール | 役割 | 依存 |
| --- | --- | --- |
| `NovelCore` | データモデル・ID型・保存層の抽象プロトコル | なし |
| `NovelStorage` | `.novelpkg` の読み書き | `NovelCore` |
| `NovelExport` | TXT / Markdown / EPUB 3の生成とアトミック書き出し | `NovelCore` |
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

- まずは macOS 版の執筆体験を最優先で作り込む。次はAI支援、PDF、iOS / iPadOSの順を既定とする(需要によりPhase 7は再判定)
- Windows版はmacOS側のPhase 6と並行してW0から開始し、保存schema・fixture・純粋ロジック仕様を共有する。W1以降のWinUI実装とWindows固有検証はWindows上で行う
- Issue / PR を作る際は [.github/ISSUE_TEMPLATE](.github/ISSUE_TEMPLATE) / [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md) を使う
