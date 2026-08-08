# 決定記録(Decision Log)

設計・技術選定の決定を記録する。新しい決定は末尾に追加し、覆す場合は元の決定を消さず「破棄(→ D-XXX)」とマークする。

---

## D-001: UI は SwiftUI + AppKit(NSTextView)アダプタ構成

- **日付**: 2026-07-07 / **状態**: 承認
- **内容**: アプリシェル(ウィンドウ、サイドバー、設定画面など)は SwiftUI。本文エディタの実体は `NSTextView` を `NSViewRepresentable` でラップし、EditorKit 内に閉じ込める。
- **理由**: SwiftUI の `TextEditor` は日本語IME・長文パフォーマンス・カスタマイズ性で小説執筆に不十分。一方シェル部分は SwiftUI が生産性・将来の iOS 展開で有利。純 AppKit は制御性は最高だがコストに見合わない。Electron/Tauri 等は日本語IMEの細かい挙動制御とネイティブ感で不利。
- **結論**: v0.1 の方針(SwiftUI前提 + NSTextView)は正しいので変更しない。

## D-002: 保存形式は `.novelpkg`(フォルダパッケージ)

- **日付**: 2026-07-07 / **状態**: 承認
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

- **日付**: 2026-07-07 / **状態**: 承認(v0.1 から変更)
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

- **日付**: 2026-07-08 / **状態**: 承認(Phase 1-C で実装)
- **内容**:
  - 新規作品の既定保存先は `~/Documents/NovelWriter/<作品タイトル>.novelpkg`。同名が存在する場合は連番(`新規作品2.novelpkg` など)で回避する
  - 自動保存: モデル(メモリ上の `NovelDocument`)への反映は編集のたびに即時。ディスクへの保存は本文編集では**2秒デバウンス**、章切り替え・章追加・並べ替え・アプリ非アクティブ時(`willResignActiveNotification`)は**即時**
  - 「最近開いた作品」は UserDefaults にファイルパスで記録(D-011 により Sandbox 不要のため、これで足りる)
- **理由**: 執筆中のキーストロークごとのディスクI/Oを避けつつ、データ喪失ウィンドウを最大2秒に抑える。章操作は頻度が低く保存コストが小さいので即時が安全。
- **既知の制限**: ~~アプリがアクティブなまま Cmd+Q した場合、最後の編集から2秒未満だと未保存になりうる~~ → **D-017(Phase 3)で解消済み**(`applicationShouldTerminate` での終了前保存)。
- **改訂**: 既定保存先の製品フォルダ名だけは **D-038** により `~/Documents/FUMINIWA` へ変更した。既存の `~/Documents/NovelWriter` 内の作品は移動・削除せず、記録済みURLからその場で開く。

## D-017: Phase 3 の終了前保存とスナップショット保存

- **日付**: 2026-07-08 / **状態**: 承認(Phase 3 で実装)
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

- **日付**: 2026-07-10 / **状態**: 承認(Phase 4.5-2a で実装)
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

- **日付**: 2026-07-10 / **状態**: 承認(Phase 4.5-2b で実装)
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

- **日付**: 2026-08-07 / **状態**: 承認(商業化基盤で実装)
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

- **日付**: 2026-08-09 / **状態**: 承認（方針変更。App bridge／fake UI／Experimental target分離まで実装、実providerは未実装）
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
- **実装状況 (2026-08-09)**: 別app target／scheme／bundle ID／既定保存root、通常版とのbuild graph分離、App-level local context、fake provider、provider-neutralな共有AI UI、Codex sidecar v1、manifest v1、exact SDKの合成CLI capture、Darwin native process supervisor、B3のarm64固定21-file packagerとExperimental native manifest verifierまで実装した。実Codex／OpenRouter adapter、実CLI／network、compile-time approved digest allowlist、exact Node runtime、immutable verify-to-use binding、Keychain、OS-level隔離、parent death後のprocess回収は未実装であり、本決定のExperimental Gateを完了した意味ではない。

## D-047: Codex sidecar v1は本文送信前attestation付きの一request protocolとする

- **日付**: 2026-08-09 / **状態**: 承認（Node／Swift mock protocol、manifest v1、exact SDK合成capture、B2 supervisor、B3 packager／native verifierまで実装。実CLI／networkは未接続）
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
- **実装状況 (2026-08-09)**: protocol mock、canonical manifest v1、`@openai/codex-sdk` 0.147.0の合成CLI capture、D-048のDarwin native process supervisorに加え、D-049のarm64固定allowlist packagerとExperimental native manifest verifierを実装した。B3 digestはbuild-time identity candidateだけであり、compile-time approved digest allowlist、exact Node runtime、完全なloaded inventory、immutable verify-to-use binding、監査済みlauncher、実SDK／CLI、credential、network、OS-level隔離は未実装である。`codex_sdk` runtime modeは引き続き禁止する。

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
