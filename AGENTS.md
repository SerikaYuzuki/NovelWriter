# AGENTS.md — AIエージェント向け作業ガイド

**ふみにわ（FUMINIWA）**はmacOS ファーストのマルチプラットフォーム日本語小説執筆アプリ。現行 macOS 版は SwiftUI シェル + `NSTextView`(TextKit 2)エディタ、将来の Windows 版は WinUI 3 + C# / .NET とし、`.novelpkg` フォルダパッケージを共通互換境界にする。

**設計の正は [docs/DESIGN.md](docs/DESIGN.md)、決定の記録は [docs/DECISIONS.md](docs/DECISIONS.md)(D-001〜)。この2つを読んでから作業すること。** コードの live 経路・負債・GitHub の載せ方は [docs/CODE_HEALTH.md](docs/CODE_HEALTH.md)。OS 間互換は [docs/CROSS_PLATFORM.md](docs/CROSS_PLATFORM.md)。通常版 AI は [docs/CLIPBOARD_AI_ASSIST.md](docs/CLIPBOARD_AI_ASSIST.md)（provider 統合の保管場所は [docs/AI_INTEGRATION.md](docs/AI_INTEGRATION.md)）。次タスクは DESIGN.md の「11. 直近の次タスク」。Device Sync は [docs/DEVICE_SYNC.md](docs/DEVICE_SYNC.md) **0章だけ**（1〜15章と 0-hist は履歴）。UI 完了記録（UIPOLISH / UIREFRESH / UIREVISION / UIFIX / UIDESIGN / PHASE4）は次タスクではない。

## 現在地(2026-08-14 時点)

- 執筆・保存・書き出し・iOS 段階導線・iCloud 作品棚・メモ型 entity 同期(D-071)・明示同期(D-073)・編集後の作品全体自動スナップショット(D-074)まで **source としては動く**。N4 署名済み Mac＋iPhone、Production schema、Package Validator、出荷準備は未完了
- 自動保存は端末内の `.novelpkg` と dirty set まで。iCloud へ出すのは結線済み作品の「iCloudと同期」と `Cmd+S` だけ(D-073)
- 通常版 AI は校正／アドバイス用 prompt の clipboard copy だけ。`NovelAI` / provider / network は通常 target に無い(D-054)
- 「商業化」は実装・品質・配布技術に限る(D-042)。価格・法務・販促は明示依頼が無い限り触らない
- **次の実装**(依頼されたとき): 公開Releaseの Package Validator Gate → External Change / Conflict Gate。Windows は W0。Device Sync のコード待ちは無く、残る N4 は操作者検証（[docs/CLOUDKIT_PRODUCTION_SCHEMA.md](docs/CLOUDKIT_PRODUCTION_SCHEMA.md) 5章）
- **GitHub**: `origin/main` には iOS / Device Sync / D-071〜074 がまだ無い。載せ方は [docs/CODE_HEALTH.md](docs/CODE_HEALTH.md) 7章。利用者の明示が無い限り origin へ push しない

## リポジトリ構成

```
NovelApp/              macOS 通常 App(AppState / Workbench)
NovelAppIOS/           iOS / iPadOS 通常 App(IOSDocumentStore / 段階 navigation)
NovelAppExperimental/  Experimental だけが compile する provider 研究コード
NovelKit/              ローカル Swift Package
  Sources/NovelCore/        モデル。依存ゼロ
  Sources/NovelStorage/     .novelpkg の読み書き
  Sources/NovelExport/      TXT / Markdown / EPUB 3
  Sources/NovelSync/        Device Sync の OS 非依存 domain（live は Note。Work/Episode は履歴）
  Sources/NovelSyncCloudKit/  private CloudKit adapter
  Sources/NovelSyncTesting/ test 専用 fake
  Sources/NovelAI/          AI の純粋 outbound domain。実 provider なし
  Sources/EditorKit/        EditorView / プラグイン / IndentRules / Platform adapters
  Sources/NovelUI/          共有 SwiftUI 部品(薄い)
  Sources/PreviewSupport/   Preview 用固定データ
project.yml            XcodeGen 定義。FUMINIWA.xcodeproj は生成物(コミット禁止)
Scripts/check.sh       ローカル CI。マージ前に全通し
docs/                  DESIGN.md / DECISIONS.md / CODE_HEALTH.md ほか
```

## 破ってはいけないルール

1. **依存方向**(DESIGN 9.1): NovelCore は何にも依存しない。NovelStorage / NovelExport / EditorKit / NovelUI / NovelSync → NovelCore のみ。NovelSyncCloudKit → NovelSync / NovelCore。NovelAI は他の NovelKit target に依存しない。違反はコンパイルで落ちるように Package.swift が組んである
2. **テキスト所有権**(D-005 / D-028): 編集中の本文の正は `NSTextView` 側。SwiftUI の update サイクルから `textView.string` を書き換えるのは話切り替え時のみ。素朴な双方向 `Binding<String>` は禁止。IME 変換中(`hasMarkedText`)はモデル反映もプラグイン介入もしない
3. **TextKit 2**(D-006): `NSTextView.layoutManager` に触れない(触れると TextKit 1 に暗黙フォールバックする)。`textLayoutManager` を使う
4. **公開APIに `NSTextView` / `UITextView` を出さない**(DESIGN 9.2)。AppKit 依存コードは `EditorKit/Platform/` 配下 + `#if canImport(AppKit)` 内のみ
5. **章順は `NovelDocument.chapters`、話順は `Chapter.episodes` の配列順が唯一の正**(D-004 / D-028)。order フィールドを追加しない。v3保存形式ではmanifestだけが両方の順序を持ち、本文・メモのファイル名はEpisodeID(UUID)ベース
6. **`.novelpkg` の内部構造を NovelStorage の外に漏らさない**(DESIGN 9.3)
7. **エディタ機能は EditorPlugin として追加する**(DESIGN 4.4)。EditorView / MacTextAdapter を直接太らせない。純粋な判定ロジックは `Rules/` に切り出してテストする
8. **UI を触る PR は [docs/STYLE.md](docs/STYLE.md)(デザイン言語)に従う**。chromeは既定でシステムLight／Darkへ追従し、利用者が明示した場合だけLight／Darkへ固定できる。本文キャンバスの利用者設定とは分離する(D-040 / D-044)。色・タイポ・余白・文言の規約と、提出前チェックリスト(STYLE.md 9章)がある。トークン外の hex 直書き・フォントサイズ直指定・常設の影は規約違反
9. **`.novelpkg` の互換契約を変更する場合は [docs/CROSS_PLATFORM.md](docs/CROSS_PLATFORM.md) と golden fixture を同時に更新する**(D-036)。OS 固有パス・bookmark・handle・UI設定を package に保存しない。Windows 実装後は双方向 round-trip を完了条件にする
10. **起動中・復旧中に編集可能なWorkbenchを出さない**(D-039)。読込失敗を新規作品へ自動fallbackせず、recent URLと原稿を保持する。manifest / world参照payloadは必須valid UTF-8、メモは欠損のみ省略可能で、存在するファイルの読込失敗を空文字へ変換しない
11. **実在する機能だけをUIへ出す**(D-040 / D-046 / D-054)。provider処理・プライバシー・同意設計のないAI placeholder、状態、送信shortcutを復活させない。通常版に許可するAI支援は、実際にplain textをsystem clipboardへ書く「校正用／アドバイス用プロンプトをコピー」だけで、AI実行済みと見える文言を使わない。保持中のprovider UIは`FUMINIWAExperimental`だけとし、通常の`FUMINIWA` app targetにはprovider入口、dependency、artifactを含めない。`Cmd+S`は`AppState.saveNow()`系の保存直列化へ寄せ、iCloud結線済みなら続けて明示同期する(D-073)
12. **作品ライフサイクルの対象を動的に読み直さない**(D-041)。開く／新規／別名保存／資料／snapshot／終了前保存はdocument operation gateで直列化し、現在作品に属する非同期操作と確認UIは呼び出し／表示時のsession tokenを検査する。遷移前はフォームとEditorKit境界のIMEを旧作品へ確定し、最終保存／installまでWorkbench全体の変更を止める。終了要求後は新しい作品操作を受け付けない。lock順はdocument operation gate → `DocumentSaveCoordinator`。gate付きpublic API同士の呼び出しは禁止
13. **将来provider統合を再開してもlocal identityをproviderへ送らない**(D-043 / D-054)。`NovelAI`はversion付きinstruction ID、exact prompt／schema、one-shot confirmationを維持し、`AIConfirmedRequest`へdocument session、editor surface、episode、UTF-16 range、source digest、URL／pathを追加しない。CodexとOpenRouterを自動fallbackさせず、prompt／response／diff／provider設定で`.novelpkg`を変更しない。現在は実providerを接続せず、この契約を休眠中の安全境界として保持する
14. **provider統合のUI／適用ロジックを分岐させない**(D-046 / D-054)。再開時も選択snapshot、exact preview、送信確認、cancel、diff、stale、Copy、明示Applyは一つのprovider-neutral orchestrator／UIを使い、process／HTTP、credential、model設定、保持情報、typed errorだけをadapterごとに分離する。B4-E、Codex／OpenRouter adapter、network、key、実原稿送信は最新stable SDK／APIの明示再評価と新Decisionまで実装しない
15. **clipboard prompt支援をprovider機能へ拡張しない**(D-054)。通常版のprompt生成は`NovelAI`、Experimental source、provider、network、Keychain、subprocessへ依存させない。選択／話／章の明示scope以外の原稿、metadata、local identity、URL／pathを加えず、コピー後の自動送信／paste／chat起動／response取込／Applyを行わない。system clipboardを履歴非保持またはsecure erase可能と扱わない

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

- 保存要求は revision ベースで直列化している(D-017)。新しい保存契機は `AppState.saveNow()` / `saveAndSyncNow()` に寄せる。自動保存から iCloud send を始めない(D-073)
- live 同期は `NoteSyncCoordinator`。`WorkSyncCoordinator` と Episode lease は履歴／旧 test 用。新しい分岐を旧経路へ足さない（[docs/CODE_HEALTH.md](docs/CODE_HEALTH.md)）
- `AppState.swift` と Mac/iOS の Device Sync 対ファイルは既に厚い。新しい 200 行を本体へ足さず、触る機能の extension へ寄せる
- `.derivedData/` と `NovelApp 20??-…` 退避フォルダはコミットしない
- W0 と Package Validator Gate は未完了。invalid UTF-8 の部分補修だけで package 検証・Windows 互換・公開準備の完了を宣言しない
- `NovelAI`、Experimental fake UI、B1〜B4-Dは削除せず保持するが、AI公開・provider 利用可能ではない。B4-E は明示再評価と新 Decision まで着手しない。clipboard 成功を provider の privacy へ一般化しない
- `EditorContext` は delegate ごとの本文スナップショット。超長文の性能は将来の最適化
- GitHub `origin/main` とローカル `main` は履歴が分岐している。載せ方は CODE_HEALTH.md 7章。ローカル merge と GitHub PR を混同しない
