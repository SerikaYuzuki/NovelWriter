# AGENTS.md — AIエージェント向け作業ガイド

**ふみにわ（FUMINIWA）**はmacOS ファーストのマルチプラットフォーム日本語小説執筆アプリ。現行 macOS 版は SwiftUI シェル + `NSTextView`(TextKit 2)エディタ、将来の Windows 版は WinUI 3 + C# / .NET とし、`.novelpkg` フォルダパッケージを共通互換境界にする。

**設計の正は [docs/DESIGN.md](docs/DESIGN.md)、決定の記録は [docs/DECISIONS.md](docs/DECISIONS.md)(D-001〜)。この2つを読んでから作業すること。** OS 間互換・Windows 実装は [docs/CROSS_PLATFORM.md](docs/CROSS_PLATFORM.md)、AI統合は [docs/AI_INTEGRATION.md](docs/AI_INTEGRATION.md) を追加で読む。次にやるべきタスクは DESIGN.md の「11. 直近の次タスク」にある。UI磨き上げの完了記録は [docs/UIPOLISH.md](docs/UIPOLISH.md)。UI-REF-1〜6の完了記録は [docs/UIREFRESH.md](docs/UIREFRESH.md)、UI-REV完了記録は [docs/UIREVISION.md](docs/UIREVISION.md)、UI Fix の完了記録は [docs/UIFIX.md](docs/UIFIX.md)、Phase UI2 と Phase 4 の完了記録は [docs/UIDESIGN.md](docs/UIDESIGN.md) / [docs/PHASE4.md](docs/PHASE4.md))。

## 現在地(2026-08-09 時点)

- Phase 0(基盤)/ Phase 1(最小執筆環境)/ Phase 2(Editorプラグイン基盤 + 自動インデント)/ Phase 3(基本操作強化)/ Phase 4(小説執筆支援機能: 4-1〜4-6)/ 旧 Phase UI(3モード刷新)/ Phase UI2(Workbench刷新)/ UI-FIX-1〜5 / UI-REV-1〜9 / UI-REF-1〜6 / UI-POL-1〜4 / Phase 5(出力、PDF除外)完了
- 動くもの: 章Disclosure／話リスト(追加・選択・タイトル編集・削除・並べ替え・話移動)、NSTextView エディタ、自動字下げ(改行で常時全角スペース、`「`/`『` で字下げ解除・IME確定後も対応)、話メモ、文字数表示、キャラクター管理、登場話ジャンプ、プロットカード、伏線管理、資料添付、世界観ノート(一覧・追加・削除・並べ替え・本文編集)、話内検索ジャンプ、スナップショット保存・一覧・確認付き復元、作品タイトル／あらすじ編集、`.novelpkg` v3自動保存(2秒デバウンス)、Cmd+S明示保存、Cmd+Q時の終了前保存、Loading / Ready / RecoveryによるSafe Launch、作品の新規・開く・別名保存、TXT / Markdown / EPUB 3書き出し、システム追従／ライト／ダークを選べる2列/3列NavigationSplitView + 一段native toolbar + 保存／文字数status bar
- 商業化基盤の現在地: ブランド移行(D-038)、Safe Launchと参照payloadのvalid UTF-8検査(D-039)、未実装AIを出荷UIへ出さないProduct Truth(D-040)、起動／作品ライフサイクルの競合防止(D-041)、アプリ外観選択(D-044)、章Disclosure改善(D-045)まで実装。**実装面の公開準備完了という意味ではない**
- AIの現在地: `NovelAI`のpure domain、EditorKitのAI selection transaction、providerへ送らないApp-level local context、送信前／適用前stale検査、決定論的fake、共通のpreview／確認／cancel／diff／Copy／Apply UIを実装。これらは別bundle・別保存rootの`FUMINIWAExperimental` targetだけに入り、通常版はbuild graph監査で`NovelAI`とAI UIを除外する。Codex sidecar v1のNode／Swift mock、canonical deployment manifest v1のNode primitive、exact SDK 0.147.0を合成CLIだけで駆動するcaptureまで実装した。実CLI／network、native supervisor／manifest verifier、Keychain、OS-level隔離は未実装
- 今後「商業化」として扱う範囲は、実装・機能・UI/UX・データ安全・性能・アクセシビリティ・互換性・ビルド／配布技術に限定する(D-042)。価格、法務、販促、決済、事業運用は、ユーザーから明示依頼がない限り調査・提案・ロードマップ化しない
- 次: 個人用AIは **Codex SDK sidecar隔離feasibility** として、allowlist packager／native manifest verifier、監査済みlauncher shim、process-group supervisorを合成helperで実装する。SDK内部のliteral U+2028／U+2029処理がNode 22.23.1と26.4.0で異なること、生stderr保持、direct childだけのAbortをboundedにした後、exact Node runtime、専用cwd／`CODEX_HOME`、environment allowlist、file-read拒否、cancel／kill／group空を実証してから既存共通UIへadapterを接続する。その後、同じUIへ独立したOpenRouter API adapterを追加する。公開Releaseの次は引き続き **Package Validator Gate**、続いて **External Change / Conflict Gate** とする(D-040 / D-043 / D-046 / D-047)
- Windows 並行トラックの次: **W0(schema / golden fixture / portable filename 契約の固定)**。[docs/CROSS_PLATFORM.md](docs/CROSS_PLATFORM.md) を正とする

## リポジトリ構成

```
NovelApp/            アプリ本体(AppState / ContentView / AppDependencies)
NovelKit/            ローカル Swift Package(ライブラリ群 + 全テスト)
  Sources/NovelCore/     モデル(Chapter, NovelDocument, DocumentRepository)— 依存ゼロ
  Sources/NovelStorage/  .novelpkg の読み書き(NovelpkgRepository)
  Sources/NovelExport/   TXT / Markdown / EPUB 3の生成とアトミック書き出し
  Sources/NovelAI/       AIの純粋outbound domain(draft / preview / confirmed request / provider protocol)。実providerなし
  Sources/EditorKit/     エディタ(EditorView / プラグイン / IndentRules / MacTextAdapter)
  Sources/NovelUI/       共有 SwiftUI 部品(まだ薄い)
  Sources/PreviewSupport/ Preview 用固定データ(まだ薄い)
project.yml          XcodeGen 定義。FUMINIWA.xcodeproj は生成物(コミット禁止)
Scripts/generate-project.sh  旧XcodeGen生成物を退避し、現行projectを生成
Scripts/check.sh     ローカルCI。マージ前に必ず全通しすること
docs/                DESIGN.md(設計)/ DECISIONS.md(決定記録)
```

## 破ってはいけないルール

1. **依存方向**(DESIGN 9.1): NovelCore は何にも依存しない。NovelStorage / NovelExport / EditorKit / NovelUI → NovelCore のみ。NovelAI は他の NovelKit target に依存しない。違反はコンパイルで落ちるように Package.swift が組んである
2. **テキスト所有権**(D-005 / D-028): 編集中の本文の正は `NSTextView` 側。SwiftUI の update サイクルから `textView.string` を書き換えるのは話切り替え時のみ。素朴な双方向 `Binding<String>` は禁止。IME 変換中(`hasMarkedText`)はモデル反映もプラグイン介入もしない
3. **TextKit 2**(D-006): `NSTextView.layoutManager` に触れない(触れると TextKit 1 に暗黙フォールバックする)。`textLayoutManager` を使う
4. **公開APIに `NSTextView` / `UITextView` を出さない**(DESIGN 9.2)。AppKit 依存コードは `EditorKit/Platform/` 配下 + `#if canImport(AppKit)` 内のみ
5. **章順は `NovelDocument.chapters`、話順は `Chapter.episodes` の配列順が唯一の正**(D-004 / D-028)。order フィールドを追加しない。v3保存形式ではmanifestだけが両方の順序を持ち、本文・メモのファイル名はEpisodeID(UUID)ベース
6. **`.novelpkg` の内部構造を NovelStorage の外に漏らさない**(DESIGN 9.3)
7. **エディタ機能は EditorPlugin として追加する**(DESIGN 4.4)。EditorView / MacTextAdapter を直接太らせない。純粋な判定ロジックは `Rules/` に切り出してテストする
8. **UI を触る PR は [docs/STYLE.md](docs/STYLE.md)(デザイン言語)に従う**。chromeは既定でシステムLight／Darkへ追従し、利用者が明示した場合だけLight／Darkへ固定できる。本文キャンバスの利用者設定とは分離する(D-040 / D-044)。色・タイポ・余白・文言の規約と、提出前チェックリスト(STYLE.md 9章)がある。トークン外の hex 直書き・フォントサイズ直指定・常設の影は規約違反
9. **`.novelpkg` の互換契約を変更する場合は [docs/CROSS_PLATFORM.md](docs/CROSS_PLATFORM.md) と golden fixture を同時に更新する**(D-036)。OS 固有パス・bookmark・handle・UI設定を package に保存しない。Windows 実装後は双方向 round-trip を完了条件にする
10. **起動中・復旧中に編集可能なWorkbenchを出さない**(D-039)。読込失敗を新規作品へ自動fallbackせず、recent URLと原稿を保持する。manifest / world参照payloadは必須valid UTF-8、メモは欠損のみ省略可能で、存在するファイルの読込失敗を空文字へ変換しない
11. **実在する機能だけをUIへ出す**(D-040 / D-046)。実処理・プライバシー・同意設計のないAI placeholder、状態、ショートカットを復活させない。実装済みAI UIを先行できるのは`FUMINIWA_ENABLE_EXPERIMENTAL_AI`付き`FUMINIWAExperimental` app targetだけで、通常の`FUMINIWA` app targetには入口、provider dependency、provider artifactを含めない。`Cmd+S`は`AppState.saveNow()`系の保存直列化へ寄せる
12. **作品ライフサイクルの対象を動的に読み直さない**(D-041)。開く／新規／別名保存／資料／snapshot／終了前保存はdocument operation gateで直列化し、現在作品に属する非同期操作と確認UIは呼び出し／表示時のsession tokenを検査する。遷移前はフォームとEditorKit境界のIMEを旧作品へ確定し、最終保存／installまでWorkbench全体の変更を止める。終了要求後は新しい作品操作を受け付けない。lock順はdocument operation gate → `DocumentSaveCoordinator`。gate付きpublic API同士の呼び出しは禁止
13. **AIのlocal identityをproviderへ送らない**(D-043)。`NovelAI`はversion付きinstruction ID、`selected_text`を未信頼データとして扱う固定指示、exact selected textから単一`applicationPrompt`を生成し、exact `applicationResponseSchema`とschema IDもpreviewから封印する。adapterはconfirmed `AIApplicationPayload`のpromptへ再構築・追記せず、schemaのcanonical JSON value tree／digestを変えない。Provider wrapperへのstrict parse／写像とwire上のescape／key順は許容するが、property追加・削除・緩和は禁止する。instructionまたはschemaを変える場合は対応IDを更新し、送信確認を取り直す。同じconfirmationはdomain executorで1回だけ実行し、再試行は新しいpreview／確認から始める。`AIConfirmedRequest`へdocument session、editor surface、episode、UTF-16 range、source digest、URL／pathを追加しない。これらは後続のApp / EditorKit bridgeがmemory-only contextで保持し、stale適用をfail-closedで拒否する。CodexとOpenRouterを自動fallbackさせず、prompt／response／diff／provider設定で`.novelpkg`を変更しない
14. **Codex SDKとAPI経路でAI UI／適用ロジックを分けない**(D-046)。選択snapshot、exact preview、送信確認、進行／cancel、結果、diff、stale、Copy、明示Applyは一つのprovider-neutral orchestrator／UIを使う。process／HTTP、credential、model設定、保持情報、typed errorだけをadapterごとに分離する。個人用でもKeychain、本文等の非ログ、専用cwd／`CODEX_HOME`、environment allowlist、OS-level file隔離、process tree回収を緩めない

## エディタにプラグインを足す手順(Phase 2 で確立)

1. 判定ロジックを `EditorKit/Rules/` に純関数で書く(AppKit 禁止、`String` + UTF-16 `NSRange`。変換は `Range(_:in:)` 経由)+ swift-testing でテスト
2. `EditorKit/Plugins/` に `EditorPlugin` 準拠の薄いクラスを作り、Rules の判定を `EditorAction` に写像する
3. `MacTextAdapter.Coordinator` の `pipeline`(現在 `[IMEGuardPlugin(), IndentPlugin()]`)に登録。**IMEGuardPlugin より後ろに置くこと**
4. `EditorKitTests/MacTextAdapterIntegrationTests.swift` の方式(実 NSTextView + Coordinator を直接組み立てて delegate を駆動)で統合テストを書く。**Undo で戻ることも必ずテストする**

## 開発ワークフロー

- **GitHub Flow**: main から `feat/…` ブランチ → PR(テンプレート: .github/PULL_REQUEST_TEMPLATE.md)。main への直接 push 禁止。**作業開始直後にブランチを切り、区切りごとに WIP コミットする**(未コミットの作業ツリーは main への自動同期で消えることがある)
- **検証はローカルのみ**(D-014。GitHub Actions は使わない): PR 前に `./Scripts/check.sh` が「All checks passed」まで通ること(SwiftFormat lint / SwiftLint / swift test / iOS向けコンパイルチェック / NovelApp ビルド)
- Xcode プロジェクトは `./Scripts/generate-project.sh` で生成(D-015)。project.yml が正。旧`NovelWriter.xcodeproj`を直接開かない
- 単体テストは swift-testing(`@Test`)。XCTest は使わない
- コミットは意味単位で `feat:` / `fix:` / `docs:` / `chore:` / `style:` プレフィックス。本文は日本語可
- 必要ツール: Xcode 16+、Node.js 18+、`brew install swiftformat swiftlint xcodegen jq ripgrep`

## 設計判断のしかた

- 新しい設計判断をしたら docs/DECISIONS.md に D-XXX として追記する(既存の決定を覆す場合は元を消さず「破棄」とマークして新しい番号で)
- DESIGN.md の内容と実装が食い違ったら、実装を直すか DESIGN.md を更新するかを明示的に決めて、変更履歴に記録する
- 作業は小さい単位で: モデル追加 / Repository 変更 / プラグイン追加 / UI追加 / テスト追加 / リファクタリングを1つの PR に混ぜすぎない(DESIGN 10章)

## 既知の注意点

- 保存要求は revision ベースで直列化している(D-017)。新しい保存契機を足す場合は `AppState.saveNow()` 系の経路に寄せること
- W0と商業化Package Validator Gateはいずれも未完了。invalid UTF-8の部分補修だけで完全なpackage検証・Windows互換・商業公開準備の完了を宣言しない
- `NovelAI`のpure domainや個人用AIの動作はAI公開を意味しない。Experimental UIの前提はexact SDK／CLI／Node version・path・hash、lockfile／package integrity、request専用empty cwd／`CODEX_HOME`、environment allowlist、Keychain、OS-level file隔離、本文／prompt／response／key／pathの非ログ、cancel／kill／orphanなし、event／process limit、local artifact inventory。arm64／x86_64、bundled runtime、nested signing／公証は公開Release Gateへ延期する。公開SDKにないtool無効化／upstream token cap／ephemeral optionをあるように扱わず、Experimental UIで未保証と表示する
- `EditorContext` は delegate 呼び出しごとの本文スナップショット。超長文でのパフォーマンスは将来の最適化課題
