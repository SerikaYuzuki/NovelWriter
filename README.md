# ふみにわ（FUMINIWA）

ことばを育て、物語を編む。macOS ファーストのマルチプラットフォーム小説執筆アプリです。長編・中編小説を快適に書き、同じ `.novelpkg` をmacOSとWindowsで安全に扱えることを目指します。

- **macOS UI**: SwiftUI(アプリシェル) + AppKit の `NSTextView`(本文エディタ実体、`NSViewRepresentable` 経由)
- **Windows UI(計画)**: WinUI 3 + C# / .NET。同一リポジトリの `Windows/` 配下へ実装する
- **macOSテキストエンジン**: TextKit 2
- **保存形式**: `.novelpkg` v3(フォルダパッケージ。`manifest.json` + `episodes/*.md` + `attachments/`)
- **書き出し**: プレーンテキスト / Markdown / EPUB 3

詳細な設計方針・技術選定の理由は [docs/DESIGN.md](docs/DESIGN.md) と [docs/DECISIONS.md](docs/DECISIONS.md)、OS間互換とWindows実装は [docs/CROSS_PLATFORM.md](docs/CROSS_PLATFORM.md) を参照。

> AI エージェント(Codex / Claude Code など)で開発する場合は、まず [AGENTS.md](AGENTS.md) を読むこと。

## ステータス

**Phase 5まで完了(PDFは未実装)**。章／話の階層管理、本文編集、話メモ、キャラクター管理、登場話ジャンプ、プロットカード、伏線管理、資料添付、文字数表示、話内検索、スナップショット保存・復元、作品の新規・開く・別名保存、`.novelpkg` v3への自動保存、`Cmd+S`明示保存、Cmd+Q時の終了前保存が動く。Editorプラグイン基盤と日本語小説向け自動字下げ(改行で全角スペース、`「`/`『`で字下げ解除、IME変換中は不介入)も実装済み。UIはシステムLight／Darkへ追従するNavigationSplitView、一段native toolbar、保存／文字数status barのワークベンチになった。

商業化基盤の最初の範囲として、製品名を「ふみにわ / FUMINIWA」へ移行し、旧設定と既存作品を保持した。起動はLoading / Ready / Recoveryの三状態で、前回作品を開けない場合に空の新規作品へ置き換えない。manifest / worldが参照する本文は必須valid UTF-8、存在する話メモもvalid UTF-8を要求する。未実装AIのplaceholderと`Cmd+J`は、プライバシー・同意を含む実機能が設計されるまで出荷UIへ表示しない(D-038〜D-040)。

個人用AIのExperimental基盤は、Codex sidecar protocol、exact SDK 0.147.0の合成capture、Darwin process supervisor、B3 deployment packager／verifier、B4-A empty approval contract、B4-B非実行exact Node inspector、B4-C probe-only suspended actual-process identityに加え、B4-DのExperimental-only／mock-only abstract interactive transport sequencingまで合成検証した。B4-Dはcontent-free factoryからfresh one-request channelを開き、sealed payload budget由来のabsolute request deadline、最大30秒の独立attestation timeout、単独`ready`のexact request／runtime／frame-boundary照合後だけのsealed `start`、`started` → 単一terminal → EOF、terminal後最大1秒のEOF drain、cancel／timeout first-wins、global live-channel reuse拒否、cleanup安全error優先とraw error redactionを固定した。B4-D 5 suitesは54/54、Experimental全体は205/205 passした。ただし具体production channel／factory／callsiteとprocess／Node／SDK／CLI／network／key／実原稿は0件で、production catalogは空、B4-C childは一度もresumeされずB4-Dへ変換されていない。これはtransport sequencing feasibilityだけで実runtime B4-Dの完了／GOではない。次はB4-E closed execution closure／native broker／helperとapproval／identity／OS-level read／exec隔離であり、残Gate完了まで`codex_sdk` runtimeと実送信はNO-GOである。通常版のtarget構成は変更していない(D-046〜D-053)。

次はPackage Validator Gate(duplicate ID／不正参照、symlink、resource limit、孤児payload保全、修復コピー、保存前検証)。Finder移動や同期サービス等の外部変更／競合検出は、その次の独立Gateとして扱う。その後もAppIcon、Developer ID署名・公証済み成果物、更新機構、配布QA、法務・プライバシー・価格・サポートが残る。**現段階は商業公開可能という意味ではない。** 詳細は [商業化基盤の実装状況](docs/COMMERCIALIZATION_IMPLEMENTATION.md) を参照。

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
(cd Sidecars/Codex && npm ci --ignore-scripts --no-audit --no-fund)
./Scripts/check.sh
```

内容: SwiftFormat(lint)→ SwiftLint → Codex sidecar protocol・deployment manifest／固定allowlist packager・exact SDK合成captureのNodeテスト→ `swift test`(swift-testing)→ iOS 向けコンパイルチェック(共有コードへの AppKit 混入検出。ビルドのみ、iOS アプリ本体は未実装)→ 通常版／Experimental版macOSアプリのテスト(合成helperだけを使うDarwin process supervisor、native manifest verifier、合成Mach-O／filesystemとspawnしないOS Security smokeを使う非実行Node inspector、合成ad-hoc helperのconstructor／`main` marker 0 + 拒否／回収とOS署名helper成功を使うsuspended identity probe、in-memory channelだけを使うB4-D abstract interactive transportを含む)。

必要なツール: Xcode、Node.js 18以降、`brew install swiftformat swiftlint xcodegen jq ripgrep`。Node依存はlockfileどおり`npm ci --ignore-scripts`で展開し、インストールスクリプトを実行させない。現在のSDKテストは合成fake CLIだけを使い、実provider通信、API key、実原稿を使わない。Node 18以降は開発時captureを走らせる条件であり、実provider runtimeのallowlistではない。個別に実行したい場合はスクリプト内のコマンドを参照。

## アプリの生成と実行

Xcode プロジェクト(`FUMINIWA.xcodeproj`)は [XcodeGen](https://github.com/yonaskolb/XcodeGen) で `project.yml` から生成する生成物であり、リポジトリにはコミットしない(正は常に `project.yml`。D-008 / D-038)。

```bash
brew install xcodegen
./Scripts/generate-project.sh
open FUMINIWA.xcodeproj
```

Xcode 上でスキーム `FUMINIWA` を選択し Run すれば起動する。`project.yml` を変更したときは `./Scripts/generate-project.sh` を再実行してプロジェクトを作り直すこと。

改名前のcheckoutから更新した環境では、Git管理外の旧`NovelWriter.xcodeproj`が残ることがある。生成スクリプトは旧プロジェクトを一時領域へ退避してから`FUMINIWA.xcodeproj`を生成する。Xcodeで旧ウィンドウを開いている場合は閉じ、`FUMINIWA.xcodeproj`／`FUMINIWA`スキームを開き直す。

## 開発方針

- 今後「商業化」として扱う作業は、実装・機能・UI/UX・原稿保全・性能・アクセシビリティ・ビルド／配布技術に限定する。価格・法務・販促・事業運用は明示依頼がない限り開発ロードマップへ含めない(D-042)
- Windows版はmacOS側の商業化基盤と並行してW0から開始し、保存schema・fixture・純粋ロジック仕様を共有する。W0はまだ未完了で、W1以降のWinUI実装とWindows固有検証はWindows上で行う
- Issue / PR を作る際は [.github/ISSUE_TEMPLATE](.github/ISSUE_TEMPLATE) / [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md) を使う
