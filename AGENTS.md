# AGENTS.md — AIエージェント向け作業ガイド

macOS ファーストのマルチプラットフォーム日本語小説執筆アプリ。現行 macOS 版は SwiftUI シェル + `NSTextView`(TextKit 2)エディタ、将来の Windows 版は WinUI 3 + C# / .NET とし、`.novelpkg` フォルダパッケージを共通互換境界にする。

**設計の正は [docs/DESIGN.md](docs/DESIGN.md)、決定の記録は [docs/DECISIONS.md](docs/DECISIONS.md)(D-001〜)。この2つを読んでから作業すること。** OS 間互換・Windows 実装は [docs/CROSS_PLATFORM.md](docs/CROSS_PLATFORM.md) を追加で読む。次にやるべきタスクは DESIGN.md の「11. 直近の次タスク」にある。UI磨き上げの完了記録は [docs/UIPOLISH.md](docs/UIPOLISH.md)。UI-REF-1〜6の完了記録は [docs/UIREFRESH.md](docs/UIREFRESH.md)、UI-REV完了記録は [docs/UIREVISION.md](docs/UIREVISION.md)、UI Fix の完了記録は [docs/UIFIX.md](docs/UIFIX.md)、Phase UI2 と Phase 4 の完了記録は [docs/UIDESIGN.md](docs/UIDESIGN.md) / [docs/PHASE4.md](docs/PHASE4.md))。

## 現在地(2026-07-16 時点)

- Phase 0(基盤)/ Phase 1(最小執筆環境)/ Phase 2(Editorプラグイン基盤 + 自動インデント)/ Phase 3(基本操作強化)/ Phase 4(小説執筆支援機能: 4-1〜4-6)/ 旧 Phase UI(3モード刷新)/ Phase UI2(Workbench刷新)/ UI-FIX-1〜5 / UI-REV-1〜9 / UI-REF-1〜6 / UI-POL-1〜4 / Phase 5(出力、PDF除外)完了
- 動くもの: 章／話リスト(追加・選択・タイトル編集・削除・並べ替え・話移動)、NSTextView エディタ、自動字下げ(改行で常時全角スペース、`「`/`『` で字下げ解除・IME確定後も対応)、話メモ、文字数表示、キャラクター管理、登場話ジャンプ、プロットカード、伏線管理、資料添付、世界観ノート(一覧・追加・削除・並べ替え・本文編集)、話内検索ジャンプ、スナップショット保存・一覧・確認付き復元、作品タイトル／あらすじ編集、`.novelpkg` v3自動保存(2秒デバウンス)、Cmd+Q 時の終了前保存、起動時の前回作品読み込み、作品の新規・開く・別名保存、TXT / Markdown / EPUB 3書き出し、セクション別2列/3列 NavigationSplitView + 一段 native toolbar
- 次: **Phase 6(AI支援の設計・プライバシー方針)**。PDFはユーザー判断によりAI実装後のPhase 6.5へ延期(D-037)
- Windows 並行トラックの次: **W0(schema / golden fixture / portable filename 契約の固定)**。[docs/CROSS_PLATFORM.md](docs/CROSS_PLATFORM.md) を正とする

## リポジトリ構成

```
NovelApp/            アプリ本体(AppState / ContentView / AppDependencies)
NovelKit/            ローカル Swift Package(ライブラリ群 + 全テスト)
  Sources/NovelCore/     モデル(Chapter, NovelDocument, DocumentRepository)— 依存ゼロ
  Sources/NovelStorage/  .novelpkg の読み書き(NovelpkgRepository)
  Sources/NovelExport/   TXT / Markdown / EPUB 3の生成とアトミック書き出し
  Sources/EditorKit/     エディタ(EditorView / プラグイン / IndentRules / MacTextAdapter)
  Sources/NovelUI/       共有 SwiftUI 部品(まだ薄い)
  Sources/PreviewSupport/ Preview 用固定データ(まだ薄い)
project.yml          XcodeGen 定義。NovelWriter.xcodeproj は生成物(コミット禁止)
Scripts/check.sh     ローカルCI。マージ前に必ず全通しすること
docs/                DESIGN.md(設計)/ DECISIONS.md(決定記録)
```

## 破ってはいけないルール

1. **依存方向**(DESIGN 9.1): NovelCore は何にも依存しない。NovelStorage / NovelExport / EditorKit / NovelUI → NovelCore のみ。違反はコンパイルで落ちるように Package.swift が組んである
2. **テキスト所有権**(D-005 / D-028): 編集中の本文の正は `NSTextView` 側。SwiftUI の update サイクルから `textView.string` を書き換えるのは話切り替え時のみ。素朴な双方向 `Binding<String>` は禁止。IME 変換中(`hasMarkedText`)はモデル反映もプラグイン介入もしない
3. **TextKit 2**(D-006): `NSTextView.layoutManager` に触れない(触れると TextKit 1 に暗黙フォールバックする)。`textLayoutManager` を使う
4. **公開APIに `NSTextView` / `UITextView` を出さない**(DESIGN 9.2)。AppKit 依存コードは `EditorKit/Platform/` 配下 + `#if canImport(AppKit)` 内のみ
5. **章順は `NovelDocument.chapters`、話順は `Chapter.episodes` の配列順が唯一の正**(D-004 / D-028)。order フィールドを追加しない。v3保存形式ではmanifestだけが両方の順序を持ち、本文・メモのファイル名はEpisodeID(UUID)ベース
6. **`.novelpkg` の内部構造を NovelStorage の外に漏らさない**(DESIGN 9.3)
7. **エディタ機能は EditorPlugin として追加する**(DESIGN 4.4)。EditorView / MacTextAdapter を直接太らせない。純粋な判定ロジックは `Rules/` に切り出してテストする
8. **UI を触る PR は [docs/STYLE.md](docs/STYLE.md)(デザイン言語)に従う**。ダーク基調だがライト外観も壊さない(セマンティックカラー原則。D-021 補足参照)。色・タイポ・余白・文言の規約と、提出前チェックリスト(STYLE.md 9章)がある。トークン外の hex 直書き・フォントサイズ直指定・常設の影は規約違反
9. **`.novelpkg` の互換契約を変更する場合は [docs/CROSS_PLATFORM.md](docs/CROSS_PLATFORM.md) と golden fixture を同時に更新する**(D-036)。OS 固有パス・bookmark・handle・UI設定を package に保存しない。Windows 実装後は双方向 round-trip を完了条件にする

## エディタにプラグインを足す手順(Phase 2 で確立)

1. 判定ロジックを `EditorKit/Rules/` に純関数で書く(AppKit 禁止、`String` + UTF-16 `NSRange`。変換は `Range(_:in:)` 経由)+ swift-testing でテスト
2. `EditorKit/Plugins/` に `EditorPlugin` 準拠の薄いクラスを作り、Rules の判定を `EditorAction` に写像する
3. `MacTextAdapter.Coordinator` の `pipeline`(現在 `[IMEGuardPlugin(), IndentPlugin()]`)に登録。**IMEGuardPlugin より後ろに置くこと**
4. `EditorKitTests/MacTextAdapterIntegrationTests.swift` の方式(実 NSTextView + Coordinator を直接組み立てて delegate を駆動)で統合テストを書く。**Undo で戻ることも必ずテストする**

## 開発ワークフロー

- **GitHub Flow**: main から `feat/…` ブランチ → PR(テンプレート: .github/PULL_REQUEST_TEMPLATE.md)。main への直接 push 禁止。**作業開始直後にブランチを切り、区切りごとに WIP コミットする**(未コミットの作業ツリーは main への自動同期で消えることがある)
- **検証はローカルのみ**(D-014。GitHub Actions は使わない): PR 前に `./Scripts/check.sh` が「All checks passed」まで通ること(SwiftFormat lint / SwiftLint / swift test / iOS向けコンパイルチェック / NovelApp ビルド)
- Xcode プロジェクトは `xcodegen generate` で生成(D-015)。project.yml が正
- 単体テストは swift-testing(`@Test`)。XCTest は使わない
- コミットは意味単位で `feat:` / `fix:` / `docs:` / `chore:` / `style:` プレフィックス。本文は日本語可
- 必要ツール: Xcode 16+、`brew install swiftformat swiftlint xcodegen`

## 設計判断のしかた

- 新しい設計判断をしたら docs/DECISIONS.md に D-XXX として追記する(既存の決定を覆す場合は元を消さず「破棄」とマークして新しい番号で)
- DESIGN.md の内容と実装が食い違ったら、実装を直すか DESIGN.md を更新するかを明示的に決めて、変更履歴に記録する
- 作業は小さい単位で: モデル追加 / Repository 変更 / プラグイン追加 / UI追加 / テスト追加 / リファクタリングを1つの PR に混ぜすぎない(DESIGN 10章)

## 既知の注意点

- 保存要求は revision ベースで直列化している(D-017)。新しい保存契機を足す場合は `AppState.saveNow()` 系の経路に寄せること
- `EditorContext` は delegate 呼び出しごとの本文スナップショット。超長文でのパフォーマンスは将来の最適化課題
