# 決定記録(Decision Log)

設計・技術選定の決定を記録する。新しい決定は末尾に追加し、覆す場合は元の決定を消さず「破棄(→ D-XXX)」とマークする。

---

## D-001: UI は SwiftUI + AppKit(NSTextView)アダプタ構成

- **日付**: 2026-07-07 / **状態**: 承認
- **内容**: アプリシェル(ウィンドウ、サイドバー、設定画面など)は SwiftUI。本文エディタの実体は `NSTextView` を `NSViewRepresentable` でラップし、EditorKit 内に閉じ込める。
- **理由**: SwiftUI の `TextEditor` は日本語IME・長文パフォーマンス・カスタマイズ性で小説執筆に不十分。一方シェル部分は SwiftUI が生産性・将来の iOS 展開で有利。純 AppKit は制御性は最高だがコストに見合わない。Electron/Tauri 等は日本語IMEの細かい挙動制御とネイティブ感で不利。
- **結論**: v0.1 の方針(SwiftUI前提 + NSTextView)は正しいので変更しない。

## D-002: 保存形式は `.novelpkg`(フォルダパッケージ)

- **日付**: 2026-07-07 / **状態**: 一部置換（→ D-077。`.novelpkg`のportable形式は維持し、通常編集の正本／autosave先だけをSQLiteへ置き換える）
- **内容**: manifest.json + 章ごとの .md ファイル + attachments/ のパッケージ構成。
- **理由**: 単一JSONより破損に強く(1章壊れても他は残る)、添付・スナップショット・差分管理を後から足しやすい。Finder 上でパッケージとして扱える。

## D-003: 章ファイル名は ChapterID ベース、章順は manifest.json のみが持つ

- **日付**: 2026-07-07 / **状態**: 承認(v0.1 から変更)
- **内容**: `chapters/0001.md`(連番)ではなく `chapters/<UUID>.md` とする。
- **理由**: 連番だと章の並べ替えのたびに全ファイルのリネームが必要になり、保存の複雑さと破損リスクが増す。ファイル名を不変IDにすれば、並べ替えは manifest.json の書き換えだけで済む。

## D-004: `Chapter.order` を持たない

- **日付**: 2026-07-07 / **状態**: 承認(v0.1 から変更)
- **内容**: 章順は `NovelDocument.chapters` の配列順が唯一の正。`order: Int` フィールドは削除。
- **理由**: 配列順と order の二重管理は必ずズレてバグになる。

## D-005: テキスト所有権ルール

- **日付**: 2026-07-07 / **状態**: 承認(v0.1 に追加)
- **内容**: 編集中の本文の「正」は `NSTextView.textStorage`。モデル同期は didChange 時(デバウンス)、モデル→View 反映は章切り替え時のみ。IME 変換中は一切介入しない。SwiftUI の素朴な双方向 `Binding<String>` 同期は禁止。
- **理由**: 日本語IMEの「巻き戻り」の典型原因は、変換中に外部から setString されること。設計段階でルール化しておかないと後から直すのが非常に高くつく。

## D-006: TextKit 2 を明示採用

- **日付**: 2026-07-07 / **状態**: 承認(v0.1 に追加)
- **内容**: `NSTextView` は TextKit 2 で使う。`layoutManager` へのアクセスで TextKit 1 に暗黙フォールバックしないよう、デバッグビルドにアサーションを入れる。
- **理由**: 長文パフォーマンスと今後の Apple の投資先。当初は「縦書きが要件化したら再評価」としていたが、縦書き非対応が確定(D-012)したため再評価条項は解消。TextKit 2 で確定。

## D-007: 最低ターゲットは macOS 14

- **日付**: 2026-07-07 / **状態**: 承認
- **理由**: `@Observable` が macOS 14+。開発機は macOS 27 なので実害なし。上げる分には自由。

## D-008: プロジェクト構成は「アプリ + ローカル Swift Package(NovelKit)」

- **日付**: 2026-07-07 / **状態**: 承認(v0.1 に追加)
- **内容**: NovelCore / NovelStorage / EditorKit / NovelUI / PreviewSupport は `NovelKit` というローカル SwiftPM パッケージ内のターゲットとして実装し、Xcode プロジェクトはアプリターゲットだけを持つ。
- **理由**: 依存方向をコンパイラで強制でき、CI で署名なしの `swift test` が回せる。将来 iOS アプリからもそのまま利用できる。

## D-009: `DocumentRepository` は URLベース + async。「最近開いた作品」は App 層の責務

- **日付**: 2026-07-07 / **状態**: 一部置換（→ D-077。URL-based repositoryはImport／Export codecへ残し、通常作品APIはWorkID-based SQLite storeへ置き換える）
- **内容**: `load(from: URL)` / `save(_:to: URL)` の async throws API とする。v0.1 の `loadRecent()` は Repository から外し、App 層(UserDefaults + セキュリティスコープ付きブックマーク)で持つ。
- **理由**: 「どのファイルを最近開いたか」は保存形式の知識ではなくアプリの状態。Repository に入れると層が濁る。async なのはファイルI/Oをメインスレッドから外すため。

## D-010: v1 は DocumentGroup(ドキュメントベースApp)を使わない

- **日付**: 2026-07-07 / **状態**: 承認
- **内容**: 単一ウィンドウ + 明示的 Repository + 自前オートセーブ(デバウンス)。
- **理由**: `DocumentGroup` はオートセーブ・バージョンを無料で貰える反面、ウィンドウ管理と状態設計の自由度が下がり、AppState 中心の設計と噛み合わない。複数作品対応(将来)の際に再評価する。

## D-011: 配布は GitHub Releases(直接配布)。App Sandbox は採用しない

- **日付**: 2026-07-07 / **状態**: 承認(Q-2 を解決)
- **内容**: macOS 版は GitHub Releases で配布する。Mac App Store は当面対象外。App Sandbox は有効にしない。
- **理由**: Sandbox 不要なら、最近開いたファイルの再オープンはただのファイルパス保存で済み、セキュリティスコープ付きブックマークの実装が丸ごと不要になる。
- **補足**: 他人に配る段階になったら Developer ID 署名 + 公証(notarization)を推奨(未署名だと Gatekeeper 警告が出る。要 Apple Developer Program)。個人利用の間は不要。将来 App Store に出す場合は Sandbox 対応をこの決定の破棄として記録すること。

## D-012: 縦書きには対応しない

- **日付**: 2026-07-07 / **状態**: 承認(Q-1 を解決)
- **内容**: 執筆・プレビュー・出力とも縦書きはスコープ外。非目標に追加。
- **理由**: ユーザー判断。これにより TextKit 2 採用(D-006)の再評価条項が消え、エディタ基盤が確定する。
- **補足**: 将来もし欲しくなった場合、「出力(PDF/EPUB)のみ縦書き」なら本文エディタに影響せず追加できる。エディタでの縦書き執筆は本決定の破棄が必要。

## D-013: iOS 対応のタイミング

- **日付**: 2026-07-07 / **状態**: 承認(Q-3 を解決)
- **内容**: 二段構えとする。
  1. **Phase 0 から**: CI で NovelKit を iOS 向けにもコンパイルする(ビルドのみ、UIなし)。ほぼタダで「共有コードに AppKit が漏れていない」ことを常時保証でき、実装ルール 9.2 をコンパイラで強制できる。
  2. **iOS アプリ本体は Phase 5(出力)完了後に Phase 7 として着手**。macOS 版で執筆体験が安定し出力まで揃ってから。UITextView アダプタ + iOS UI はここで作る。
- **理由**: 早すぎる iOS 対応は macOS 版の足を引っ張るが、放置すると EditorKit の抽象が macOS 専用に腐る。コンパイル保証だけ先行させるのが最も安いバランス。Phase 5 完了時点で需要がなければ先送りしてよい(AI支援 Phase 6 を優先して構わない)。
- **補足**: 当初「CI で」としていた iOS コンパイル保証は、D-014 によりローカルの `Scripts/check.sh` で行う(内容は同じ)。

## D-014: CI/CD はローカル実行のみ。GitHub Actions は使わない

- **日付**: 2026-07-07 / **状態**: 承認(ユーザー判断。Phase 0 の GitHub Actions CI を置き換え)
- **内容**: クラウド CI(GitHub Actions)は廃止。検証は `Scripts/check.sh` をローカルで実行する。内容は SwiftFormat(lint)→ SwiftLint → `swift test` → iOS 向けコンパイルチェックで、旧 CI と同一。マージ前に必ず実行する運用とする。
- **理由**: ユーザーの方針。個人開発では macOS ランナーの待ち時間・管理コストに見合わない。GitHub Flow(ブランチ + PR)自体は継続する。
- **補足**: Phase 0 で一度 GitHub Actions を構築し正常動作を確認済み(履歴: `.github/workflows/ci.yml`、初回 run で lint 設定の不備を1件検出・修正)。将来チーム開発になったら本決定を破棄して復活させればよい。

## D-015: Xcode プロジェクトは XcodeGen で生成する

- **日付**: 2026-07-08 / **状態**: 承認(D-008 の具体化、Phase 1-C で導入)
- **内容**: `NovelWriter.xcodeproj` はコミットせず、リポジトリルートの `project.yml` から `xcodegen generate` で生成する。正は常に `project.yml`。
- **理由**: pbxproj の手書き・手動管理はエラーの温床で、diff も読めない。project.yml なら宣言的でレビュー可能、AIエージェントにも扱いやすい。
- **補足**: 開発者(と `Scripts/check.sh`)は `brew install xcodegen` が必要。将来 XcodeGen が Xcode の新形式に追従できなくなったら再評価。プロジェクト名だけは **D-038** により `FUMINIWA.xcodeproj` へ改称したが、生成物をコミットせず `project.yml` を正とする契約は維持する。

## D-016: 新規作品の既定保存先と自動保存の方針

- **日付**: 2026-07-08 / **状態**: 一部破棄（→ D-063／D-077。最大2秒のlocal autosaveは維持し、通常保存先、recent path、package commitをSQLite＋CASへ置き換える）
- **内容**:
  - 新規作品の既定保存先は `~/Documents/NovelWriter/<作品タイトル>.novelpkg`。同名が存在する場合は連番(`新規作品2.novelpkg` など)で回避する
  - 自動保存: モデル(メモリ上の `NovelDocument`)への反映は編集のたびに即時。ディスクへの保存は本文編集では**2秒デバウンス**、章切り替え・章追加・並べ替え・アプリ非アクティブ時(`willResignActiveNotification`)は**即時**
  - 「最近開いた作品」は UserDefaults にファイルパスで記録(D-011 により Sandbox 不要のため、これで足りる)
- **理由**: 執筆中のキーストロークごとのディスクI/Oを避けつつ、データ喪失ウィンドウを最大2秒に抑える。章操作は頻度が低く保存コストが小さいので即時が安全。
- **既知の制限**: ~~アプリがアクティブなまま Cmd+Q した場合、最後の編集から2秒未満だと未保存になりうる~~ → **D-017(Phase 3)で解消済み**(`applicationShouldTerminate` での終了前保存)。
- **改訂**: 既定保存先の製品フォルダ名だけは **D-038** により `~/Documents/FUMINIWA` へ変更した。既存の `~/Documents/NovelWriter` 内の作品は移動・削除せず、記録済みURLからその場で開く。

## D-017: Phase 3 の終了前保存とスナップショット保存

- **日付**: 2026-07-08 / **状態**: 一部置換（→ D-077。終了前にlocal commitを完了することと保存直列化は維持し、package内SnapshotをSQLite／CAS Snapshotへ置き換える）
- **内容**:
  - `applicationShouldTerminate` で終了を一旦待たせ、保留中のデバウンス保存をキャンセルして現在の `NovelDocument` を保存してから終了を許可する。保存に失敗した場合は終了をキャンセルする。
  - App 層の保存要求は revision ベースで直列化し、本文編集・章操作・並べ替え・終了前保存が同じ保存経路を通るようにする。
  - スナップショット保存は `SnapshottingDocumentRepository` として保存層の能力に分離する。`.novelpkg` 実装では `snapshots/<timestamp>.novelpkg` に現在状態を退避し、通常保存では既存 `snapshots/` を保持する。
- **理由**: D-016 の Cmd+Q 直後の未保存ウィンドウを解消しつつ、高速な章操作や並べ替えで保存処理が重なって古い状態が後勝ちするリスクを下げる。スナップショットの置き場所は保存形式の詳細なので、App 側からは抽象プロトコル越しに扱う。
- **補足**(実装レビューで確定): revision ベースの保存直列化は NovelCore の `DocumentSaveCoordinator`(@MainActor)に切り出した。保存処理と保存対象の取得はクロージャ注入とし、NovelCore の依存ゼロ原則(9.1)を維持。「実行中の保存がある場合は owner が dirty ゼロになるまでループし、待機側は owner の結果を受け取る」方式で、保存完了直後の隙間に入った変更が保存されないまま成功が返る競合(初版実装に存在)を排除。この interleaving はユニットテストで回帰保証している(`DocumentSaveCoordinatorTests`)。
- **補足2**(Phase 4 レビューで追加): 添付ファイルの追加・削除のように「パッケージ全置換の保存と重なるとデータを失う操作」のため、`performExclusive(_:)` を追加した。実行中の保存の完了を待ってから排他区間を開始し、区間中は新しい保存を一切開始させない(区間中に来た保存要求は区間終了後に通常手順で実行)。**排他区間の中で `saveNow()` を呼ぶとデッドロックする**ため、保存の排出は区間の前に行うこと(添付操作の呼び出し側パターンは `AppState.addAttachment` を参照)。
- **補足3**(D-041レビューで追加): 別名保存のように「保存排出後のURL切替」と「操作中に増えたrevisionの新URLへの保存」を一つの不可分な境界にする場合は、二段の`saveNow(); performExclusive { ... }`ではなく`performExclusiveAfterFlushing(flushAfter:)`を使う。排他を取得したまま事前保存、package操作、URL切替、事後保存を順に行い、旧URLへ保存が再開する隙間を作らない。

## D-018: Phase 4 メタデータの保存配置とフォーマットバージョン方針

- **日付**: 2026-07-08 / **状態**: 承認(Phase 4-1 で実装。実行計画は docs/PHASE4.md)
- **内容**:
  - Phase 4 で増えるデータの置き場所: 章メモ = `notes/<ChapterID>.md`(本文と同じくファイル分割、空メモはファイルなし)、キャラクター = `characters.json`、シーンカード = `plot.json`、伏線 = `flags.json`。各 JSON は prettyPrinted + sortedKeys、配列順 = 表示順(D-004 の原則を踏襲し order フィールドは持たない)
  - `formatVersion` を "2" に上げる。読み込みは "1" / "2" を受理し、"1" は新ファイルの欠損を「空」として読む(マイグレーション = 次回保存で "2" になる)。当初は "3" 以上をエラーとしていたが、**v3 は D-028 で定義**し、未対応の "4" 以上をエラーとする
  - **保存時にパッケージ直下の未知のファイル/ディレクトリを保持する**(保存はパッケージ全置換のため、これが無いと古いアプリが新しいパッケージを保存した際に新規データを消してしまう。将来のフォーマット追加への安全弁)
- **理由**: manifest.json への一極集中はサイズ・git差分・部分破損耐性で不利。章メモを本文と同じ「章ID対応ファイル」にすることで、1章分の破損が他に波及しない既存方針(D-002)を保つ。バージョンを上げるのは、v2 を知らない旧バイナリが黙ってデータを落とすより「開けない」方が安全なため(未知ファイル保持は同一メジャー内の追加への保険)。
- **補足**: 添付(attachments/)への操作は 9.3 により App から直接行わず、NovelCore の抽象プロトコル経由とする(詳細は PHASE4.md 4-6)。
- **補足2**(2026-07-11): Chapter / Episode 階層と `formatVersion` "3" は D-028 を正とする。本決定の章メモ配置(`notes/<ChapterID>.md`)は v1 / v2 の読み込み互換として残し、v3 保存では `episode-notes/<EpisodeID>.md` へ移る。

## D-019: UI は単一ウィンドウ・3モード制。プロットは章レーンボード、キャラはシート型

- **日付**: 2026-07-08 / **状態**: 破棄(→ D-021。実装済みだが新UI方針で置き換える)
- **内容**:
  - ウィンドウ1枚のまま、ツールバーの segmented control(Cmd+1/2/3)で **執筆 / キャラクター / プロット** の3モードを切り替える。右インスペクタに全機能を詰める現行構造は廃止し、インスペクタは執筆モード専用の「章コンテキスト」(章メモ・この章のカード/登場キャラ・資料)に縮小する
  - **プロットモード = 章レーン式カードボード**: レーン=章(+未割り当て)、カード=シーン。レーン間ドラッグ= `chapterID` 付け替え、レーン内ドラッグ=順序変更。既存モデル `PlotCard { title, memo, chapterID? }` と1:1で写像でき、モデル変更なしで成立する
  - **キャラクターモード = シート型**: 左に一覧、中央にテンプレート項目のプロフィールシート(基本/口調/設定/自由メモ/登場章)。`Character` に Optional フィールドを追加(後方互換は decodeIfPresent)
- **理由**: 定番ツールの調査に基づく。Nola(国内の作家向け定番)はテンプレート項目式キャラシート、Scrivener はカード操作の corkboard、Plottr はレーン式の視覚的プロットで支持されている。章レーンボードは Scrivener × Plottr の折衷で、既存データモデルに一切手を入れずに導入できる案を優先した。260pt のインスペクタにキャラ設計・プロット構成を同居させる現行 UI は、作業モードの異なる機能の混載であり狭すぎる
- **破棄理由**: 3モード制は「キャラクター設計」「プロット構成」を広い画面に出す点では改善したが、執筆中に常に参照したい Outline / 状態 / AI支援がモード切替で分断される。新方針では Project Sidebar + Outline + Editor + 下部AIパネルの常設ワークベンチに移行する。
- **非目標(将来)**: キャラクター関係図、複数プロットライン、カスタムテンプレート項目

## D-020: デザイン言語を STYLE.md として制定(awesome-design-md 形式の借用)

- **日付**: 2026-07-08 / **状態**: 承認
- **内容**: 見た目と手触りの唯一の正として docs/STYLE.md を制定。構成(テーマ→カラー→タイポ→スペーシング→コンポーネント→階層→状態→文言→AIチェックリスト)は [awesome-design-md](https://github.com/VoltAgent/awesome-design-md) の DESIGN.md 形式を借用し、中身はネイティブ macOS 前提で自作。UI を触る PR は STYLE.md 準拠を必須とする(AGENTS.md ルール8)。
- **理由**: UIDESIGN.md は画面構成を定義したがデザイン言語が未定義で、AIエージェントが PR ごとにバラバラの見た目を作るリスクがあった。既製ブランドの DESIGN.md をそのまま使わないのは、Web の CSS 由来トークン(固定hex・shadow流儀)がネイティブのセマンティックカラー・素材・HIG と衝突し「ネイティブなのにWebアプリっぽい」見た目になるため。
- **要点**: セマンティックカラー最優先(hex はトークンのみ)/ 藍アクセント / エディタ本文は明朝16pt・行間1.5 / 8ptグリッド / 常設影の禁止 / 日本語UIライティング規約 / 提出前チェックリスト。

## D-021: UI は4領域ワークベンチ + 下部AI Assistant Panel に刷新する

- **日付**: 2026-07-08 / **状態**: 一部破棄(Project Sidebar / Outline / EditorのWorkbenchは維持。AI Assistant Panelの常設はD-040で破棄し、chrome外観方針はD-040へ更新)
- **内容**:
  - 画面は **Project Sidebar / Outline / Editor / AI Assistant Panel** の4領域を基本構造にする
  - 左の Project Sidebar は 作品情報 / 企画 / 執筆 / プロット / 登場人物 / 世界観 / 資料 / 設定 をアイコン + ラベルで並べる。幅は固定気味にし、macOS のサイドバーらしい静かなナビゲーションにする
  - 中央左の Outline は原稿・章・シーンの一覧を担う。各項目にタイトル、文字数、更新状態を出し、ドラッグ並び替えに対応する。検索バーは通常隠し、上方向スクロールまたは Cmd+F で表示する
  - 中央右の Editor は最も広い領域とし、上部に現在の章タイトル、検索、履歴、プレビュー、保存状態を置く。本文は長時間執筆向けに余白と行間を広めにする。自動保存、自動字下げ、将来のルビ対応を前提にする
  - 下部の AI Assistant Panel は VS Code のターミナル領域のように画面下から開閉する。展開時はチャット入力欄、提案一覧、選択中テキストへの操作ボタンを持つ。閉じている時は保存状態、文字数、カーソル位置、AI状態、執筆モードを出す薄いステータスバーにする
  - UI は macOS 専用、SwiftUI シェル、ダークテーマ、キーボード主体で設計する
  - View は `ProjectSidebarView` / `OutlineView` / `EditorPaneView` / `AIAssistantPanelView` に分割し、`ContentView` を肥大化させない
  - 将来的な機能追加のため、Project Sidebar のセクション単位で Outline / Detail / Command / StatusItem を差し込めるプラグイン風の構造に寄せる
- **理由**: 小説執筆では「本文を書く」「章やシーンを並べ替える」「人物・資料・プロットを参照する」「AIに相談する」が頻繁に往復する。3モード制は各機能を広く使える一方で、作業中の文脈が切り替わりやすい。4領域ワークベンチなら、章構造と本文を常に見ながら、必要な補助機能を Project Sidebar と下部パネルから呼び出せる。特にAI支援は将来の中核機能になるため、右インスペクタではなく下部パネルとして本文の横幅を圧迫しない構造にする。
- **非目標(この決定ではやらない)**: AIプロバイダ接続の本実装、シーン永続モデル、世界観モデル、複数ウィンドウ、iOS UI、縦書き。
- **補足**(レビューで明確化): 本文中の「ダークテーマ」は**ダーク基調のデザイン方向**の意であり、STYLE.md 1章の「ダーク/ライト両対応(セマンティックカラーで自動化)」の原則は維持する。ライト外観を意図的に壊す実装(ダーク前提の固定色など)は不可。
- **改訂**(2026-08-07): 未実装AIのplaceholder panel、AI状態表示、`Cmd+J`は商業化時の機能誤認を避けるためD-040で出荷UIから撤去した。下端は保存状態と文字数を伝えるstatus barとして維持する。

## D-022: 出力の前に作品ライフサイクルと保存状態を安定化し、出力は独立モジュールにする

- **日付**: 2026-07-10 / **状態**: 承認(第3項のPDFをPhase 5対象とする部分はD-037で破棄)
- **内容**:
  1. UI2 完了後の次タスクを直ちに Phase 5 へ進めず、Phase 4.5 として「保存状態の可視化・保存失敗時の導線」「新規／開く／別名保存」「復旧性・保存性能の基準化」を先に行う。
  2. 出力は `NovelExport` SwiftPM ターゲットに分離し、`NovelCore` だけに依存させる。`NovelStorage` の `.novelpkg` 内部構造、AppState、UI に依存させない。macOS 固有の PDF 実装は `NovelExport/Platform/macOS/` と条件コンパイル内に置き、公開 API に AppKit 型を出さない。
  3. Phase 5 の v1 対象はプレーンテキスト、Markdown、EPUB 3、PDF。出力対象は作品名・章名・話名・本文だけで、メモ・人物・プロット・伏線・添付・スナップショットは含めない。EPUB/PDF は横書きの最小仕様とし、縦書き・ルビ・画像埋め込み・高度な組版は対象外とする。章／話の順序と空要素の扱いはD-028およびPHASE5.mdを正とする。**PDFをPhase 5に含める部分はD-037で破棄し、AI実装後へ延期した。**
  4. 出力は呼び出し時の `NovelDocument` 値を入力にし、本文編集と自動保存をブロックしない。生成物は一時 URL に書き、成功時のみ目的地へ置き換える。
- **理由**: 現状は自動保存・終了前保存・添付操作の排他制御が整っている一方、通常操作の新規／開く／別名保存がなく、保存失敗が UI で判別できない。これを残したまま出力と配布へ進むと、原稿を扱うアプリとしての信頼性を損なう。また書き出しが `.novelpkg` を直接読めば保存形式と出力形式が密結合になり、将来の iOS 対応・別ストレージ・テスト容易性を損なう。純粋な `NovelDocument` から出力すれば、形式別テストと安全な非同期処理を両立できる。
- **補足**: 保存性能は大きい添付・多数の snapshots により劣化しうるが、まず代表データで測定してから改善する。測定なしにパッケージ保存を差し替えない。詳細なサブフェーズと出力仕様は [PHASE5.md](PHASE5.md) を正とする。

## D-023: 作品切り替えは候補を先読みし、別名保存の付随データ複製は保存層へ委譲する

- **日付**: 2026-07-10 / **状態**: 一部破棄（→ D-063。候補先読みと保存層へのpackage複製委譲は維持し、macOS標準導線の新規保存先とactive URLを切り替える別名保存は置き換える）
- **内容**:
  1. 別作品を開く際は、候補の `NovelDocument` と資料一覧を一時値へ読み込み、現在作品の未保存 revision を保存し終えた後にだけ AppState の document / URL / 各 selection / 資料一覧を一括で置き換える。候補の読み込みまたは現在作品の保存に失敗した場合は切り替えない。
  2. 新規作品は D-016 の既定保存先へ先に保存し、現在作品の保存と新規パッケージ保存が成功した後にだけ切り替える。I/O 待機中の編集も切り替え直前に再度保存する。
  3. 別名保存で `NovelDocument` 外の資料・スナップショット・未知項目を引き継ぐ能力は `DocumentCopyingRepository` として NovelCore に抽象化し、`.novelpkg` の具体的な複製方法は NovelStorage に閉じ込める。新しい URL と最近使った作品は複製成功後にだけ更新する。
- **理由**: async I/O の途中で AppState を段階的に書き換えると、後半の失敗時に本文・選択・資料が別作品同士で混ざる。また App 層が付随データを直接コピーすると `.novelpkg` の内部構造が漏れる。候補を先読みして最後に同期的に確定し、パッケージ固有の複製を能力プロトコルへ委譲すれば、編集中の保存直列化とストレージ境界の両方を維持できる。

## D-024: 上部は3列に追従する一体型 toolbar とし、編集操作だけをカスタマイズ可能にする

- **日付**: 2026-07-10 / **状態**: 承認(Toolbar-1 / Toolbar-2 / UI-FIX-4で実装済み。pane固有操作の配置はD-029で一部改定)
- **内容**:
  1. Workbench 上部は独自のペイン内バーを重ねず、Project Sidebar / Outline / Editor に追従する macOS ネイティブの一体型 toolbar へ寄せる。Project Sidebar 上は標準の表示／非表示、Outline 上は作品名 + 章数、Editor 上は一段の操作列 + 右端の話内検索とする。
  2. Sidebar toggle、Outline identity、話内検索は構造上のアンカーとして固定する。章／話追加、話メモ、スナップショット、「この章」などの編集操作は、stable ID を持つ個別の `ToolbarItem` とし、macOS 標準UIで追加・削除・並べ替え可能にする。
  3. すべての toolbar 操作にメニューバーまたは文脈メニューの代替入口を用意し、toolbar を非表示にしても機能を失わない。カスタマイズ状態は OS に委ね、`NovelDocument` / `.novelpkg` / AppState へ保存しない。
  4. ネイティブの列追従と Sidebar toggle を得るため、二重の `HSplitView` は3列 `NavigationSplitView` へ段階的に移行する。toolbar 所有者は `NovelWorkbenchView` 一箇所に限定し、EditorKit は変更しない。
- **理由**: 長時間執筆では本文の縦幅と、頻用操作への一手での到達が重要である。macOS 標準 toolbar はユーザーごとの作業スタイルに合わせたカスタマイズ、overflow、メニューとの一貫性を提供できる。一方、すべてを自由移動可能にするとペインの開閉・現在地・検索の位置まで失われるため、固定の構造要素と可変の編集操作を分ける。
- **制約**: macOS 14 の SwiftUI では「全項目を自由に移動」と「各項目を常に特定ペインの真上へ固定」は同時保証できない。初期配置を3領域に合わせ、カスタマイズ対象は中央の編集操作に限定する。厳密な tracking separator のための AppKit bridge は採用しない。

## D-025: 別名で保存は Cmd+Shift+S、スナップショット保存は Cmd+Option+S に割り当てる

- **日付**: 2026-07-10 / **状態**: 一部破棄（→ D-063。`Cmd+Shift+S`はactive identityを変えない「書き出す…」へ置き換え、`Cmd+Option+S`のスナップショット保存は維持する）
- **内容**: File メニューの「別名で保存…」に macOS の慣習どおり `Cmd+Shift+S` を割り当てる。従来この組み合わせを使っていた「スナップショットを保存」は `Cmd+Option+S` へ移す。
- **理由**: `Cmd+Shift+S` は macOS アプリ全般で「別名で保存」を意味する強い慣習であり、Phase 4.5-2b で「別名で保存…」を新設するにあたりこの慣習を優先した。スナップショットは執筆中の補助機能であり、慣習上の固定割当を持たないため、衝突回避の移動先として `Cmd+Option+S` を採用した。

## D-026: スナップショット復元は現在状態を先に退避する

- **日付**: 2026-07-10 / **状態**: 承認(Phase 4.5-3a で実装)
- **内容**:
  1. `SnapshottingDocumentRepository` に一覧(`listSnapshots`)と書き戻し(`restoreSnapshot`)を追加する。置き場所やファイル名規則は保存層に閉じ込め、App は `DocumentSnapshotInfo` の URL / 表示名だけを扱う。
  2. 復元は確認ダイアログのあと、(1) 対象スナップショットの読み込み (2) 現在作品の保存完了 (3) 現在状態の `saveSnapshot` (4) 現在パッケージへの書き戻し (5) メモリ状態の置換、の順で行う。失敗した段階で止め、`documentURL` / 本文 / 資料一覧を切り替えない。
  3. 書き戻しでは本文・資料はスナップショットから、既存の `snapshots/` は現在パッケージから引き継ぐ。
- **理由**: 復旧導線を破壊的にしないことが Phase 4.5-3a の完了条件であり、復元前退避を App 層のトランザクションとして固定することで、保存形式の詳細を知らなくても安全に戻せる。

## D-027: 保存性能は代表パッケージで測り、予算超過時だけ改善する

- **日付**: 2026-07-10 / **状態**: 承認(Phase 4.5-3b で計測・採否)
- **内容**:
  1. 代表パッケージは **1 MB 本文 + 100 MB 添付 + 20 スナップショット** とする。
  2. 上書き保存の許容 wall time は **15 秒**(`SavePerformanceBudget.overwriteSaveDuration`)。UI 応答性は、遅い `saveOperation` のあいだ MainActor がハートビートできることを常時テストで保証する。
  3. 重い実測は `NOVELWRITER_PERF_TEST=1 ./Scripts/measure-save-performance.sh` でのみ実行し、`Scripts/check.sh` には含めない。
  4. 予算を超えた場合に限り、snapshots の保持方法・保持数・コピー方式を別 PR で改善する。測定なしの保存形式全面変更はしない。
- **実測 (2026-07-10)**: 上書き保存 0.039s(準備 0.035s)。APFS 同一ボリュームでは `copyItem` が clonefile になり実バイトコピーにならないため、現状は予算を大きく下回る。
- **採否**: **現状維持**(改善 PR は作らない)。非 APFS やクロスボリュームで劣化が観測されたら、本決定の予算を基準に再判定する。

## D-028: 原稿は Chapter(章) / Episode(話)の2階層とし、出力より先に移行する

- **日付**: 2026-07-11 / **状態**: 承認(UI-FIX-2a〜5で実装済み。Phase 5はD-032のWorkbench再調整完了後に開始)
- **内容**:
  1. `Chapter` は章タイトルと順序付きの `[Episode]` を持つ構造とし、本文は持たない。`Episode` は `EpisodeID`、話タイトル、本文、メモを持つ編集単位とする。章順は `NovelDocument.chapters`、話順は `Chapter.episodes` の配列順だけを正とし、どちらにも `order` を追加しない。
  2. `PlotCard.chapterID` と `Flag` の張った章／回収章は章単位の参照として維持する。今回 `episodeID` 参照は追加しない。現行の章メモは v1 / v2 → v3 移行時に生成される話のメモへ移し、章自体のメモは追加しない。
  3. `.novelpkg` は v3 とし、manifest が章順と章内の話順を持つ。本文とメモは `EpisodeID` ベースのファイルへ分離する。v1 / v2 は各旧章の `ChapterID` と章タイトルを保ち、その本文・メモをタイトル「本文」の1話へ移して読み込む。読み込みは v1 / v2 / v3、保存は v3 とする。未対応の `formatVersion` "4" 以上はエラーとする(D-018 の「未知メジャーは開けない」方針を継承)。
  4. AppState の選択は `selectedChapterID` / `selectedEpisodeID` に分け、EditorKit へ渡す切り替えキーは `EpisodeID` とする。本文所有権(D-005)は話切り替え時だけモデルから本文を流し込む形で維持する。
  5. 新規作品は「第1章 + タイトル『本文』の話1件」で始め、すぐ編集できる状態を維持する。「章を追加」は空の章を作り、話が無いあいだは `ContentUnavailableView` を出す。「話を追加」で空の話を追加して選択する。
  6. 検索・文字数・登場箇所検出は `Episode` 単位へ移す。PlotCard / Flag の章ジャンプは章単位のままとし、ジャンプ先はその章で最後に選んだ話(なければ先頭の話)とする。
  7. Phase 5 の出力は作品→章→話の配列順を共通の原稿展開処理で走査し、全形式で章見出しと話見出しを区別する。空章は章見出しだけ、空話は話見出しだけを出力する。詳細な改行・空タイトル規則はPHASE5.mdを正とする。
- **理由**: 章を本文の編集単位として扱う現行モデルでは、章の中に複数の話を持つ構成を表現できず、執筆 Outline とプロットの章選択も同じ意味にならない。出力実装後に階層を変えると全形式のレンダラと fixture を作り直すため、出力前に保存形式・選択状態・UIを一貫して移行する方が安全である。既存の ChapterID を章側に残せば、プロットカードと伏線の参照を壊さず移行できる。

## D-029: Outlineはtranslucent materialへ統一し、pane固有の追加操作はpaneへ固定する

- **日付**: 2026-07-11 / **状態**: 承認(UI-REV-1〜4で実装済み。実装計画は [UIREVISION.md](UIREVISION.md))
- **内容**:
  1. Project Sidebarを含むすべてのOutlineは、不透明な`.bar`背景ではなく、背面がわずかに見えるmacOS標準の`.thinMaterial`を共通surfaceとする。標準List選択、focus ring、Reduce Transparency fallbackはOSへ委ねる。
  2. Plot detailは上段Plot canvas／下段伏線の`VSplitView`とし、下段だけを伏線一覧／詳細の`HSplitView`にする。Plotカードは章レーンの囲いを持たず、Outline選択を文脈として横方向へ連続表示する。
  3. Plotカードは`PlotCardID`をdrag payloadとし、Plot Outlineの章または未割り当てへdropして`chapterID`を変更できるようにする。
  4. D-024のうち、Sidebar toggleとEditor共通操作を一体型toolbarへ置く方針は維持する。一方、章追加などpane固有の追加操作は厳密な位置を優先してOutline headerへ固定し、カスタマイズ対象から外す。Editor側の話追加は`square.and.pencil`としてEditor上部左端へ置く。
- **理由**: UI-FIX-5はOutlineの操作作法だけでなく背景まで不透明な方向へ統一してしまい、意図したmacOSのglass感と逆になった。またmacOS 14では自由なtoolbar移動とpane直上への固定を同時保証できないため、構造操作の位置を優先してD-024を部分的に修正する。

## D-030: 明示的な執筆補助はEditor command境界から選択範囲を置換する

- **日付**: 2026-07-11 / **状態**: 承認(UI-REV-5〜6で実装済み。実装計画は [UIREVISION.md](UIREVISION.md))
- **内容**:
  1. Editor下部へ`……`、`――`、ルビ、傍点のcompact accessory barを置く。これはユーザーが明示的に実行するcommandであり、自動入力変換の`EditorPlugin`にはしない。
  2. SwiftUIは本文Bindingを直接書き換えず、EditorKitのAppKit非公開command APIへ置換要求を送る。MacTextAdapterがUTF-16選択範囲、IME、Undoを管理し、置換を1 Undo単位にする。
  3. ルビは`｜親文字《ルビ》`、傍点は`｜字《・》`(1文字ずつ。→ **D-034 で改訂**。旧 `《《対象文字列》》` は廃止)へ固定する。ルビは選択ありで入力欄をprefillして元範囲を置換。傍点は選択範囲の直接変換(D-034)。キャンセル、stale range、IME変換中は本文を変更しない。
- **理由**: 本文所有権D-005 / D-028を守りながら選択文字列を扱うには、SwiftUIモデル経由ではなくNSTextView内部の正規編集経路へ命令する必要がある。公開APIへNSTextViewを出さず、UndoとIMEを同じ境界で保証する。

## D-031: 「企画」を廃止し、あらすじはproject.jsonのadditive metadataとする

- **日付**: 2026-07-11 / **状態**: 承認(UI-REV-7〜9で実装済み。実装計画は [UIREVISION.md](UIREVISION.md))
- **内容**:
  1. 永続モデルを持たない`ProjectSection.planning`を削除し、保存済みselectionが`planning`なら`projectInfo`へ移行する。Project Sidebarのショートカットは7項目へ再割当する。
  2. `NovelDocument`へ`synopsis: String`を追加し、UIでは「あらすじ」と表示する。作品情報上段でタイトルとあらすじを編集し、保存場所・状態・章数・話数・文字数・形式は下段の読み取り専用カードへ分離する。
  3. タイトルはmanifestを正として維持し、あらすじはNovelStorageだけが構造を知る`project.json`へ保存する。欠損は空文字とし、空へ戻した場合は既知項目として旧ファイルを除去する。
  4. `project.json`は`.novelpkg` v3へのadditive metadataとし、formatVersionは上げない。旧アプリはunknown root item保持により通常保存、別名保存、snapshotでファイルを維持できる。
- **理由**: 企画placeholderを残すより、作品の中心情報であるタイトルとあらすじを作品情報へ集約する方が導線が明確である。manifestへフィールドを足すと旧アプリの再保存で欠落するが、未知root itemを保持する既存方針を使えばv3互換を維持できる。

## D-032: Workbench全体をtranslucent chromeとし、Outline不要セクションと世界観ノートを導入する

- **日付**: 2026-07-11 / **状態**: 承認(UI-REF-1〜6で実装済み。次は Phase 5-1)
- **内容**:
  1. Project Sidebar / Outline / detail chromeは`.thinMaterial`を基本のsurfaceとする。原稿および世界観ノートの`EditorView`背景だけは可読性のため不透明キャンバスを維持する。Outlineの不透明`.bar`統一は引き続き禁止し、detail側の`.bar`見出しもthinMaterialへ寄せる。
  2. 長文・短文を問わず、ラベルと入力コントロールの間隔は8pt、長文入力は内側inset 8ptを共通部品で固定する。横並び`LabeledContent`は短文1行に限り、あらすじなどの長文には使わない。
  3. 作品情報と設定はOutline(content列)を持たない。`NavigationSplitView`をSidebar + Detailの2列で表示し、1行だけの概要Listは置かない。執筆・プロット・登場人物・資料・世界観は従来どおり3列とする。
  4. 世界観は章立てのないノート一覧とする。`WorldNote { id, title, content }`を`NovelDocument.worldNotes`の配列順で持ち、本文所有権は話と同じく`NSTextView`側を正とする。保存は`world.json` + `world-notes/<UUID>.md`のadditive metadataとし、formatVersionは上げない。
  5. 世界観ノートとあらすじはPhase 5 v1の出力対象に含めない。
- **理由**: UI-REVでOutlineのglass化は進んだが、detail chromeとフォーム余白が追いついておらずSwiftUIらしい透明感が分断されている。また作品情報・設定の概要Listは操作対象がなく列を浪費する。世界観は企画placeholderの代替として、自由記述の資料置き場を永続化する必要がある。出力前に保存形式と列構成を固定し、Exporter着手後の手戻りを避ける。

## D-033: 自動字下げは常時適用し、鉤括弧の字下げ解除はIME確定後にも行う

- **日付**: 2026-07-11 / **状態**: 承認(UI-POL-1で実装済み。残りは [UIPOLISH.md](UIPOLISH.md) UI-POL-2〜4)
- **内容**:
  1. **旧 R2(空白のみ行での改行時に空白を掃除して字下げしない)を廃止**し、改行は常に「改行+全角スペース1つ」を挿入する(R1')。字下げが不要な行はユーザーが自分でスペースを消す。
  2. 鉤括弧による字下げ解除(R3)は直接入力にしか効かない(日本語IMEの `「` は変換を経由し、IMEGuard が正しくパイプラインを止めるため shouldChange ベースの R3 が発火しない)。**IME確定後の textDidChange で後処理する R5 を新設**: キャレット直前が `「`/`『` で、その直前が行頭の全角スペース1つなら、そのスペースを undo 可能な正規経路で削除する。R4(変換中は不介入)とは矛盾しない。
- **理由**: 2連続改行で字下げが消える現行挙動は「常に字下げ、不要なら消す」という執筆者の期待に反する(ユーザー判断)。症状「`「` で字下げが消えない」の根本原因は R3 の設計盲点(IME 経由の入力を考慮していなかった)であり、確定後の後処理が D-005 と両立する唯一の介入点。
- **補足**: Phase 2 の確定ルールのうち R2 を破棄する改訂。DESIGN 4.5 は UI-POL-1 実装時に更新する。

## D-034: 傍点は1文字ずつのルビ点方式(｜字《・》)に改訂する

- **日付**: 2026-07-11 / **状態**: 承認(UI-POL-2で実装済み。D-030 の記法規定 3. を改訂)
- **内容**: 傍点の生成を `《《対象文字列》》` から、選択範囲の1文字(grapheme)ごとの `｜字《・》` へ変更する。改行・空白は変換対象外。傍点は選択範囲の直接変換とし入力シートを廃止(選択が空なら disabled)。置換は D-030 の command 境界のまま 1 Undo 単位。
- **理由**: `《《》》` はカクヨム限定記法で、なろう等では傍点として機能しない。1文字ずつのルビ点方式は主要投稿サイトで最も広く通用する(ユーザー指定)。
- **補足**: ルビ(`｜親文字《ルビ》`)は変更しない。D-030 のその他の規定(command 境界・IME/Undo 保証)は維持。

## D-035: 追加操作は「一覧のOutline上」、本文操作は「Editor上」にツールバーを再配置する

- **日付**: 2026-07-11 / **状態**: 承認(UI-POL-4で実装済み)
- **内容**: セクションの一覧アイテムを増やす操作(章 / 登場人物 / 世界観ノート / 資料。プロットにも章追加を追加)は Outline 上の固定ボタンに統一し、ペーン内の重複導線は撤去する。本文に作用する操作(話を追加=Editor左端固定 / 話メモ / スナップショット / プロットカードを追加)は Editor 上に置き、中央のみカスタマイズ可能とする。「この章」アイコンは利用実態が薄く削除。プロットカードの追加導線はツールバーのアイコンのみに一本化。既定配置の意図的変更のため toolbar 全体 ID を版上げする。
- **理由**: 「どこで増えるものは、その一覧の上で追加する」という空間対応で導線を覚えやすくする(ユーザー要望)。全操作にメニューバーの代替入口を維持する原則(TOOLBAR.md 5章)は不変。

## D-036: `.novelpkg` を公開互換境界とし、Windows 版は WinUI 3 で同一リポジトリに実装する

- **日付**: 2026-07-16 / **状態**: 承認(Windows 実装前。詳細契約は [CROSS_PLATFORM.md](CROSS_PLATFORM.md))
- **内容**:
  1. 製品方針を macOS 専用から **macOS ファーストのマルチプラットフォーム**へ拡張する。Windows 版は WinUI 3 + C# / .NET とし、同一リポジトリの `Windows/` 配下に置く。
  2. Swift の `NovelCore` / `NovelStorage` / `EditorKit` や SwiftUI View を Windows から直接再利用しない。共有の正は `.novelpkg` schema、Chapter / Episode 等のドメイン意味、純粋ロジックと Export の入出力 fixture、日本語 UI 用語とする。Windows 側は同じ依存方向を .NET class library で再実装する。
  3. `.novelpkg` は OS 間の公開互換境界とする。読み込み v1 / v2 / v3・保存 v3、UTF-8(BOMなし)、ISO 8601 UTC、UUID、配列順、未知ルート項目保持、OS 固有パスを保存しないことを共通契約にする。添付名は Windows の禁止名と case-insensitive 衝突を考慮する。
  4. Windows 実装の前に W0 として言語非依存 schema と golden fixtureを作り、macOS reader / writerを補修・検証する。W0完了後のW1で、Mac writer → Windows reader、Windows writer → Mac reader、両方向round-tripで本文・メタデータ・添付・スナップショット・未知項目が失われないことを品質ゲートにする。
  5. 保存 API は OS ごとに異なってよいが、「同じ親に完全な一時パッケージを作り、完成前のデータで既存作品を壊さず、失敗時は既存作品と dirty 状態を維持する」という結果を共通要件にする。
  6. UI は各 OS の native 慣習に従う。macOS の D-021 / STYLE.md の画面表現を WinUI へ機械的に複製せず、テキスト所有権、機能の意味、情報構造を共有する。Windows 固有のデザインガイドは WinUI 実装開始時に別途作る。
- **理由**: `.novelpkg` は JSON、UTF-8 テキスト、UUID ベースのファイルから成り、Swift / AppKit 型を含まないため Windows でも実装可能である。一方、Swift ソースや native UI の共有を狙うと WinUI の日本語 IME、Undo、file picker、ファイルロック、Windows の操作慣習を損ねる。保存契約と fixture を共有し、native 実装を分ける方が、互換性と各 OS の品質を同時に保てる。
- **補足**: Windows 上の Codex を実装主体とする。WinUI / Windows App SDK、IME、NTFS、署名・配布は Windows 実機で検証し、macOS 側は同じ fixture による Mac reader-writer 検証を担当する。D-014 のローカル検証方針は両 OS に適用する。

## D-037: Phase 5はTXT / Markdown / EPUBで完了し、PDFはAI実装後へ延期する

- **日付**: 2026-07-16 / **状態**: 一部破棄(Phase 5の3形式完了と未実装形式を露出しない方針は維持。AI→PDFの固定順はD-040で破棄)
- **内容**:
  1. D-022でPhase 5 v1に含めたPDFを今回の完了条件から外す。Phase 5はプレーンテキスト、Markdown、EPUB 3、3形式のmacOSアプリ統合までで完了とする。
  2. PDFはPhase 6のAI支援を設計・実装した後の **Phase 6.5** として再開する。現時点では `ExportFormat`、形式選択UI、テストfixtureにPDFを追加しない。
  3. PDF再開時も、実装済みの共通原稿展開、`NovelDocument` 値スナップショット、アトミック書込み、`NovelExport → NovelCore` の依存境界を維持する。macOS固有レンダラは `NovelExport/Platform/macOS/` に閉じ込め、公開APIへAppKit型を出さない。
  4. 未実装形式をUIに先出ししない。Fileメニューとtoolbarは現在利用可能なTXT / Markdown / EPUBだけを表示する。
- **理由**: 現時点の製品価値はAI支援を先に完成させる方が高く、PDF組版を挟むとAI実装の開始が遅れる。PDFを曖昧な未完成状態で同梱せず、既に品質ゲートを通った3形式でPhase 5を閉じ、AI後に独立した受け入れ条件で実装する方が進捗と品質の両方を明確にできるため。
- **改訂**(2026-08-07): 商業化の優先順位を原稿保全・配布品質へ変更したため、AI実装をPDF着手の技術的前提にはしない。AIとPDFはいずれも商業公開Gateの後に、需要・費用・プライバシーを別々に評価して着手する(D-040)。
- **改訂**(2026-08-08): D-042により需要・費用等の事業評価は通常の開発Gateから外す。今後は技術Gate後に、AIとPDFを独立機能として受け入れ条件と実装順だけ定める。事業評価はユーザーから明示依頼がある場合に限る。

## D-038: 製品名を「ふみにわ / FUMINIWA」へ変更し、保存形式と旧設定は互換資産として維持する

- **日付**: 2026-08-07 / **状態**: 一部破棄（→ D-063。名称・形式・旧設定互換は維持し、macOS Releaseの`~/Documents/FUMINIWA`を通常作業場所として見せる第3項だけを置き換える）
- **内容**:
  1. 日本語の表示名と広報名を **「ふみにわ」**、英字ロゴ・配布物・アプリbundle・実行ファイル・Xcode project / schemeを **`FUMINIWA`**、Swiftのブランド型名を `Fuminiwa` とする。初出では必要に応じて「ふみにわ（FUMINIWA）」と併記する。
  2. bundle identifierは商業配布前に `dev.serikayuzuki.fuminiwa` へ変更する。旧bundle domain `dev.serikayuzuki.NovelWriter` の最近開いた作品、選択セクション、Editor設定6項目（計8キー）はallowlist方式で一度だけ移行する。新しい値を旧値で上書きせず、旧domainと旧ファイルを削除しない。
  3. 新規作品の既定保存先はReleaseで `~/Documents/FUMINIWA`、DebugでApplication Support配下の `FUMINIWA/Drafts` とする。既存の `NovelWriter` フォルダや作品は一括移動せず、移行した絶対URLから元の場所のまま開く。
  4. `.novelpkg`、formatVersion v1〜v3、manifest、内部パス、`NovelKit` / `NovelCore` / `NovelStorage` / `NovelExport` / `EditorKit`等のドメイン名は変更しない。Finder上では同じ拡張子をUTType `dev.serikayuzuki.fuminiwa.novelpackage` の「ふみにわ作品」として宣言する。
  5. toolbar customization ID `novelwriter.workbench.v3` は永続互換IDとして維持する。過去ADR、旧成果物名、旧UserDefaults key、監査時点の証跡も履歴として書き換えない。
- **理由**: 既存の無料OSS `novelWriter` との検索・口コミ・問い合わせ上の混同を避け、商業化前に独自ブランドを確立する。一方、作品形式や設定識別子まで見た目に合わせて一括改名すると、原稿・最近開いた作品・Editor設定・toolbar配置・将来のWindows互換を壊す。外向きのブランドと内向きの互換境界を分けることで、改名とデータ継続性を両立する。
- **販売前条件**: コード上の採用は名称の法的な利用可能性を保証しない。第9類・第42類等の商標、App Store、ドメイン、SNS、既存の `fuminiwa design` 等との役務・表示上の距離を、最初の署名済み外部配布前に弁理士を含めて確認する。
- **スコープ改訂**(2026-08-08): 上記販売前条件は履歴として残すが、D-042により通常の開発Gate、優先度、実装完了判定には含めない。法務・名称調査はユーザーから明示依頼がある場合だけ別作業として扱う。

## D-039: 起動は Loading / Ready / Recovery の三状態とし、読込失敗時は原稿を置き換えない

- **日付**: 2026-08-07 / **状態**: 承認(商業化 Safe Launch Gateで実装)
- **内容**:
  1. 起動状態を `loading` / `ready` / `recovery` に分け、`ready`になるまで編集可能なWorkbenchを生成しない。初期 `NovelDocument` は内部の一時値にすぎず、bootstrap完了前のユーザー入力を受け付けない。
  2. 前回作品、Finderから指定された作品、またはその付随データの読込に失敗した場合、新規作品へ自動fallbackせず `recovery` で停止する。失敗したURLとrecent preferenceは変更せず、原稿への保存も行わない。
  3. Recoveryでは「再試行」「Finderで表示」「別の作品を開く」「利用者が明示した新規作品作成」を提供する。新規作品は保存成功後だけ現在作品として採用し、その後にだけrecent URLを更新する。
  4. `bootstrap()`は一度だけ起動処理を開始し、同時呼び出しは実行中Taskの完了へ合流する。初回I/O中のFinder URLも起動完了前に処理し、SwiftUIのtask再評価や通知再登録で作品を二重作成・巻き戻ししない(D-041)。`Cmd+S`、終了前保存、自動保存は`ready`な作品だけを対象とする。
  5. manifestが参照する本文・世界観本文、または存在するメモpayloadが読めない／UTF-8でない場合は空文字へ変換せず型付きエラーにする。仕様上省略可能な空メモの欠損は維持する。さらに広いduplicate ID、symlink、孤児payload、resource limit、修復コピーは後続のPackage Validator Gateで扱う。
- **理由**: 起動直後の編集可能placeholderは、前回作品の非同期読込で入力を上書きし得る。また読込失敗を空の新規作品へ見せかけrecentまで更新すると、利用者には原稿消失に見え、次の自動保存が復旧余地を狭める。執筆アプリでは「開けない」ことを明示する方が「空で開けた」ように装うより安全である。

## D-040: 実在する機能だけを出荷UIへ出し、システム外観と明示保存を製品契約にする

- **日付**: 2026-08-07 / **状態**: 承認(商業化 Product Truth Gateで実装)
- **内容**:
  1. 実処理を持たないAI Assistant placeholder、AI状態、入力欄、`Cmd+J`は出荷UIから除く。AIは将来も**任意機能**とし、アカウント・ネットワーク・AI契約なしで既存の執筆／保存／書き出しが完結することを維持する。
  2. AIを再びUIへ出す前に、送信対象と送信前preview、明示同意、provider、保存期間、学習利用、費用上限、取消・失敗時の挙動、生成結果の採用確認を設計・文書化する。設定だけでなく最初の送信時にも同意を取り、本文を黙って送信・置換しない。
  3. Workbench下端は保存状態、保存失敗の再試行、選択話／作品全体の文字数、検索結果だけを示す非展開型status barとする。未実装機能の入口や状態は置かない。
  4. アプリのSidebar、Outline、toolbar、form等のchromeはmacOSのシステムLight／Dark外観へ追従し、アプリ全体へ`.preferredColorScheme(.dark)`を強制しない。本文エディタのキャンバスはchromeから独立した利用者設定とし、従来どおり暗色を既定にできる。
  5. Fileメニューの`Cmd+S`は`AppState.saveNow()`を経由し、自動保存・終了前保存と同じrevision直列化へ合流する。起動状態が`ready`でない間は実行しない。
  6. 直近の開発順はAIやPDFではなくPackage Validator Gateを優先する。duplicate ID／不正参照、symlink、resource limit、孤児payloadの保全、修復コピーを一単位とし、外部変更／競合検出は続く独立Gateとして扱う。その後に署名・公証・更新・法務・サポート等の公開Gateを通す。AIとPDFの順序は、公開Gate後に需要とリスクを別々に評価する。
- **置き換える範囲**: D-021のAI Assistant Panel常設を破棄し、chrome外観方針をシステム追従へ更新する。D-037の「AI実装後にPDF」という固定順も破棄する。D-021の3列Workbench、D-037のPhase 5完了範囲と「未実装機能を先出ししない」原則は維持する。
- **理由**: placeholderは利用者に「使える」「本文が送信されるかもしれない」という誤解を同時に生む。執筆アプリの信用は機能数より原稿保全、表示の正直さ、OS慣習への追従、利用者が選べることから生まれる。AIやPDFの順番を商業公開の前提にせず、原稿保全と配布品質を先に完了させる。
- **改訂**(2026-08-14): D-073により、iCloudへ結んだ作品の`Cmd+S`はlocal保存のあと明示同期する。未結線の作品と自動保存／終了前保存／話切替flushは従来どおり`saveNow()`だけ。

## D-041: 作品ライフサイクルを直列化し、古いUI操作を別作品へ適用しない

- **日付**: 2026-08-08 / **状態**: 承認(PRレビューの原稿保全修正で実装)
- **内容**:
  1. `bootstrap()`の同時呼び出しは実行中Taskを共有し、初回I/O中に届いたFinder URLの処理まで同じ完了境界へ含める。後続呼び出しだけが先に戻ってdelegateを起動完了扱いにしない。
  2. 開く、新規作成、別名保存、Recovery再試行、資料操作、スナップショット操作、終了前保存は、AppStateのFIFOなdocument operation gateで`await`を越えて直列化する。Finder openは通常の「開く」経路へ合流させ、二重にgateを取得しない。
  3. 現在作品に属する操作は、呼び出し時の`generation + document ID + standardized URL`をsession tokenとして保持する。gate待機中に作品、保存先、または復元世代が変わった操作は、Repositoryを変更する前に失敗として破棄する。スナップショット、資料、章／話／人物／プロット／伏線／世界観ノートの確認UIも、一覧項目を表示した時点のtokenを対象値と一体で引き継ぐ。
  4. 別名保存はpackage copyだけでなくURL、recent、session世代の切替まで保存排他区間で確定し、コピー中の編集を新URLへ保存する。この最終保存に失敗した場合は成功扱いにせず、保存先を切り替えた事実と再試行方法を利用者へ伝える。復元は固定した現在URLに対する復元前退避、書き戻し、メモリ状態のinstallを一つの保存排他区間で行う。
  5. 開く、新規、別名保存、復元、終了前保存では、first responderとEditorKitの公開command境界を通じて表示中のフォーム入力／IME変換を旧作品へ確定・モデル同期し、最終保存とinstallが終わるまでWorkbench全体の変更を拒否する。本文callbackは表示時の章／話／ノートIDとsessionへ固定し、同じ子IDを持つ複製作品でも本文install世代をEditor keyへ含めて再読込する。別名保存は本文install世代を変えず、caretとUndoを維持する。AppKit型や本文BindingをAppStateへ公開しない。
  6. 終了要求を受けた時点で新しい作品ライフサイクル操作の受付を停止する。重複した終了要求は同じsingle-flight Taskと一度のAppKit replyへ合流する。先行操作がgateを抜けた後に最後の保存を行い、失敗して終了を取り消す場合だけ受付とエディタを戻す。
  7. lock順は常にdocument operation gate → `DocumentSaveCoordinator`とする。通常の自動保存／明示保存は外側gateへ入れず、既存のrevision保存直列化へ流す。gate付きpublic API同士を呼び出さない。
- **理由**: `@MainActor`は一つの同期区間を守るが、Repository I/Oの`await`中には別TaskがAppStateへ入れる。Aの復元待ち中にFinderからBを開くと、再開後に動的な`documentURL`を読み直してBへAのsnapshotを書き戻せた。また同時bootstrapの片方だけが早く完了すると、Finderで開いたBを遅い初回処理がAへ巻き戻せた。操作全体の順序と対象作品を別々に固定しなければ、順序だけを直列化しても待機中の古い確認操作が新作品へ誤適用される。さらにD-005によりIME変換中の本文はモデルへ未反映なので、破壊的遷移の直前に旧エディタ自身から確定させなければ、通常保存だけでは未確定文字を保全できない。
- **既知の制限**: FIFO gateの待機Taskはcancellationを明示処理せず、待機後にsession検査または操作を続ける。現行UIの破壊操作は自動cancelされず安全性はsession検査で保つが、構造化Taskへ移す際にcancellation-aware waiterを追加する。また別名保存はcopy完了後のfirst responder／IME確定に失敗すると現在作品へ切り替えない一方、作成済みの保存先copyが残り得るため、後続で案内または安全なcleanup方針を決める。

## D-042: 今後の「商業化」作業は実装・機能品質に限定する

- **日付**: 2026-08-08 / **状態**: 承認(ユーザー指定)
- **内容**:
  1. このリポジトリで今後「商業化」として調査・設計・実装・進捗管理する対象は、アプリの実装、機能完成度、UI/UX、原稿保全、性能、アクセシビリティ、互換性、テスト、ビルド、Archive、署名／公証、更新機構など、コードまたは技術成果物として完了条件を検証できる範囲に限定する。
  2. 価格、競合／市場、販促、商標を含む法務、税務、決済、問い合わせ体制、事業継続などは、ユーザーから個別に明示依頼がない限り、開発ロードマップ、優先度、発売可否の判定、提案へ含めない。
  3. AI機能のprovider adapter、送信先、送信範囲preview、明示確認、取消、保持／学習利用設定の技術的な検証と表示、保存範囲、利用上限、失敗時挙動はアプリ機能として対象に含める。一方、規約作成やproviderとの契約判断は本決定の通常スコープ外とする。
  4. 既存の商業化総合監査は当時の履歴として保持するが、今後の実装進捗は`COMMERCIALIZATION_IMPLEMENTATION.md`の技術Gateだけで追跡する。D-040第6項のうち法務・サポート等を開発Gateとして扱う部分を本決定で置き換える。
- **理由**: 今後の作業を、リポジトリ上で具体的に修正・テスト・検証できる製品品質へ集中させるというユーザー判断。外部の事業判断を実装バックログへ混在させないことで、次に直すべき機能と技術的な完了条件を明確に保つ。

## D-043: AI統合はCodex SDK first / OpenRouter secondの純粋domainから始める

- **日付**: 2026-08-08 / **状態**: 承認（pure domain、EditorKit selection transaction、App-level context、fake UI、Codex sidecar v1 mock protocolは実装。実provider／SDK接続は未実装）
- **内容**:
  1. AI支援は常に任意機能とし、API key、アカウント、ネットワーク、AI providerなしで既存の執筆、保存、検索、snapshot、TXT / Markdown / EPUB書き出しを完結できる状態を維持する。
  2. 最初の機能は、Editorで利用者が明示選択した範囲だけを対象とする校正案とする。固定指示にはversionを兼ねるinstruction IDを付け、`selected_text`を未信頼の本文データとして扱い、その中の命令に従わず選択外の文脈やファイルを参照しないよう固定する。domainは指示ID、固定指示、空白／改行／約物を保持したexact selected textから単一の`applicationPrompt`を決定論的に生成し、exact JSON Schemaとversion付きresponse schema ID（初版`proofreading-result-v1`）も決定する。送信前にpromptとschemaのexact content／内訳、provider、model、送信範囲、保持／学習利用について技術的に確認できた情報をpreviewし、requestごとの明示確認を必須にする。instructionまたはschemaを変更する場合は対応するIDも更新し、preview後にprompt、schema、いずれかのID、対象または送信先が変われば確認を無効にする。
  3. 結果は初期版ではmemory onlyとし、prompt、選択本文、応答、diffをFUMINIWAの永続設定、ログ、snapshot、`.novelpkg`へ保存しない。結果を本文へ自動適用せず、原文との差分を示して明示適用させる。request後にdocument session、editor surface、episode、UTF-16範囲、対象文字列のいずれかが変わった結果はstaleとして適用を拒否する。
  4. 最初の実装PRは`NovelAI`のprovider-neutralなoutbound契約に限定する。未確認draftからinstruction ID、adapterがそのまま渡す単一`applicationPrompt`、response schema IDとexact `applicationResponseSchema`を含むpreviewを作り、明示確認後にだけprovider／purpose／budget／promptとschemaを合計したapp-provided input countとともに`AIApplicationPayload`へ封印する。Adapterはpromptへ再構築・追記せず、schemaもdomainのcanonical JSON value tree／digestを変えない。Provider wrapperへのstrict parse／写像とwire上のescape／key順は内容変更に含めないが、property追加・削除・緩和を禁止する。domain所有のexecutorだけが不変provider descriptorを照合してadapterを開始し、同じconfirmationのcopy／並行呼出しでも最初の1回だけを許可するone-shot leaseを持つ。providerの公開完了APIはraw structured outputとusageだけを受け、domainがexact schemaでstrict decodeして`AIResult`へ変換する。payload／budget／descriptor／resultの値型、preview／confirmed requestのone-shot capability、provider protocol／event、型付きerror、決定論的fakeと契約テスト以外のSwiftUI、AppKit、AppState、EditorKit接続、local session／surface／range snapshot、stale判定、network、subprocess、Keychain、provider SDK、出荷UI、`.novelpkg`変更は含めない。providerへ渡すconfirmed requestにはdocument ID、session、surface、range、path等のlocal identityを混ぜず、SDK固有型もdomain APIへ漏らさない。後続のEditorKit selection transactionでstale検査と1 Undo適用を実装し、App-level identityとの結合はさらに独立して扱う。
  5. providerの実装順はCodex SDK first、OpenRouter secondとする。これはfallback順ではなく、Codexの失敗、timeout、rate limit、認証失敗からOpenRouterへ自動fallbackしない。provider変更は利用者の明示操作と、送信先を更新したpreviewの再確認を必要とする。
  6. CodexはSwift-native SDKではないため、公式TypeScript SDKのstable non-alphaをprovider実装／更新PRごとに再確認し、semver rangeなしのexact versionで固定したNode sidecarから利用する案だけを候補とする。2026-08-09の調査baselineは`0.147.0`である。SDK、全依存、Node runtime、Codex CLIをversion／hash固定し、requestごとのempty cwdと専用`CODEX_HOME`、`skipGitRepoCheck: true`、親environmentを継承しないallowlist、Keychain由来のAPI key、OS-level file sandbox、`AbortSignal`からprocess treeのkillまでを実装する。実repositoryや、この検査を通すためだけの偽Git repositoryをcwdにしない。arm64／x86_64、nested code signing、Hardened Runtime、notarization、file-read拒否、cancel／timeout後にorphanがないことを実機で証明するまで、sidecarは非出荷・UI非表示とする。
  7. TypeScript SDKの公開APIにはephemeral／non-persistent thread optionが確認できないため、FUMINIWA側のresultをmemory onlyにしても「履歴非保持」「zero retention」とは主張しない。provider／service側のsession保持と学習利用だけでなく保持期間を一次資料で確認し、専用`CODEX_HOME`、cwd、temporary directory等にSDK／CLIが作るartifactの場所、範囲、保持期間を実測する。providerの料金単位とrequest上限の表示根拠も含め、これらは出荷UI前の未実装技術Gateとし、FUMINIWA側の保存範囲と分けて表示する。
  8. OpenRouterはCodex sidecarと独立したadapterとして実装し、domain protocolだけを共有する。OpenRouter内のmodel／provider routing fallbackも無効にして、指定先が利用不能ならfail-closedとする。
  9. provider descriptorは実行中に変化せずI/O／lock待機を行わないO(1)の値とし、streaming、cancellation、usage reportingを必須能力とする。完了usageの`outputTokens`は必須かつ非負、`inputTokens`は不明なら省略可能だが存在時は非負とし、欠損／不正値はfail-closedにする。usageは事後報告であって費用上限そのものではない。domainはexecutor呼出しからのwall-clock timeout、cancel済み／stream破棄後のprovider実行権または外部副作用の開始拒否、app-provided input、raw structured output、stream deltaの文字／UTF-8 byte、decoded resultの文字／byte／注意点件数とusageを強制する。注意点件数上限はrequest budgetへ封印してpreviewに表示し、細切れdeltaは内容を保持したままboundedに集約する。adapterは最初の外部副作用より前にcancellation handlerを登録し、その登録時に既にcancel済みなら通信／subprocess等を開始しない。provider／SDKの`maximumOutputTokens`相当parameter、wire直前payload、event byte／件数、process resource limitも検証する。
  10. AI設定、prompt、応答、diff、provider情報を`.novelpkg`へ追加せず、formatVersionを変更しない。D-040のPackage Validator → External Change / Conflict → 配布技術Gateという出荷優先順を維持する。純粋domainと隔離PoCだけは非出荷・UI非表示で並行可能だが、Gate完了前にAI対応を宣言しない。
- **理由**: 執筆アプリが扱う原稿を、暗黙送信、古い非同期結果、agent processの広いfile access、自動provider切替から守りながら、providerの交換可能性と決定論的テストを先に確立するため。SwiftからNode／CLIを同梱する配布経路は通信成功だけでは安全性も署名可能性も証明できないため、domain契約とsidecarの出荷Gateを分離する。
- **詳細**: request state、snapshot identity、保存範囲、sidecar Gate、PR分割は[AI_INTEGRATION.md](AI_INTEGRATION.md)を正とする。

## D-044: アプリ外観はシステム追従を既定とし、利用者の明示選択を許可する

- **日付**: 2026-08-08 / **状態**: 承認（実装済み）
- **内容**:
  1. Sidebar、Outline、toolbar、form等のchromeは引き続きシステム外観への追従を既定とする。
  2. 設定に「システムに合わせる／ライト／ダーク」を追加し、利用者が明示した場合だけメインウィンドウと設定ウィンドウへ同じ外観を適用する。未保存値または未知の保存値はシステム追従へ戻す。
  3. アプリ外観は本文キャンバスの本文色・背景色と独立させる。Light chromeを選んでも暗色本文キャンバスを維持でき、外観変更で原稿や`.novelpkg`を変更しない。
- **置き換える範囲**: D-040第4項の「システム外観へ追従」を既定動作として維持しつつ、利用者による明示overrideを追加する。無条件のDark固定を禁止する原則は維持する。
- **理由**: OS全体の設定を変えず、執筆アプリだけ明るい外観で使いたい利用者に選択肢を提供しながら、既存利用者の挙動と本文キャンバスの独立性を守るため。

## D-045: 執筆Outlineの章は横一行のDisclosureとして行全体で開閉する

- **日付**: 2026-08-08 / **状態**: 承認（実装済み）
- **内容**:
  1. 章は話と同じ選択カードにせず、話一覧を開閉するDisclosureとする。話だけを本文選択の対象にする。
  2. 章行は章名、話数、文字数、現在行にだけ出す作品保存状態を横一列へ収め、章名を優先して末尾の数値を固定する。
  3. 標準chevronだけでなく章labelの横幅全体を一回のクリックで開閉できるhit targetにする。章名編集は章メニュー、context menu、VoiceOverから到達可能にし、並べ替えの入口も開閉操作と競合させない。
- **理由**: 章は本文そのものではなく話を束ねる階層であり、選択カードより引き出しとして表現する方が情報構造に合う。行全体を操作対象にすることで、狭いchevronを狙う負担をなくすため。

## D-046: 公開を延期し、個人用Experimental AIをCodex SDKから同一UIの複数provider構成で実装する

- **日付**: 2026-08-09 / **状態**: 一部破棄（→ D-054。provider実装を現在の優先作業とする部分だけを延期。App bridge／fake UI／Experimental target分離と安全契約は保持）
- **内容**:
  1. 一般公開を当面延期し、AIはまず開発者本人だけが使う明示的な`FUMINIWAExperimental` app target／scheme（compile flagは`FUMINIWA_ENABLE_EXPERIMENTAL_AI`）で実装・検証する。通常の`FUMINIWA` app targetとsourceを共有しても、AI provider target／resourceへの依存はExperimental targetだけが持つ。D-040第6項のPackage Validator → External Change / Conflict → 配布技術Gateという順序は**公開Releaseの条件として維持**するが、実処理と安全境界が成立した個人用AI UIをその完了まで待たせる部分は本決定で置き換える。target／scheme分離は実装済みで、生成後のtarget graphをローカル検査し、provider artifact追加時には両Archive内容も再検証する。
  2. 最初の実providerはD-043どおりCodex TypeScript SDKとする。Editor bridgeとfake providerで原稿誤適用防止を成立させ、共有Experimental UIをfakeで検証した後、固定protocolのNode sidecarとCodex adapterをそのUIへ接続する。続いてAPI経路の第一候補としてOpenRouter adapterを同じUIへ追加する。
  3. CodexとOpenRouterは、選択snapshot、exact preview、requestごとの送信確認、進行／cancel、校正案、局所diff、stale表示、Copy、明示Applyから成る**同一のprovider-neutral UIとoperation orchestrator**を使う。共有するのは`NovelAI`のdomain契約、App / EditorKitのlocal operation context、provider-neutralな表示状態だけとし、process／HTTP transport、credential、model設定、保持情報、error mappingはadapterごとに分離する。
  4. providerは利用者が送信前に明示選択し、previewへprovider、model、送信内容、確認できた保持情報と上限を反映する。Codex失敗時にOpenRouterへ、OpenRouter失敗時にCodexへ切り替えず、OpenRouter内部のmodel／provider routing fallbackも無効にする。providerまたはmodelの変更、再試行は新しいpreviewと明示確認を必要とする。
  5. 個人用実験では、bundled universal Node runtime、arm64／x86_64両実機、nested signing、Hardened Runtime、notarization、stapling、Gatekeeperを**AI UI開発の前提から外し、公開Release Gateへ延期**できる。開発用Node／sidecarを使う場合も、SDK／CLI／Nodeの採用version、lockfile／package integrity、実行pathとcryptographic hashを明示し、期待値と一致しなければfail-closedにする。ambientな`~/.codex`、作品repository、親process environmentへ暗黙依存しない。
  6. 個人利用でも、D-043の原稿保全と送信安全は緩めない。local identityをproviderへ送らない、IME確定済みsnapshot、exact preview、requestごとの明示確認、one-shot送信、自動適用禁止、stale適用拒否、1 Undo、Keychain、本文／prompt／response／API key／pathを通常ログと永続設定へ残さないこと、専用empty cwd／`CODEX_HOME`、environment allowlist、OS-level file-read拒否、cancel／timeout／終了時のprocess tree回収とorphanなし、local artifact inventoryをExperimental UIの前提にする。
  7. Codex SDKにtool無効化、ephemeral thread、upstream maximum output token等の必要な公開APIが存在しない場合、機能があるように補わない。個人用Experimental UIでは、確認できない保持、tool能力、上流費用capを「なし」「無効」「上限あり」と表示せず、利用中SDKで未保証であることを送信前に示す。FUMINIWA側のbyte／event／time／process上限は強制するが、上流token／費用capの代替とは扱わない。公開Releaseでは、必要なSDK制御の追加または別の承認済み決定がない限り未達Gateのままとする。
  8. Experimental AIはruntime flagだけで隠さない。通常の公開`FUMINIWA` app targetでは`FUMINIWA_ENABLE_EXPERIMENTAL_AI`を定義せず、AIのmenu／shortcut／設定／panelを生成せず、Codex／OpenRouter adapter、Node／CLI／sidecar artifactへのtarget dependencyとlink／copy／登録を持たない。別app target方式を変更する場合は、configuration別dependency除外が実際に成立することを先に実証する。Archiveのtarget graph、Link Binary、Copy Resources、bundle inventory、menu／shortcut、network／process起動のテストでこの境界を検証する。公開AIへ移す場合は、本決定を更新し、D-043の配布Gateをすべて通す。
  9. prompt、response、diff、provider選択、credentialで`.novelpkg`を変更しない。AIなしの通常Releaseと、Experimental buildでAIを未設定／無効にした状態の双方で、既存の執筆、保存、検索、snapshot、TXT / Markdown / EPUB書き出しが完結することを回帰保証する。
- **置き換える範囲**: D-040第6項とD-043第6・10項のうち、Package Validator、External Change / Conflict、両architecture、bundled universal runtime、nested signing／公証を**個人用Experimental UIの前提**とする部分、およびD-043第9項のupstream `maximumOutputTokens`相当parameter必須を**Codex Experimentalに限り未保証表示へ置き換える部分**だけを置き換える。version／lockfile／integrity／実行path／hash固定は個人用でも維持する。OpenRouter等、上流capを提供するadapterでは第9項を維持し、Codexも公開Releaseでは未達Gateとして残す。D-040のProduct TruthとD-043の原稿・送信安全は常時有効であり、その他の置き換えていないD-043条件も維持する。
- **理由**: 当面は個人利用で実装を先行し、Codex SDKの改善を待ちながら実際の使用感と失敗条件を蓄積する。一方、SDK経路とAPI経路で別々のUIや適用ロジックを作ると、送信確認、stale検査、Undo、原稿保全がproviderごとに乖離する。同一の安全な操作境界へ独立adapterを差し込む構成なら、今の実験速度と将来の公開品質を両立できる。
- **詳細**: Experimental／Public Gate、共有UI、adapter順、検証項目は[AI_INTEGRATION.md](AI_INTEGRATION.md)を正とする。
- **実装状況 (2026-08-09)**: 別app target／scheme／bundle ID／既定保存root、通常版とのbuild graph分離、App-level local context、fake provider、provider-neutralな共有AI UI、Codex sidecar v1、manifest v1、exact SDKの合成CLI capture、Darwin native process supervisor、B3 packager／native verifier、D-050のB4-A compile-time approval契約、D-051のB4-B非実行exact Node inspector、D-052のB4-C suspended actual-process identity probe、D-053のB4-D abstract mock interactive sequencingまで実装した。production catalogは空で、B4-Cはprocessをresumeせず殺して回収する非authority観測に限定し、B4-Dへ変換しない。B4-Dの具象production channel／factory／callsite、実Codex／OpenRouter adapter、実CLI／network、approved runtime、Node version検査、complete loaded inventory／immutable verify-to-use binding、Keychain、OS-level隔離、parent death後のprocess回収は未実装であり、本決定のExperimental Gateを完了した意味ではない。

## D-047: Codex sidecar v1は本文送信前attestation付きの一request protocolとする

- **日付**: 2026-08-09 / **状態**: 承認（Node／Swift mock protocol、manifest v1、exact SDK合成capture、B2／B3、B4-A〜Dの分離checkpointまで実装。実CLI／networkは未接続）
- **内容**:
  1. SwiftとNode sidecarの境界は、UTF-8・LF終端・厳密なfield集合・frame／累計byte上限を持つJSONL protocol v1とする。CR／CRLF、BOM、invalid UTF-8、partial EOF、duplicate JSON member、未知field／enum／version、非canonical integerをfail-closedで拒否する。
  2. 原稿を含む`start`より前に、content-freeな`hello` → `ready` handshakeを必須にする。`ready`はsidecar、Node、SDK、CLIのversion、architecture、package integrity／hashを返し、Swiftがbuild-time allowlistと完全一致させた場合だけconfirmed payloadを送れる。attestationはartifactの独立した起動前hash検査を置き換えず、別runtimeへの暗黙fallbackを許さない。
  3. 一process／一requestとし、valid `start`を受理した場合は`started`の後に`completed`または`failed`を一度だけ返す。cancel／timeout／provider完了を同じstate machineで直列化し、先に確定したterminalだけを採用する。EOF、process exit、duplicate／late event、grace後のprocess-group signal、direct childのwait／reap、group非空をtyped failureの受け入れ条件へ含める。process lifecycleで実証できる範囲とorphan-freeを一般化しない境界はD-048を正とする。
  4. `start`はconfirmed `AIApplicationPayload`のprompt、schema、両ID、model、budget、app-provided countを再構築せず写像する。request ID、runtime identity、count、budget、pathをprovider prompt／metadataへ追加しない。文字数はSwift `String.count`でpreviewに封印した値を正とし、JavaScriptのUTF-16／code-point数へ置き換えない。UTF-8 byte数は双方が独立して再計算する。
  5. Codex protocol v1は`started`とterminalから成るbounded event streamを提供するが、SDK 0.147.0に安定したtoken deltaがないため部分置換文字列を捏造しない。`AIProviderCapability.streaming`は非同期event streamの能力を表し、部分本文の到着を保証しない。部分本文が存在しないproviderでは、UIは完了まで結果本文を表示しない。
  6. `completed`はraw structured outputとusageだけを返し、Swift側のNovelAI strict decodeを迂回しない。`failed`は`AIError`へ固定写像できるcodeだけを持ち、SDK error、stderr、本文、pathを返さない。golden fixtureは実際のversion付きinstruction／schemaと小さな合成選択を使い、NodeとSwiftが同じ値、prompt／schemaのUTF-8 bytes、state遷移を検証する。
  7. 公開TypeScript SDK 0.147.0はstdout JSONL一行、stderr保持、direct child killに必要なhard cap／process-tree handleを公開しない。このprotocol mockの成功だけで実SDK feasibility、file隔離、process回収、個人用送信Gate、公開Gateの完了を宣言しない。実SDK接続前に、外側supervisor／監査済みwrapperまたは同等のOS hard limitでno-LF record、stderr flood、memory、同一group descendantの停止、direct child wait、group空観測を実証する。credentialはspawn時のargv／environmentへ入れず、artifactの独立検証とcontent-free attestation後に別のone-shot anonymous pipeから渡す。
- **理由**: version driftを本文送信後に検出する構成や、Swift／JavaScriptの文字数差、SDKのraw error／無制限bufferをprotocol外へ放置すると、exact previewと原稿非漏洩を満たせないため。content-free preflightと小さい一request state machineを先に固定すれば、Codex SDKと将来の更新をprovider-neutral UIから切り離して検証できる。
- **詳細**: wire形式とstateの正は[`Sidecars/Codex/PROTOCOL.md`](../Sidecars/Codex/PROTOCOL.md)、AI全体のGateは[AI_INTEGRATION.md](AI_INTEGRATION.md)を正とする。
- **実装状況 (2026-08-09)**: protocol mock、canonical manifest v1、`@openai/codex-sdk` 0.147.0の合成CLI capture、D-048 supervisor、D-049 packager／native verifier、D-050のB4-A compile-time approval契約、D-051のB4-B非実行exact Node inspector、D-052のB4-C suspended actual-process identity probe、D-053のB4-D abstract mock interactive sequencingを実装した。production catalogは意図的に空であり、B4-Cはactual childをresumeせず殺して回収し、B4-Dへ変換しない。B4-Dの具象production channel／factory／callsite、Node version検査、完全なloaded inventory、immutable verify-to-use binding、監査済みlauncher、実SDK／CLI、credential、network、OS-level隔離は未実装である。`codex_sdk` runtime modeは引き続き禁止する。

## D-048: Darwin supervisorはdirect childの回収とprocess group空観測を分けてfail-closedにする

- **日付**: 2026-08-09 / **状態**: 承認（合成helper向けnative primitiveを実装。実SDK／CLI／networkは未接続）
- **内容**:
  1. Codex sidecarの外側に置くmacOS native supervisorは、`FUMINIWAExperimental`だけにcompileするactorとする。同じinstanceで同時に実行できるsessionは1件、1 invocationはcanonicalなabsolute executable／cwd、exact argv／明示environment／stdinを使って`posix_spawn`した1 direct childと1 process groupを所有する。shell／`PATH`探索と親environmentの暗黙継承を行わず、`POSIX_SPAWN_CLOEXEC_DEFAULT`と明示pipe mappingで未許可file descriptorをchildへ渡さない。macOS 27では`pipe2`をDarwin runtimeからprobeし、不在ならlegacy `pipe`へfallbackせずfail-closedにする。他のOS version／architectureへの成立は別に検証する。
  2. childは`POSIX_SPAWN_SETPGROUP`で自分のPIDをPGIDとするgroup leaderにし、spawn後にもPID／PGID一致を検査する。cancel、timeout、I/O／cap failure、normal leader exit後のlive descendantは一つのlocked stateでfirst-winsにclaimし、遅い自然exitで成功へ戻さない。自然exit後にlive descendantが観測された場合はgroupをcleanupしても`lingeringDescendant` failureを維持する。
  3. stdin／stdout／stderrは同時に処理し、stdinとstdoutは512 KiB、stderrは16 KiBを上限とする。stdoutは上限内だけ保持し、stderrは内容をresult／通常ログへ保持せずbyte countだけを持つ。超過errorの`actualAtLeast`は観測済み下限であって総出力量ではない。secure erase、upstream token／費用cap、memory／CPU／process件数の制限を主張しない。
  4. 停止時はdirect childの終了を`waitid(WNOWAIT)`で観測してreap前のanchorを保ち、同じgroupへTERM、grace後に必要ならKILLを送る。親が`waitpid`できるのはdirect childだけであり、`EINTR`を再試行してboundedにreapした後、`kill(-pgid, 0)`が`ESRCH`となることをboundedに観測する。anchor前の`EPERM`は短いbounded loopで`waitid`観測を再試行し、未解決ならpermission failureとする。未reap leaderをanchorした後の`EPERM`も最終的なgroup empty証拠にせず、reap後に再検査する。reap後の非`ESRCH` groupへはPGID reuseによる誤signalを避けるため再signalせずfail-closedにする。
  5. request timeoutはterminal claimのdeadlineであり、その後のTERM／KILL、direct child回収、pipe drainは別のbounded cleanup windowで続ける。したがって`run`の総wall timeはrequest timeoutを超え得る。cleanup、reap、group probeが失敗した場合は先行terminalがcancel／timeoutでもcleanup errorを優先し、成功を返さない。
  6. process groupの`ESRCH`は観測時点の証拠に限る。grandchildを`waitpid`／reapしたとは扱わず、`setsid`／`setpgid`／権限変更でgroupを脱出したdescendant、appの`SIGKILL`／crash／power loss後のcleanup、PGID reuse raceをsame-process supervisorで解決済みとしない。parent death後の回収には独立した監査済みhelperまたは同等のOS lifecycle契約が別途必要である。
  7. Checkpoint B2は合成shell helperだけでstdin／stdout／stderr、timeout、cancel、cap超過、TERM無視、同一group descendant、normal leader exit後の残存descendantを検証する。実Codex SDK／CLI、API key、network、実原稿、native manifest verifier、OS-level sandboxを使わず、実送信を引き続き禁止する。
- **理由**: Foundationのhigh-level process APIやSDKの`AbortSignal`だけでは、同時pipe drain、bounded output、process group全体の停止、direct child所有権、reap後のgroup状態を区別して検証できない。一方でmacOSの親がreapできるのはdirect childだけであり、same-process cleanupはparent death後に動けない。実証できる狭い保証と残るcontainment Gateを分離し、合成成功を一般的なorphan-freeへ拡張しないため。
- **詳細**: lifecycle、固定上限、Darwinの`EPERM`／PGID境界と合成テストは[`Sidecars/Codex/SUPERVISOR.md`](../Sidecars/Codex/SUPERVISOR.md)、AI全体のGateは[AI_INTEGRATION.md](AI_INTEGRATION.md)を正とする。

## D-049: B3のdeployment digestはarm64 identity candidateに限定し、実行承認と分離する

- **日付**: 2026-08-09 / **状態**: 承認（固定allowlist packagerとExperimental native verifierを実装。`codex_sdk` runtimeはNO-GO）
- **内容**:
  1. Node packagerのproduction policyはcaller supplied allowlistを受けず、`@openai/codex-sdk`／`@openai/codex` 0.147.0と`@openai/codex-darwin-arm64` 0.147.0-darwin-arm64に固定する。root 0700、派生15 directory 0755、固定21 regular fileを0644または0755で新規destinationへ組み立て、x86_64や任意の追加fileを暗黙に含めない。exact pathは[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md)を正とする。
  2. packagerはroot／lockfile／installed package metadataとSDK／CLI／platform packageのexact version／lock SRI／arm64 layoutを、provider packageをimportまたはlaunchせずに検査する。各sourceを`O_NOFOLLOW`で開き、新規destinationを`O_EXCL`で作成し、実コピー中にsource bytesをSHA-256してdestination側canonical manifestのsize／digestと一致させる。返すのは`packagerVersion`、`manifestVersion`、`candidateRootDigest`、`recordCount`、`canonicalManifestByteCount`だけであり、pathや実行capabilityを返さない。
  3. root内のself manifestと、packagerが返す`candidateRootDigest`は検査用copy／候補値であり、production approvalのauthorityではない。destination作成後のfailureはrecursive cleanupせず、`partial_destination_retained`と`underlyingCode`で残存を通知する。既存destinationは変更／削除しない。partial rootは実行不能として扱い、呼出側が対象identityを再確認して手動で隔離または削除する。
  4. `FUMINIWAExperimental`だけにcompileするSwift native verifierはcanonical manifest v1をNodeと独立実装し、synthetic five-record oracleのdigest `15b98ccfac850c24e2427249c55c9fba5aba29b6ef1632301136688c13d35288`、278 canonical bytes、record順／mode／size／SHA-256を一致させる。expected root digestはself fileから読まず、64文字lowercase SHA-256の独立引数として受け取る。verifier自身は固定21 pathやapproved digestをhard-codeしない。
  5. native verifierはcanonical root／UTF-8 byte順、symlink／hardlink／special file／危険mode、entry／path／file／aggregate／canonical byte capをfail-closedにし、`lstat`、`open(O_NOFOLLOW)`、`fstat`、再`lstat`と全体再検査でcontent、inode、directory mutationを検出する。ただし、このpathname-based検査をimmutableなtrust root、same-user adversaryへの完全なTOCTOU防止、または検査済みbytesを実際にNodeが評価した証明とは扱わない。
  6. B3にはcandidate digestを承認するcompile-time native allowlist、exact Node executable bytes、完全なESM／CJS／dynamic import／native addon／CLI／runtime data inventory、verificationからimport／path-based spawnまでのimmutable bindingがない。Node pathname APIもsame-userによるsource／destination ancestorまたはroot swap raceを閉じない。これらをB4の独立Gateとし、self manifestや直前のpath hashへ権威を戻さない。
  7. B3 testはchecked-in development rootのmetadataを読取検査し、残りは合成filesystem tree／oracleだけを使う。実Codex SDK／CLIをimport／launchせず、API key、network、実原稿、`codex_sdk` runtimeを使わない。B3完了後も実送信はNO-GOである。
- **理由**: allowlist copyとnative再計算を追加しても、候補digestを独立して承認し、検査した同じbytesをruntimeへ不可分に渡さなければ、mutable pathの差し替えや未列挙artifactを防げない。一方、部分生成物を自動再帰削除すると同時差し替えされた無関係rootを消す危険があるため、identity candidateの生成、承認、使用、失敗後の手動処理を分離する。
- **詳細**: exact tree、canonical bytes、packager／verifierの保証とTOCTOU境界は[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md)、残るB4以降のAI Gateは[AI_INTEGRATION.md](AI_INTEGRATION.md)を正とする。

## D-050: B4-Aはcompile-time approval契約だけを実装し、空catalogをfail-closedの正とする

- **日付**: 2026-08-09 / **状態**: 承認（Experimental native approval契約を実装。production catalogは意図的に空、実行経路なし）
- **内容**:
  1. `CodexRuntimeApprovalPolicy`は、`FUMINIWAExperimental` native hostへcompile-timeに封印するproduction approval契約のcanonical／validated shapeであり、それ自体はapproval authorityではない。`CodexRuntimeApprovalProposal`もreview用の非authority値である。production approval authorityはnested `ProductionCatalog`だけが持ち、private initializerの`CodexApprovedRuntimeIdentity`の生成も同catalogだけが所有する。B4-A時点のproduction catalogは**空**であるため、承認済みcandidate、Node、SDK／CLI runtimeは0件であり、lookup成功や実行capabilityを生成できない。
  2. B3の`candidateRootDigest`、root内self manifest、packager／verifierが観測したdigest、`CodexRuntimeApprovalProposal`、package metadata、`ready` frame、runtimeのversion／path／hash／CDHash／署名情報、local probe結果、environment、UserDefaults、server responseをcatalogへ自動昇格させない。候補採用は、生成処理とは独立したnative sourceの明示差分とreviewを必要とし、同一buildで生成値をそのまま承認値へ書き戻す経路を持たない。
  3. policy generationやcatalog entryの型は、永続的な単調増加状態、旧appの起動拒否、revocation、またはanti-rollbackを証明しない。B4-Aはfallbackを提供しないだけであり、旧signed app／旧catalogへのdowngrade防止を主張しない。anti-rollbackが必要になった場合は、署名済みupdate floorと改ざん耐性のある永続状態を別Decision／Gateで設計する。
  4. deployment candidateはB3がcopyしてcanonical digestへ含めた全file／directoryの集合であり、存在するだけで評価・承認済みとは扱わない。approval inventoryのroleは実装enumどおり、`evaluatedSource`（実評価するJS等）、`resolutionMetadata`（package／module解決を決めるmetadata）、`executable`（Node／CLI／helper）、`conditional`（lazy／dynamicに到達し得るartifact）、`provenance`（lock／license等の由来証拠でruntime入力ではないもの）、`requestData`（prompt／schema／本文／response／credential等）、`operatingSystemTrust`（明示的に信頼するApple sealed OS境界）、`forbidden`（到達禁止）を区別する。
  5. 各inventory recordのcontent identityも、`exactFile`（固定size／digestで一致必須）、`boundedRequestData`（専用場所・型・上限を別Gateで強制する可変request data）、`operatingSystemProvided`（明示OS trust policyに属するもの）、`forbidden`（読込／評価／実行禁止）を区別する。`requestData`をdeployment digestへ混ぜず、`operatingSystemTrust`や`operatingSystemProvided`を無制限なimplicit allowlistにしない。roleとcontent identityの不正な組合せはpolicy validationで拒否する。
  6. B4-Aは型、validation、empty production catalog、合成fixture／testだけを対象とする。processをspawnせず、SDK／CLIをimport／executeせず、network、API key、実原稿、manuscript-bearing `start`を使わない。通常の`FUMINIWA` target／Archiveのdependency、resource、menu／shortcut、process／network経路は変更しない。
  7. 後続を小checkpointへ分離する。**B4-B**はexact Nodeのnative inspector、**B4-C**は実process identityをuser code実行前に検査するsuspended launch、**B4-D**はcontent-free `hello` → exact `ready`後にだけ`start`を書けるinteractive transport、**B4-E**はclosed linker／native broker／helperとOS-level read／exec隔離を結合し、検証済みbytesと実際のimport／path-based spawnを不可分にする。
  8. B4-B〜Eではsame-userによるancestor／root／Node／module／CLI swap、保持済みwrite FD、ambient module resolution、dynamic import／native addon、partial candidate、署名／ownership／mode、実行時closureを個別に実証する。path再hash、`--version`、`ready`自己申告、単一trace、事前`codesign`だけをimmutable bindingまたはcomplete inventoryの証拠にしない。
  9. B4-Eまで完了しても、D-043／D-046のcredential、保持情報、parent-death、resource、配布Gateを自動的に満たしたことにはならない。全Gateを明示的に通すまで`codex_sdk` runtime、実provider、実CLI通信、network、API key、実原稿送信はNO-GOを維持する。
- **理由**: candidate生成、観測、承認、実行を同じ値や同じ実装へ循環させると、改変されたcandidateやambient runtimeが自己申告だけで信頼境界を越えられる。まず空catalogで「承認がなければ何も実行できない」native契約を固定し、exact process、段階送信、load／exec closure、OS隔離を別々に証明するため。
- **詳細**: inventory role、B3 candidateとの境界、B4-B〜EのNO-GOは[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md)と[AI_INTEGRATION.md](AI_INTEGRATION.md)を正とする。

## D-051: B4-Bのexact Node inspectorは非実行の観測に限定し、承認と利用を分離する

- **日付**: 2026-08-09 / **状態**: 承認（Experimental native inspectorを実装。production catalogは空、process実行なし）
- **内容**:
  1. B4-Bは`FUMINIWA_ENABLE_EXPERIMENTAL_AI`付き`FUMINIWAExperimental`にだけcompileするnative `CodexNodeExecutableInspector`とする。入力は利用者が与えるexact absolute pathとrequested architectureだけで、観測結果にpath、file descriptor、process handle、launch capabilityを含めない。Nodeをspawnせず、SDK／CLIをimport／executeせず、network、API key、原稿を使わない。
  2. pathはNFCのraw UTF-8 bytesに限定し、absolute、`PATH_MAX - 1`以下、NUL／backslash／control／illegal／format／U+2028／U+2029なしを要求する。`lstat`後のraw pathと`realpath`をbyte一致させ、`open(O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)`したdescriptorの`F_GETPATH`も同じraw bytesであることを検査する。symlink、non-regular file、`nlink != 1`、effective userと異なるowner、set-id／sticky／group-writable／world-writable mode、owner execute bitなしをfail-closedに拒否する。
  3. descriptorだけから最大512 MiBの全bytesを`pread`でSHA-256し、thin 64-bit／fat32／fat64 Mach-Oのheader、architecture、slice boundary／alignment／overlap／duplicate、load command count／sizeをboundedにstrict parseする。arm64とx86_64以外、32-bit Mach-O、requested architectureを含まないcontainer、malformed／overflowは拒否する。
  4. code signatureはrequested architectureを`SecStaticCodeCreateWithPathAndAttributes`の`kSecCodeAttributeArchitecture`へ`arm64`または`x86_64`として渡し、Security frameworkの`SecStaticCodeCheckValidity`をstrict／all-architectures／no-networkで呼ぶ。valid／unsigned／invalid／unavailableとrequested sliceの20-byte CDHashの有無を**観測**する。universal Mach-Oとarchitecture別CDHashも観測に留まり、approvalではない。invalid／unsigned／unavailableの場合もinspectorがapprovalを与えたり実行したりせず、観測値として返す。署名の有効性だけでruntimeを承認しない。
  5. `lstat`／`fstat`のdevice、inode、mode、link count、owner／group、size、mtime／ctime／birthtime、flags／generationとcanonical path／`F_GETPATH`を、open後、hash／Mach-O観測後、signature観測後に再検査する。ただしreturn後の同一userによるpath／bytes差し替えを防ぐimmutable bindingではなく、path観測値と後続processの同一性も証明しない。
  6. `CodexNodeExecutableObservation`はnon-authority値であり、B4-Aのproposalやproduction catalog entryではない。production catalogを空のまま維持し、SHA-256／architecture／owner／mode／CDHash／signature観測からapproved runtime、path／FD／process capability、実行経路を生成しない。
  7. 次のB4-CでNodeをuser code実行前にsuspended launchし、actual childのidentityを検査する。続くB4-Dでcontent-free `hello` → exact `ready`後にだけmanuscript-bearing `start`を書けるinteractive transportを実装する。Node version、actual process identity、complete loaded artifact inventory、verified bytesとimport／spawnのimmutable binding、same-user post-verify swap、OS-level read／exec隔離は未達であり、B4-B完了後も`codex_sdk`、実SDK／CLI、network、credential、原稿送信をNO-GOとする。
- **理由**: path上の実行ファイルの形式とidentityを実行せずにboundedに観測するprimitiveと、その観測を承認・起動・使用へ進めるauthorityを分離するため。観測後にmutable pathを起動する構成ではTOCTOUが残るため、actual suspended childと実際にload／execされるbytesの拘束を後続Gateへ分離する。
- **詳細**: inspectorの観測項目、resource cap、非authority境界とB4-C以降のNO-GOは[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md)と[AI_INTEGRATION.md](AI_INTEGRATION.md)を正とする。

## D-052: B4-Cはsuspended actual-process identityのprobeに限定し、processをresumeしない

- **日付**: 2026-08-09 / **状態**: 承認（Experimental限定のprobe-only primitiveを実装。production catalogは空、`codex_sdk` runtimeはNO-GO）
- **内容**:
  1. B4-Cは`FUMINIWA_ENABLE_EXPERIMENTAL_AI`付き`FUMINIWAExperimental`にだけcompileする`CodexSuspendedProcessIdentityInspector`とする。入力はcanonicalなabsolute executable path、requested architecture、caller-suppliedのexact lowercase 20-byte CDHash、最大30秒のtimeoutだけである。expected architecture／CDHashは照合用のnon-authority値であり、B4-A catalog entryや実行承認ではない。
  2. spawnはexact pathのみを`argv[0]`に持つ固定argv、empty environment、cwd `/private/var/empty`、stdin／stdout／stderr `/dev/null`とする。`POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF`と`posix_spawnattr_setbinpref_np`でrequested architectureの新しいprocess group leaderを起動する。shell、`PATH`探索、親environment継承、protocol pipe、credential pipeを使わない。
  3. spawn前はcanonical raw path／`realpath`／`F_GETPATH`、regular file、`nlink == 1`、rootまたはeffective user owner、危険modeなし、owner execute bit、512 MiB以下を検査し、open descriptorとpath metadataの安定性をactual-process観測の前後で再検査する。ただしB4-BのSHA-256／Mach-O observationとB4-C requestをauthorityとして結合せず、検査済みdescriptorからspawnするimmutable bindingも実装しない。
  4. actual childはDarwinからPID／direct PPID／PIDと同じPGID／effective・real・saved UID／GID／開始時刻／executable path／`SSTOP`／requested architectureを観測する。各identity観測の前後snapshotとidentity観測自体の2回を一致させ、PID再利用または状態変化を観測した場合はfail-closedにする。
  5. 署名identityはactual PIDを`SecCodeCopyGuestWithAttributes`でdynamic `SecCode`として得て、`SecCodeCheckValidity(.noNetworkAccess, exact CDHash requirement)`、dynamic signing informationのvalid status／20-byte CDHash／pathを照合する。ad-hoc、unsigned／invalid、path／CDHash不一致は拒否する。`kSecCSMatchGuestRequirementInKernel`は実測環境で成功契約として使えず、mapped vnodeとin-place mutationをkernel内照合で不変に拘束したとは扱わない。
  6. probeは`SIGCONT`を送らず、resume API、process capability、PID、path、file descriptor、process handleを返さない。成功候補とspawn後の通常failureの両方でdirect childへ`SIGKILL`を送り、`waitpid`によるreap完了後だけarchitectureとCDHashの`CodexSuspendedProcessIdentityObservation`を返す。kill／reapのOS failureはcleanup errorを優先し、成功へ戻さない。production catalogは空のままである。
  7. timeout／cancelはphase境界でterminal化し、watchdogがchildのkill／reapを開始するが、best-effortのlifecycle boundであり、同期Security APIやblocking `waitpid`を中断するasync hard return deadlineではない。cleanup完了まで待つため、総wall timeはrequest timeoutを超え得る。また同じUIDの外部processはchildへ`SIGCONT`を送り得るため、独立したresume拒否／再stop containmentなしにadversarialな「user code実行0」を保証しない。同期Security呼出し中のPID再利用raceもhard-boundに解決済みとしない。
  8. 合成ad-hoc helperはconstructor／`main`のmarkerが0のまま拒否・回収されること、OS署名helperは非ad-hoc dynamic identity照合後にresumeされず回収されることを合成testで固定する。このtestは協調的な環境での証拠であり、同じUIDの攻撃processに対する一般的な不実行証明ではない。実Node／SDK／CLI、network、API key、実原稿は使わない。
  9. B4-CはNode version、B4-B SHA-256とactual processのauthority binding、approval、complete loaded artifact inventory、dyld／module／CLI closure、immutable verify-to-use、監査済みhelper／parent-death回収、OS-level read／exec隔離を保証しない。次のB4-Dでcontent-free `hello` → exact `ready` 後にだけ`start`を書けるinteractive transportを固定し、B4-Eと残るD-043／D-046 Gateまで`codex_sdk`、実provider／CLI／network／credential／原稿送信をNO-GOとする。
- **理由**: pathの事前観測だけでは、実際に生成されたchildのarchitecture／署名identityと同じであることを確認できない。一方、identityを観測したprocessをそのまま利用可能にすると観測が承認と起動capabilityに変質する。probe-onlyで必ず回収し、次のcontent Gateとload／exec closureから分離するため。
- **詳細**: spawn／actual PID／dynamic code identity／reap／時間上限／非authority境界は[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md)と[AI_INTEGRATION.md](AI_INTEGRATION.md)を正とする。

## D-053: B4-Dはabstract mock transportのsequencing契約に限定し、production runtimeへ接続しない

- **日付**: 2026-08-09 / **状態**: 承認（Experimental-only／mock-onlyのinteractive transport sequencing checkpointを実装。実runtime B4-Dは未完了、`codex_sdk`はNO-GO）
- **内容**:
  1. B4-Dは`FUMINIWA_ENABLE_EXPERIMENTAL_AI`付き`FUMINIWAExperimental`だけにcompileする、mock runtime専用のabstract interactive transportとする。具象的なproduction channel／factory／callsiteは作らず、processをspawnせず、Node／SDK／CLI／provider／network／API key／実原稿を使わない。production catalogは空のままで、B4-Cのsuspended childをresumeせず、channelや実行capabilityへ変換しない。
  2. `CodexSyntheticInteractiveChannelFactory.openContentFree()`はrequest、payload、identity、pathを含む引数を受け取らず、呼び出しごとにfreshな1-request／`AnyObject` class-bound channelを返す。open中のcancelは`requestOpenCancellation()`の戻りをacknowledgementとして待ち、pending open自体もjoinする。stopが先にlate channelが返った場合、未claimのfresh channelだけをprocess-wide registryでclaimしてcleanupする。既に別sessionがclaimしたduplicateは所有権を取らずcleanupしない。open-cancel acknowledgement／所有したlate channelのcleanup／通常cleanupのsafety failureは先行terminalより優先する。
  3. channelのinstance reuseはprocess-wideのweak registryで照合する。同じfactoryを別transportから使った場合もlive channelの再利用を`reusedChannel`で`hello`前に拒否し、通常openとlate returnのどちらでduplicateを見つけても先行ownerのchannelをcleanupしない。cleanup済みchannelをregistryがstrong retainし続けない。
  4. request全体のabsolute deadlineは`run` entryでsealed `AIApplicationPayload.budget.timeoutSeconds`だけから決め、factory openやattestationの遅延で延長しない。attestation timeoutは別のcontent-free上限として0秒超／30秒以下だけを受理し、両deadlineの先着をfirst-winsで反映する。
  5. transportは最初にexact framed `hello`だけを書く。入力はexact request ID／mock runtime identityの`ready` 1 frameだけを受け、そのchunk処理後にdecoderがexact frame boundaryであることを必須とする。`ready`と次eventのcoalesced chunk、partial trailing frame、extra／mismatch／EOFは`start` 0件でfail-closedに拒否し、照合完了後にだけsealed `AIApplicationPayload`からexact framed `start`を1件書く。
  6. `start`後は`started` → `completed`または`failed`の単一terminal → exact EOFを必須とする。provider terminalをrequest deadline前にclaimした場合はrequest timerを無効化し、観測時から最大1秒のEOF drainを開始する。duplicate terminal、terminal後のlate event、partial EOF、EOF欠落を拒否し、EOFでdrainが完了するまでresultを配送しない。1秒以内にEOFがなければ`terminalDrainTimedOut`とする。
  7. consumer cancel、明示cancel、attestation timeout、request timeout、terminal drain timeoutはactor内でfirst-winsにclaimする。wire terminal後でもresult delivery前のlocal cancelはresultを破棄し、terminal phaseのためwire `cancel`は0件のままにする。channelのatomic `requestCancellation(cancelFrame:)`が、phaseに応じたoptional cancel frameとpending read／writeのunblockを一括所有する。finalizing中の新しいcancelはdelivery破棄だけを記録し、追加I/Oを開始しない。
  8. 同じtransport instanceの並行2件目はfactory open前に`alreadyRunning`で拒否する。複数のcancel／timeout要求は最大1回のchannel cancellationへ収束させ、所有channelのcleanupも1回に限り、settled後のcancelはno-opとする。factory／channelの生error、path、contentを上位へ漏らさず、操作分類の固定typed errorへredactする。所有するchannelのcleanup／open cancellation／fresh late cleanup failureはsuccess、cancel、timeout、provider terminalより優先する。
  9. 新規の合成B4-D 5 suites／54 testは54/54、`FUMINIWAExperimental`全体は205/205 passした。これはabstract mock channelのsequencing、race、cleanup、redactionの証拠であり、actual Node／SDK／CLI process、native approval／identity、OS read／exec隔離と結合した実runtime B4-Dの完了またはGOではない。
  10. D-053承認時点の後続GateはB4-Eであり、closed execution closure／native broker／helperとapproval／actual identity／OS-level read／exec隔離を結合し、complete loaded artifact inventoryとimmutable verify-to-useを固定する計画だった。B4-Eと残るD-043／D-046 Gateが完了するまで`codex_sdk`、実provider／CLI／network／credential／原稿送信をNO-GOとする境界は維持するが、B4-Eの実装自体は後続D-054で延期した。
- **理由**: 本文送信前のattestationとprotocol sequencingを、process identity、artifact approval、loader closure、OS containmentから分けて決定論的に検証するため。abstract channelの成功をactual runtime実行capabilityに拡張すると、B4-Cのprobe-only境界とB4-Aのempty catalogを迂回してしまう。content-free open、isolated attestation、sealed start、terminal／EOF、cancellation／cleanupを先に固定し、実行可否はB4-E以降の別Gateに残す。
- **詳細**: factory／channel／deadline／frame／cancellation／cleanup契約は[AI_INTEGRATION.md](AI_INTEGRATION.md)、B4-A〜Eのapproval／identity／execution closure境界は[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md)、B2とB4-Dの非結合境界は[`Sidecars/Codex/SUPERVISOR.md`](../Sidecars/Codex/SUPERVISOR.md)を正とする。

## D-054: 実provider統合を延期し、通常版のAI支援をクリップボードへの明示的なプロンプトコピーへ切り替える

- **日付**: 2026-08-09 / **状態**: 承認（ユーザー判断。Codex／OpenRouter実装を延期し、通常版の非通信機能を優先）
- **内容**:
  1. Codex SDK sidecarのB4-E以降、Codex／OpenRouter adapter、network、credential、実原稿送信を現在の実装ロードマップから外す。再開には利用者の明示判断と、その時点の公式stable SDK／APIを一次資料、package、captureから改めて評価する別Decisionを必要とする。B4-Eを直近または自動継続のtaskとして扱わない。
  2. D-043／D-046〜D-053に基づいて実装した`NovelAI`、Editor transaction、fake UI、sidecar protocol、manifest、supervisor、B3、B4-A〜Dのコード、fixture、testは削除せず、B4-Dまでのfeasibility成果として保持する。ただしproduction catalogは空、具象production channel／factory／callsiteは0件、通常版のprovider dependency／artifact／入口は0件のままとし、保持したコードを実行承認、AI対応、または再開判断へ自動昇格させない。
  3. 通常版`FUMINIWA`で当面提供するAI支援は、利用者が選んだ原稿範囲と依頼文をplain textのプロンプトへ組み立て、明示操作でsystem clipboardへ1回コピーする機能に限定する。FUMINIWA自身はAI chatを開かず、providerへ送信せず、network、subprocess、API key、model設定を使わない。この機能は`NovelAI`のconfirmed outbound／provider protocolや`FUMINIWAExperimental`へ依存させない。
  4. 依頼目的は「校正」と「アドバイス」の2種類、対象scopeは「本文の明示選択」「1話」「1章」の3種類とする。選択scopeはIME確定済みの非空exact selection、話scopeは対象話のタイトルと本文、章scopeは対象章のタイトルと`Chapter.episodes`配列順の各話タイトル／本文だけを含む。空の話も順序から消さない。作品タイトル、あらすじ、話メモ、人物、プロット、伏線、世界観、資料、snapshot、ID、session token、UTF-16 range、digest、URL／pathを暗黙に含めない。
  5. 校正用プロンプトは意味と文体を保った誤字脱字、文法、句読点、表記揺れ等の指摘と修正案を求め、続きの生成や不要な全面改稿を求めない。アドバイス用プロンプトは長所、読みづらさ、構成／流れ／描写／会話等の改善点、優先度付きの具体策を求め、本文の自動置換を求めない。どちらも対象原稿を命令ではなく引用データとして扱う固定指示を持ち、同じ入力から決定論的に生成する。
  6. 各章と各話から両目的のコピー操作へ到達でき、本文のcontext menuでは現在の非空選択に対して両操作へ到達できるようにする。画面上の文言は「AIで校正」等の実行を示す表現ではなく、「校正用プロンプトをコピー」「アドバイス用プロンプトをコピー」とする。VoiceOverとキーボード利用者にも同じcommand境界の代替入口を提供する。
  7. 章／話の操作は表示時のdocument sessionと対象IDをactivation時に再検査し、作品切替後に別作品の同一IDまたは現在選択へ読み替えない。本文scopeはEditorKitの公開selection command境界から取得し、空選択、invalid UTF-16、IME marked text、dismantle済みsurfaceではコピーしない。コピーは同期的なsnapshotに対して行い、本文やモデルを変更しない。
  8. system clipboardはFUMINIWAのmemory-only境界の外にあり、他アプリ、clipboard manager、Universal Clipboard等から読まれ得る共有面である。コピー操作自体を利用者の明示的な境界越えとし、自動送信、自動paste、自動chat起動、clipboard内容のログ／UserDefaults／snapshot／`.novelpkg`保存を行わない。成功表示や診断へ本文を再掲せず、purpose、scope、文字数等の内容を持たない情報だけを使う。自動消去やsecure erase、外部AI側の保持／学習利用を保証しない。
  9. 外部AIの応答取得、response parse、diff、stale result、Copy result、Apply、Undo、cancel、retryはこの機能の対象外である。利用者が任意のAI chatへ手動で貼り付け、応答を手動で扱う。既存Experimentalの結果UIを通常版へ接続または転用しない。
  10. 受け入れtestは2目的×3scope、Unicode／改行／空白の保持、章／話順と空話、scope外dataの非混入、空選択／IME／session切替／surface失効、clipboard abstractionへのexact 1 writeと失敗時の原稿不変、`.novelpkg`不変、通常targetの`NovelAI`／Experimental source／provider／network／process依存0を固定する。
  11. provider統合を再評価するときは、当時の最新stable SDK／CLI／Nodeまたはnative APIをゼロから調査し、tool無効化、upstream output cap、session保持制御、cancel、loader／artifact surface、OS隔離、署名／配布を再測定する。0.147.0のcapture、古いhash、B4-Dのmock成功、保持済みarchitectureをそのまま採用根拠にしない。より小さく安全な公式境界が提供された場合は、旧sidecar設計を維持することより新しい境界の再設計を優先してよい。
- **置き換える範囲**: D-046のうちCodex SDKから個人用実providerを直ちに実装し、続けてOpenRouterを接続する現在の順序を置き換える。D-043のprovider順序とD-047〜D-053は、将来provider統合を再開する場合の安全契約と実装履歴として保持する。D-040のProduct Truth、AIなしで執筆を完結できる原則、通常版からproviderをbuild時に除外する境界は維持する。provider延期はPDFその他の独立機能を永久に待たせる条件にはしない。
- **理由**: 2026-08-09時点のSDK／CLI経路は、安全に実原稿を渡すためにloader closure、OS-level file隔離、process lifecycle、artifact identity等の大きな独自実装を必要とする。利用者はその実装を先送りし、SDKが更新されてより小さく検証可能な境界になった時点で再評価することを選んだ。一方、clipboardへの明示コピーなら、送信先をアプリが所有せず、原稿scopeを利用者が選んだまま、任意のAI chatを簡単に利用できる。
- **詳細**: B1〜B4-Dの実装結果と未達項目は[CODEX_SDK_FEASIBILITY_REPORT_2026-08-09.md](CODEX_SDK_FEASIBILITY_REPORT_2026-08-09.md)、clipboard promptの製品契約は[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)を正とする。provider再開時の休眠中技術契約は[AI_INTEGRATION.md](AI_INTEGRATION.md)を参照する。

## D-055: 本文末尾に表示専用の執筆余白を確保し、IME確定後の括弧ペアも字下げ解除する

- **日付**: 2026-08-10 / **状態**: 承認（ユーザー要望。EditorKitへ実装）
- **内容**:
  1. macOS本文エディタは、既存の`textContainerInset` 16pt四方を維持したうえで、本文末尾の下に96ptの執筆用表示余白を常に確保する。この余白は`NSClipView.contentInsets`によるスクロール領域であり、本文へ改行、全角／半角スペース、属性付き文字を追加せず、`.novelpkg`、文字数、検索、書き出しを変更しない。
  2. 改行や字下げを`EditorPlugin`の内部置換として適用した後は、置換後の選択範囲を`scrollRangeToVisible`へ明示的に渡す。複数回の改行でもキャレットを画面外へ残さず、下端の表示余白を使って執筆位置の下に空間を残す。
  3. D-033のR5を、IME確定後の `　「` / `　『` だけでなく、対応する括弧ペア `　「」` / `　『』` にも適用する。段落先頭では行頭の全角スペースだけを正規の置換経路で削除する。実IMEがmarked rangeを保持したまま`insertText`で確定する場合は、確定前のdelegateで後処理要求を記録する。さらに一括入力と開閉括弧が別々に届く通常入力のいずれでも、対応する空の括弧ペアは字下げの有無や文中位置にかかわらずキャレットを括弧内へ置く。IME変換中の不介入、TextKit 2、UTF-16 range、Undo / Redoの既存契約は維持する。
- **理由**: プラグインが標準入力を置き換える改行経路では、複数改行後のキャレット表示をAppKitの暗黙動作だけに任せられず、本文末尾では見える位置の下にも執筆余地が必要になる。また日本語IMEが `「」` を確定すると直接入力時のR3をIMEGuardが止める。テストで使っていた`unmarkText`と異なり、実IMEはmarked rangeを保持したまま`insertText`へ入るため、確定後処理を記録できず段落字下げが残っていた。通常入力でも開閉括弧は別々のreplacementとして届き、一括ペアだけを対象にした判定ではキャレットを移動できなかった。括弧ペアのキャレット位置は段落字下げとは独立した入力支援であり、字下げなしの行頭や文中でも同じ操作感にする。
- **詳細**: 表示規約は[STYLE.md](STYLE.md)、入力規則と本文編集の受け入れ条件は[DESIGN.md](DESIGN.md) 4.5 / 6.3を正とする。

## D-056: Phase 7をiOS 17のapp-private文書MVPとして着手する

- **日付**: 2026-08-10 / **状態**: 承認（IOS-1〜5実装済み。実機・Accessibility / Release QAは未完了。D-063で原本を変えないimport／app-private edit／export原則をApple版共通のcloud library境界へ拡張）
- **内容**:
  1. D-013でPhase 5完了後としていたPhase 7へ着手する。iOS / iPadOS 17以降を対象にiPhone / iPad共通の通常app targetを追加し、iPadはProject Sidebar / Outline / Editorの適応的な複数列、iPhoneは`NavigationStack`による段階遷移を基本とする。macOSのView階層、toolbar、file panelを縮小して機械移植せず、`NovelDocument`、document session、保存、入力の意味を共有する。
  2. 最初の文書境界は **app-private import / edit / export** とする。Files pickerで選んだ`.novelpkg`はsecurity-scoped access中にアプリ専用stagingへコピーし、原本を変更せず、読み込み成功後だけapp-private作品としてinstallする。自動保存とrecentはapp-private URLだけを対象にし、利用者の明示操作で別の`.novelpkg`として外部へ書き出す。外部URL、bookmark、provider固有identifier、pathをpackageへ保存しない。
  3. iOS MVPでも`DocumentSaveCoordinator`とdocument operation gateを保存・遷移の唯一の所有者にする。`DocumentGroup` / `UIDocument`による別autosave経路を並立させない。取込、作品切替、書出は呼び出し時sessionを固定し、遷移前に旧作品のIMEを確定して最終保存し、失敗時は現在作品、原本、dirty状態を保持する。
  4. Files / iCloud Drive / 他社File Provider上の原本を直接編集するopen-in-placeはMVPに含めない。Package Validator Gate（duplicate ID／不正参照、symlink、resource limit、孤児payload保全、修復コピー、保存前検証）とExternal Change / Conflict Gate（move／delete／同期／他プロセス変更の検出と上書き防止）を完了し、security-scoped bookmark、file coordination / presentation、競合UI、保存所有者を別Decisionで固定した後だけ着手する。app-private MVPをopen-in-place／クラウド同期対応済みとは表現しない。
  5. iOS本文は`EditorKit/Platform/iOS`内の`UITextView` adapterで実装し、TextKit 2を明示的に使う。`layoutManager`へ触れてTextKit 1へfallbackさせず、`UITextView`を公開APIへ出さない。編集中本文の正はtext view側、モデル→View反映はepisode key変更時だけとし、`markedTextRange != nil`の間はモデル通知、plugin介入、表示属性の再適用を行わない。
  6. 字下げ／鉤括弧判定をUIKit側へ複製せず、共有の`IndentRules.action(for:in:range:)`と`postChangeAction(in:caretLocation:)`を使う。既定pipelineは`IMEGuardPlugin → IndentPlugin`とし、R1'の常時字下げ、R3の字下げ置換と一括／開閉別の括弧ペア内キャレット、R4の変換中不介入、D-055で拡張したR5の `　「` / `　『` / `　「」` / `　『』` を維持する。旧R2や「キャレット直前の1文字だけ」で判定する旧R5を復活させない。
  7. UIKitのdelegate通知順をAppKitと同一とは仮定しない。`markedTextRange`を保持した確定入力を実機で観測し、確定前のpending記録からcomposition終了後に一度だけR5を適用する。plugin置換は正規変更経路を通してUndo / Redo、typing attributes、selectionを保ち、UTF-16、直接入力、一括ペア、開閉別入力、実IME確定を実`UITextView`統合testで固定する。本文末尾96ptの表示専用余白と、plugin置換後の明示的なcaret revealもD-055どおり提供し、保存本文、文字数、検索、exportを変えない。
  8. 通常iOS targetがlinkするNovelKit productは通常macOS版と同じ`NovelCore`、`NovelStorage`、`NovelExport`、`NovelUI`、`EditorKit`の5つだけとする。`NovelAI`、Experimental source／UI、Codex／OpenRouterその他のprovider、SDK、Node／CLI／sidecar、network callsite、credential、model設定、provider resourceをdependency、compile、link、bundleの全段階で0件にする。生成target graph、source、Archiveをローカル検査する。
  9. iOS版で許可するAI関連機能はD-054のclipboard prompt copyだけとする。校正／アドバイス×本文選択／話／章を同じpure builderとsession検査で生成し、iOS固有実装はplain textを`UIPasteboard`へexact 1 writeするadapterに限る。自動送信、AI chat起動、応答取込、diff、Apply、履歴、secure eraseは提供せず、system clipboardとUniversal Clipboardの共有境界を同じ文言で示す。
  10. 実装順はIOS-1 Build Graph → IOS-2 Shared App Boundary → IOS-3 UITextView Adapter → IOS-4 Document MVP / Adaptive Shell → IOS-5 Clipboard Prompt → IOS-6 Parity / Release QAとする。`Scripts/check.sh`へiOS app build / testとtarget separation検査を段階的に追加し、iPhone / iPad実機の日本語IME、Undo / Redo、scene非アクティブ化、import / export round-trip、VoiceOver / Dynamic Typeを完了条件にする。クラウドCIを使わないD-014は維持する。
- **置き換える範囲**: D-013の「需要がなければPhase 7を先送りしてよい」という未着手状態を、着手決定へ置き換える。D-010の単一保存所有者、D-040のProduct Truthと公開Gate、D-054のprovider延期、D-055の現行入力契約は維持する。Phase 7実装はPackage Validator / External Change / Conflictの公開Release Gateを完了扱いにせず、これらと安全に並行してよい。
- **理由**: Phase 5までの共有domain、保存、exportが成立し、利用者がiOS / iPadOS実装を明示的に選んだため。外部provider上の原本を直接編集するより、原本を変更しないapp-private作業コピーを最初の境界にする方が、既存のrevision保存とRecoveryを再利用しながら破損・競合範囲を小さくできる。また字下げと鉤括弧はD-055で実IMEに合わせて修正済みであり、iOS側に古い単純判定を再実装すると同じ不具合を再導入するため、純粋ルールを共有しUIKit固有の通知順だけをadapterで吸収する。
- **詳細**: iOS / iPadOSの製品範囲、アーキテクチャ、PR順、受け入れ条件は[IOS.md](IOS.md)を正とする。保存形式のOS間契約は[CROSS_PLATFORM.md](CROSS_PLATFORM.md)、clipboard境界は[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)を参照する。

## D-057: iOSを作品棚起点の段階導線とし、初回外観をDarkにする

- **日付**: 2026-08-10 / **状態**: 一部置換（→ D-063。作品棚起点の段階導線と初回Darkは維持し、package名identityの「このデバイスの作品」とcloud同期除外をWorkID identityの単一「iCloudの作品」へ置き換える）
- **内容**:
  1. iOS / iPadOS版の起点を、直近作品の編集画面ではなく **作品棚** とする。作品棚は`Application Support/FUMINIWA/Works`直下にあるapp-private作業コピーを一覧にし、同時編集は行わず、選択した1作品だけを既存のdocument operation gateと`DocumentSaveCoordinator`で開く。
  2. Files / iCloud Drive / 他社File Provider上の外部原本を独自に列挙しない。作品棚には「Files／iCloud Driveから取り込む…」を置き、標準pickerで選ばれた`.novelpkg`をD-056どおりapp-private作業コピーへ取り込む。外部の場所、同期状態、cloud badgeを保存・表示せず、原本の直接編集やiCloud同期済みと表現しない。
  3. iPhoneの基本導線を **作品棚 → 作品ホーム → 作品情報または執筆 → 章／話アウトライン → Editor** とする。iPadは同じ情報階層を標準の適応的なsplitへ展開してよい。作品ホームには実装済みの作品情報、執筆、書き出しだけを出し、未接続の機能をplaceholderとして並べない。EditorKit、本文所有権、字下げ／鉤括弧、Undo / Redoは変更しない。
  4. 作品棚のidentityは`NovelDocument.id`ではなくapp-private package名とする。同じ外部原本を複数回取り込んでdocument IDが重複しても別の作業コピーとして扱う。hidden staging、非package、symlink、root外pathを一覧・open対象にしない。読み込めない1作品は警告行として隔離し、他の作品までRecoveryへ巻き込まない。
  5. iOS版のアプリchromeは新規インストール時にDarkを既定とする。設定には「システムに合わせる／ライト／ダーク」を残し、利用者の変更をapp-privateな設定へ永続化する。これはiOS初回値だけについてD-044を置き換え、macOSのシステム追従既定は維持する。特定色を直書きせず、semantic colorとsystem materialでLight／Darkの両方を成立させる。
  6. 外観、現在の画面階層、最後に開いた作業コピー名は`.novelpkg`へ保存しない。作品切替前はIME確定と現作品の最終保存を行い、保存または読込に失敗した場合は現在作品、recent、画面遷移を変更しない。
- **置き換える範囲**: D-056の段階遷移とapp-private import / edit / exportを具体化し、DESIGN 12章の「ライブラリ管理UI」をapp-private作品棚に限って対象へ移した。D-063はitem 1／2／4のlocal root列挙、package名identity、独自cloud同期除外を、WorkID catalog／registryを使う単一「iCloudの作品」へ置き換える。作品棚→作品ホーム→各機能の段階導線、外部原本を一覧／直接編集しないこと、初回Dark、複数作品同時編集除外は維持する。D-044のシステム追従既定はmacOSと、iOSで利用者が「システムに合わせる」を選んだ後について維持する。
- **理由**: 既存実装はapp-private領域へ新規・取込作品を蓄積していたが、recent 1件しか再選択できず、起動直後に章一覧を出すため作品選択と機能選択の情報階層が欠けていた。作品棚と作品ホームを分ければ、原本を直接編集しない安全境界を保ったまま、利用者が「どの作品で何をするか」を先に選べる。Darkを初回既定にする要望も、変更可能な外観設定とsemantic colorを維持すれば、固定色のDark専用UIにせず実現できる。
- **詳細**: 画面階層、文書境界、アクセシビリティと受け入れ条件は[IOS.md](IOS.md)、色・余白・外観規約は[STYLE.md](STYLE.md)を正とする。

## D-058: iOSの作品機能を実画面へ接続し、執筆補助を本文直下へ置く

- **日付**: 2026-08-11 / **状態**: 承認（ユーザー要望。iOS機能parityとして実装）
- **内容**:
  1. iOS / iPadOSの作品ホームとProject Sidebarへ、既存の`NovelDocument`へ実際に保存される **プロット、登場人物、世界観、資料、設定** を追加する。プロット画面には章別の`PlotCard`と作品全体の`Flag`をまとめ、macOS版と同じ「プロット／伏線」の意味を保つ。未接続のplaceholderや将来機能は並べない。
  2. iPhoneは作品ホームから各一覧、選択項目の編集画面へ`NavigationStack`で進む。iPadはProject Sidebar / Outline / Detailを基本にし、Editor表示中に別セクションや項目へ移る前はD-041 / D-056のEditor同期境界でIME確定と旧話の全文captureを完了する。同期に失敗した場合は遷移しない。
  3. プロットカード、伏線、登場人物、世界観ノートは既存のIDと配列順を唯一の正とし、追加、選択、編集、削除、並べ替えを同じrevision保存経路へ流す。世界観本文は既存の`world.json` + `world-notes/<WorldNoteID>.md`、資料は`AttachmentManaging`境界を使い、App層からpackage内部構造を読まない。
  4. 資料の取り込みは利用者が選んだ外部URLへsecurity-scoped accessを得ている間だけ行い、現在のapp-private作業コピーへ複製する。作品操作gate → 保存直列化のlock順、呼び出し時の作品identity、失敗時に現在作品を維持する契約を守る。資料の一覧、削除、共有は実在するRepository機能だけを出す。
  5. iOS Editor上の重複した「本文」見出し、話タイトル入力、文字カウンターを外す。話タイトルはOutline／navigationの文脈を正とし、保存チェック／保存状態は上部のnative toolbarへ移す。本文面積を優先し、下部に別のstatus barを重ねない。
  6. Editor直下、ソフトウェアキーボード表示時はIMEの直上に、本文キャンバスと同じ背景を持つ執筆補助バーを置く。操作は`……`、`――`、`ルビ`、`傍点`の4つとし、D-030 / D-034の`EditorCommandSession`、選択snapshot、`EditorNotationRules`、正規のselection replacementをそのまま使う。App側が本文Bindingを直接変更せず、各実行はUndo 1回で戻せる。
  7. `……`と`――`は現在選択を置換し、空選択ではcaretへ挿入する。ルビは選択文字列を親文字として入力sheetへ渡し、確定時に`｜親文字《ルビ》`へ置換する。傍点は非空選択をgrapheme単位の`｜字《・》`へ変換し、改行と空白はそのまま保つ。IME変換中、surface失効、作品／話切替、古いselection snapshotでは本文を変更せず、明示的に再試行できる状態へ戻す。
  8. 執筆補助バーの背景を本文キャンバスへ揃えることはiOS Editor固有の例外とし、Project Sidebar / Outline / Formは引き続きsemantic colorとsystem materialを使う。4操作は44pt以上のhit target、Dynamic Type、VoiceOver label、hardware keyboardからの代替入口を持つ。`.novelpkg` schema、EditorPlugin pipeline、字下げ／鉤括弧のR1' / R3 / R4 / R5、TextKit 2、通常版のAI依存境界は変更しない。
- **置き換える範囲**: D-057の「作品ホームには作品情報、執筆、書き出しだけを出す」は、当時未接続だった機能をplaceholderとして出さないための制限だった。本Decisionにより実装・保存まで接続したプロット、登場人物、世界観、資料、設定を追加対象へ移す。macOSのstatus bar規約は維持し、iOS Editorだけ保存状態を上部へ移して文字カウンターを常設しない。
- **理由**: 作品棚と作品ホームで「どの作品で何をするか」は選べるようになったが、既存packageに保存されている小説支援データへiOSから到達できず、Editorにも話文脈と文字数の重複表示が残っていた。既存domainとcommand境界を再利用すれば、入力規則をUIKitへ複製せず、本文面積を優先したiOSらしい段階導線と、macOS版と同じ明示的な執筆補助を安全に提供できる。
- **詳細**: 端末別の情報階層、資料操作、Editor受け入れ条件は[IOS.md](IOS.md)、背景とtoolbarの規約は[STYLE.md](STYLE.md)、commandとnotationの正はD-030 / D-034および[DESIGN.md](DESIGN.md) 6.3を参照する。

## D-059: app-private作品へ話単位Device Syncと強制継続後の統合を追加する

- **日付**: 2026-08-11 / **状態**: 承認・実装中（`NovelSync`／file journal／`NovelSyncCloudKit` adapterはsource実装済み。Mac / iOS Appはsource接続済みで実装済み範囲の全ローカル回帰を通過したが、通常handoff、CloudKit外部設定、署名済み実機検証は未完了）
- **内容**:
  1. 各端末のapp-private `.novelpkg`を、端末内でdurableに保存する作業コピー兼、同期revisionをmaterializeしたportable snapshotとする。Files / iCloud Drive / File Provider上のpackageをopen-in-placeにして同期せず、live syncはpackageとは別の **話単位record protocol** で行う。sync binding、lease、remote revision、device / session ID、fork journalをpackageへ保存せず、S1で`.novelpkg` v3 schemaを変更しない。
  2. transport非依存の`NovelSync`境界を追加する。公開domain、wire、state、merge、fixtureへCloudKit / SwiftData / UI型を出さず、version付きportable JSONと共通fixtureを正とする。WindowsはC#、AndroidはKotlin等で同じprotocolを再実装し、SwiftやCloudKit adapterの直接共有を前提にしない。
  3. 現行Apple版は利用者のprivate CloudKit databaseと`CKSyncEngine`を使い、自前serverを置かない。SwiftDataはcanonical storeにせず、端末内のdurable package / journalとremote revision graph / headを明示的に調停する。CloudKit固有のrecord、change tag、account、push、asset処理は`NovelSyncCloudKit` adapterへ閉じ込める。
  4. 通常の端末移動はEpisodeIDごとのsoft leaseで調停する。leaseはopaqueなholder device、fresh editor session、単調増加するepochを持ち、同じ話は1 writerだけを編集可能、他端末はread-onlyとする。heartbeatや期限は応答待ちUIのhintに限り、local clockを権限の正にしない。
  5. 本文publishはimmutable revisionとし、`mutationID + expected remote head + lease holder / session / epoch`を条件にremote CASする。mutation receiptを同じtransactionで保存してretryをidempotentにし、headまたはepoch不一致を更新日時の新しい本文で上書きしない。wall-clock last-write-wins、push到着順、端末時刻によるwinner選択を禁止する。
  6. iPhoneの **強制的に続ける** は、最新remote controlをfetchしたうえでepochをexactly 1増やし、自分のfresh sessionへholderを移す明示CASとする。remote lease epoch CASが成功し、成功後headのfetch / installまで完了した場合だけ新writerとして編集可能にする。通信不能、fetch失敗、CAS競合時はread-onlyを維持する。成功したforceは旧writerをfenceし、旧epochのpublishを拒否する。旧writerの未同期本文はIME確定、native全文capture、端末内package保存を行い、base / local / remoteとstable fork revision IDをpackage外のdurable journalへ保全する。remote headをinstallしてもlocal forkを捨てない。offline forkは、通信断前にauthorityを持っていたwriterが継続した結果、または旧writerが別端末のforceをまだ観測せず継続した結果の保全に限り、非holderが通信不能のまま開始する編集modeにはしない。
  7. fork統合は共通祖先を確認した3-way mergeとする。base上の変更区間が非重複だと証明できる場合だけ自動mergeし、同一挿入点、曖昧なmapping、overlapは両本文とbaseを示して手動統合、keep local、keep remoteを選ばせる。どの選択もlocal forkをimmutable revisionとして保存し、`[remote head, local fork]`を親に持つ新しい2-parent merge revisionをCASでheadにする。競合解決用のauthority再取得は、確認済みremote revision IDとcontent digestをepochと同じCAS条件に含め、確認後にheadが進んでいればholder / epochを変更せず最新3面を再表示する。選ばれなかった本文／revisionを自動削除しない。
  8. 通常handoffは、旧writerの **IME commit → native capture → local package / journal save → pending remote flush → grant**、新writerの **fetch → verify → package materialize → native install** の順にする。remote install時はその話のUndo / Redo historyを破棄し、別baselineへ旧transactionを適用しない。`NSTextView.hasMarkedText` / `UITextView.markedTextRange`がactiveな間は外部本文を書き込まず、force通知もpendingとして確定後にfence / capture / installする。
  9. S1の製品範囲は、利用者が明示選択し、初回binding時にordered ChapterID / EpisodeIDの構造digestが完全一致した作品の **話本文handoff** に限る。binding時のEpisodeID集合をpackage外へsnapshotし、その後に構造が増えてもsnapshot内の既存話は同期継続、新規話はlocal-onlyとしてremoteへ暗黙作成しない。remote descriptorの列挙はstructure一致で絞る明示binding候補と既存bindingの検査にだけ使い、作品棚のcloud library、package取得、automatic bindingにはしない。`sourceDocumentID`は候補表示順と明示binding後のlocal package continuity検査に限り、remote identityや自動bindingへ使わない。package bootstrap、章・話の追加削除／タイトル／順序、作品情報、メモ、人物、プロット、伏線、世界観、資料、snapshot、attachment、live collaboration、CRDTは後続Decisionとする。未実装範囲をcloud同期済みと表示しない。
  10. Apple実装のiCloud container identifierは`iCloud.dev.serikayuzuki.fuminiwa.sync`に固定する。macOS / iOS entitlementとiOS remote notification background modeはsourceへ追加済みだが、Developer Program上のcontainer作成、両App IDへの同一container割当、CloudKit / Push capability、署名profile、development / production schema、同一iCloud accountの署名済みMac / iPhone実機検証は外部Gateとして未完了を明示する。macOSはD-011の非Sandbox直接配布を維持し、CloudKitのためにApp Sandboxを有効化しない。Package Validator / External Change / Conflict Gateも未完了のままとし、Device Syncをopen-in-place許可の根拠にしない。
- **置き換える範囲**: D-056 item 4の「app-private MVPをクラウド同期対応済みとは表現しない」とD-057 item 2 / 置き換える範囲の「独自cloud同期は対象外」は、**未実装を同期済みと表現しないProduct Truth**と**外部原本のopen-in-place除外**を維持したまま、本Decisionのapp-private話本文Device Sync trackに限って置き換える。D-056 item 8の「通常iOS targetは5 productだけ」も、S1実装でOS非依存`NovelSync`と`NovelSyncCloudKit`を追加できる範囲だけ置き換え、`NovelAI`、Experimental、provider、SDK、Node / CLI / sidecar、AI用network / credentialを除外する安全境界は維持する。D-056 / D-057のFiles / File Provider原本を直接編集しない境界、外部provider横断一覧の除外、単一package保存所有者は変更しない。
- **理由**: 利用者はMacで開いた話を、その場または移動後すぐiPhoneで続ける。単なるfile syncや時計LWWでは、両端末を同時に開いたままのIME確定前本文、未flush本文、package内部の部分競合を安全に扱えない。一方、1話1 writerのleaseとremote CASなら通常移動を単純にでき、明示force後も旧本文をforkとして残して決定論的に統合できる。package互換境界とlive同期protocolを分離すれば、将来Windows / AndroidがCloudKitを使わなくても同じ安全意味を再実装できる。
- **詳細**: wire、state、record mapping、handoff、force、offline、merge、editor境界、security / privacy、外部Gate、test、実装順は[DEVICE_SYNC.md](DEVICE_SYNC.md)を正とする。`.novelpkg`のOS間契約は[CROSS_PLATFORM.md](CROSS_PLATFORM.md)、iOS固有のProduct Truthは[IOS.md](IOS.md)を参照する。
- **実装状況 (2026-08-11)**: `NovelSync`のportable domain／fixture、`FileEpisodeSyncJournal`、`NovelSyncCloudKit`のprivate zone／CAS／receipt／asset／change tracking／account fence／engine recovery／local metadata bootstrap／durable pending create / bind intent／明示binding APIはsource実装済みである。Mac / iOS Appのproduction composition、設定UI、editor／保存／lifecycle、force／merge UIもsource接続済みで、`Scripts/check.sh`はMac通常114件／Device Sync 20件、iOS通常71件／Device Sync 15件を含む全検査を通過した。通常handoffの全経路の完結、container / App ID / capability / profile / schema deploy / 署名済み同一account実機、Package Validator / External Change / Conflictは未完了である。

## D-060: Device Syncをremote single-writer／全端末local-first編集へ変更する

- **日付**: 2026-08-11 / **状態**: 承認・Domain／Apple adapter／Mac・iOS App source実装・ローカル回帰通過（D-059の同期安全化は基準commit `508947d2`でsource実装と全ローカル回帰を固定済み。D-060の`NovelSync`は94 / 94件、`NovelSyncCloudKit`は48 / 48件、Mac Device Syncは45 / 45件とprivate-root 1 / 1件、iOS Simulator Device Syncは42 / 42件とnative focused 2 / 2件が通過。host in-memory local fakeも通過。paired native Mac↔iPhone、手動VoiceOver／実OS process-kill campaign、署名済み実CloudKitは未完了）
- **内容**:
  1. EpisodeIDごとのlease、holder / session / monotonic epoch、fencing token、revision CASは維持する。ただしwriterは **remote headを直接進められる1端末** を表すだけとし、local Editorへ入力できる端末を制限しない。同期設定済みの作品もMac / iPhoneの両方で同じ話を開いたまま編集でき、通信不能、remote holder、claim／takeover／fetch失敗だけを理由にread-onlyへしない。
  2. 確定した本文変更は **native editor → model反映 → app-private `.novelpkg`保存 → package外journalへのlocal revision保存 → remote同期** の論理順に扱う。process killでpackage前の本文を失わないため、package commit前にはexact全文／digest／scope／sequenceを持つapp-private full-body WALをatomic保存するが、これは一時的なrecovery guardであってportable revision、sync wire、`.novelpkg` metadataではない。CloudKit fetch／claim／uploadはEditor入力、package保存、journal保存を待たせない。同期対象話で「この端末に保存済み」と表示できるのは最新本文のpackage保存、journal保存、WALのexact acknowledgementが全て完了した後だけとし、background移行時はnetwork taskを待たずIME確定、WAL、package、journalを優先する。
  3. 本文入力、paste、delete、Undo、Redo、ルビ、傍点、`……`、`――`等によってnative editorの確定本文が実際に変わったことを暗黙の編集意思とする。閲覧、選択、copy、scroll、検索移動だけではremote authorityやremote stateを変更しない。Editor表示時のobserved baselineはexplicit edit／pending revisionを作らずclaim／publishもしない。remoteとの祖先不明時に本文保全のreviewとなってもauthorityは変更しない。最初の実変更をlocal branchへdurable化した後だけ、裏側で通常claimと必要なepoch更新を試す。現行wire v1に`HandoffRequest` recordはなく、別holder時はobserved remote head ID／digest／epochのexact CASによるinternal takeoverを使う。cooperative request／flush／grantを追加する場合は将来のadditive Decision／protocolとする。
  4. remote authorityを持たない端末の変更は、最後に証明できたremote revisionをbaseとするdetached local branchへ保存する。journalは少なくとも`SyncWorkID`、`EpisodeID`、`LocalWorkingCopyID`、最後に確認したremote revision ID／digest、stable branch／local revision ID、exact本文、replica ID、protocol version、同期未確認状態を保持する。共通祖先を証明できなくても本文を保存し、自動merge／publishはしない。app再起動後もaccount／network確認を待たずpackageとjournalからlocal編集を再開できる。
  5. reconnect後、remote headがbaseから不変ならauthority取得後にlocal revisionを自動publishする。local／remoteの本文digestが同じなら重複を畳む。証明済み共通祖先に対する変更箇所が非重複なら、boundedなUnicode scalar Myers diffで複数hunkを決定論的に統合し、`[remote head, local head]`を親に持つ2-parent merge revisionを自動生成してpublishする。同じ範囲の変更、祖先不明、またはresource budget超過だけを「変更の確認が必要」とし、base／local／remoteと安全な非重複hunkを反映した確認用下書きをdurableに保持する。
  6. review中も現在端末のEditorとlocal保存を止めず、追加編集は新しいlocal headとして保持する。「この端末を採用」「もう一方を採用」「手動で統合」の結果は必ず最新remote headと確認済みlocal headを親に持つ2-parent revisionとする。remote publish、package反映、journal上の解決checkpointが全て成功するまで元の両本文を削除しない。確認後にremoteまたはlocalが進んだ場合も確認済み下書きを捨てず再評価する。
  7. remote本文をactiveなnative editorへCloudKit callbackやSwiftUI updateから突然流し込まない。Editor surface／作品／話／世代、expected digest、IME marked text、Undo／Redo、selection、未journaled本文を再検査する明示的なexternal replacement境界だけを使い、安全でなければjournalへpending materializationとして延期する。古いcallbackや別baselineのUndo transactionを新しい本文へ適用しない。
  8. 通常UIに「編集権」「lease」「epoch」「fencing」「fork」「強制的に続ける」「オフライン下書きを開始」を表示しない。Editor上部の小さな状態記号を正とし、チェックは端末内保存済み、控えめな進行表示は同期処理中、小さなoffline表示は端末内保存済み、警告は変更の確認が必要、エラーはiCloud account／設定または端末内保存の確認が必要、を表す。詳細は記号を選択したときだけ表示し、VoiceOverでは「この端末に保存済み」「iCloudにも同期済み」「オフライン」「統合が必要」「同期設定を確認」を区別する。macOS Editorもこの上部記号へ揃え、通常の同期bannerや強制継続buttonを置かない。
  9. iCloud accountが変わった場合、旧account scopeへ属するrevision／binding／journalを新account transportへ渡さない。旧本文はpackageとquarantineしたjournalに残してlocal編集できる。account確認失敗、CloudKit bootstrap失敗、entitlement未成立はremote処理だけを止め、既存bindingはlocal metadata／journal resolverへfallbackしてlocal Editor／package／journalを止めない。一時的なtransport／CloudKit unavailableはofflineとしてbootstrapを再試行し、no account／account変更／entitlement・設定不整合だけを設定確認とする。既存bindingの旧account transportへも、live account scopeの再確認が成功するまで送信しない。
  10. `.novelpkg`はportable snapshot、交換、backup境界のままとし、CloudKit固有metadataやpre-package WALを追加しない。revision、branch、CAS、merge、journal、状態機械は`NovelSync`へ置き、CloudKitはApple専用transport adapterに限定する。D-060では既存のDevice Sync wire protocol v1を維持し、package外journalだけをschema v2へ更新する。wire v1、journal schema v2、UTF-8、canonical UUID、digest、resource cap、parent順、状態遷移、merge結果をgolden fixture化する。journalのpending revisionは最大5件、競合保持は最大3件、materialization graphは最大4件、fresh-session relay込みのpendingは最大5件、journal JSONは最大80 MiBとする。1 MiBのcontrol character本文を全revisionへ置いた最大状態75,506,494 bytesのencode／save／load回帰を固定する。app-private WALのreview用`preservedMarkers`は最大3本文とし、さらに未知／不整合なbranchが来た場合は既存package／WAL／preserved本文を保持したlocal integrity／recovery errorへfail-closedにして、choice／remote mutationを行わない。これは通信／別holderによるread-onlyではなく本文欠落を防ぐresource capである。WindowsはC#、AndroidはKotlin等で同じwire v1とjournal／state／merge fixtureを再実装し、SwiftUI、UIKit、AppKit、NovelStorage、CloudKitへ依存しない。Mac／iOSのWALとmerge recovery rootは信頼済みapp-private ancestorへanchorし、下位symlink／final symlink／root identity差し替えをfail-closedにするが、1操作中にrenameを競合させる悪意あるsame-UID processへの完全なTOCTOU耐性は主張せず、External Change / Conflict Gateを未完了のまま維持する。
  11. 完了報告は **実装完了**、**Simulator／local fake server検証**、**署名済みMac＋iPhoneによる実CloudKit検証** を分離する。source、署名なしbuild、fake成功を実CloudKit完了と読み替えず、container／App ID／capability／profile／schema／同一account実機は外部Gateとして残す。
- **置き換える範囲**: D-059自体とその実装済み／全ローカル回帰通過の履歴は削除しない。本DecisionはD-059 item 4の「同じ話は1 writerだけを編集可能、他端末はread-only」、item 6の「非holderはoffline編集を開始できず、明示forceとremote install完了までread-only」、item 8の「handoff中は入力を止め、grant後remote本文を直ちにinstall」を置き換える。D-059 item 5のremote CAS／mutation receipt／fencing、item 7の共通祖先と2-parent revision／原文保持、item 1〜3／9〜10のpackage・依存・製品範囲・CloudKit外部Gateは維持する。D-058の「macOSは下部status barを維持し、iOS Editorだけ保存状態を上部へ置く」は、Editorのlocal保存／同期状態に限り両platform上部の小さな記号へ置き換える。
- **理由**: 利用者はMacとiPhoneを同時に開いたまま、通信やremote holderを意識せず交互に執筆する。remote writerとlocal入力許可を同じ状態にすると、通信待ちや別端末の存在が執筆停止へ直結する。一方、本文を先に各端末のpackage／journalへ保存し、remote headだけをsingle-writer CASで進めれば、Appleのメモに近いlocal-first UXと、遅延publish／同時編集時の上書き防止を両立できる。
- **実装状況 (2026-08-11)**: `NovelSync`のwire v1／journal v2、v1 migration、observed baseline、detached local revision、offline復元、exact authority takeover、同一結果collapse、bounded multi-hunk merge、2-parent automatic／manual integration、stale fencing、upload tail、process再開をsource実装し、94 / 94件（local-first 33件、既存coordinator 18件）が通過した。`NovelSyncCloudKit`は48 / 48件が通過した。Mac／iOSのfull-body pre-package WAL、local-first保存、remote nonblocking化、editor guard、上部状態UI、reviewもsource実装・freeze済みで、Mac Device Sync 45 / 45件とprivate-root 1 / 1件、iOS Simulator Device Sync 42 / 42件とnative focused 2 / 2件が通過した。host上のin-memory local fakeも通過した。container／App ID／capability／profile／schema／paired native Mac↔iPhone／手動VoiceOver／実OS process-kill campaign／署名済み同一account実CloudKitは未完了である。
- **詳細**: local durability、detached branch、authority、reconnect、merge、native editor、表示、test、段階的実装は[DEVICE_SYNC.md](DEVICE_SYNC.md)を正とする。portable wire v1／journal schema v2の境界は[CROSS_PLATFORM.md](CROSS_PLATFORM.md)、iOS固有境界は[IOS.md](IOS.md)、全体の依存とロードマップは[DESIGN.md](DESIGN.md)を参照する。

## D-061: Device Syncを作品全体のlocal-first snapshot同期へ切り替える

- **日付**: 2026-08-11 / **状態**: 一部置換（→ D-063でcloud library／bootstrap、→ D-071でwhole revision `CKAsset`・作品全体3-way merge・3面reviewを置き換える）。Domain／Apple adapter／Mac・iOS App source実装・focused local回帰通過（D-061はWork Domain 44 / 44件・5 suites、CloudKit schema focused 3 / 3件を含む`NovelSyncCloudKit` full 59 / 59件・15 suites、Mac `NovelAppDeviceSyncTests` 64 / 64件・3 suites、iOS focused 56 / 56件、generic iOS build／build-for-testingが通過。D-059／D-060の既存件数と基準commitは別の履歴として維持する。署名済み実CloudKit、paired native Mac↔iPhone、手動VoiceOver、実OS process-kill campaign、production migration／minimum-version fenceは未完了）
- **内容**:
  1. 現行の通常Mac／iOS Appで使うDevice Syncの単位をEpisode本文から **`NovelDocument`全体の`WorkSnapshot`** へ切り替える。v1 snapshotには作品タイトル／あらすじ、章と話のID・タイトル・所属・配列順、各話の本文／メモ、登場人物、プロットカード、伏線、世界観ノートを含める。資料binary／attachment、snapshot履歴、アプリ外観／本文フォント等の端末設定、選択状態、local path／bookmark、作品棚としてのcloud library、別端末へのpackage初回download／new-device bootstrapは含めない。`.novelpkg` v3 schemaは変更しない。
  2. `WorkSyncWireProtocol.currentVersion = 1`を、D-059／D-060のEpisode用`SyncWireProtocol` v1とは **別namespace・別互換系列** として追加する。Apple adapterも同じprivate custom zone内で`FUMINIWAWorkControlV1`、`FUMINIWAWorkRevisionV1`、`FUMINIWAWorkMutationReceiptV1`を既存Episode recordとは別に使う。番号がどちらも1であることを相互decode可能という意味にしない。
  3. local保存の順序を **native editor／form → model → package外Work journalへのstaged snapshot → app-private `.novelpkg`保存 → staged revisionのexact confirm → remote同期** とする。stageはpackage保存前のwrite-ahead intentで、confirm前はpublishできない。stageに失敗してもpackage保存は止めず、次回preflightでpackageのexact snapshotを回収する。package保存に失敗したstageはremoteへ昇格しない。CloudKit fetch／uploadはこのlocal durability経路の後に別taskで行う。
  4. remote revisionはcanonicalなwhole-work snapshotを持つimmutable revisionとし、Apple adapterはcanonical whole revisionを`CKAsset`へ保存する。publishは`mutationID`、expected head revision ID、expected head snapshot digestを同じcontrol CASで検査し、revision／mutation receipt／更新後controlをatomicに保存する。応答消失時は同じmutation IDとcommand digestでread-back／retryし、時計、更新日時、push順によるlast-write-winsは使わない。
  5. 端末内の変更はFIFO mutation laneで直列化する。network I/Oはlane外で行い、返答を適用するときにsealed mutation／revisionと現在のjournal observationが一致する場合だけ状態を進める。network中の追加入力はlocal head／tailとして保持し、古い応答で上書きしない。
  6. mergeはstable IDと配列順を使う作品全体の3-way mergeとする。共通祖先に対する非重複変更だけを自動統合する。同じfield／本文範囲の重複、delete対edit／move／reorder、両側で異なる順序変更、同じIDの異なる追加、祖先不明、resource budget超過は自動winnerを選ばずreviewへ送る。
  7. conflict reviewは **この端末／iCloud／統合案** の3面を同じ画面で比較し、「この端末を採用」「iCloudを採用」「統合案を採用」を明示的に選べるようにする。閉じてもbase／local／remote／proposedをjournalへ保持する。通常のcloud conflict中はEditorとlocal保存を止めず、追加編集を最新local headとして再評価する。一方、再起動時にpackage、staged intent、pending remoteのどれがmaterialized truthか一意に決められない **local recovery** は、本文を推測採用せず同じ比較UIで利用者が選ぶまで作品編集をgateする。
  8. remote fetch／push callbackからactiveな`NSTextView`／`UITextView`へ本文や作品snapshotを注入しない。remote fast-forward、自動merge、解決結果はpending materializationとして保持し、作品／session／Editor surface／世代、IME、selection、Undo／Redo、未保存変更を確認しlocal saveを完了した安全な境界だけでpackageへmaterializeする。書戻し後に再読込した`WorkSnapshot`がexact一致した場合だけjournalをacknowledgeする。
  9. v1のresource上限は、canonical `WorkSnapshot` 48 MiB、canonical `WorkRevision` 50 MiB、`FileWorkSyncJournal` 320 MiB、outbox revision 3件、journal内revision store 5件、conflict descriptor 512件、descriptor内各比較値のexcerpt 1 KiBとする。各snapshot stringは1 MiBを上限とし、超過時は切り詰め、部分publish、暗黙winner選択をせずfail-closedにする。完全な三者snapshotはexcerptとは別にrevision／reviewへ保持する。5 revision、完全なproposed snapshot、bounded conflictsを含む到達可能な最大構成270,439,704 bytesのjournal保存／再読込回帰を通過させる。
  10. D-061は公開前の **development cutover** とする。D-059／D-060は署名済み実CloudKitへdeploy／一般出荷していない前提で、開発CloudKit同期dataをresetし、全test端末を同じD-061 buildへ更新して検証する。Episode recordをWork recordへ自動migrationせず、旧Episode-only clientとD-061 clientを同じ作品へ同時接続した場合の収束・競合検出・相互安全性を主張しない。production upgradeを行う場合は、互換migrationまたはminimum client version fenceを別Decisionで実装・検証する。それまでは出荷不可とする。
  11. 完了報告はD-060と同様に、(a) sourceとunit／integration、(b) Simulator／local fake、(c) 署名済みMac＋iPhoneの実CloudKitを分離する。D-061 sourceとfocused local testの成功を、container／schema deploy、paired native、手動VoiceOver、実OS process-killの完了へ読み替えない。
- **置き換える範囲**: D-059／D-060自体、基準commit、既存test件数、Episode wire v1／journal v2の実装履歴は削除しない。本Decisionは、現行通常Mac／iOS Appの同期対象についてD-059 item 9とD-060の「binding snapshot内の1話本文だけ」を置き換え、D-060 item 2のpackage→Episode journal順をwhole-work modeではitem 3のstage→package→confirmへ置き換える。Episodeごとのlease／holder／epoch／internal takeover、Episode review UIを現行Work pathの権限・UXとしては使わない。D-059 item 1〜3／10とD-060 item 7／9／11のapp-private package、層分離、active editor非注入、account fence、外部Gateは維持する。Files / File Provider原本のopen-in-place除外、Package Validator / External Change / Conflict Gate、AI安全境界は変更しない。
- **理由**: 利用者が地下鉄等の不安定な通信下でも作品を編集し、後で統合したい対象は本文だけではない。作品情報や構成を別端末で変更できないEpisode単位S1は利用者の「作品が同期される」という理解と一致しない。全作品snapshotを各端末へ先にdurable化し、remoteではexact CAS、非重複自動merge、曖昧時だけ3面reviewを使う方が、リアルタイム共同編集を実装せずAppleのメモに近いlocal-first体験を一貫して提供できる。
- **実装状況 (2026-08-12更新)**: `WorkSnapshot`／`WorkRevision`／whole-work merger／file journal／coordinator、別namespaceのWork wire v1、CloudKit Work control／revision asset／mutation receipt、Mac／iOSのstage→package→confirm→network、safe materialization、local recovery gate、3面review UIをsource実装した。Work Domain focused 44 / 44件（5 suites）、CloudKit schema focused 3 / 3件を含む`NovelSyncCloudKit` full 59 / 59件（15 suites）、Mac `NovelAppDeviceSyncTests` 64 / 64件（integration 57＋edit-intent 4＋root 3）、iOS focused 56 / 56件（integration 49＋UI 7）、generic iOS build／build-for-testingが通過した。Work conflict UIは既存Mac focused coverageを含め最終source監査した。これらはlocal／Simulator／署名なしbuildの証跡であり、D-059／D-060の既存件数はD-061へ流用しない。Developer Program上のcontainer／App ID／profile／development・production schema、paired native Mac↔iPhone、手動VoiceOver、実OS process-kill campaign、署名済み実CloudKit、production migration／minimum-version fenceは未完了である。
- **詳細**: current whole-work scope、local durability、merge／review、CloudKit mapping、test／外部Gateは[DEVICE_SYNC.md](DEVICE_SYNC.md)を正とする。portable boundaryは[CROSS_PLATFORM.md](CROSS_PLATFORM.md)、iOS固有境界は[IOS.md](IOS.md)、全体の依存とロードマップは[DESIGN.md](DESIGN.md)を参照する。

## D-062: macOSの通常起動を明示的な作品選択から始める

- **日付**: 2026-08-12 / **状態**: 大部分を置換（→ D-063。明示選択、Safe Launch、local preflight／recovery gateは維持し、local recent 1件、2ペイン、保存場所／Finder表示、外部原本の直接openを置き換える）
- **内容**:
  1. macOSの通常起動は`loading`の後に編集不能な`documentSelection`を表示し、前回作品を自動で開かず、recentが無い場合も新規作品を自動作成しない。利用者が前回作品、新規作品、または別の`.novelpkg`を明示的に選び、安全な読込／保存が成功した後だけ`ready`へ進む。Finder / Open WithからURLを指定した起動は、その明示選択を優先してchooserを経由せず直接開く。単一windowと明示Repositoryを維持し、別のwelcome windowや`DocumentGroup`は追加しない。
  2. chooserが表示するrecentは、App層の既存preferenceに保存した **直近1件のstandardized local URL** だけとする。これは管理対象作品を列挙する作品棚、app-private library、iCloud上の作品一覧、remote descriptor、new-device bootstrapではない。Documents／iCloud Drive／File ProviderやCloudKitを走査せず、同期badgeを表示しない。recentは表示しただけではRepositoryへ読み込まず、選択時のsession tokenが現在値と一致した場合だけ通常の作品operation gateへ渡す。
  3. chooserは同じwindow内の標準`NavigationSplitView`とし、左に「作品を選ぶ」／「最近使った作品」、右に選択した直近作品の名称と保存場所を表示する。主操作は「作品を開く」、通常操作は「Finderで表示」「新規作品」「別の作品を開く…」とする。recentが無いときは「作品を選んでください」／「新しい作品を作るか、保存済みの作品を開けます。」を示す。macOSのSystem／明示Light／明示Dark、semantic color、標準List selection、標準button階層を使い、iOS固有の「このデバイスの作品」「取り込む」「選択中」や初回Darkを持ち込まない。
  4. 前回作品または別作品の読込、新規作品の初回保存が失敗した場合は、新規作品へfallbackせずD-039の`recovery`へ進む。失敗したURL、recent preference、ディスク上の作品を変更せず、「再試行」「Finderで表示」「別の作品を開く…」「新規作品を作る…」を維持する。Finder指定URLの起動失敗も同じである。chooser／Recoveryから開始した非同期操作は、表示時のsession tokenが古ければRepository変更前に拒否する。
  5. 通常chooserの直近作品／open panel／明示的新規作成と、起動Recoveryの再試行は、install成功後に **AppStateのactivation経路からlocal WorkSync preflightを必ず起動してawaitする**。Viewの表示、Workbenchのsection選択、remote signal到着をpreflight開始条件にしない。cold launchのFinder / Open Withは、指定URLをbootstrapでinstallした直後に既存scene startup境界からAppStateのpreflightをawaitする。preflightは現在sessionとpackage／package外Work journalを照合し、曖昧でなければlocal編集を解放する。unbound、network offline、account／transport確認失敗だけを理由にlocal Editorを止めず、remote処理はD-061のlocal durabilityより後に行う。
  6. preflightでpackage、staged intent、pending materializationの正を一意に決められないlocal recoveryの間は、`permitsDocumentInteraction`を閉じてWorkbench内の本文／フォーム／構造変更、保存、作品内操作をgateし、背後のWorkbenchを知覚・操作可能にしない。ただし解決に必要なroot-levelの「変更を確認」と、その先の「この端末を採用」「iCloudを採用」「統合案を採用」は操作可能なままにする。root recovery choiceは通常mutationの例外的な許可ではなく、表示時のexact reviewとdocument sessionを再検査してlocal recoveryを解決する専用経路とする。通常のcloud conflict reviewはD-061どおりlocal Editorとlocal保存を止めない。
  7. recent行は作品名をaccessibility label、前回作品であることと保存場所をvalue、開き方をhintとして一要素で読み上げる。OS標準focus ringを維持し、矢印キーで選択、Returnで「作品を開く」、`Cmd+N`／`Cmd+O`で既存File commandへ到達できるようにする。preflight／recovery gateは状態を文字とVoiceOver labelで伝え、色や進行表示だけへ依存しない。System／Light／Dark、Full Keyboard Access、VoiceOver、Increase Contrast、Reduce Transparency／Reduce Motionを受け入れ対象にする。
- **置き換える範囲**: D-039 item 1の三状態をmacOSでは`loading`／`documentSelection`／`ready`／`recovery`へ拡張し、D-039 item 2／理由に含まれる「前回作品を通常起動で自動読込する」前提と、従来の「recentが無ければ新規作品を自動作成する」挙動だけを置き換える。D-039の編集可能placeholder非表示、読込／保存失敗時の自動fallback禁止、URL／recent／原稿の保持、Recovery導線、bootstrap single-flight、valid UTF-8境界は維持する。D-010の単一window、D-041のFIFO gate／session token／IME確定、D-044のmacOS System外観既定、D-061のlocal-first preflight／local recovery gate／cloud library除外も変更しない。`ready`中の通常の新規／open／作品切替の意味と安全境界は変更せず、iOSのapp-private作品棚もD-057のままとする。
- **理由**: 前回作品を即座に開く起動は速い一方、複数の原稿を扱う利用者に「どの作品へ入るか」を確認する余地がなく、recentが無いだけでディスクへ新規作品を作る副作用も生んでいた。直近1件と明示的な新規／openだけを示す小さなchooserなら、現行のlocal URL契約をcloud libraryへ誤拡張せず、D-039のSafe Launchを保ったまま利用者の選択を起点にできる。また通常chooser／Recoveryのactivation直後にlocal preflightを待ち、root recovery choiceだけを専用経路として残せば、Workbenchが先に編集可能になる隙間を作らず、通信不能でも安全なlocal状態だけで執筆を再開できる。
- **実装状況 (2026-08-12)**: `documentSelection`、同一windowのnative chooser、明示open／new、Finder直開き優先、Recovery再試行後のactivation、話が0件でもepisode選択に依存しないwhole-work preflight、root local-recovery gateをsource実装した。Mac `AppStateBootstrapTests` 15 / 15件、`NovelAppDeviceSyncTests` 64 / 64件（integration 57＋edit-intent 4＋root 3）とFUMINIWA macOS buildが通過し、実AppのSystem Dark外観でもchooserの2ペイン、recent、各操作の表示を確認した。これはlocal／署名なしbuildの証跡であり、cloud library／new-device bootstrapや署名済み実CloudKitを実装済みとはしない。
- **詳細**: 起動状態、AppState責務、WorkSync preflightは[DESIGN.md](DESIGN.md)、画面構成・文言・外観・アクセシビリティは[STYLE.md](STYLE.md)、local recoveryと3面reviewの安全契約は[DEVICE_SYNC.md](DEVICE_SYNC.md)を正とする。

## D-063: Apple版をiCloud作品ライブラリ起点のapp-private作業コピーへ切り替える

- **日付**: 2026-08-12 / **状態**: 一部置換（→ D-071／D-072、次世代はD-077。単一作品棚、WorkID、account fence、原本非破壊Import／identity不変Exportは維持し、app-private package正本、CloudKit catalog／working copy実装はSQLite＋Rust Snapshot Syncへ置き換える）。macOS／iOS / iPadOSとも現行source実装完了／local automated GO（D-077は未実装、Release NO-GOは継続）
- **内容**:
  1. Apple版の通常起動は`loading`後、1つの「iCloudの作品」を作品選択の正とする。macOSは同じwindow内の単一paneに、小さなアプリアイコン／「ふみにわ」、「作品を取り込む…」「新しい作品」、1つのListだけを表示する。iOS / iPadOSは既存の適応navigationを維持し、rootの作品棚を同じ「iCloudの作品」へ置き換える。どちらもlocal path、保存場所、Finder／Files上の作業コピー、recent専用一覧、複数のlocal／cloud棚を並べない。macOSのListはsingle clickで選択し、Listがfocus中のReturnまたはdouble clickで開く。上部buttonのkeyboard focusをrootのReturn処理が奪わない。`Cmd+N`は新規、`Cmd+O`は取込、`Cmd+Shift+S`は「書き出す…」へ到達させる。iOS / iPadOSはtap、pull-to-refresh、標準Files picker／exporterを使い、macOSのkeyboard／window配置を機械的に移植しない。
  2. 「iCloudの作品」は、private CloudKitのWork catalogと、端末内で検証したapp-private working copy registryを`SyncWorkID`だけでmergeする。作品タイトル、`NovelDocument.id`、構造digest、package名を同一作品判定に使わない。remote controlにexact headがないworkを別端末の作品として列挙しない。表示用タイトルはUTF-8 1 KiBまでのbounded projectionとし、完全タイトルのdigest／byte countをhead identityへ含める。省略時は末尾の「…」とVoiceOverで伝える。remote catalog cacheは最大1,088件（binding 1,024件＋unbound pending-open最大64件を覆う）のrecent entryにbounded化し、local-bound／pending workを優先する。refresh中／一時失敗で既存cacheを空にしない。1件のmalformed remote rowはそのWorkIDだけをquarantineし、他のvalid rowとlocal inventoryを残す。以前確認済みsame account scopeの一時offlineではcached remote-only行を残してdownloadだけを無効にするが、`accountRequired`／unscoped／account mismatchではlocal packageのないremote rowとtitleをquarantineして表示しない。
  3. activeなApple版作業コピーは、利用者へ見せない信頼済みapp-private rootへ1 work 1 packageで置く。macOSは`SyncWorkingCopies-v2/<SyncWorkID>.novelpkg`、iOS / iPadOSは同じ意味を持つiOS専用private rootとし、相互にOS固有pathを契約化しない。URLをregistryへ保存せずWorkIDから導出し、各workのregistry recordを個別fileとしてatomicに更新する。registry欠損時はdeterministicなpackage inventoryから保全し、壊れたrecord／orphan packageはそのworkだけを`needsReview`／利用不可へ隔離する。未確認状態を自動で「同期済み」にせず、別workの破損で棚全体を空にしない。通常UI、Recovery、資料、snapshotへ内部pathやFinder／Files入口を出さず、diagnostic log／利用者向けerrorへapp-private path／WorkIDを出さずboundedなerror categoryだけを記録する。
  4. 既に端末内へexactに保存されているworkは通信不能でも開いて編集でき、D-061のstage→package→confirm→remoteを続ける。local registryはiCloud accountに依存せずlocal openの根拠にできるが、別accountへのupload／bindingの根拠にはしない。継続uploadはaccount-scoped CloudKit metadata／journalのexact bindingだけをauthorityとし、account変更／identity未確認時は旧accountのremote title、binding、pending revisionをquarantineして新accountへ送らない。active WorkSyncに`lastKnownRemoteHead`があるのにcurrent remote headがnilなら、initial publishへ読み替えずtyped `remoteHeadMissing`でpublish前に停止する。local head、outbox、last-known head、sealed publishをexactに保持し、remote head復帰後に同じlocal revisionを再送する。初回account bindingもremote mutationより前にdurable化する。
  5. 「新しい作品」と「作品を取り込む…」のlocal reserve／private package install／registry確定は、networkとlive iCloud account確認を待たず、remote catalog全体の取得に失敗していても開始できる。新規は毎回新しい`SyncWorkID`を作り、取込は外部`.novelpkg`を原本のまま保持して、新しいWorkIDのapp-private copyとしてinstallする。同じ`NovelDocument.id`、タイトル、構造、以前に書き出したpackageの再取込でもdeduplicate／automatic rebindしない。Finder / Open Withで明示されたpackageもopen-in-placeせず、この取込境界を通す。旧`~/Documents/FUMINIWA`等の利用者可視packageは自動移動・削除・rekeyせず、明示Importでだけ新しいworkにする。以前exactに確認したaccount scopeがあり一時的にofflineな場合だけ、そのsame scopeのpending creation／bindingをdurable化し、同じscopeの復旧後に自動再開できる。`accountRequired`／unscoped／different account中に新しく作ったunbound workはlocal-onlyとして開いて編集できるが、後から現れたaccountへautomatic adopt／rebind／uploadしない。account-quarantinedとするのは以前のscopeへexactに結び付いた検証済みcopyだけである。明示的account association UIとauthorityは後続Decisionまで提供しない（→ D-072が明示の「iCloudに保存」を定義。automatic adopt禁止は維持）。first account bindingは常にremote mutationより前にdurable化する。
  6. 新規／取込は、作成予定snapshotからexpected package attestationを作り、WorkIDとともにreservationへatomic保存してからstagingへ進む。D-063以前の`reservedForPublish`でpackage／expected attestationがnilのlegacy recordはdocument ID一致だけでstaging／finalを自動採用せずquarantineする。finalと同じapp-private rootのdeterministic stagingへ完全packageを作り、portable tree検証、`NovelDocument`／`WorkSnapshot`のread-back、byte／digest attestationをexpected値と照合した後だけno-overwriteのatomic renameでinstallする。registry intentをinstall／networkより先にdurable化し、finalが既にある場合はexactに準備済みのheadだけをresumeする。それ以外は既存finalを置換せずquarantine／reviewへ送る。sourceとstaging／finalの重なり、symlink、resource上限、pre／post treeまたはlogical read-backで検出した内容不一致はfail-closedにし、stagingを破棄して再起動後も作業コピーとして採用せず、原本と既存作業コピーを変更しない。ただしcopy中のhard-link／外部process変更を完全に防ぐTOCTOU耐性は主張せず、Package ValidatorとExternal Change / Conflict Gateを未完了のまま維持する。
  7. remote-only workを開く場合はonlineかつlive account scope確認済みに限り、WorkIDと表示時のexact headを持つpending-open intentをasset fetchより前にatomic保存し、catalogを再取得してhead revision ID／snapshot digest／byte countが一致することを確認する。取得するのはD-061 `WorkSnapshot` v1だけであり、full revisionのdigest／parents／work identityを検証する。app-private stagingへmaterializeし、package read-backがexact一致した後だけcanonicalなWorkID locatorへbindし、remote bootstrap専用journalを作ってpending intentを完了する。process終了後も各checkpointから冪等に再開し、既存finalが別内容なら上書きしない。Domain bind完了後からregistryのsynced mark前にprocessが終了しても、exact package、pending projection、outbox-free journalが一致すれば、offlineかつremote catalogが0件でもそのWorkIDだけを`synced`へ復旧する。
  8. startup rowの表示はProduct Truthを守る。local package attestationとaccount-scoped remote receipt／exact headの両方が一致する場合だけ`checkmark.icloud`と「iCloudと同期済み」を出す。availableなcurrent catalogからacknowledged workが欠落した場合は、過去receiptだけで同期済みを主張せず`.cloudUnavailable`へ落とし、checkmark、open、自動uploadを止めてlocal packageを保持する。same-scopeのlocal変更がremote未確認なら「この端末に保存済み、iCloudへ反映中」、一時offlineなら「接続後にiCloudへ同期」とする。`accountRequired`／unscoped／different account中に新しく作ったunbound local-only workは「この端末にのみ保存済み」とし、account確認だけで自動同期するように見せない。remote-onlyは「タップ／選択してこの端末に保存」、download済みofflineは「この端末に保存済み、オフラインでも開けます」、競合は「内容の確認が必要」とする。account mismatchでも旧scopeへexactに結び付いた検証済みlocal packageは「この端末に保存済み、iCloudアカウントが異なります」として開いて編集できるが、旧scopeのremote title／binding／pendingをquarantineしてuploadしない。`accountRequired`／different accountでは、local packageのないApp `remoteOpenPending` rowを含むremote-only row／titleを棚から除外する。head欠損、registry／package破損も安全に開けない状態として区別し、一時refresh中はcached rowsを維持する。状態を色／iconだけで表現しない。
  9. Apple版MVPでは利用者がworkを削除するUI／APIを出さない。誤ったidentity推定による別work削除を避け、削除・CloudKit tombstone・複数端末retentionは別Decisionで設計する（→ D-072がこの端末のlocal removeを定義。CloudKit tombstoneは禁止のまま）。
  10. `.novelpkg`を利用者へ渡す操作は各platformの「作品を書き出す…」に統合する。native editor／form、app-private package、Work journalをcurrent sessionでflushした後、`PortableDocumentPackageRepository`（`DocumentCopyingRepository`を含む）の検証済みpackage全体copyを使い、destination側もread-backする。能力がない場合はplain `save`へfallbackせず失敗する。現在端末のpackageに存在するattachment、snapshot履歴、非hidden未知root itemを保持するが、書き出し先をactive URLにせず、document session、recent、WorkID、binding、journal、selectionを変更しない。iOS / iPadOSでも一時的なexport artifactを生成するだけで、Files URLを編集先へ切り替えない。
  11. D-063のcloud library／new-device bootstrapは、D-061で除外した **作品棚列挙と別端末のWorkSnapshot初回取得だけ** を追加する。attachment／資料binary、`.novelpkg` snapshot履歴、非hidden未知root item、アプリ外観／本文font等の端末設定、selection／navigationは引き続きCloudKit同期対象外である。したがって別端末から初回downloadしたpackageにはそれらが復元されず、当該端末で書き出すpackageにも存在しない可能性がある。「iCloud」は作品本文・構成等のWorkSnapshot同期を意味し、完全backup、package全体mirror、E2EE、資料／snapshot復元済みとは表示しない。
  12. D-063も一般配布前のdevelopment cutoverである。D-061以前の実CloudKit未配布を前提にdevelopment custom zoneと旧local sync metadata／journal／registryをresetし、全test端末を同じD-063 buildへ更新して検証する。ただしoutbox、staged revision、pending materialization、pending create／bind／open、reviewが1件でもある場合はblind resetしない。reset前にexact versionのreaderで全hidden working copyを列挙・attestし、registryをexactに再構築／保全できるか、検証済み`.novelpkg`としてExportして回収する。attachment／snapshot／unknown rootはremote WorkSnapshotから戻らないため、remote head一致だけでhidden packageを削除してはならない。未到達package、未知version、不整合、Export失敗が1件でもあればresetを停止し、hidden working-copy root自体をmetadata resetの削除対象にしない。old visible packageは明示Importで原本を残す。production upgradeにはdata migrationまたはminimum client version fenceを別Decisionで実装・検証する。
  13. Package Validator Gate、External Change / Conflict Gate、Developer Program上のcontainer／App ID／profile／development・production schema、署名済みMac＋iPhoneの実CloudKit、paired offline／account switch／process-kill／VoiceOver campaign、production migration／minimum-version fenceが完了するまでReleaseはNO-GOである。source／unit／local fake／署名なしbuildの成功を、実CloudKit、完全backup、production migration、公開準備完了へ読み替えない。
  14. iOS / iPadOSのD-057作品棚は、D-063有効時にlocal package名をidentityとする「このデバイスの作品」から、Macと同じWorkID catalog／registry projectionを使う1つの「iCloudの作品」へ切り替える。remote-onlyは明示tap後にexact headをprivate packageへ取得し、cached local／local pending／local-only／account-quarantined／reviewを同じ棚で区別する。旧iOS app-private rootにだけ存在するpackageは自動upload／削除／rekeyせず「タップして新しい作品として取り込む」という明示recoveryで新WorkIDのportable copyを作り、new copyのinstall／read-back後も旧bytesを`legacyPreserved`として保全する。cold Files / Open WithはCloud account確認中でも失わず、bootstrap完了後に通常Importへ直列化する。作品ホームから棚へ戻ってもactive packageを閉じたりidentityを変えたりしない。
- **置き換える範囲**:
  - D-016のmacOS Releaseで利用者可視な既定保存先とrecent path起点をapp-private WorkID rootへ置き換える。2秒debounce、即時保存契機、終了前保存は維持する。
  - D-023 item 2の可視既定保存先への新規作成とitem 3のactive URLを切り替える別名保存を、private installとidentity不変のpackage exportへ置き換える。候補先読み、失敗時の現在作品維持、付随data複製をStorageへ委譲する原則は維持する。
  - D-025の`Cmd+Shift+S = 別名で保存`を`Cmd+Shift+S = 書き出す…`へ置き換える。`Cmd+Option+S = スナップショットを保存`は維持する。
  - D-038 item 3の`~/Documents/FUMINIWA`を通常作業場所とする部分を、macOS app-private `SyncWorkingCopies-v2`へ置き換える。名称、UTType、`.novelpkg`互換、旧設定／旧作品を消さない契約は維持する。
  - D-056 item 2〜4とD-057 item 2の原本を変更しないImport→app-private edit→explicit Export、open-in-place禁止をmacOSへ一般化する。iOSの段階導線と初回Darkは維持するが、D-057のpackage名identityによる「このデバイスの作品」棚は、D-063有効時にWorkID identityの単一「iCloudの作品」へ置き換える。
  - D-061 item 1／置換範囲のcloud library／new-device bootstrap除外を本Decisionのcatalog／bootstrapで置き換える。作品全体の同期対象、active editor非注入、資料／snapshot／端末設定除外は維持する。stage→package→confirm、whole revision CAS、merge、3面reviewはD-071が置き換える。
  - D-062 item 1〜3／7のlocal recent 1件、2ペイン、保存場所／Finder表示、Finder URLの直接openを、単一paneのcloud libraryとImportへ置き換える。明示選択、Safe Launch、activation直後のlocal WorkSync preflight、local recovery gate、session token、失敗時の自動fallback禁止は維持する。
- **理由**: 利用者が目指す体験は、MacのFinderやiPhone／iPadのFilesで作業packageを選び続けることではなく、Appleのメモに近く「どのApple端末でも同じ作品棚から選び、通信が不安定でも端末内copyですぐ書け、後で安全に統合できる」ことである。remote catalog、app-private durable copy、portable exportを別境界にすれば、通常UIからpathとcopy管理を隠しつつ、offline編集、exact CAS、原本保全、OS間の`.novelpkg`受け渡しを同時に維持できる。iCloudの表示をexact receiptへ限定し、同期外resourceを明記することで、library実装を完全backupと誤認させない。
- **外部Gate変更前のsource freeze証跡 (2026-08-12)**: 当時のfreshな`./Scripts/check.sh`は`All checks passed`。D-063の層別回帰はnear-cap 270,439,704 bytesを含む`NovelSync` 142 / 142件（14 suites）、`NovelSyncCloudKit` 71 / 71件（19 suites）、FUMINIWA macOS xcresult device cases 208 / 208件（top-level 203件、hosted 124件＋unhosted 79件、dynamic casesを含む）、iOS 137 / 137件（App 79件＋Device Sync 58件）、Experimental 205 / 205件であった。focused Cloud＋storeはdevice cases 15件／top-level 14件、hosted Startup Cloud UIは1 / 1件である。macOS Cloud flowはexpected attestation先行reservationとlegacy nil隔離、packageなしpending rowのaccount隔離、ack済みwork欠落時の`.cloudUnavailable`、private WorkID／path log redactionを固定した。Work domainはremote head消失時のtyped `remoteHeadMissing`、state保持、同revision再送を固定した。UI test分離後のhosted `NovelAppTests`は`NovelSyncTesting`へ依存しない。実Mac AppのComputer Useによるvisual／Accessibility tree受け入れもPASSし、当時の安全再監査はP0／P1なしだった。以上は外部Gate変更前のsource complete／local automated GOの証跡であり、現行差分の証跡ではない。
- **現行macOS外部Gate source freeze (2026-08-12・最終更新)**: Debug／Release別entitlement、再生成可能なlocal Team設定、D-063 live 4 record type＋保持中の旧Episode 3 typeのProduction schema checklist、clean zoneの`.zoneUnavailable`復旧、zone作成後かつ最初のWorkControl保存前に終了したexact pending create＋bindingだけの`.invalidArguments`復旧を追加した。root revisionの空`parentRevisionIDs`はCloudKit fieldを省略し、decode時のnilだけを空parentとして扱う。restored engine stateがない初回`CKSyncEngine`のsame-account `.signIn`はin-flight operationをcancelしてlive scopeを再検証し、一致時はreadyを維持する。別account／sign-outは引き続きfail-closedにする。root parent修正focused 28 / 28件、`NovelSync` 142 / 142件（14 suites）、`NovelSyncCloudKit` 84 / 84件が通過した。署名済み実Mac Appは同一accountのDevelopment環境へ既存1作品を初回publishし、registry `synced`、journal outbox 0／`synchronized`、catalog cache 1件までread-backした。`Invalid Arguments`／rate mitigationの再発はない。以上をmacOSのsource complete／local automated GOと初回remote createの証跡とするが、remote update／delete、同一実accountのpaired native、Production deploy、実account変更／offline、実OS process-kill、手動VoiceOver、Package Validator、External Change / Conflict、production migration／minimum-version fenceはRelease NO-GOのままである。
- **iOS / iPadOS拡張の現行source freeze (2026-08-12)**: Macと同じcatalog／WorkID identity、iOS専用private registry／working-copy root、remote-only exact download、local-first new／Import、same-scope resume／account quarantine、portable identity不変Export、旧iOS private packageの明示recovery、cold Open With待機、棚への戻りをsource実装した。現行Simulator上の`IOSCloudLibraryIntegrationTests` 28 / 28件（1 suite、2.636秒、`xcodebuild` exit 0）、先行xcresultの`FUMINIWADeviceSyncIOSTests` device cases 89 / 89件、fresh check runの同target 86 top-level / 86件（4 suites）、hosted `FUMINIWAIOSTests` 79 / 79件が通過し、`FUMINIWAIOS` generic build／build-for-testingもPASSした。fresh `./Scripts/check.sh`は`All checks passed`で、`NovelSync` 142 / 142件（14 suites）、`NovelSyncCloudKit` 84 / 84件、macOS Device Sync 88 / 88 top-level（5 suites）も含む。最終署名済みiOS generic Debug buildはstrict codesign validで、application identifier `Z699T95YH7.dev.serikayuzuki.fuminiwa.ios`、Development container `iCloud.dev.serikayuzuki.fuminiwa.sync`、CloudKit service、APNs `development`をentitlement read-backした。focused suiteはbootstrap／cold Open With、local-only new／Import、reservationとstaging／finalの終了窓復旧・mismatch保全、remote download／account復帰、stale open、needs review、legacy recovery／collision／single-flight、wrong-write、portable Export、signal coalescingを固定する。以上をiOS / iPadOSのsource complete／local automated GOとするが、先行xcresultのdynamic device casesとfresh check runのtop-level件数は集計単位が異なる。既存D-063 Mac freezeやD-061 iOS件数は流用しない。この署名成果物確認も署名済みiPhone実機の実CloudKit、Production entitlement／profile／schema deployを証明しない。
- **詳細**: library／bootstrap／account fence／cutoverは[DEVICE_SYNC.md](DEVICE_SYNC.md) 0章、AppState／保存・Export責務は[DESIGN.md](DESIGN.md)、画面・文言・アクセシビリティは[STYLE.md](STYLE.md)、portable packageと将来platformの境界は[CROSS_PLATFORM.md](CROSS_PLATFORM.md)を正とする。

## D-064: Apple版の前景UI・local durability・remote sync・materializationを分離する

- **日付**: 2026-08-12 / **状態**: 一部置換（→ D-071。前景UI／local durability／remote／materializationの分離とactive editor非注入は維持し、item 4の「統合案」とwhole-work journal入力だけを置き換える）。source実装とlocal focused testを追加（Release NO-GOは継続）
- **内容**:
  1. macOS／iOSの前景UI層は、Editor／IME／selection／Undo・Redo／sessionと画面遷移を所有する。通常の編集、復帰、作品選択、作品切替はCloudKitの応答を待たずにlocalの確定境界だけで進める。同期処理が停止・失敗・offlineでも、local packageが検証済みならEditorをread-onlyにしない。
  2. local durability層は、確定した入力をmodelへ反映し、app-private `.novelpkg`をatomicに保存し、read-back／attestationとlocal registry、package外のjournal／outboxを確定する。短時間のdocument operation gateはこのlocal境界、IME確定、破壊的な切替の安全にだけ使い、remote I/Oをgate内へ入れない。
  3. remote sync層は、immutableなpackage／journal snapshotを入力として、single-flight、coalescing、account／session／generation fence、retry／backoffを適用する。remote refresh／publish／retryはUIのdocument gateを保持せず、失敗や永久停止はstatus／pendingとして残すだけで、foreground編集を止めない。
  4. remote materialization層は、remoteから得たsnapshotやconflictをpendingとして保持し、activeな`NSTextView`／`UITextView`へ注入しない。作品を開く／切り替える、明示的な再読込、またはsafe no-editor boundaryで利用者の選択とexact identityを再検査した場合だけlocal packageへ反映する。conflictはこの端末／remote／統合案の明示選択を必要とし、暗黙のwinnerを選ばない。
  5. iOSは`inactive`で同期処理を開始せず、`background`ではlocal checkpointだけを実行し、`active`で画面を先に利用可能にしてからremote refresh／retryをscheduleする。macOSはresign／sleepでlocal checkpointだけを行い、activate／wake後にremote処理をscheduleする。どちらもscene／application lifecycle callbackからremote awaitを前景復帰の必須条件にしない。
- **置き換える範囲**: D-061〜D-063のlocal-first、active editor非注入、whole-work journal、account／generation fence、external Gateを維持したまま、startup／foreground復帰／document transitionがremote refreshを暗黙に待つ実装上の結合だけを置き換える。D-041のdocument operation gateとD-063の作品棚・private working copyのauthorityは維持する。
- **理由**: 利用者が必要としているのは、通信状態に関係なく今の原稿を安全に書けることと、後で作品全体を明示的に統合できることの両立である。前景UI、local durability、remote sync、materializationの権限を分けることで、IMEやUndoをremote callbackにさらさず、停止したremote処理が通常の執筆を巻き込まない。
- **検証**: remote catalogを永久にpauseしたmacOS local-first bootstrap、document activationとremote retryの非ブロッキング、iOS lifecycleのinactive／background／active境界をlocal／pauseable fakeで固定する。これはlocal／Simulator／署名なしbuildの証跡であり、実OS process-kill、paired native、署名済み実CloudKit、Production schema、Package Validator、External Change / Conflict Gateを完了したことを意味しない。

## D-065: whole-work CloudKit read round-tripを既知IDのbatch取得へ集約する

- **日付**: 2026-08-13 / **状態**: 履歴（→ D-071。D-061 whole-work `CKAsset`経路のread集約として保持し、Notes型entity recordの通常経路には使わない）
- **内容**: whole-workのCloudKit transportでは、publish前のWork／WorkControl／mutation receipt、snapshot取得時のWork／WorkControl、revision取得時のWork／revisionを、既知のrecord IDに対する`CKDatabase.records(for:)`の1回のbatch readへ集約する。保存後のhead／asset read-back、atomic CAS、receipt／generation／account fence、missing itemとmaterial errorの区別は維持する。
- **理由**: D-061〜D-064の安全なwhole-work protocolを変えずに、同じpublish／open／refreshで直列に発生していた不要なCloudKit往復を減らすためである。batch readはreadの同時性だけを改善し、remoteのwinner選択、active editorへの注入、local durabilityの順序は変更しない。
- **置き換える範囲**: `NovelSyncCloudKit`内部のwhole-work read pathだけを対象とし、作品棚のcatalog契約、episode legacy transport、CloudKit schema、record identity、remote materialization境界は変更しない。CloudKitのサーバー処理時間、iOS background scheduling、作品全体assetの転送時間は別の残課題として扱う。
- **検証**: `NovelSyncCloudKit` 84 / 84件を通過し、既存の`./Scripts/check.sh`でmacOS／iOSの全テストとbuildを再検証する。これはlocal／Simulator／署名なしbuildの証跡であり、実CloudKitの実測短縮やpaired native端末の同期完了時間を証明するものではない。

## D-066: 執筆画面へ章別プロットカードのスライド式参照ペインを追加する

- **日付**: 2026-08-13 / **状態**: 承認・実装
- **内容**:
  1. macOSの執筆画面では、ツールバーの「プロットカード」から右側の参照ペインを開閉できる。ペインは選択中の章に属する既存の`PlotCard`だけを表示し、カードの追加・編集・削除は既存のプロット画面と保存経路を正とする。
  2. 参照ペインは本文を押しのける一時的なスライド式UIとし、本文EditorのIME、selection、Undo／Redo、session境界を変更しない。章を切り替える、執筆画面を離れる、作品を切り替える場合はペインを閉じる。
  3. 上部toolbarはSidebar／Outlineの表示状態によらず同じsemanticなwindow toolbar背景を使い、ペインの開閉によって本文とtoolbarの背景を混在させない。CoreUIのWindowControlsログはアプリ固有APIへ依存しないOS／Xcode描画警告として扱う。
- **置き換える範囲**: D-024 / TOOLBAR.mdの一段native toolbar方針を維持したまま、執筆時の参照操作を追加する。プロットカードのpackage schema、配列順、編集・保存・同期契約は変更しない。
- **理由**: 執筆中に本文とプロットの往復を行うため、画面遷移で文脈を失わず章のカードを確認できる必要がある。一方、常設の列を増やすと本文面積を奪うため、必要時だけ右側から開く参照ペインとする。
- **検証**: macOS／iOSを含む既存のローカルチェックを通過させ、実機でIME、ペイン開閉、本文幅、toolbar背景、VoiceOverを確認する。CoreUIログの再発有無はOS／Xcode betaの実行環境依存として別途観測する。

## D-067: プロットカード参照の開閉入口を右上のprimary actionへ置く

- **日付**: 2026-08-13 / **状態**: 承認・実装
- **内容**:
  1. 執筆画面のプロットカード参照ペインは、中央の編集操作列ではなく、検索欄の左側にある右上の`primaryAction`へ`sidebar.trailing`アイコンの独立ボタンとして表示する。本文の利用可能幅と他の編集操作を圧迫しないことを優先する。
  2. ツールバーの背景は`windowBackgroundColor`ではなく、macOS標準の`underPageBackgroundColor`を使う。スクリーンショットで確認した左上の明るめの茶色のchromeに寄せつつ、Light／Dark外観とアクセシビリティ設定への追従を維持する。
- **置き換える範囲**: D-066の参照ペイン本体、章別カード表示、session境界、toolbarの一段構成は変更しない。変更対象は開閉入口の配置、アイコン、ボタン階層、semantic toolbar背景だけとする。
- **理由**: 引き出しの存在と開閉状態を画面右上で見つけやすくし、本文と関係する補助操作のまとまりを崩さないためである。`underPageBackgroundColor`は固定hexを増やさず、従来の暗すぎるwindow背景よりchromeの視認性を上げる。
- **検証**: SwiftFormat、SwiftLint、macOS／iOSの既存テストとbuildを通し、実機で右上ボタンの配置、ペイン開閉、toolbar色、VoiceOverラベルを確認する。

## D-068: クラウド同期状態を話メモの左へ移し、執筆本文上の重複表示をなくす

- **日付**: 2026-08-13 / **状態**: 承認・実装
- **内容**:
  1. `DeviceSyncStatusControl`は執筆本文の上端に置かず、native toolbar内で話メモの左に固定する。状態に応じて`checkmark.icloud`、`icloud.slash`、`exclamationmark.icloud`などを使い、保存済み・同期中・オフライン・確認必要を表現する。
  2. 統合確認が必要な状態では、toolbarの状態ボタンから既存のconflict reviewを開く。同期状態の表示移動で保存、IME、本文Editor、競合解決の契約は変更しない。
- **理由**: 同期は本文編集の補助状態であり、本文面積を削る独立行ではなく、話メモと並ぶ執筆補助操作として常に見つけられる場所へ置くためである。
- **検証**: macOS／iOSの既存ローカルチェックを通過させ、実機で同期状態の各アイコン、メモとの順序、確認画面への到達、VoiceOverラベルを確認する。

## D-069: macOSのプロットカード入口はsecondaryActionへ固定する（破棄）

- **日付**: 2026-08-13 / **状態**: 破棄（D-070で置換）
- **内容**: プロットカード参照ボタンは`primaryAction`ではなく、macOSで利用できる`secondaryAction`へ置く。ボタンはtoolbarのカスタマイズ対象から外し、同期・メモ・スナップショット・書き出しの後、検索欄の直前に宣言して右上の独立した入口として維持する。toolbar IDは`novelwriter.workbench.v6`へ版上げし、既存のv5配置状態を引き継がない。
- **理由**: macOSの`primaryAction`は右上ではなくleading edgeへ解決されるため、右上という製品要件を満たさない。macOS非対応の`topBarTrailing`は使わず、右側のsecondary領域へ解決されるsemantic placementを採用する。さらにtoolbar内の宣言順を最後にすることで、プロットボタンを同期状態やメモより右側へ分離する。
- **検証**: macOSのtoolbarコンパイルと既存チェックを通し、実機で検索欄との独立性、右上配置、開閉、VoiceOverラベルを確認する。

## D-070: プロットカード入口はツールバーのカスタマイズ対象に戻す

- **日付**: 2026-08-13 / **状態**: 承認・実装
- **内容**: プロットカード参照は特定のtoolbar領域へ固定せず、通常の`ToolbarItem`として`.reorderable`にする。初期表示は編集操作列の末尾とし、macOS標準の「ツールバーをカスタマイズ…」でユーザーが同期・メモ・スナップショット・書き出しとの順序を変更できる。検索欄とSidebar切替の構造上のアンカーは引き続き固定する。
- **理由**: macOSのsemantic placementだけでは、プロットカードをユーザーが望む「検索欄の直前」へ確実に移動できない。プロットカードをカスタマイズ可能な編集操作として扱えば、macOS標準の導線で各ユーザーが使いやすい位置を選べる。
- **検証**: macOSのtoolbarコンパイルと既存チェックを通し、実機でプロットカードの表示・非表示・開閉と、ツールバーカスタマイズ画面での並べ替え・再追加を確認する。

## D-071: Device Syncをメモ型のlocal-first／entity record同期へ切り替える

- **日付**: 2026-08-13 / **状態**: 現行実装・次世代では一部破棄（→ D-073、最終置換はD-077）。N1〜N3 source＋unit／layout。N4はin-memory simulationのみ。署名済みpaired／実CloudKitは未実施。client cutoverまで通常Appのlive経路は`NoteSyncCoordinator`。item 2の裏送信とitem 5のpackage保存直後pending登録はD-073が破棄し、D-077はNote record／CloudKit／package正本をSQLite＋Snapshot HTTPへ置き換える。作品全体という利用者単位、3択、時計LWW禁止は維持する
- **内容**:
  1. 使う側の同期対象は引き続き **1つの作品** である。作品タイトル／あらすじ、章・話の構成と順序、本文、メモ、人物、プロット、伏線、世界観を同期する。資料binary／attachment、`.novelpkg` の手動スナップショット履歴、端末設定、選択状態、path、CloudKit metadataは同期しない。`.novelpkg` v3は各端末の正本（画面が読むlocal store）のまま変更しない。SwiftData／Core Dataをcanonical storeにせず、独自同期サーバーも置かない。
  2. 画面は **この端末の `.novelpkg` だけ** を開く。起動、アプリ切替で戻る、執筆画面に入る、は通信完了を待たない。検証済みlocal packageがあればofflineでも編集・保存できる。`CKSyncEngine` の送信／取得は裏で行い、失敗や遅延は状態表示だけに残す。編集中の `NSTextView`／`UITextView` へremoteを流し込まない（D-005／D-064）。
  3. 送る単位は作品全体の1資産ではない。Appleメモの1枚に相当する **entity record** にする。portable種類は次に固定する。`work`（タイトル／あらすじ／章ID順）、`chapter`（タイトル／話ID順）、`episode`（所属章／タイトル／本文／メモ）、`character`、`plotCard`、`flag`、`worldNote`。変わったrecordだけを送り、他端末は欠けているrecordだけを取る。組み立てた結果が1つの作品である。話単位の同期管理画面、lease／holder、排他ロックは出さない。
  4. Apple adapterは `CKSyncEngine` に **pending recordのsave／deleteを登録し、batch providerから実際に送る**。現行 `CloudKitChangeTrackingDriver` の「fetchとstateだけ担当し、writeは自前CAS」は通常経路から外す。private database／固定custom zone／account fence／engine state serializationは維持する。D-059のEpisode control／revision／lease recordと、D-061の `FUMINIWAWorkControlV1`／`FUMINIWAWorkRevisionV1`／`FUMINIWAWorkMutationReceiptV1` をlive encode／decodeしない。新しいrecord type namespace（`FUMINIWANote*V1`）を使う。本文がCloudKit record payload上限を超える話だけ、その話の `CKAsset` を使う。作品全体を1つの `CKAsset` にしない。
  5. local保存の順は **native editor／form → model → app-private `.novelpkg` 保存 → 変更したentity IDのdurable dirty set → CKSyncEngineへpending登録** とする。dirty setはpackage外の小さなmetadataであり、作品全体snapshotの複製journalではない。package保存が終わるまでremoteへ送らない。通信失敗・終了・再起動後は同じdirty setから再送する。未送信原稿の正はpackageであり、dirty setは「どれをまだ送っていないか」だけを持つ。
  6. 衝突の検出は編集時刻でも、作品全体の3-way mergeでもない。同じentityをこの端末がdirtyにしている間に、server change tagが変わって `serverRecordChanged` になった場合だけ衝突とする。片側だけ進んだrecordは確認せず適用／送信する。時計、更新日時、push順によるwinner選択は禁止する。`WorkSnapshotMerger` と3面「統合案」は通常Appから外す。
  7. 同じ作品で1件以上のentityが衝突したら、内部語（revision／branch／merge／journal／lease）を出さず、作品に対して次の3つだけを選ばせる。「この端末の内容を使う」「iCloudの内容を使う」「両方を別作品として残す」。cloud衝突中もEditorとlocal保存は止めない。選択するまで衝突したremoteはpendingに保ち、入力中本文を巻き戻さない。
     - この端末: 衝突したlocal entityをserver版の上へ送る（change tagを取り直したあとlocalをsave）。他の非衝突remoteは通常どおり取り込む。
     - iCloud: 衝突したremote entityを、編集中surfaceでない安全な境界でpackageへ入れる。
     - 両方残す: 今開いている内容（この端末）を **新しい `SyncWorkID`** の作品として棚に残し、元のWorkIDはiCloud側を正として取り込む。どちらも消さない。話の中に「（衝突コピー）」を増やす方式はv1では採用しない。
  8. D-063の「iCloudの作品」棚、WorkID identity、app-private working copy、account mismatch quarantine、原本を変えないImport、identity不変のExportは維持する。catalogの正は「そのWorkIDのwork recordが存在すること」であり、whole revision ID／snapshot digest／byte countをdownloadの唯一条件にしない。remote-only openはwork recordと、そのWorkIDに属するentity record一式を取得してpackageへ組み立てる。表示用タイトルと更新日時はhintであり、winner決定に使わない。
  9. 別Apple Accountへ切り替わっても作品を混ぜない、旧accountへ送らない、未確認accountへautomatic adoptしない契約（D-063）は維持する。手動スナップショット機能は端末内バックアップのままクラウドへ載せない。リアルタイム共同編集、Git履歴画面、独自アカウント、利用者が同期処理を管理する画面は追加しない。
  10. D-071は公開前の **development cutover** とする。D-061 whole-work経路もD-059 Episode経路も一般出荷していない前提で、開発CloudKit zoneと旧sync metadataをresetし、全test端末を同じD-071 buildへ揃える。Work revision asset／Episode lease recordをentity recordへ自動migrationしない。mixed old／new clientの相互運用を主張しない。production migration／minimum-version fenceは別Decisionとする。それまで出荷不可。
  11. 実装順は混ぜない。
     - **N0（本Decision）**: DESIGN／DEVICE_SYNC／CROSS_PLATFORM／IOS／STYLEの契約を切り替える。
     - **N1**: `NovelSync` にentity record、dirty set、衝突3択、作品組み立てのdomainとtestを追加する。mergerを通常経路から外す。**完了（domain／unit test。App live経路は未切替）**
     - **N2**: `NovelSyncCloudKit` で新record typeと、`CKSyncEngine` のsend／fetchを接続する。catalog／bootstrapをentity取得へ切り替える。**完了（source／unit。実CloudKit send／fetchは未実施）**
     - **N3**: Mac／iOS Appでpackage先行、dirty enqueue、短い3択UI、内部語の非表示、active editor非注入を接続する。**完了（source／layout test。Simulator上の実CloudKitは未実施）**
     - **N4**: 署名済みMac＋iPhoneのpaired往復、offline／復帰、account switch、process-killを検証する。N1〜N3のlocal test成功をN4完了へ読み替えない。**in-memory simulationのみ完了。署名済みpairedは未実施**
  12. 完了報告は (a) sourceとunit／integration、(b) Simulator／local fake、(c) 署名済み実CloudKit を分離する。N0の文書更新を同期実装済みとしない。
- **置き換える範囲**: D-061 item 2〜7／9のWork wire v1、whole revision `CKAsset`、mutation receipt CAS、作品全体3-way merge、3面reviewを、通常Appのlive経路として置き換える。D-061 item 1の同期対象（作品全体に含めるもの／含めないもの）、item 8のactive editor非注入、D-063の作品棚／private copy／account fence／Import／Export、D-064の層分離とlifecycleでremoteを待たない契約、D-005の本文所有権は維持する。D-059／D-060／D-061のsourceとtestは削除せず履歴とする。D-065のwhole-work batch readは旧経路の最適化として履歴にする。Files / File Provider原本のopen-in-place除外、Package Validator、External Change / Conflict Gate、AI安全境界は変更しない。
- **理由**: Appleメモが速く、offlineでも復帰しても普通に書ける理由は、画面がlocalを正にし、変更した1枚だけを `CKSyncEngine` が裏で送ることである。ふみにわの作品は棚の上では1つだが、中身を1個の巨大資産として自前の版グラフで上げ下げしていたため、ロードと確認が重くなった。同期するものは作品全体、送るものはentity、衝突したら合成せず3択、がメモに寄せつつ小説の「1作品」を壊さない境界である。
- **詳細**: 現行契約は[DEVICE_SYNC.md](DEVICE_SYNC.md) 0章を正とする。portable境界は[CROSS_PLATFORM.md](CROSS_PLATFORM.md)、iOSは[IOS.md](IOS.md)、画面文言は[STYLE.md](STYLE.md)、全体は[DESIGN.md](DESIGN.md)を参照する。

## D-072: 作品棚に明示的なiCloud保存・複製・この端末からの削除を置く

- **日付**: 2026-08-14 / **状態**: 現行実装・次世代では一部置換（→ D-077。WorkID、明示account scope、automatic adopt禁止は維持し、iCloud固有保存／hidden package複製／package削除をSQLite＋online bindingへ置き換える）
- **内容**:
  1. `accountRequired`／unscoped／different account中に作ったunbound workは、これまでどおり後から現れたaccountへautomatic adopt／rebind／uploadしない。iCloud accountが確認できているとき（catalogが空、またはNote type未作成などでcatalog読込に失敗した`.unavailable`を含む）だけ、作品棚の「iCloudに保存」、Workbench／Fileメニューの同じ項目が、検証済みlocal packageをそのaccountへ明示的に結び付ける。`.accountRequired`／`.differentAccount`／offlineでは出さない。失敗は`try?`で握りつぶさず、path／WorkIDを出さないcategory logと「iCloudへ保存できませんでした。このMac／この端末の作品はそのまま残っています。」を出す。backgroundの初回publishは従来どおりbest-effortでよい。
  2. 作品棚から複製すると、新しい`SyncWorkID`のapp-private copyをportable検証付きでinstallする。同じ`NovelDocument.id`でもdeduplicate／rebindしない。chooser／作品棚に留まり、複製先へ自動で切り替えない。資料は`saveValidatedCopy`で複製する。
  3. 作品棚の削除は、この端末のregistry recordとhidden packageだけを外す。確認ダイアログと`role: .destructive`を必須とする。local-onlyは「この端末の作品を削除します。元に戻せません。」、cached remote等は「この端末の作業コピーを削除します。iCloud上の作品は消えません。」とする。CloudKit tombstone、他端末のretention、remote-only行の削除は出さない。以前同期した作品は、catalogに残っていればremote-onlyとして再表示され得る。
  4. 操作はD-041のdocument operation gateと表示時session tokenで直列化する。macOS chooserはList focus中のDeleteキー、context menu、行の「iCloudに保存」ボタンを使う。新規後のWorkbenchではtoolbarとFileメニューにも同じ項目を出す。iOSはswipe／context menu／行の保存ボタンに加え、作品ホームからも明示保存できる。1 paneの「iCloudの作品」は維持する。
- **置き換える範囲**: D-063 item 5の「明示的account association UIとauthorityは後続Decisionまで提供しない」を、signed-in（catalog availableまたはtype未作成によるcatalog失敗）かつlocal-only／localPendingに限る明示保存へ置き換える。automatic adopt禁止は維持する。D-063 item 9の「MVPではwork削除UI／APIを出さない」を、この端末のlocal removeだけへ置き換える。CloudKit tombstone／複数端末retentionは引き続き禁止し、別Decisionとする。
- **理由**: 新しい作品がCloudKit type未作成などでlocal-onlyに留まったとき、失敗が見えず再送も試せない。明示保存は検証しやすい。既存作品の複製と、この端末の作業コピーを棚から外す操作は、Finder／Filesを見せずに日常の棚操作として必要である。
- **詳細**: 画面・文言は[STYLE.md](STYLE.md)、棚の状態は[DEVICE_SYNC.md](DEVICE_SYNC.md) 0.10〜0.11、全体は[DESIGN.md](DESIGN.md)を参照する。

## D-073: 自動保存は端末内だけ行い、iCloud送信は明示同期にする

- **日付**: 2026-08-14 / **状態**: 現行実装・次世代では破棄（→ D-077。local commitがremoteを待たない原則は維持し、明示同期限定を自動再開workerへ置き換える）
- **内容**:
  1. 自動保存、話切替、画面遷移、終了前保存、資料操作の`saveNow()`はapp-private `.novelpkg`とdirty setまでとする。package保存の成功や失敗を、iCloudのオンライン／オフラインと混ぜない。CKQueryの12／2015（`recordName`未QUERYABLE）をオフライン表示の根拠にしない。
  2. iCloudへ結んだ作品のFileメニュー`Cmd+S`と、Workbench／iOSの「iCloudと同期」だけが、同じlocal flushのあとNote `publishLocal`／`pullRemote`を始める。未結線の作品の`Cmd+S`は従来どおりlocal保存だけ。初回の「iCloudに保存」はD-072のまま別操作とする。
  3. 起動、アプリ切替で戻る、執筆画面に入る、remote change signalはNote send／pullのきっかけにしない。他端末の変更は次の明示同期まで待って取り込む。衝突3択の直後だけは、選んだ結果を送るために同じ明示経路を使う。
  4. 編集中の状態表示は、local保存済みなら「この端末に保存済み」とする。未送信のdirtyを「iCloudへ同期中」や「オフライン」としない。`checkmark.icloud`は明示同期が成功し、その後のlocal変更がないときにだけ使う。本当のaccount／network不能だけをオフラインとし、「接続が戻ると自動で同期します」とは書かない。
  5. Development schemaで`CKQuery`が使えないときは、work recordと順序付き子entityをrecord IDで取る。作品棚は同じ窓で`workID` field query、`modificationDate` query、`CKSyncEngine`が観測したNote WorkIDのrecord ID取得を試す。queryで取れた他端末のWorkIDは、この端末既知IDのfetch-by-id補完と件数が違ってもremote-onlyとして出す。query失敗を同期失敗やオフラインへ畳み込まない。内容digestが同じchange tag衝突はackし、3択にしない。衝突3択で選んだ内容のsaveがengineにackされない場合は失敗とし、黙って3択を残さない。keepLocalは画面が出したkeysをpendingが空でも使う。
  6. Editor openのlocal preflightが`.temporarilyOffline`でも、Note coordinatorが作れた結線済み作品の明示同期はsendを拒否しない。本当のaccount／network失敗は`publishLocal`／`pullRemote`のerror tokenで分類する。未作成のNote typeへのqueryは空として扱い、既にmap済みのadapter errorを`.operationFailed`へ潰さない。Debugでは失敗ダイアログに同じtokenを付ける（環境変数`FUMINIWA_NOTE_SYNC_DEBUG=0/1`で上書き）。path／WorkID／title／`localizedDescription`は出さない。
- **置き換える範囲**: D-071 item 2の「`CKSyncEngine`の送信／取得は裏で行い」と、item 5のpackage保存直後のpending登録／自動再送を破棄する。dirty setをpackage保存後に残す契約と、D-005のactive editor非注入、D-040／D-041のlocal `saveNow()`直列化、D-072の初回明示保存は維持する。D-040 item 5の「`Cmd+S`は`saveNow()`と同じ」は、結線済み作品に限ってlocal flush＋明示同期へ改訂する。
- **理由**: 話切替などのlocal保存のたびにcatalog queryが走り、Development schemaでは失敗して常時オフラインに見えた。端末保存とiCloud送信を分ければ、編集中はlocalが正で、送りたいときだけ同期できる。
- **詳細**: 現行契約は[DEVICE_SYNC.md](DEVICE_SYNC.md) 0.2、画面は[STYLE.md](STYLE.md)／[TOOLBAR.md](TOOLBAR.md)、全体は[DESIGN.md](DESIGN.md)を参照する。

## D-074: 編集後の作品全体スナップショットを Time Machine 型で間引く

- **日付**: 2026-08-14 / **状態**: 現行実装・次世代では一部置換（→ D-077。Time Machine型retention、lifecycle checkpoint、復元前退避は維持し、package copyとonline除外をSQLite／CAS＋online checkpointへ置き換える）
- **内容**:
  1. 自動スナップショットは一定間隔の定期実行ではない。本文、話メモ、作品情報、人物、プロット、伏線、世界観など、`NovelDocument`に属する編集があったあと約5分で、その時点の作品全体を1件残す。追加の編集では待ち時間を延長せず、1件残したあとにまた編集があれば次の5分を数える。編集が無ければ作らない。最小単位は5分とする。
  2. 対象は話本文だけではない。章・話構造、タイトル、あらすじ、メモ、人物、プロット、伏線、世界観、その時点の資料を含む app-private `.novelpkg` 全体とする。入れ子の `snapshots/` は持たせない。iCloudへは送らない。
  3. アプリをバックグラウンドへ移す、Macが非アクティブまたはスリープになる、ときは待ち時間を待たず、未退避の編集があれば同じ作品全体を残す。IME変換中は確定を待ってから残す。失敗をダイアログにしない。
  4. 手動保存（ツールバー／`Cmd+Option+S`）と復元前退避は従来どおり手動扱いとし、間引きしない。
  5. 自動分の保持は Time Machine にならい、新しいほど密、古いほど疎にする。直近1時間はすべて残し、24時間以内は同じ時間の最新1件、30日以内は同じ日の最新1件、1年以内は同じ週の最新1件、それより前は同じ月の最新1件だけ残す。
- **置き換える範囲**: D-026の手動保存・復元前退避・一覧／復元手順は維持する。自動作成と自動分の間引きだけを追加する。
- **理由**: 定期実行だと無編集でも増え、直近だけ固定件数だと数日前の状態へ戻れない。編集があった作品全体を、新しいほど細かく古いほど粗く残す。
- **詳細**: 画面は[STYLE.md](STYLE.md)、iOS導線は[IOS.md](IOS.md) 4.5a、全体は[DESIGN.md](DESIGN.md) 6.4を参照する。

## D-075: 停止中のExperimental AI実装を削除し、確定した編集安全境界だけを残す

- **日付**: 2026-08-15 / **状態**: 承認・実装
- **内容**:
  1. `FUMINIWAExperimental` app／scheme、`NovelAppExperimental`、そのtest target、fake provider、AI校正UI、Codex sidecarのSwift実装・Node実装・fixturesを削除する。これらは現行製品でも将来の採用が確定したAPIでもなく、AI層を大きく再設計する際の負債になるためである。
  2. `NovelAI` package targetとprovider protocol／request／streamの実装・testも削除する。provider-neutralという名前だけの現在APIを将来のAI層へ自動継承しない。`AI_INTEGRATION.md`、D-043、D-046〜D-054、Codex feasibility reportは、当時の検討履歴として残すが、現行実装・出荷可能性・再利用契約とは扱わない。
  3. `EditorKit`の選択transaction／stale検査／IME境界／one-shot置換と、通常版の`AIClipboardPrompt`（system clipboardへ明示コピーするだけ）は残す。前者は将来のAIに限らず外部提案の安全な編集適用境界であり、後者は現在提供している実機能だからである。
  4. providerを再開するときは、最新の公式API／SDK、payload、credential、transport、保持期間、cancel、配布境界を新しいDecisionで再評価し、削除したExperimentalコードを復活させる前提にしない。通常版のbuild graphにはprovider／network／sidecar／keyを追加しない。
- **置き換える範囲**: D-054の「`NovelAI`、fake UI、sidecar protocol、manifest、supervisor、B3、B4-A〜Dを削除せず保持する」という保持方針を、本Decisionで置き換える。D-043 / D-046〜D-053に記録された安全上の要求（local identityを送らない、明示確認、stale拒否、one-shot apply、fail-closed）は設計上の検討記録として維持する。EditorKitのselection transactionとclipboard promptの契約は変更しない。
- **理由**: 実providerを接続しないまま、別app target・provider domain・fake UI・sidecar・検証fixtureを持ち続けると、現在使える機能と将来再設計する実験を混同し、依存・テスト・公開判断の誤解を生む。確定度の高い編集安全境界と現行clipboard機能だけを残す方が、再開時の設計自由度と保守性を保てる。
- **検証**: 生成projectにExperimental target／schemeがなく、macOS／iOS通常targetがprovider productをlinkしないこと、`swift test --package-path NovelKit`、通常macOS／iOS build・test、AI boundary auditが通ることを確認する。

## D-076: Feature単位の構造とSwift 6の境界で大規模ファイルを段階的に分割する

- **日付**: 2026-08-15 / **状態**: 承認・R1/R2/R3/R4/R5a/R5b/R5c/R5d/R5e/R6a/R6b/R6c/R6d/R6e/R7実装済み（R5 target分離・R6継続。live Note／CloudKit target前提と同期契機不変の制約だけはD-077が置換。D-076全体の完了とは扱わない）
- **内容**:
  1. **目的と判断基準**: `NovelApp`／`NovelAppIOS`直下の平坦な配置、1,000行級のApp／同期ファイル、Mac／iOSの重複、Episode／Work／Noteの3世代同期が同時に見える状態を段階的に解消する。行数は分割の警告であって品質の代理値ではない。分割単位は「変更理由が一つ」「依存方向が一方向」「独立してtestできる」を優先し、短いだけのファイル、同じ共有可変状態を触る`extension`の乱造、画面ごとのPackage化は行わない。利用箇所での明瞭さを短さより優先するSwift API Design Guidelinesを命名と公開境界の基準にする。
  2. **Feature-based App構造**: macOS／iOSのApp targetは、同じ製品概念を同じFeature名で探せるよう、次を基準に再配置する。ディレクトリは探索・所有権の単位であり、直ちにSwift moduleを増やす意味ではない。Assets、localized resources、entitlement、Info.plistは既存のtarget資源境界を維持する。

     ```text
     NovelApp/                       NovelAppIOS/
     ├── Application/                ├── Application/
     ├── DocumentLifecycle/          ├── DocumentLifecycle/
     ├── Library/                    ├── Library/
     ├── Features/                   ├── Features/
     │   ├── Writing/                │   ├── Writing/
     │   ├── Characters/             │   ├── Characters/
     │   ├── Plot/                   │   ├── Plot/
     │   ├── Worldbuilding/          │   ├── Worldbuilding/
     │   ├── Attachments/            │   ├── Attachments/
     │   ├── ProjectInfo/            │   ├── ProjectInfo/
     │   └── Settings/               │   └── Settings/
     ├── DeviceSync/                 ├── DeviceSync/
     │   ├── Note/                   │   ├── Note/
     │   ├── Runtime/                │   ├── Runtime/
     │   ├── Conflict/               │   └── Conflict/
     │   └── Legacy/                 └── Platform/iOS/
     └── Platform/macOS/
     ```

  3. **AppState／IOSDocumentStore**: `AppState.swift`はstored stateと`init`を保つ。既存の`AppState+…`分割は第一段階として維持するが、`AppState+StartupLibrary.swift`や`AppState+Lifecycle.swift`をさらにextensionだけで細切れにしない。pureな棚projection、I/Oを行うloader、open/install transaction、document transitionを、それぞれ名前を持つ値型／coordinatorへ抽出し、AppStateは呼出し時のsession tokenを渡して結果をcommitするcomposition rootに寄せる。ファイルを跨ぐためだけに`private` setterや内部stateを`internal`へ広げない。document operation gate → `DocumentSaveCoordinator`のlock順、IME確定、遷移中のWorkbench停止はD-041のまま変更しない。
  4. **共有作品棚境界**: Mac／iOSで重複するlocal library record、registry、package attestation、pending open、棚projectionは、実装段階でローカルSwift Package target `NovelLibrary`へ統合する。`NovelLibrary`は`NovelCore`／`NovelStorage`／`NovelSync`だけに依存し、SwiftUI、AppKit、UIKit、CloudKitへ依存しない。OS固有のprivate root決定、画面、File／Finder／Files操作、CloudKit compositionは各Appまたは`NovelSyncCloudKit`へ残す。`.novelpkg`内部を公開せず、保存・portable検証はNovelStorageのAPIを使う。Mac／iOSで意味が異なるlegacy migrationだけを注入policyとし、共通状態機械をcopyして分岐させない。
  5. **live同期と履歴同期**: D-071のlive Note同期と、D-059〜D-061のEpisode／Work履歴を、最終的に別targetへ隔離する。通常の`FUMINIWA`／`FUMINIWAIOS`はliveの`NovelSync`／`NovelSyncCloudKit`だけをlinkし、旧test／互換検証だけが`NovelSyncLegacy`と必要なCloudKit legacy adapterへ依存する。履歴sourceとtestは本Decisionだけを根拠に削除しない。先に`Legacy/`ディレクトリとnormal-target dependency auditを導入し、target分離はcompile／fixture／旧testを保つ独立PRで行う。CloudKit型を`NovelSync`／`NovelLibrary`へ出さない。
  6. **Swift API Design Guidelines**: 新規・変更APIは宣言だけでなく代表的なcall siteを読んで評価する。利用箇所で曖昧にならないargument labelを付け、型名を繰り返す不要語は省く。型／protocolは役割を表す名、side effectのある操作は動詞、Boolは肯定形のpredicateにする。`Manager`／`Helper`／`Utils`を新しい責務型の既定名にせず、`Loader`、`Repository`、`Coordinator`、`Projection`、`Policy`など実際の役割を使う。`ID`、`URL`、`UTF8`、`IME`等の確立した語以外の独自略語を増やさない。`public`／`package` API、protocol、非自明な並行性・計算量・失敗条件にはcall siteから理解できる要約documentationを付ける。
  7. **可視性**: `private`を既定とし、同一moduleのFeature間契約だけを`internal`、NovelKit内のtarget間共有でAppへ公開しないものは適切な場合に`package`、製品targetへ必要な最小面だけを`public`とする。testのためだけにproduction APIを`public`へ上げず、`@testable import`または`NovelSyncTesting`等のtest supportを使う。1ファイル1 primary typeを目安とするが、小さな密接値型は同居を許す。
  8. **Swift 6 Strict Concurrency**: 全targetでSwift 6 language modeとcomplete strict concurrencyを維持し、コンパイラのdata-race検査を並行性の正とする。UI状態とUI commandは型全体を`@MainActor`へ隔離し、file／registry／dirty set等の共有可変I/O stateはactorが所有し、projection／snapshot／command／resultは可能な限り値型かつ`Sendable`にする。isolation境界を越える公開値は`Sendable`を明示し、境界を越えて実行されるclosureは`@Sendable`を契約へ含める。actor内でも`await`をatomic境界とみなし、再開後はsession／generation／WorkID等の固定identityを再検査する。これはD-041の「対象を動的に読み直さない」を並行性境界にも適用するものである。
  9. **unsafe escape hatch**: `@unchecked Sendable`、`nonisolated(unsafe)`、`@preconcurrency`、`MainActor.assumeIsolated`、無所有の`Task.detached`を、警告を消すための通常手段にしない。必要な場合は、なぜstatic isolationで表せないか、誰が同期とlifecycleを所有するか、終了／cancel／再入時のtestを同じ変更へ含め、専用allowlistで可視化する。`MainActor.run`の散在で本来の型isolationを隠さず、長期的な境界は型またはprotocolへ静的に表す。
  10. **SwiftFormat／SwiftLintの役割**: SwiftFormatを機械的整形の唯一の正、SwiftLintをコードスメル・複雑度・構造上の警告にする。同じ表記を両方に競合して決めさせない。`.swiftformat`へSwift compiler versionだけでなくlanguage mode 6を明示し、minimum tool versionを固定する。tool更新と全体再整形は機能PRから分ける。SwiftLintは段階的に`NovelApp`、`NovelAppIOS`、各App testへ対象を広げ、生成物、`.build`、`.derivedData`、Xcode退避folderを除外する。opt-in ruleは一度に大量追加せず、意味、既存違反、formatterとの重複、false positiveを確認して一つずつ有効化する。`Scripts/check.sh`はSwiftFormat lint → SwiftLint → test／buildの順を維持する。
  11. **サイズと複雑度のbudget**: production Swift fileは400行で責務レビュー、600行でwarning、800行で原則分割または理由付き例外とする。これは型／functionの凝集度を読むtriggerであり、空行削除や無意味な別ファイル化で通さない。既存超過はversion管理したdebt allowlistへ固定し、新規超過を追加せず、対象ファイルを変更するPRでは増加させない。function body、type body、cyclomatic complexity、nestingもSwiftLintの現実的な段階値で監視する。algorithmically cohesiveなparser／merger、fixture、生成物は理由とownerを記録して例外にできる。
  12. **test構造**: 大規模testはproduction file名の鏡ではなく、IME／Undo／Lifecycle／Authority／Offline／Conflict／Recovery等の振る舞いscenarioで分割する。共通fixture builderはtest supportへ置き、1つの巨大test fileへ戻さない。移動・renameだけのPRでもtest discovery数を減らさず、Swift 6 isolation annotationを外して通さない。
  13. **実装順**: 一つのPRへ混ぜず、(R1) tool設定・現状budget・dependency audit、(R2) App／iOSのFeature directory移動、(R3) StartupLibrary／Lifecycleの責務型抽出、(R4) `NovelLibrary`統合、(R5) legacy同期target隔離、(R6) algorithm／test file分割、の順に進める。rename／moveだけの段階では挙動を変えず、`git diff --check`、`./Scripts/check.sh`、target dependency auditを通す。R3以降は既存の原稿保全、offline、account fence、session token、IME、Undoのfocused regressionも通す。各段階で`.novelpkg` schema、CloudKit schema、UI文言、同期契機を変更しない。
- **R3実装記録**: 棚の純粋な行変換を `StartupLibraryProjection`、端末inventory/package readbackを `StartupLibraryLoader`、document session／終了／遷移とURL重複判定を `DocumentLifecyclePermissionPolicy`／`DocumentURLPolicy` へ抽出した。`AppState+StartupLibrary` は refresh/merge、opening は open/install/recovery に分割し、`StartupLibraryProjectionTests` と `DocumentLifecyclePolicyTests` を追加した。既存のsession token、account fence、package検証、IME／Undo契約は変更していない。macOS targetのコンパイル、SwiftFormat、baseline付きSwiftLint、構造budget、AI target境界auditを確認済み。
- **R4実装記録**: Mac／iOSに重複していたlocal libraryの状態、package attestation、record、inventoryを `NovelKit/Sources/NovelLibrary/LocalLibraryModels.swift` へ移し、`NovelLibrary` product（NovelCore／NovelSync依存）として両通常Appへ接続した。OS固有のprivate root、filesystem actor、CloudKit compositionは各Appに残し、公開モデルは`.novelpkg`内部構造を参照しない。旧Mac／iOS型は同一package型へのmodule内typealiasへ置き換え、状態superset（account quarantine／legacy preservation）を共通化した。Codable／validationの `NovelLibraryTests`、NovelKit全テスト、macOS build、汎用iOS build、AI target境界auditを確認済み。
- **R5a実装記録**: Mac／iOSの通常production compositionから `WorkSyncTransport` の注入を外し、`DeviceSyncRuntime.workTransport`／`IOSDeviceSyncRuntime.workTransport` を `nil` とした。これにより通常アプリの同期入口はD-071のlive Noteに限定され、旧Workの型・transport・test factoryはtarget分離まで保持する。`Scripts/check-sync-production-boundary.sh` を `Scripts/check.sh` へ組み込み、production sourceへlegacy transportが再接続されることを機械検査する。これはR5のtarget／source分離完了ではなく、旧CloudKit adapterとWork型はまだ同一package targetにある。
- **R5b実装記録**: `docs/D-076-R5-LEGACY-INVENTORY.md` に、`NovelSyncLegacy`／`NovelSyncCloudKitLegacy`へ移す純粋legacy sourceと、live Note／作品棚／CloudKit compositionと交差するtransitional sourceを分類した。`Scripts/check-sync-legacy-inventory.sh` を `Scripts/check.sh` に追加し、候補sourceの欠落・無意識のrenameを検出する。target追加やsource移動はまだ行わず、まず通常AppのEpisode／Work依存をlive Note境界から外す順序を固定した。
- **R5c実装記録**: Mac／iOSのproduction runtime actorから`WorkSyncTransport`のconformanceと旧Work transportメソッドを外し、`DeviceSync/Legacy/`へ移した。旧Work journal outboxの互換resumeも同じLegacy境界へ移し、live Runtime側はNote transportとNote first-publishだけを残した。`Scripts/check-sync-production-boundary.sh` を拡張して、RuntimeへのWork transport再混入とLegacy境界ファイルの欠落を検出する。これはAppのruntime物理境界を固定する段階であり、`NovelSyncLegacy` target作成や`DeviceSyncRuntime`のlegacy value field分離はまだ完了していない。
- **R5d実装記録**: `FileEpisodeSyncJournal`／`FileWorkSyncJournal`を`NovelSyncLegacy` targetへ移し、`NovelSyncCloudKit`からはtarget間の公開journal契約だけを利用する構成へ変更した。既存のgolden fixture／journal testは`NovelSyncLegacy`を明示的にlinkする。これはfilesystem adapterのsource移動であり、CloudKitのEpisode／Work adapterとApp runtimeのlegacy value fieldはまだ分離途中である。
- **R5e実装記録**: `Scripts/check-sync-target-dependencies.sh`を追加し、通常Xcode targetの`NovelSyncLegacy`直接link、`NovelSync`／`NovelSyncTesting`からの逆import、R5dで移したjournalのlive targetへの再混入を機械検査するようにした。現時点の`NovelSyncCloudKit`→`NovelSyncLegacy`推移依存は意図した過渡状態として明示的に検査し、CloudKit Episode／Work adapterの移行前に誤って外さない。これは依存監査の実装であり、R5 target分離完了ではない。
- **R6a実装記録**: `WorkSnapshotMerger.swift`からportableな競合descriptor（`WorkEntityKind`／`WorkConflictReason`／`WorkFieldConflict`）を`WorkSnapshotMergeConflict.swift`へ分離した。mergerのalgorithm engineと、UI／journalが保持するbounded conflict値型の変更理由を別ファイルにし、公開API・wire形式・merge結果は変えない。`WorkSnapshotMergerTests`を含むtarget testを通し、R6全体のalgorithm／test分割は継続する。
- **R6b実装記録**: mergerの安定ID順序グラフ、anchor挿入、決定的UUID順序を`WorkSnapshotMergeOrdering.swift`へ分離した。`WorkSnapshotMerger.swift`にはfield／entityの3-way判定とmaterialize処理を残し、順序アルゴリズムの入力・出力と循環時のfail-closed挙動は変更しない。`WorkSnapshotMergerTests`を再実行し、R6cのtest専用fixture／helper分割は継続する。
- **R6c実装記録**: `WorkSyncTestSupport.swift`から同期fixture値の生成と非同期coordinator helperを分け、`WorkSyncAsyncTestSupport.swift`へ`stageAndConfirm`／`waitUntil`を移した。production targetには入らないtest target内でも、fixture（値・作品生成）と操作待機（actor／Task境界）の変更理由を分離し、`WorkSyncCoordinatorTests`を通した。R6全体のtest専用分割は、残る大規模testファイルの責務を見ながら継続する。
- **R6d実装記録**: `EpisodeSyncCoordinatorTests.swift`からpublish／recovery競合シナリオ6本を`EpisodeSyncCoordinatorRecoveryTests.swift`へ分離した。authority／restoreのcore scenarioと、再入・応答消失・強制epoch・fenceのrecovery scenarioを別ファイルで探索できるようにし、共通fixture helperはtest target内のinternal境界に留めた。18件のcoordinator testを再実行し、R6全体のtest専用分割は残る大規模testファイルの棚卸しとともに継続する。
- **R6e実装記録**: `MacTextAdapterIntegrationTests.swift`を基本入力／設定／delegate・IME通知／AppKit実入力／Document・Lifecycle／IME確定のscenarioへ分離し、実`NSTextView` fixtureを`MacTextAdapterIntegrationSupport.swift`へ移した。各scenarioを独立したtest fileとして探索できるようにし、AppKit境界とIME／Undo回帰を保ったまま52件のEditorKit testを再実行した。R6全体は残る大規模testとCloudKit混在adapterの棚卸しを継続する。
- **R7実装記録**: SwiftLintのfile length warning 3件を解消するため、`AppleDeviceSyncAccount`のremote boundary／journal boundary／journal factoryを専用ファイルへ分離し、macOS／iOSの`DeviceSyncLocalLibraryStore`からrecord persistence、root identity、path validation、package inventoryを`LocalLibraryRegistry`へ抽出した。各store本体にはactorのライフサイクル遷移と公開操作を残し、CloudKit、`NovelLibrary`、private working-copy rootの依存方向とSwift 6 isolationは変更していない。分割後のproduction fileは400行未満となり、`swiftformat --lint`、baseline付きSwiftLint、`swift test --package-path NovelKit`、`./Scripts/check.sh`（`All checks passed`）を確認した。R6の残る大規模test／adapter棚卸しは継続する。
- **置き換える範囲**: [CODE_HEALTH.md](CODE_HEALTH.md) 3〜5章の簡素化候補を、実装可能な構造・API・並行性・tooling契約として具体化する。[DESIGN.md](DESIGN.md) 3章／9章の現行target graphと依存方向は、R4／R5を実装して同文書を更新するまでは現在の正を維持する。D-005／D-006のEditor所有権、D-036のportable境界、D-041のlifecycle直列化、D-071／D-073のlive Note／明示同期、D-075のprovider削除を変更しない。Package Validator Gate以下の製品ロードマップも入れ替えない。
- **理由**: 現在の大規模ファイルは、AIが一つの変更に必要以上の文脈を読むだけでなく、人間にも変更理由、actor isolation、live／legacy経路を見分けにくくしている。一方、extension分割だけでは共有可変stateとアクセス範囲が残り、Packageの乱造はbuild graphと公開APIを増やす。Featureによる探索、役割型による可変stateの封じ込め、再利用が実在する箇所だけのmodule境界、Swift 6コンパイラとformatter／linterによる機械検査を組み合わせることで、原稿保全契約を変えずに保守性とAI開発時の文脈量を下げられる。
- **参考基準**: [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)、[Swift 6 Concurrency Migration Guide](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/)、[SwiftLint](https://github.com/realm/SwiftLint)、[SwiftFormat](https://github.com/nicklockwood/SwiftFormat)。
- **完了条件**: R1〜R6を個別に検証し、通常Mac／iOS targetがlegacy同期をlinkせず、Mac／iOSのlocal library共通状態機械が1実装になり、AppState／IOSDocumentStoreからI/Oとpure projectionが分離され、既存budget超過が増えず、`./Scripts/check.sh`が`All checks passed`になること。文書追加だけ、ディレクトリ作成だけ、行数減少だけをD-076完了とは扱わない。

## D-077: SQLiteをlocal canonicalとし、不変作品SnapshotをRust同期サーバーへ非同期複製する

- **日付**: 2026-08-15 / **状態**: 承認・設計採択（設計のみ。E2EE／account判断はD-078で確定。`docs/sync/v1`と`docs/auth/v1`は最終設計監査済みの実装authorityだが、R0 cross-language conformance、Rust server、SQLite client、旧CloudKit移行、Production運用はすべて未実装）
- **内容**:
  1. 通常編集の端末内正本を、app-private `.novelpkg`から **1 local profileにつき1 SQLite database** へ移す。native editorはIME変換中の本文を一時的に所有し、確定した作品状態、作品棚、Snapshot、SyncIntent、SealedAttempt、Inbox、Conflict、account fence、migration ledgerをSQLiteの短いtransaction境界で管理する。大きいattachmentはapp-private content-addressed storeへ置き、SQLiteがSHA-256、byte count、論理参照を所有する。DB writerは専用actorだけとし、transaction中にnetworkを待たない。
  2. `.novelpkg` v1〜v3は通常autosave先／同期working copyから外し、macOS／iOS／Windows間の **検証済みImport／Export専用portable artifact** とする。Importは外部原本を変更せずnew WorkIDとしてSQLite＋CASへ取り込み、Exportは1 committed Snapshotからpackageを生成してread-back後にatomic採用する。active work、session、WorkID、bindingを変えない。package schemaとgolden fixtureを捨てず、local SQLite schema、Intent／Attempt、account、server URLをpackageへ入れない。
  3. 同期の論理単位は常に作品全体とする。title／synopsis、章・話構造と順序、本文／メモ、人物、プロット、伏線、世界観、attachment metadata／bytesを、version付きcanonical entity payloadとblobへ分けてcontent-address化し、物理転送は変わったobjectだけにする。Importで見つけた未知の非hidden portable resourceは原bytesと相対pathをlocal CASへ保全してExportで戻すが、意味を検証できないためprotocol v1のonline履歴／同期対象にはしない。
  4. 自動保存は最初の未保存変更から最大2秒のcoalescing windowでcurrent state、dense local Snapshot、`SyncIntent`を1 SQLite transactionへcommitし、追加入力で期限を延長しない。話／画面遷移、background／sleep、window close、quit、`Cmd+S`はIME／formを確定して同じ境界をflushする。close／quitの完了条件はlocal commitとIntent durabilityまでで、remote完了ではない。workerはcommit後に非同期起動し、通信復帰、foreground、次回起動で自動再開する。手動同期は同じworkerの即時再試行入口に限り、正しさの前提にしない。
  5. SnapshotはI-JSON制限付きRFC 8785 JCS manifestのSHA-256をidentityとし、0〜2 parent、WorkID、sorted EntityKey／object hashを持つ。reason、capture時刻、pinはidentity外の複数occurrence metadataとする。headは`{ generation, snapshotID }`で、headなしは`null`、存在するgenerationは`1...9007199254740991`のJSON安全整数とする。更新時刻、端末名、push到着順をidentityやwinner判断に使わない。local／server履歴、同期、復元は同じSnapshot schemaを使う。dense autosaveはstable checkpointのleafにし、manual／lifecycle／online acknowledged時はcurrentまたはsource leafの同じSnapshot IDへ保護occurrenceを追加してstable checkpointへpromotionする。manual／pinned online checkpointは独立した耐久intentからremote-equivalent Snapshotをregisterしてheadを変えないhistory occurrenceとして記録し、後続latest stateだけをheadへpublishする。最新leafをparentに別checkpointを作らず、古いdense siblingを間引き可能にする。復元前に現在状態を保護し、過去内容を持つ **新しい** local 2-parent Snapshotを作り、headを過去へ直接巻き戻さない。選択元がlocal-onlyならserverへlocal parent鎖をuploadせず、workerが復元後entriesをremote head直下の通常candidateとして複製する。
  6. local save時はcoalesce可能なIntentだけを作る。per-work workerが送信直前にcurrent remoteを確認し、最新local stateからremote head直下のbranch candidateを作って、operation ID、canonical request digest、expected head、candidate、source local generation／Snapshotを`SealedAttempt`へ固定する。一度送ったattemptは変更せずexact retryする。通常publish、auto-union、Conflict resolution、online restore等のlocal-origin head mutationはすべてsource generation／Snapshotをsealし、ack時はsource以下のIntentだけをclearする。通信中の追加入力はcurrent／次Intentへ残し、解決後headを新baseとして再reconcileしてactive editorへ注入しない。Rust serverは不足object照会／finalize、immutable manifest登録、expected head CAS、cursor付きchange pull、history、Divergence／ConflictをHTTP APIで提供する。operation receipt、head event、head更新はPostgreSQL transactionでatomicにし、同じoperation ID＋同じrequestは同じ結果、同じID＋異なるrequestは拒否する。push／WebSocketは起床hintであり、correctnessはcursor pullとidempotent retryで成立させる。
  7. CAS不一致時はcandidateを捨てず、まずDivergenceとしてbase／local／remoteを保存する。client pure domainが共通baseから変更されたEntityKeyを比較するが、key非重複だけで安全としない。entity全key、所属order、参照関係のdependency closureを作り、delete対同group edit／参照追加、同一IDの異なる追加をConflictへ送る。候補作品全体のinvariantがvalidな場合だけpayload内部をmergeせず決定的な2-parent Snapshotへ自動統合する。同じkeyの異なるObjectID、dependency conflict、base不明、resource上限超過をConflictとし、暗黙winner、timestamp LWW、本文3-way mergeを行わない。
  8. Conflict中もlocal編集を止めず、利用者へは「この端末の内容を使う」「オンラインの内容を使う」「両方を別作品として残す」の3択だけを出す。3択はいずれも非競合deltaを両方保持し、元WorkIDへlocal／remoteをparentに持つresolutionをpublishする。「両方」はlocalでnew WorkID／0-parent rootを`pendingKeepBoth`へ一度だけ予約し、cloneの通常laneをblockしたまま元Work head、新Work root、Conflict、receipt、change eventを1 server transactionでall-or-nothingに確定する。lost ack／local・remote stale／再提示では同じ予約を再利用し、別operation所有のWorkID collisionだけは両head未変更をread-backして同じpending rowの予約を1組だけ差し替え、local cloneを重複作成しない。表示後にremote headまたはlocal generationが進んでいればstaleとして再提示し、古い選択を新状態へ読み替えない。全3択で送信前flush時のsource local generation／Snapshotをpending resolutionへ保存し、送信後の追加入力は新current／Intentへ残す。ACKはsource以下だけを解決済みにし、currentが進んでいれば解決後headを新baseとして再reconcileしてactive editorへ注入しない。解決済みにするのは選択結果のlocal commit、Conflict ID付きremote CAS／resolve、read-back後だけとする。
  9. pullしたSnapshot／objectはInboxへstageしてhash、size、schema、WorkID、accountを検査する。remote callbackからactive `NSTextView`／`UITextView`へ注入しない。fast-forwardは`current_local_snapshot_id == last_remote_equivalent_local_snapshot_id`であり、pending Intent／Attempt／transfer／Divergence／Conflictと未保存editor／form変更がなく、IME、document session、editor generationを確認できるD-041のsafe boundaryに限る。同じSQLite transactionでexpected current＋local generation CASを再検査し、1条件でも不成立ならInboxへ保持してreconcileしcurrentを進めない。remote I/O中にdocument operation gateを保持しない。
  10. 自動Snapshotの保持はD-074のTime Machine型（直近1時間は全件、24時間は毎時、30日は毎日、1年は毎週、それ以前は毎月）をlocal dense historyとonline acknowledged checkpointへ適用する。effective pin、local current、remote current head、全pending transfer／SealedAttempt／latest Intent／checkpoint replication、必要なlineage、未分類／未解決Divergence、未解決Conflict、migrationを自動削除しない。manual／restore-beforeは作成時にpinするがreason自体を永久rootにせず、利用者が明示unpinした非current版はbucket対象になり、receipt-idempotentなpayload releaseでonline entry mapだけをlineage stubへ縮退できる。解決済みConflict sourceも`resolvedAt + 90日`まで保持する。quota超過でもlocal保存を止めない。dense autosaveはstable checkpointのleafにし、serverはgraph stubとpayload availabilityを分け、DB参照を正とするmark-and-sweepとgrace periodでobjectをGCする。remote work trash／hard deleteはwire v1 scope外とし、後続Decisionへ分離する。
  11. serverは **Rust API + PostgreSQL + S3互換object store** とし、Docker Composeでまず`192.168.11.5`へdevelopment／integration環境を置く。clientはPostgreSQL／object storeへ直接接続しない。LAN版の固定Bearer tokenはdevelopment専用だが平文HTTPへ流さずTLSまたはVPN内HTTPSを使う。Production account、Keychain token、tenant fence、rate／size limit、off-host backup、監視、minimum client versionは必須とし、具体的なcontent protection／認証方式はD-078で固定する。初回設定で利用者がonline保存とexact account scopeを選んだ後、そのscopeで作る新規workは作成時にbindするが、account不明／別account中に作ったunbound workは後のloginだけでautomatic adoptしない。CloudKitと新serverを二重authorityにしない。
  12. 旧CloudKit record、app-private package、registry、dirty set、Note Conflict、legacy Work review、snapshot、attachmentをreset／削除しない。exact version readerでwork単位にinventoryし、raw bytesと検証済みpackageをread-only migration archiveへ残す。SQLite移行を`discovered → copied → verified → committed`として冪等化し、local／remote／legacy conflictを別Snapshotへ変換する。新serverのmanifest／object／headとExportをread-backしてからwork単位で新engineへ切り替える。旧CloudKitはread-only migration sourceとし、**max(1 major release、90日)** 保持する。削除は別Decisionと明示承認を必要とする。
  13. 実装は、R0 contract freeze（コードなし）→ R1 Snapshot domain＋SQLite／CAS → R2 Import／Export → R3 networkなしlocal product → R4 Rust sync server＋Apple verifier／FUMINIWA session → R5 Swift Apple auth／Keychain＋HTTP worker → R6 3択／online history → R7 CloudKit非破壊migration → R8 Production hardening＋account lifecycle、の順に分ける。packageとSQLiteの長期dual-write、CloudKitと新serverのdual authority、local DB切替と全UI／migrationの1 PR実装を行わない。
- **置き換える範囲**: D-002／D-009／D-016／D-017の通常保存先とURL identity、D-063のhidden package／JSON registry／CloudKit catalog実装、D-071のNote entity CloudKit経路と「自前serverを置かない」、D-072の「iCloudに保存」／hidden package複製／local package削除、D-073の明示同期限定、D-074 item 2のpackage copy／online除外、D-076のlive Note／CloudKit target前提と「同期契機を変えない」制約を置き換える。
- **維持する範囲**: D-005／D-006のnative editor所有権、IME、TextKit 2、D-036の`.novelpkg`公開互換、D-041のsession固定／operation gate／IME確定／Workbench停止、D-063の単一作品棚、WorkID identity、offline open、原本非破壊Import、identity不変Export、account fence／automatic adopt禁止、D-064のremote I/O分離とactive editor非注入、D-071の作品全体という利用者単位／3択／時計LWW禁止、D-074のlifecycle checkpoint／retention／復元前退避、D-076のFeature構造／Swift 6 actor／Sendable／scenario testを維持する。
- **理由**: 現行はpackage、registry JSON、dirty JSON、CloudKit state、package内snapshotの成功境界が分かれ、additive state migrationや終了時の整合を複雑にしている。SQLite transactionへcurrent state、dense Snapshot、SyncIntentを統合し、送信済みattemptだけを別のimmutable stateにすれば、画面と原稿は常にlocalだけで完了し、remote障害を編集不能へ波及させず、同じ不変Snapshot schemaを同期と復元へ再利用できる。作品全体の意味を保ちつつcontent addressingで変更objectだけを送るため、1巨大assetと細かいremote entity管理の両方を避けられる。
- **詳細**: protocol、local schema責務、server API、Conflict、履歴、非破壊migration、実装段階、Release Gateは[SNAPSHOT_SYNC.md](SNAPSHOT_SYNC.md)、実装委譲境界は[SNAPSHOT_SYNC_HANDOFF.md](SNAPSHOT_SYNC_HANDOFF.md)を正とする。[DEVICE_SYNC.md](DEVICE_SYNC.md) 0-current章のNote契約はclient cutoverまで現行実装の説明として残すが、新規同期設計の正ではない。
- **Release NO-GO**: SQLite transaction／migration／CAS renameのprocess-kill、DB corruption recovery、Import／Export round-trip、Swift／Rust canonical fixture、lost ack／duplicate／server restart、同時offline編集／3択、active editor非注入、account switch、server backup restore、旧CloudKit migration／rollback、Production TLS／auth／quota／off-host backup／monitoring／minimum-version fence、アプリ内account deletion開始／Apple token revoke／remote削除完了read-back、署名済みMac＋iPhoneの実機検証をすべて通すまで公開同期完成としない。
- **後続Decision**: E2EE v1かserver-readable v1か、Production account方式はD-078で解決した。技術既定は`192.168.11.5`をLAN／VPN限定検証機、unknown portable resourceをlocal-only、account合計5 GiB／attachment単体250 MiB／解決済みConflict 90日とする。固定dev tokenも平文LANへ流さずTLSまたはVPN内HTTPSを使う。remote work trash／hard deleteはSnapshot Sync wire v1後の別Decisionとする。server account deletionはAuth v1 client wireのscope外だが、公開前に削除開始、retention／取消猶予、唯一のApple identity、Apple token revoke、remote削除完了read-backをversioned account-lifecycle contractとfixtureへ固定し、R8で実装・検証する。

## D-078: Snapshot Sync v1をserver-readableとし、Sign in with Appleを唯一の初期認証providerにする

- **日付**: 2026-08-16 / **状態**: 承認・設計確定（設計のみ。versioned sync／auth contractとfixtureは最終設計監査済み。auth／server／client、R0 cross-language conformance、Productionは未実装）
- **内容**:
  1. Snapshot Sync protocol v1のcontent protectionを`serverReadableV1`、`e2ee=false`に固定する。通信路はTLS、PostgreSQL／object store／backup／credential secretはserver管理の保存時暗号化を必須とするが、これはE2EEではなく、権限を持つserver運用者は原稿内容を読める。通常UIとprivacy説明でこの境界を隠さない。tenant authorization、最小権限のoperator access、監査、本文／title／pathを含めないlogをRelease Gateにする。
  2. E2EEをv1のflag、account設定、deployment差分として追加しない。将来採択する場合はprotocol namespace／epoch、ObjectID、manifest、server validation、key distribution、recovery、migrationを置き換える別Decisionと互換性のないv2 migrationを必要とする。v1に利用者用work keyやrecovery codeを作らない。
  3. Production v1で実装する外部identity providerは **Sign in with Appleだけ** とする。macOS／iOS／iPadOSはAuthenticationServicesのnative flowを使う。別providerのbutton、設定、fake adapter、provider選択UIを通常版へ出さない。Windows等でApple認証を将来使う場合はServices IDと登録済みweb redirectを使う別client adapterとして設計するが、v1のApple native実装完了をそれに依存させない。
  4. 同期所有権の正はproviderから分離した不変・opaqueなFUMINIWA `AccountID`と1 Account＝1 Tenantである。serverは`accounts`、`external_identities`、`auth_sessions`、`provider_credentials`を分離し、検証済み`(provider configuration, exact issuer, subject)`をAccountIDへ一意に写像する。Apple subject、authorization code、identity／refresh token、email、氏名、private relay addressをWork、Snapshot、`.novelpkg`、SQLite、同期request body、logへ出さない。email／氏名／relay addressの一致をidentity、dedupe、account link、account recoveryに使わない。
  5. provider adapterは`VerifiedExternalIdentity`だけをauth domainへ渡し、sync APIは`AuthenticatedPrincipal { AccountID, TenantID, SessionID, AccountAuthEpoch }`だけを見る。最初の検証済みApple identityは新AccountIDを作り、同じissuer／subjectへの再認証は同じAccountIDへ戻す。将来のprovider追加はprovider registry／adapterを増やしてもAccountID、WorkID、sync protocolを変更しない構造にする。既存accountへの追加identityはactive session＋既存identityのfresh reauthentication＋新providerのone-time challengeによる明示linkだけとし、別account同士のmergeと暗黙linkを行わない。最後の有効identityは代替identityなしにunlinkできない。v1はApple以外のadapter、link API、link UIを実装しない。
  6. Apple clientはserver発行のsingle-use `state`／`nonce`をAuthenticationServices requestへ設定し、identity tokenと短命authorization codeをTLSでauth APIへ一度だけ渡す。Rust serverはchallengeをatomic consumeし、state、Apple JWS signature／`kid`、exact issuer、audience、expiry／issued-at、nonce、subjectを検証し、authorization codeをApple token endpointで交換して同じidentityを確認する。Apple credentialを検証前のAccountID、account fence、tenant存在情報の開示に使わない。名前とemailは要求せず、Appleが返してもidentity key／profile authorityとして保存しない。
  7. Apple tokenを同期APIのBearerにしない。auth serverは短命・opaqueなFUMINIWA access tokenとone-time rotationするopaque refresh tokenを発行し、clientはKeychainだけへ保存する。serverはtokenのhash／HMAC、session family、rotation receiptを保持し、生tokenをDB／logへ保存しない。lost responseは同じrotation IDで同じ結果をread-backし、消費済みrefresh tokenを別rotation IDで再利用した場合はfamilyを失効してinteractive Apple sign-inを要求する。Apple refresh tokenはserverだけが暗号化保管する。
  8. `AccountFence`はaccess／refresh token個体ではなく、server instance＋protocol epoch＋AccountID＋server管理`AccountAuthEpoch`へbindしたopaque値とする。通常token refresh、同一Apple identityの再認証、access token再発行では変えない。別accountへの切替、identity/security scopeの変更、全session失効、Apple consent revoke等でepochを進める。旧fenceのpresence、Intent、Attempt、cursorは送らずquarantineし、同じAccountIDの新fenceでもbootstrap／missing照会／replan後だけ再開する。別AccountIDのworkをloginだけでadoptしない。
  9. sign-outはFUMINIWA sessionを失効し、local SQLiteの原稿、Snapshot、未送信Intentを削除しない。Apple credential revoke／account changeは署名済みserver-to-server notificationとnative credential stateを検証し、該当identity／sessionを失効、fenceをrotateしてremote laneを停止する。clientはserver検証済みexchangeに対応するApple user handleを`getCredentialState(forUserID:)`専用にKeychainへ保存できるが、AccountID／link keyにせずSQLite／package／request／logへ出さない。設計／検証段階では通知だけを根拠に誤ったAccountのremote原稿を暗黙削除せず`locked／deletionPending`へfail closedする。利用者によるserver account削除、retention、Apple token revocation、別identityがある場合の扱いはremote hard-deleteと合わせて後続Decisionにする。ただしaccount作成を提供するApp Store版はアプリ内から削除を開始できることが必要なため、この後続Decisionと削除完了read-backなしにProduction GOにしない。
  10. v1の利用者側account recoveryは同じApple external identityへの再認証とFUMINIWA session再発行である。Apple identityを失った場合にemail、氏名、support担当者の判断だけでAccountIDを別subjectへ移譲しない。端末内SQLiteと明示Exportは認証失効中も利用可能にする。serverの保存時暗号化key／backup復旧は利用者用account recoveryとは別の運用drillである。
  11. development固定tokenはProduction identity providerではなく、明示したdevelopment build／deploymentだけのtest harnessとする。Production build／deploymentではcompile-time／startup validationで無効にし、capabilitiesは実際に使えるproviderとして`apple`だけを返す。auth failure、sign-out、Apple outage、token expiryはonline送信だけを止め、open／edit／autosave／transition／quitを止めない。
- **将来provider追加時の不変条件**: 新providerはprovider-neutral auth contractへ新しいprovider configurationとadapterとして追加する。AccountID／TenantID、Snapshot schema、sync Bearer、account fence、作品bindingをprovider固有claimへ変更しない。provider追加は別Decision、security review、account-link fixture、利用者へ実在するUIを出すことを必要とする。
- **置き換える範囲**: D-077 item 11と「後続Decisionが必要」のProduction account／E2EE未決定部分を具体化する。D-063／D-064のaccount fence、automatic adopt禁止、offline編集、active editor非注入は維持する。現行CloudKit runtimeのApple Accountは移行元scopeであり、新Rust serverのSign in with Apple sessionへ読み替えない。
- **詳細**: auth domain、wire、provider adapter、session、revocation、fixtureは[AUTH.md](AUTH.md)と`docs/auth/v1/`、同期側のcontent protection／account bindingは[SNAPSHOT_SYNC.md](SNAPSHOT_SYNC.md)と`docs/sync/v1/`を正とする。
- **Release NO-GO**: Apple issuer／audience／signature／nonce／state／code replay、JWKS rotation、lost response、refresh rotation／reuse、同一identity再認証、別subject account switch、server notification、Keychain、account fence rotation、cross-tenant non-disclosure、auth停止中のlocal editing、operator／backup access、at-rest key／backup restoreに加え、アプリ内account deletion開始、Apple token revoke、remote data削除完了のread-backをfixtureとProduction相当環境で検証するまで公開認証完成としない。

## D-079: CloudKit同期実装を廃止し、SQLite／Rust Snapshot Syncだけを現行経路にする

- **日付**: 2026-08-16 / **状態**: 承認・実装着手
- **内容**:
  1. D-077／D-078のSQLite local canonical、Rust Snapshot Sync、Sign in with Appleを唯一の現行同期経路とする。macOS／iOS通常targetから`NovelSyncCloudKit` product、CloudKit adapter、CloudKit entitlement、CloudKit bootstrapを外し、CloudKitへ接続するコードを残さない。
  2. 旧CloudKit recordはこのアプリから削除・上書き・自動移行しない。既存利用者の原稿はSQLite／Rust serverの保存物を正とし、旧CloudKitの復旧が必要な場合は別の明示的な外部移行ツール／バックアップ手順で扱う。アプリ内にCloudKitとのdual-read／dual-writeを戻さない。
  3. `.novelpkg`はImport／Export専用、SQLite＋CASが端末内正本、Rust serverがオンライン正本であることをUI・ログ・設定名にも反映する。「iCloudと同期」「iCloudに保存」など旧経路を示す操作は提供しない。
  4. 既存の競合／履歴／復元契約はSnapshot Syncの3択とserver historyを正とする。CloudKit由来のNote／Work reviewを新Snapshotへ暗黙変換せず、旧実装のテスト・schema・adapterは削除する。
- **置き換える範囲**: D-077 item 12の「旧CloudKitをread-only migration sourceとして保持」、D-078の「現行CloudKit runtimeは移行元scope」を本Decisionで破棄する。D-005／D-006／D-036／D-041／D-063／D-064／D-077／D-078のSQLite、portable、editor、lifecycle、account、server-readable境界は維持する。
- **完了条件**: `Package.swift`とXcodeGen target graphに`NovelSyncCloudKit`／CloudKit framework／iCloud entitlementが無く、CloudKit source／testが削除され、macOS build、iOS compile、NovelKit tests、Rust server tests、`git diff --check`が通ること。旧CloudKit recordへ破壊的操作を行わないこと。

## D-080: Snapshot Sync v2を新namespace・新DB・新Docker volumeの唯一live経路にする

- **日付**: 2026-08-17 / **状態**: 実装中・統合／実機Gate前
- **内容**:
  1. v2はD-077〜D-079のlocal-first、server-readable、Sign in with Apple、AccountID／AccountFence境界を引き継ぐが、v1のlive runtime、schema、wire、dual-read／dual-writeを置き換える非互換namespaceとする。v1はread-only archiveであり、live appはv1へfallbackしない。
  2. clientは`Library/SnapshotSyncV2/`の新SQLiteだけを開き、初版object bytesはSQLite BLOBへ置く。serverは`/v2` API、新PostgreSQL schema、新Docker volume（development既定名`fuminiwa-sync-v2-data`）だけを使い、初版object bytesをPostgreSQL `BYTEA`へ置く。Rust domainは`ObjectStore` traitへ依存し、初版は`PostgresObjectStore`、将来S3は別migration／Gateとする。外部CAS root／object volumeを初版契約へ含めない。旧DB／server rows／CloudKit／package snapshotは明示migration／export backupの入力に限り、削除・上書き・暗黙adoptしない。
  3. SQLiteをlocal canonicalの唯一authorityとし、current pointer、immutable Snapshot、object reference、account binding、sealed commandをatomic checkpoint transactionへ含める。networkをtransactionへ持ち込まず、`.novelpkg`はImport／Export専用とする。macOS／iOSは同じv2 kernelを共有し、filesystem／UI adapterだけを分ける。
  4. Snapshot IDとcommand digestは受信したRFC 8785 JCSのexact UTF-8 bytesのSHA-256とする。Rust serverはcanonical manifest／commandをPostgreSQL `BYTEA`へ保存し、JSONB再serializeでraw bytesを失わない。accepted bytes、digest、schemaVersion、account scopeをread-backできない状態を成功扱いにしない。
  5. account switchはautomatic adopt／送信を禁止する。同一AccountID＋同一Fenceのtoken refreshだけ再開し、Fence変更はpresence／command／attemptをquarantineしてcapabilities／bootstrap／replanへ送る。別AccountIDはWorkIDを再bindせず、local editを継続し、明示Export／Importまたはnew WorkID cloneだけで移動する。
  6. workごとにactive conflictを1件だけ持ち、解決は`useDevice`／`useServer`／`keepBoth`の3択に閉じる。未選択時にwinnerを決めず、useServerは事前checkpointを残し、keepBothは新WorkIDを作る。restoreは事前checkpoint後に新しい2-parent Snapshotを作り、headを過去へ巻き戻さない。
  7. state-changing requestはnetwork byte以前にsealed commandとしてSQLiteへdurable化し、first-send後はexact retryする。物理RuntimeModeは`production`／`test(TestDependencies)`／`preview`だけとし、archive readerは別offline executableへ分離する。production URL／root／Keychainはtest型として構築できない。
  8. publishはremote headとの比較だけでconflictにせず、candidateがcurrent remote graphのequal／ancestorなら`200/noChanges`として現在のhead／generationとcandidate `snapshotId`を返す。不comparableなvalid descendantsだけを`409/conflictPending`とする。clientはreceipt JSONだけでこの応答を確定せず、account／fence検証済みInbox graph IDを必須にして、閉じた親グラフ上のancestor証明とhead／generation一致を再検証する。ACKはexact source Intentだけをclearし、遅延receiptでheadを巻き戻さず、active editorへremote bytesを注入しない。
  9. Auth wireはv1（`authProtocolEpoch=1`）のまま維持するが、D-080でliveになったSync v2の`PROTOCOL_EPOCH=2`をcapabilities、exchange／refresh／`/me`のsession bindingへ返す。`authProtocolEpoch`と`syncProtocolEpoch`を混同せず、Auth v1からSync v2のauthenticated principal／capabilities／command headerへこの同じepochを渡す。AccountFenceはserver instance＋Sync epoch 2＋AccountID＋AccountAuthEpochへbindし、refreshでは不変とする。
  10. Importで検証された`.novelpkg`のopaque resourceは、Snapshot identity／online wireへ混ぜず、`resources` CASと`work_resources` path mirrorへ同じlocal SQLite transactionで採用する。通常checkpointでresource引数を省略した場合は既存mirrorを保持し、明示Import／clearだけが置換する。keepBoth／explicit account cloneでは参照とbytesを同一transactionで複製し、GC rootは全Work参照から再計算する。
  11. SQLx migrationの前にPostgreSQL identity guardを実行し、system objectとSQLxの`_sqlx_migrations` bookkeepingだけを持つ真にfreshなDB、または`sync_v2.server_meta`がnamespace／protocol epoch／schema version／DDL contract markerの全てでv2と完全一致する既存DBだけを許可する。legacy／partial／nonempty／unrecognized user schemaはmigrationが作成・変更・seedする前にfail closedし、拒否時のDB状態を変更しない。既存v2 DBとSQLx metadataの再起動も許可し、実DBをvolume renameや削除で移行しない。
- **置き換える範囲**: D-077／D-078のv1 wire／schema／runtimeをv2 contractへ置き換える。D-077〜D-079のoffline editing、原稿保全、SQLite authority、`.novelpkg` portable境界、D-041のsession／IME／operation gate、D-078のApple-only／server-readable／AccountID／Fenceは維持する。`docs/sync/v1/`は編集・削除せず履歴として残す。
- **詳細**: [SNAPSHOT_SYNC_V2.md](SNAPSHOT_SYNC_V2.md)と`docs/sync/v2/`を正とする。closed command／entity schema、JCS exact bytes／hash、SQLite／PostgreSQL DDL、`/v2` resource/cursor/read-back wire、RuntimeMode、migration evidence、Mac／iOS UI projection、account switch、conflict、restore fixtureは同一versioned contractとして変更する。新v2 PostgreSQL deploymentは凍結済みAuth v1 wire/stateを別ownerの`auth_v1` schemaへ実装し、`sync_v2`はopaque AuthenticatedPrincipal／capabilities境界だけを受ける。Apple identity／credentialをsync schemaへ持ち込まない。
- **完了条件**: Swift／Rustの独立conformance harnessがv2 fixtureのJCS bytes、hash、schema failure、sealed command、account isolation、single conflict、3択、restore、restartを一致検証し、v2 DB／server namespace／Docker volumeの新規構成、macOS／iOS共有kernel、旧archiveの非破壊read-only境界を確認するまでv2 live cutoverを宣言しない。

## D-081: Snapshot Sync v2のmigration ownerとruntime roleを分離する

- **日付**: 2026-08-18 / **状態**: 実装中・Production read-back／既存volume移行Gate前
- **内容**: 新しいrole-split Compose projectだけが、fresh v2 databaseでbootstrap roleから migration owner と runtime roleを作成する。migration ownerだけがSQLx migration、`_sqlx_migrations`、`server_meta`／`deployment_binding` bootstrap、runtime ACL grantを実行し、runtime roleは必要なschema USAGE、table DML、sequence `USAGE, SELECT, UPDATE`だけを持つ。runtime serverはmigrationを実行せず、role flags、所有権、database/schema DDL、migration table、exact ACL、server marker、deployment bindingをread-backしてから起動する。
- **安全境界**: 既存のsingle-role／legacy／partial／mixed volumeは自動ALTER、ownership rewrite、GRANT、REVOKE、DROPの対象にしない。exact role-split v2だけは再実行をread-only attestationとして許可し、現staging volumeは別のversioned non-destructive operator migrationとrollback evidenceが揃うまで保持する。新Composeは既存volumeと異なるrole-split volume名を使う。
- **詳細**: `docs/sync/v2/deployment.md`、`docs/sync/v2/auth-boundary.md`、`SyncServerV2/docker-compose.yml`、`SyncServerV2/src/bin/sync_v2_migrator.rs`を正とする。

## D-082: Snapshot Sync v2のruntime sequence権限をUSAGE-onlyにする

- **日付**: 2026-08-18 / **状態**: D-081を部分撤回・Production read-back Gate前
- **内容**: Rust server sourceにsequenceの`currval`、`setval`、`last_value`参照はなく、runtime roleは必要なsequenceに`USAGE`だけを持つ。D-081の`USAGE, SELECT, UPDATE`というsequence grant記述と実装を撤回し、`SELECT`／`UPDATE`をruntimeへ与えない。PostgreSQLにsequenceの独立した`EXECUTE`権限はないため、insert時のnextval利用に必要な最小権限を`USAGE`とする。
- **検証**: runtime attestationは全sequenceで`USAGE=true`かつ`SELECT=false`／`UPDATE=false`をread-backし、実PostgreSQL opt-in gateは`last_value`／`setval`を拒否する。D-081のmigration owner、schema/table DML、ownership、column ACL、既存volume非破壊境界は維持する。
