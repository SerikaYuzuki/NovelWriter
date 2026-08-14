# ふみにわ（FUMINIWA）

ことばを育て、物語を編む。macOS ファーストのマルチプラットフォーム小説執筆アプリです。長編・中編小説を快適に書き、同じ `.novelpkg` をmacOSとWindowsで安全に扱えることを目指します。

- **macOS UI**: SwiftUI(アプリシェル) + AppKit の `NSTextView`(本文エディタ実体、`NSViewRepresentable` 経由)
- **iOS / iPadOS UI**: SwiftUI の適応シェル + UIKit の `UITextView`。iPhone は段階 navigation、iPad は複数列
- **Windows UI(計画)**: WinUI 3 + C# / .NET。同一リポジトリの `Windows/` 配下へ実装する
- **macOSテキストエンジン**: TextKit 2
- **保存形式**: `.novelpkg` v3(フォルダパッケージ。`manifest.json` + `episodes/*.md` + `attachments/`)
- **書き出し**: プレーンテキスト / Markdown / EPUB 3

詳細な設計方針・技術選定の理由は [docs/DESIGN.md](docs/DESIGN.md) と [docs/DECISIONS.md](docs/DECISIONS.md)、OS間互換とWindows実装は [docs/CROSS_PLATFORM.md](docs/CROSS_PLATFORM.md) を参照。

> AI エージェント(Codex / Claude Code など)で開発する場合は、まず [AGENTS.md](AGENTS.md) を読むこと。

## ステータス

**Phase 5まで完了(PDFは未実装)**。macOS の執筆ワークベンチに加え、iOS / iPadOS の作品棚〜執筆（IOS-1〜5、D-058）も source として入っている。iCloud 作品棚(D-063)、メモ型 entity 同期(D-071)、明示同期(D-073)、編集後の作品全体自動スナップショット(D-074)も source 実装。**署名済み Mac＋iPhone の N4、Production schema、Package Validator、一般公開準備は未完了。**

章／話の階層管理、本文編集、話メモ、キャラクター、プロット／伏線、世界観、資料、話内検索、スナップショット、`.novelpkg` v3 自動保存、`Cmd+S`（結線済みなら明示同期）、TXT / Markdown / EPUB 3、校正／アドバイス用 prompt の clipboard copy が動く。

次の実装 Gate は Package Validator。詳細は [商業化基盤の実装状況](docs/COMMERCIALIZATION_IMPLEMENTATION.md)。エージェントは [AGENTS.md](AGENTS.md) と [docs/CODE_HEALTH.md](docs/CODE_HEALTH.md) を先に読む。

Windows並行トラックはW0として、言語非依存schema・golden fixture・portable filename契約の固定から始める。W0完了後、Windows上でWinUI版のCore / Storage実装へ進む(D-036)。

## モジュール構成

現行本体は `NovelKit` というローカル Swift Package と、macOS の `NovelApp`、iOS の `NovelAppIOS` で構成する(D-008)。Windows版は同じ依存方向を .NET class libraryで再実装し、Swiftソースは直接共有しない。

| モジュール | 役割 | 依存 |
| --- | --- | --- |
| `NovelCore` | データモデル・ID型・保存層の抽象プロトコル | なし |
| `NovelStorage` | `.novelpkg` の読み書き | `NovelCore` |
| `NovelExport` | TXT / Markdown / EPUB 3の生成とアトミック書き出し | `NovelCore` |
| `NovelSync` | Device Sync の OS 非依存 domain（live は Note entity） | `NovelCore` |
| `NovelSyncCloudKit` | private CloudKit adapter | `NovelSync` / `NovelCore` |
| `EditorKit` | 本文エディタ（macOS `NSTextView` / iOS `UITextView`、プラグイン） | `NovelCore` |
| `NovelUI` | 再利用可能な SwiftUI 部品 | `NovelCore` |
| `NovelAI` | AI の純粋 outbound domain。通常 App は link しない | なし |
| `PreviewSupport` | SwiftUI Preview 用の固定データ | `NovelCore` |

依存方向・プラットフォーム依存の閉じ込め方など、実装上守るべきルールは [docs/DESIGN.md 9章「実装ルール」](docs/DESIGN.md) にまとめている。

## ビルド・テスト

検証はすべてローカルで行う(GitHub Actions などのクラウド CI は使わない → docs/DECISIONS.md D-014)。マージ前に必ず以下を実行する:

```bash
(cd Sidecars/Codex && npm ci --ignore-scripts --no-audit --no-fund)
./Scripts/check.sh
```

内容: SwiftFormat(lint) → SwiftLint → Codex sidecar の Node テスト → `swift test`(NovelKit) → iOS 向け NovelKit コンパイル → `FUMINIWA` / `FUMINIWAExperimental` の macOS テスト → iOS Simulator 上の EditorKit と `FUMINIWAIOS` テスト。Experimental 側の Darwin supervisor / B4 系は合成 helper と in-memory channel だけを使い、実 provider 通信はしない。

必要なツール: Xcode、Node.js 18以降、`brew install swiftformat swiftlint xcodegen jq ripgrep`。Node依存はlockfileどおり`npm ci --ignore-scripts`で展開し、インストールスクリプトを実行させない。現在のSDKテストは合成fake CLIだけを使い、実provider通信、API key、実原稿を使わない。Node 18以降は開発時captureを走らせる条件であり、実provider runtimeのallowlistではない。個別に実行したい場合はスクリプト内のコマンドを参照。

## アプリの生成と実行

Xcode プロジェクト(`FUMINIWA.xcodeproj`)は [XcodeGen](https://github.com/yonaskolb/XcodeGen) で `project.yml` から生成する生成物であり、リポジトリにはコミットしない(正は常に `project.yml`。D-008 / D-038)。

```bash
brew install xcodegen
./Scripts/generate-project.sh
open FUMINIWA.xcodeproj
```

Xcode 上でスキーム `FUMINIWA`（macOS）または `FUMINIWAIOS`（iOS Simulator）を選んで Run する。`project.yml` を変えたときは `./Scripts/generate-project.sh` を再実行する。

改名前のcheckoutから更新した環境では、Git管理外の旧`NovelWriter.xcodeproj`が残ることがある。生成スクリプトは旧プロジェクトを一時領域へ退避してから`FUMINIWA.xcodeproj`を生成する。Xcodeで旧ウィンドウを開いている場合は閉じ、`FUMINIWA.xcodeproj`／`FUMINIWA`スキームを開き直す。

## 開発方針

- 今後「商業化」として扱う作業は、実装・機能・UI/UX・原稿保全・性能・アクセシビリティ・ビルド／配布技術に限定する。価格・法務・販促・事業運用は明示依頼がない限り開発ロードマップへ含めない(D-042)
- Windows版はmacOS側の商業化基盤と並行してW0から開始し、保存schema・fixture・純粋ロジック仕様を共有する。W0はまだ未完了で、W1以降のWinUI実装とWindows固有検証はWindows上で行う
- Issue / PR を作る際は [.github/ISSUE_TEMPLATE](.github/ISSUE_TEMPLATE) / [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md) を使う
