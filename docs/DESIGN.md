# 小説執筆アプリ 設計書 v0.42

> v0.1 をレビューし、承認した設計。変更点は末尾の「変更履歴」を参照。
> 個別の決定と未決事項は [DECISIONS.md](DECISIONS.md) に記録する。

## 1. 目的

本アプリは、長編・中編小説の執筆を支援する **macOS向け小説執筆アプリ** である。
将来的には iOS / iPadOS 対応、AI支援、EPUB/PDF出力、キャラクター管理、プロット管理、検索、校正、要約、差分管理などを追加できるようにする。

初期段階では、以下を最優先する。

- 小説本文を快適に書けること
- 章単位で管理できること
- データが壊れにくいこと
- 後から機能追加しやすい設計にすること
- AIエージェントが実装しやすいよう、責務を分離すること

## 2. 開発方針

### 2.1 基本方針

- まずは macOS版を優先する
- ライブラリ群は multiplatform library として作成する
- iOS / iPadOS は後から対応する
- AppKit / UIKit などのプラットフォーム依存処理は EditorKit 内に閉じ込める
- NovelCore はプラットフォーム非依存の純粋なモデル層にする
- 保存形式は将来拡張しやすい `.novelpkg` を採用する
- EditorView は肥大化させず、入力処理はプラグイン化する

### 2.2 技術スタック(決定事項)

- **UI**: SwiftUI をアプリシェルに採用。ただし本文エディタの実体は AppKit の `NSTextView`(`NSViewRepresentable` 経由)。SwiftUI の `TextEditor` は日本語IME・長文性能・制御性の面で本用途に不適のため使用しない
- **テキストエンジン**: TextKit 2 を明示採用(縦書き非対応が確定したため再評価不要 → D-012)。`layoutManager` への誤アクセスによる TextKit 1 フォールバックを防ぐため、デバッグビルドでアサーションを入れる
- **配布**: GitHub Releases による直接配布。App Sandbox は採用しない(→ D-011)
- **最低ターゲット**: macOS 14(`@Observable` の要件。実機は macOS 27 なので余裕あり)
- **テスト**: swift-testing(`@Test`)を使用
- **プロジェクト構成**: Xcode アプリプロジェクト + ローカル Swift Package(`NovelKit`)。NovelCore / NovelStorage / EditorKit / NovelUI / PreviewSupport は NovelKit 内のターゲットとして実装し、署名不要の `swift test` を回せるようにする
- **Xcodeプロジェクト生成**: XcodeGen(`project.yml` が正、`*.xcodeproj` はコミットしない → D-015)

## 3. モジュール構成

```text
NovelWriter
├── NovelApp                     (Xcode アプリターゲット)
│   ├── AppDependencies.swift
│   ├── AppState.swift
│   └── ContentView.swift
│
└── NovelKit                     (ローカル Swift Package)
    ├── NovelCore
    │   └── Models.swift
    ├── NovelStorage
    │   └── NovelpkgRepository.swift
    ├── EditorKit
    │   ├── EditorView.swift
    │   ├── Core
    │   │   ├── EditorPlugin.swift
    │   │   └── EditorContext.swift
    │   ├── Rules
    │   │   └── IndentRules.swift
    │   ├── Plugins
    │   │   ├── IndentPlugin.swift
    │   │   └── IMEGuardPlugin.swift
    │   └── Platform
    │       └── macOS
    │           └── MacTextAdapter.swift
    ├── NovelUI
    │   └── SidebarRow.swift
    └── PreviewSupport
        └── Fixtures.swift
```

## 4. 各モジュールの責務

### 4.1 NovelCore

アプリの中核となるデータ構造とプロトコルを定義する。
**NovelCore は他モジュールに依存してはならない。**

> **Chapter / Episodeモデル(D-028、UI-FIX-2a/2b/2c実装済み)**: `Chapter` は章タイトルと `[Episode]` を持つ構造、`Episode` はタイトル・本文・メモを持つ編集単位である。AppStateは`selectedChapterID` / `selectedEpisodeID`を選択の正とし、執筆UIはUI-FIX-2cで階層表示へ移行済みである。

主な責務:

- 作品モデル
- 章モデル
- ID型
- 保存層の抽象プロトコル
- 保存要求の直列化(`DocumentSaveCoordinator`。保存処理はクロージャ注入で、依存ゼロを維持 → D-017)

代表モデル:

```swift
public struct ChapterID: Hashable, Codable, Sendable {
    public let rawValue: UUID
}

public struct EpisodeID: Hashable, Codable, Sendable {
    public let rawValue: UUID
}

public struct Episode: Codable, Sendable, Identifiable {
    public var id: EpisodeID
    public var title: String
    public var content: String
    public var memo: String
}

public struct Chapter: Codable, Sendable, Identifiable {
    public var id: ChapterID
    public var title: String
    public var episodes: [Episode]
    // order は持たない。章順は chapters、話順は episodes の配列順が唯一の正
}

public struct NovelDocument: Codable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var chapters: [Chapter]
}

public protocol DocumentRepository: Sendable {
    func load(from url: URL) async throws -> NovelDocument
    func save(_ doc: NovelDocument, to url: URL) async throws
}
```

設計上の注意:

- `Chapter.order` は置かない。配列順と `order` の二重管理は必ずズレる
- 「最近開いた作品」の追跡は Repository の責務ではなく App 層の責務(UserDefaults にファイルパスを保存すれば足りる。Sandbox 非採用のため → D-011)。Repository は URL に対する load / save に徹する

### 4.2 NovelStorage

作品データの保存・読み込みを担当する。`.novelpkg` はフォルダ形式のパッケージであり、将来的に画像・資料・AI生成メモなどを追加しやすい。

> **v3形式(D-028、UI-FIX-2a実装済み)**: 本文は `episodes/<EpisodeID>.md`、メモは `episode-notes/<EpisodeID>.md` に保存し、manifest の `chapters[].episodes[]` が話順を持つ。v1 / v2 は読み込み時に各旧章を「同じIDの章 + 本文1話」へ変換する。

保存形式:

```text
MyNovel.novelpkg/
├── manifest.json
├── episodes/
│   ├── 7B0C…D4E1.md      ← ファイル名は EpisodeID(UUID)。連番にしない
│   └── 3F2A…9C08.md
├── episode-notes/
└── attachments/
```

**本文ファイル名は EpisodeID ベースにする。**
理由: 連番だと章や話の並べ替えのたびに全ファイルのリネームが発生し、破損リスクと将来の同期・差分管理の複雑さが増す。章順と話順は manifest.json だけが持つ。

`manifest.json` の責務:

- 作品ID / 作品タイトル
- フォーマットバージョン
- 章の順序付きリスト(章ID + 章タイトル + 章内の話ID / 話タイトル)
- 作成日時 / 更新日時

`episodes/*.md` の責務:

- 各話の本文をプレーンテキスト(Markdown互換)として保存する。メタデータは持たせず、manifest.json に一元化する

NovelStorage の設計方針:

- NovelCore の `DocumentRepository` に準拠する
- App側は保存形式の詳細を知らない(`.novelpkg` の内部構造を漏らさない)
- 書き込みは `FileWrapper` またはテンポラリ書き出し + `replaceItemAt` でアトミックに行い、破損リスクを減らす
- 将来的にスナップショット保存を追加できるようにする
- App Sandbox は採用しない(GitHub 直接配布のため → D-011)。セキュリティスコープ付きブックマークは不要。将来 App Store 配布に切り替える場合のみ再考する

### 4.3 EditorKit

本文エディタを提供する。初期実装では macOS の `NSTextView` を SwiftUI から利用する。iOS は後から `UITextView` アダプタを追加する。

EditorKit の責務:

- `EditorView` の提供
- `NSTextView` / `UITextView` の差異吸収
- 本文のモデル同期
- IME対応
- 自動インデント
- 将来的な検索・置換・ルビ・禁則処理の基盤

**テキスト所有権ルール(最重要)**:

編集中の本文の「正」は `NSTextView` の `textStorage` である。

- モデルへの同期は `didChange` 時に行う(自動保存はデバウンス)
- モデル → View への反映は**話切り替え時のみ**。編集中に外から `setString` しない
- IME 変換中(`hasMarkedText`)は、プラグイン処理・モデル反映ともに行わない

v0.1 が懸念していた「日本語IMEの不自然な巻き戻り」は、ほぼすべてこのルール違反(編集中の双方向Bindingによる setString)が原因で起きる。SwiftUI の `Binding<String>` で素朴に双方向同期する実装は禁止。

EditorView は肥大化させない。入力処理はプラグイン方式にする。

```text
EditorView
└── MacTextAdapter
    ├── IMEGuardPlugin
    ├── IndentPlugin
    ├── Future: PasteSanitizerPlugin
    ├── Future: SearchPlugin
    └── Future: RubyPlugin
```

### 4.4 Editor Plugin System

EditorPlugin は、入力前・入力後の処理を分離するための仕組みである。

目的:

- EditorView の肥大化を防ぐ
- 入力処理を小さい単位で追加できるようにする
- 各プラグインを単体テストしやすくする
- macOS / iOS で可能な限り共通化する

実装済みのプロトコル(Phase 2 で確定。v0.1 草案からの変更点は後述):

```swift
public enum EditorAction: Equatable {
    case allow                    // 介入しない。次のプラグインへ
    case allowSkippingRemaining   // 介入せず、以降のプラグインもスキップして許可(IMEGuard用)
    case replace(range: NSRange, text: String, caretOffset: Int)
    // range: 置換対象(UTF-16)。shouldChange に渡された range と同じとは限らない
    // caretOffset: 置換後のキャレット位置(range.location 起点の UTF-16 オフセット)
}

public protocol EditorPlugin: AnyObject {
    func shouldChange(context: EditorContext, range: NSRange, replacement: String) -> EditorAction
    func didChange(context: EditorContext)
}

public final class EditorPluginPipeline {
    public init(plugins: [EditorPlugin])
    public func shouldChange(context:range:replacement:) -> EditorAction
    public func didChange(context:)
}
```

草案からの変更(Phase 2 実装時に確定):

- `replace` に `range:` を追加 — IndentRules の R2/R3 は「行頭の空白全体」など提案範囲と異なる範囲を置換する必要があるため
- `allowSkippingRemaining` を追加 — IME変換中に後続プラグインを一切実行させないため(素の `allow` =「次のプラグインに委ねる」と区別)
- `EditorPluginPipeline` を追加 — 「登録順に実行、最初に `.allow` 以外を返したプラグインで確定」という規則の実装体

既定パイプラインは `IMEGuardPlugin → IndentPlugin` の順で EditorKit 内部で有効化されており、`EditorView` の公開APIには現れない(プラグイン構成の公開は必要になったときに検討)。プラグインが確定した置換は、`shouldChangeText(in:replacementString:)` → `textStorage` 書き換え → `didChangeText()` の経路で適用され、Undo が通常のタイピングと同様に機能する。

`EditorContext` は、プラグインから本文やIME状態にアクセスするための抽象インターフェースである。

```swift
public protocol EditorContext {
    var string: String { get }
    var isIMEComposing: Bool { get }
    func lineRange(at location: Int) -> NSRange
}
```

注意: `NSRange` は UTF-16 単位。Swift `String` と突き合わせる際は `Range<String.Index>` への変換を必ず経由する(絵文字・結合文字で壊れる典型ポイント)。

### 4.5 IndentRules

`IndentRules.swift` は、改行時の字下げルールを定義する純ロジックである(AppKit / UIKit 非依存、`String` + UTF-16 `NSRange` のみ)。`IndentPlugin` はこの判定を `EditorAction` に写像するだけの薄い層。

確定済みルール(Phase 2 実装。テスト仕様そのもの):

- **R1**: 非空白文字を含む行で改行 → 新しい行を全角スペース(U+3000)1つで開始(地の文の字下げ)
- **R2**: 空白(全角/半角スペース・タブ)のみの行で改行 → その行の空白を掃除して空行にし、新しい行は字下げしない(字下げのゴミ行を残さない)
- **R3**: 行の内容がちょうど `　`(全角スペース1つ)でキャレットが行末のとき `「` または `『` を入力 → 全角スペースを鉤括弧に置き換える(会話文は字下げしない作法)
- **R4**: 日本語IME変換中は一切介入しない(IMEGuardPlugin がパイプライン先頭で保証)

対象は単一の `\n` 挿入(R1/R2)と単一の `「`/`『` 挿入(R3)のみ。複数行ペースト等は素通し(将来の PasteSanitizerPlugin の領分)。`NSRange` ⇄ `String.Index` の変換は `Range(_:in:)` 経由に閉じ込め、絵文字・サロゲートペアで壊れないことをテストで保証している。

### 4.6 NovelUI

再利用可能なSwiftUI部品を置く。

初期実装: `SidebarRow`

将来的に追加するもの: Project Sidebar 行 / Outline 行 / AI Assistant status item / 検索バー / 設定画面部品 / キャラクターカード / プロットカード

NovelUI は可能な限りプラットフォーム非依存にする。

### 4.7 PreviewSupport

プレビュー用の固定データを置く。

- 各Previewでダミーデータがバラつくのを防ぐ
- UIの確認をしやすくする

## 5. App側の設計

### 5.1 AppDependencies

依存関係を組み立てる。例: `NovelpkgRepository`、将来のAIクライアント、設定ストア、Exporter。
App本体は具象クラスを直接作りすぎない。

### 5.2 AppState

アプリ全体の状態を管理する。

```swift
@Observable
final class AppState {
    var document: NovelDocument
    var selectedChapterID: ChapterID?
    var selectedEpisodeID: EpisodeID?
    var workspaceSelection: WorkspaceSelection
    var outlinePresentation: OutlinePresentationState
    var aiAssistantPanel: AIAssistantPanelState
}
```

主な責務:

- 現在開いている作品
- 現在作品の保存完了後にだけ新規作成・別 URL 読み込み・別名保存を確定するトランザクション
- 選択中の章ID / 話ID
- 選択中のProject SidebarセクションとOutline項目
- Outline検索バーの表示状態
- 下部AI Assistant Panelの開閉・高さ・入力状態
- 選択中章 / 話の取得
- 選択中話本文・メモの更新
- 最近開いた作品の記録(ファイルパス)

章選択は `ChapterID` で管理する。`Chapter` オブジェクトそのものを選択状態として持たない。

UIの正は `WorkspaceSelection`(Project Sidebar + Outline)に寄せる。旧3モード制で使った `AppMode` は Phase 4.5-1 で撤去済みであり、新UIへ再導入しない。

### 5.3 ContentView

画面構成を担当する。

```text
ContentView
└── NovelWorkbenchView
    ├── NavigationSplitView
    │   ├── ProjectSidebarView
    │   ├── content(Outline / セクション一覧)
    │   │   └── OutlineContainerView / CharacterListView / …
    │   └── detail(Editor / セクション詳細)
    │       └── EditorPaneView / CharacterDetailView / …
    └── AIAssistantPanelView
```

主な操作: Project Sidebar のセクション選択 / Outline での章・シーン選択 / 章追加 / 章並べ替え / 本文編集 / 検索 / 下部AI Assistant Panel の開閉 / 自動保存

新UIの画面構成は D-021 / D-024 / D-032 と [UIDESIGN.md](UIDESIGN.md) / [TOOLBAR.md](TOOLBAR.md) / [UIREFRESH.md](UIREFRESH.md) が正である。Outlineを持つ執筆・プロット・登場人物・世界観・資料は、左から Project Sidebar、Outline(content)、Detail を `NavigationSplitView` で並べる。作品情報・設定はOutlineを置かず、Project SidebarとDetailだけの2列で表示する。下部にはいずれも AI Assistant Panel を置く。本文執筆では content に章一覧、detail に本文を出す。

`ContentView` 自体は肥大化させず、状態の受け渡しと共通コマンドの入口に留める。本文エディタの実体は従来どおり EditorKit の `EditorView` であり、App側の `EditorPaneView` は本文と選択反映を担当する。

上部 chrome は D-024 と [TOOLBAR.md](TOOLBAR.md) を正とする。Toolbar-1 で3列基盤と標準 Sidebar 開閉・Outline の作品名 + 章数を成立させ、Toolbar-2 で `EditorTopBarView` と展開式検索行を撤去し、編集操作を macOS 標準の toolbar カスタマイズ対象にした。保存状態は下部 status bar、選択章名は Outline を正とし、上部で重複表示しない。

補足: v1 では `DocumentGroup`(ドキュメントベースApp)は使わず、単一ウィンドウ + 明示的な Repository 構成とする。オートセーブやバージョン管理を自前で持つ代わりに、ウィンドウ管理・状態管理がシンプルになる。複数作品対応の際に再評価する。

## 6. 初期機能要件

### 6.1 作品管理

- 起動時に最近の作品を読み込む
- 作品がなければ新規作品を作成する
- 保存は `.novelpkg` 形式で行う
- 将来的には複数作品を選択して開けるようにする

### 6.2 章／話管理

- 章一覧を表示できる
- 章を選択できる
- 章を追加できる
- 章を並べ替えできる
- 章タイトルを保持できる
- 章の配下に話を追加・選択・並べ替え・移動できる
- 話タイトル・話本文・話メモを保持できる

### 6.3 本文編集

- 本文を編集できる
- 話を切り替えても本文が保持される
- 日本語IME入力で不自然な巻き戻りが起きない
- Undo / Redo が可能
- 改行時に自動インデントできる

### 6.4 保存

- `.novelpkg` に保存する
- 話本文は `episodes/<EpisodeID>.md`、話メモは `episode-notes/<EpisodeID>.md` として保存する
- 章順と章内の話順は `manifest.json` で管理する
- 保存はアトミックに行い、データ破損を起こしにくくする
- 自動保存はデバウンス(例: 入力停止2秒後 + 話切り替え時 + アプリ非アクティブ時)
- 将来的にスナップショット保存を追加する

## 7. 将来機能

### 7.1 検索

作品内検索 / 話内検索 / 検索結果ジャンプ / ハイライト表示

### 7.2 キャラクター管理

名前 / ふりがな / メモ / 関係性 / 登場章 / AI用キャラクター要約

### 7.3 プロット管理

シーンカード / 時系列 / フラグ管理 / 未回収伏線リスト / 章との紐付け

### 7.4 書き出し

プレーンテキスト / Markdown / EPUB / PDF。

書き出しは `.novelpkg` の内部構造を読まない独立した `NovelExport` 機能として実装する。入力は `NovelDocument` の不変スナップショットだけとし、本文・作品名・章名だけを対象にする。初期版の EPUB/PDF は横書きの最小仕様に留め、高度な組版・画像埋め込み・縦書きは対象外とする。詳細な実装順と仕様は [PHASE5.md](PHASE5.md) を正とする。

### 7.5 AI支援

AI機能はアプリ本体から独立したFeatureとして扱う。

想定機能: 章の要約 / 矛盾検出 / キャラクター口調チェック / 伏線チェック / 続きの提案 / 表現の言い換え / 誤字脱字チェック / 世界観メモ生成

方針:

- 本文編集をブロックしない
- AIが失敗しても執筆機能は壊れない
- AI処理結果は下部の AI Assistant Panel に出す(D-021)
- 本文への反映はユーザー確認後にする

## 8. 開発ロードマップ

### Phase 0: 開発基盤

- git init + GitHub Flow
- PRテンプレート / Issueテンプレート
- SwiftFormat / SwiftLint
- ローカル検証スクリプト `Scripts/check.sh`(lint + `swift test` + **iOS向けコンパイルチェック**。共有コードへの AppKit 混入をコンパイラで検出する → D-013, D-014。クラウドCIは使わない)
- 最小テスト

### Phase 1: 最小執筆環境

- NovelCoreモデル
- AppState
- 章リスト
- EditorView(テキスト所有権ルール準拠)
- `.novelpkg` 保存
- 起動時読み込み

### Phase 2: Editor基盤強化

- Editorプラグイン基盤
- IndentPlugin / IMEGuardPlugin
- 自動インデント
- Undo / Redo確認
- EditorView肥大化防止

### Phase 3: 基本操作強化

- 章タイトル編集
- 章削除
- 章並べ替え安定化
- Cmd+Q 時の即時保存
- 検索ジャンプ
- スナップショット保存

### Phase 4: 小説執筆支援機能

詳細なサブフェーズ分解と作業指示は **[PHASE4.md](PHASE4.md)** を参照(実行エージェント向けの一次資料)。データ配置とバージョン方針は D-018。

- **4-1** メタデータ基盤 + 章メモ + 文字数(必須・最初)
- **4-2** キャラクター管理・最小(必須)
- **4-3** キャラクター ⇄ 本文の連携(推奨)
- **4-4** プロット / シーンカード・最小(必須)
- **4-5** 伏線・フラグ管理(推奨)
- **4-6** 資料添付(任意)

### Phase UI: GUI刷新(旧3モード制)

完了済み。ただし D-021 により次の Phase UI2 で置き換える。

- 単一ウィンドウ・3モード制(執筆 / キャラクター / プロット)を実装
- キャラクターシート
- 章レーン式プロットボード + 伏線トラッカー
- 執筆モードの章コンテキストインスペクタ
- エディタ表示設定

### Phase UI2: Workbench刷新

完了済み。詳細なサブフェーズ分解と完了記録は **[UIDESIGN.md](UIDESIGN.md)** を参照。

- Project Sidebar(作品情報 / 企画 / 執筆 / プロット / 登場人物 / 世界観 / 資料 / 設定)
- Outline(原稿・章・シーン一覧、文字数、更新状態、ドラッグ並び替え、スクロール連動検索)
- Editor Pane(広い本文領域、章タイトル、検索、履歴、プレビュー、保存状態)
- AI Assistant Panel(下部開閉パネル + collapsed status bar)
- 旧3モード制と右インスペクタ中心の導線を撤去

### Phase 4.5: 安定化・作品ライフサイクル

詳細なサブフェーズと完了条件は **[PHASE5.md](PHASE5.md)** を参照。

- 保存状態の可視化と保存失敗時の再試行導線
- 新規作品 / 開く… / 別名で保存… / Finder で表示
- スナップショットの復元導線と、添付・スナップショットがある作品の保存性能基準

### Phase 5: 出力

詳細なサブフェーズと出力仕様は **[PHASE5.md](PHASE5.md)** を参照。

- `NovelExport`(NovelCore のみに依存)を追加
- プレーンテキスト / Markdown / EPUB 3 / PDF 出力
- ネイティブ保存パネル、進捗、失敗・キャンセル表示

### Phase 6: AI支援

- 要約 / 講評 / 矛盾検出 / 伏線確認 / 文章改善提案

### Phase 7: iOS / iPadOS 対応

- UITextView アダプタ(EditorKit/Platform/iOS)
- iOS アプリターゲット + UI 調整
- Phase 5 完了後に着手(需要次第で Phase 6 と順序入れ替え可 → D-013)

## 9. 実装ルール

### 9.1 依存方向

```text
NovelApp
├── NovelCore
├── NovelStorage
├── NovelUI
└── EditorKit

NovelStorage → NovelCore
NovelUI     → NovelCore
EditorKit   → NovelCore

NovelCore → 依存なし
```

NovelCore は絶対にUIやStorageに依存しない。

### 9.2 プラットフォーム依存

- AppKit / UIKit は EditorKit の Platform 配下に閉じ込める
- Public API に `NSTextView` や `UITextView` を出さない
- iOS未実装部分はダミーViewでよい

### 9.3 保存形式

- 保存形式の詳細は NovelStorage に閉じ込める
- App側は `DocumentRepository` のみを見る
- `.novelpkg` の内部構造をApp側に漏らさない

### 9.4 Editor拡張

- EditorView に直接機能を増やしすぎない
- 入力処理は EditorPlugin として追加する
- 純粋な判定ロジックは Rules 配下に置く
- 可能な限り単体テストを書く
- 編集中に外部から textStorage を書き換えない(テキスト所有権ルール)

## 10. AIエージェント向け実装指示の基本方針

依頼するときは、以下の単位で小さく投げる。

悪い例: 「小説アプリを全部作って」

良い例: 「EditorKit に EditorPlugin プロトコルを追加し、macOS の NSTextViewDelegate から shouldChange を呼び出す MacTextAdapter を実装してください。既存の EditorView は薄い Facade として保ってください。iOS は未実装で構いません。」

作業単位:

1. モデル追加
2. Repository追加
3. EditorPlugin追加
4. UI追加
5. テスト追加
6. 保存形式変更
7. リファクタリング

## 11. 直近の次タスク

Phase 0 / 1 / 2 / 3 / 4 / 旧 Phase UI / Phase UI2 / Phase 4.5 / Toolbar-1 / Toolbar-2 / UI-FIX-1〜5 / UI-REV-1〜9 / UI-REF-1〜2 は完了済み(→ 変更履歴)。次は **UI-REF-3「Outlineなしセクション」**。詳細な作業指示書は [UIREFRESH.md](UIREFRESH.md)。

Phase 5 の作品→章→話の配列順、空章・空話、空タイトル、改行の共通規則は [PHASE5.md](PHASE5.md) を正とするが、実装開始はUI-REF-1〜6の完了後とする。UI-REV完了記録は [UIREVISION.md](UIREVISION.md)。上部 chrome の現行設計は [TOOLBAR.md](TOOLBAR.md) / D-032。

Phase UI2 の完了記録は **[UIDESIGN.md](UIDESIGN.md)**。新UIは Project Sidebar / Outline / Editor / AI Assistant Panel の4領域ワークベンチ(→ D-021)として成立した。

Phase 4(小説執筆支援機能)の実行記録は [PHASE4.md](PHASE4.md) を参照。4-1〜4-6 すべて完了済み(Nice to have の未実施分は PHASE4.md のチェックボックスに残してあり、一部は UIDESIGN.md の Nice に引き継いだ)。

## 12. 非目標

初期段階では以下はやらない。

- 縦書き対応(執筆・出力とも非対応で確定 → D-012)
- iOS完全対応(Phase 7 まで着手しない。CIでのコンパイル保証のみ → D-013)
- クラウド同期
- 複数作品同時編集・ライブラリ管理UI
- AI本文自動書き換え
- EPUB/PDFの高度な組版
- リアルタイム共同編集
- 独自レンダリングエンジン

まずは、macOSで快適に小説を書ける最小機能を完成させる。

---

## 変更履歴

### v0.42 (2026-07-11)

UI-REF-3完了に伴い、Outlineのないセクションの列方針を実装へ反映(→ D-032、[UIREFRESH.md](UIREFRESH.md))。

- 作品情報・設定は Sidebar + Detail の2列 `NavigationSplitView` とし、空の概要Listを置かない
- 執筆・プロット・登場人物・世界観・資料は従来どおりSidebar + Outline + Detailの3列を維持

### v0.41 (2026-07-11)

UI-REF-2完了に伴い、Labeled Field共通部品を導入した(D-032、[UIREFRESH.md](UIREFRESH.md))。

- `WorkbenchLabeledField` / `WorkbenchLabeledEditor`を追加
- 作品情報・登場人物シートへ適用し、長文入力の内側8pt insetとseparator枠を統一
- 設定画面の`EditorSettingsView`二重paddingを解消

### v0.40 (2026-07-11)

UI-REF-1完了に伴い、detail chromeのglass surfaceを共通化した(D-032、[UIREFRESH.md](UIREFRESH.md))。

- `workbenchGlassChromeStyle()`と`workbenchOutlineListStyle()`を分離
- 執筆Outlineはpane全体へglass、Listは1層だけmaterialを適用
- SectionSurface、Editor accessory、人物・資料・プロットdetailのchromeをthinMaterialへ統一

### v0.39 (2026-07-11)

Phase 5前のWorkbench再調整を追加(D-032、[UIREFRESH.md](UIREFRESH.md))。

- detail chromeまでtranslucent materialを広げ、本文キャンバスだけ不透明を維持
- ラベルと入力欄の8pt余白を共通部品化
- 作品情報・設定からOutline列を外し、世界観を自由ノート(タイトル+本文)として永続化する

### v0.38 (2026-07-11)

UI-REV-1〜9完了に伴い、次タスクをPhase 5-1へ進めた(D-029〜D-031、[UIREVISION.md](UIREVISION.md))。

- Glass Outline、Plot上下split、章／話追加の分離、執筆補助、企画削除、あらすじ保存、作品情報UIを実装済みとして記録
- 作品情報は編集カードと読み取り専用の保存情報カードへ分離

### v0.37 (2026-07-11)

UI-FIX完了後の方向違いを修正する再設計を追加(D-029〜D-031、[UIREVISION.md](UIREVISION.md))。

- 全Outlineを背面がわずかに見えるtranslucent materialへ統一
- Plotを上段flat card canvas／下段伏線一覧＋詳細へ再構成し、Outline dropを追加
- 章追加／話追加のpane位置を分離し、Editor下部に記号・ルビ・傍点commandを追加する方針を確定
- 「企画」を削除し、作品情報へ編集可能なタイトル／あらすじと読み取り専用カードを置く方針を確定

### v0.36 (2026-07-11)

Phase 5着手前監査として、Chapter / Episode移行の残骸と出力仕様を整理した(D-022 / D-028、[PHASE5.md](PHASE5.md))。

- Chapter本文・メモの互換accessorとAppStateの章単位互換APIを撤去し、Phase 5での誤用をコンパイル時に防止
- 全出力形式の作品／章／話見出し、空章・空話、空タイトル、改行規則を確定
- 6章の現行機能要件と`.novelpkg` v3の保存配置をChapter / Episode構造へ更新

### v0.35 (2026-07-11)

UI-FIX-5完了に伴い、キャラクター詳細のヘッダーと各セクションのOutline規約を統一した([UIFIX.md](UIFIX.md))。

- キャラクター名を詳細の最上段へ移し、ふりがな・カラーを2行目へ配置
- Character / Plot / References / overview / 執筆Outlineでsidebar Listの背景・選択・行メタデータを統一
- セクション別Toolbarとメニューの追加導線、context menu / Deleteキーの削除fallbackを整理

### v0.34 (2026-07-11)

UI-FIX-4完了に伴い、Toolbarのメモ・スナップショット・この章をアイコン起点の anchored popoverへ移行した([UIFIX.md](UIFIX.md))。

- `WorkbenchOverlayState` でToolbar overlayの排他表示と再クリックによる開閉を管理
- スナップショットの保存・一覧・Finder表示・復元をToolbar popoverへ集約
- この章のカード内容popupと、プロットカード画面への明示的な移動導線を追加

### v0.33 (2026-07-11)

UI-FIX-3完了に伴い、プロット画面を章Outline＋カード／伏線splitへ移行(D-028、[UIFIX.md](UIFIX.md))。

- content列に執筆Outlineと共通の章選択Listを追加
- detail列を選択章のプロットカードと作品全体の伏線のHSplitへ変更
- 選択章以外のカードを隠し、既存のChapterID参照と章ジャンプを維持

### v0.32 (2026-07-11)

UI-FIX-2c完了に伴い、執筆OutlineをChapter / Episodeの階層表示へ移行(D-028、[UIFIX.md](UIFIX.md))。

- 章行の下に話行を表示し、話選択をEpisodeIDへ接続
- Toolbarの追加メニューから章／話を追加できるよう変更
- 話タイトル編集、章内並べ替え、別章移動、削除確認を追加
- 章／話ごとの件数、文字数、メモ状態をOutlineへ表示

### v0.31 (2026-07-11)

UI-FIX-2b完了に伴い、AppStateの選択正と編集支援をChapter / Episode階層へ移行(D-028、[UIFIX.md](UIFIX.md))。

- `selectedChapterID` / `selectedEpisodeID`を追加し、章ごとの最後の話選択と削除後のfallbackを実装
- 話の追加・更新・削除・並べ替え・別章移動をNovelCore / AppStateへ追加
- Editorの切り替えキー、検索、文字数、登場箇所検出をEpisodeID / Episode本文へ移行
- 新規・開く・別名保存・snapshot復元後の話選択を回帰テストで保証
- UI-FIX-2cまで既存の章単位互換APIを残し、階層Outlineの変更は次PRへ分離

### v0.30 (2026-07-11)

UI-FIX-2a完了に伴い、Chapter / Episodeモデルと`.novelpkg` v3を実装(D-028、[UIFIX.md](UIFIX.md))。

- `EpisodeID` / `Episode` / `Chapter.episodes` をNovelCoreへ追加
- v1 / v2を読み込み、v3(`episodes/` + `episode-notes/` + nested manifest)へ保存する移行を追加
- 複数話の順序、旧形式、欠損本文、添付、snapshotをNovelKitテストで保証
- UI-FIX-2bまで既存Appを動かす章単位互換accessorを追加

### v0.29 (2026-07-11)

UI Fix 計画と Chapter / Episode 階層への移行方針を追加(→ D-028、[UIFIX.md](UIFIX.md))。

- エディタ余白、8ptフォント、toolbar popover、人物header、Outline統一の修正順を確定
- `Chapter` を章構造、`Episode` を本文編集単位とする `.novelpkg` v3 方針を確定
- プロットを章 Outline + 選択章カード / 伏線の左右 split へ変更する計画を追加
- 手戻り防止のため Phase 5-1 を UI Fix 完了後へ移動

### v0.28 (2026-07-10)

Toolbar-2(一段ツールバー + カスタマイズ)完了に伴う更新(→ D-024、[TOOLBAR.md](TOOLBAR.md))。

- `WorkbenchToolbarContent` と stable ID で章追加・メモ・スナップショット・この章を native toolbar へ移設
- `EditorTopBarView` と展開式検索行を撤去し、`.searchable` + `EditorSearchSession` で右端検索
- `ToolbarCommands()` / 章メニュー / File の復元メニューで toolbar 外 fallback を確保

### v0.27 (2026-07-10)

Toolbar-1(3列ワークベンチ基盤)完了に伴う更新(→ D-024、[TOOLBAR.md](TOOLBAR.md))。

- root を3列 `NavigationSplitView` へ移行し、標準 Sidebar 開閉を有効化
- Outline content に作品名 + 章数、各 ProjectSection の content/detail 対応を固定
- 人物・プロットの入れ子 split を解消。`EditorTopBarView` は Toolbar-2 まで維持

### v0.26 (2026-07-10)

Phase 4.5-3b(保存性能の基準化)完了に伴う更新(→ D-027、[PHASE5.md](PHASE5.md))。

- 代表パッケージ(1MB 本文 / 100MB 添付 / 20 スナップショット)の計測手順と 15s 予算を追加
- 実測は予算内のため snapshots 保持方式の変更は行わない採否を記録

### v0.25 (2026-07-10)

Phase 4.5-3a(スナップショットの復旧導線)完了に伴う更新(→ D-026、[PHASE5.md](PHASE5.md))。

- `SnapshottingDocumentRepository` に一覧・書き戻し API を追加
- 復元は現在状態を先に退避し、失敗時は現在作品を維持する
- Editor Top Bar の履歴メニューから一覧・Finder 表示・確認付き復元ができる

### v0.24 (2026-07-10)

Workbench 上部ツールバーの次期設計を追加(→ D-024、[TOOLBAR.md](TOOLBAR.md))。

- Project Sidebar / Outline / Editor に追従する一体型 macOS toolbar を採用
- Sidebar 開閉、作品名 + 章数、一段の編集操作、右端の章内検索という既定配置を確定
- 章追加・章メモ・スナップショット等を個別に追加・削除・並べ替え可能にする方針を確定
- 固定アンカーとカスタマイズ可能な編集操作を分け、toolbar 外の代替コマンドを必須化

### v0.23 (2026-07-10)

Phase 4.5-2a(作品切り替えのトランザクション)完了に伴う更新。

- 現在作品の保存と候補作品の読み込みが両方成功した後にだけ状態を置き換える AppState API を追加
- 新規作品の既定保存先方針を維持し、保存失敗時は現在作品を保つ遷移を追加
- 資料・スナップショット・未知項目を保存層内で引き継ぐ別名保存能力を追加
- 成功／保存失敗／本文読込失敗／資料読込失敗を NovelAppTests で回帰保証

### v0.22 (2026-07-10)

Phase 4.5-1(保存状態の信頼性、警告と移行残骸の解消)完了に伴う更新。

- `DocumentSaveCoordinator` の保存イベントから、未保存 / 保存中 / 保存済み / 保存失敗を AppState と各表示へ反映
- 保存失敗時の再試行導線を追加し、保存失敗 → 再試行成功を NovelAppTests で回帰保証
- XcodeGen の `NovelAppTests` と `Scripts/check.sh` のアプリ層テストを追加
- メタデータ操作をドメイン別ファイルへ分割し、未使用の `AppMode` を撤去

### v0.21 (2026-07-10)

全体評価を受け、出力前の安定化と作品ライフサイクルを Phase 4.5 として追加(→ D-022)。

- 保存状態の可視化、保存失敗時の導線、新規／開く／別名保存を Phase 5 の前提に変更
- `NovelExport` を NovelCore のみに依存する独立ターゲットとして追加する方針を決定
- プレーンテキストを Phase 5 の対象に明記し、Markdown / EPUB 3 / PDF の最小仕様と検証順を [PHASE5.md](PHASE5.md) に固定

### v0.20 (2026-07-09)

Phase UI2(Workbench刷新)完了に伴う更新。

- Project Sidebar / Outline / Editor Pane / AI Assistant Panel の4領域ワークベンチを実装
- プロット、登場人物、資料、設定を Project Sidebar 配下へ再配置
- Outline のメタ情報をアイコン表示にし、文字数・保存状態・メモ状態の詳細をホバーで確認できるようにした
- 11章「直近の次タスク」を Phase 5 に更新

### v0.19 (2026-07-08)

- D-021 を追加し、UI 方針を Project Sidebar / Outline / Editor / AI Assistant Panel の4領域ワークベンチへ刷新
- D-019(単一ウィンドウ・3モード制)を破棄扱いに変更。旧 Phase UI は完了済みの履歴として残し、Phase UI2 で置き換える
- [UIDESIGN.md](UIDESIGN.md) を Phase UI2 の実行計画として全面更新
- [STYLE.md](STYLE.md) をダークテーマ・macOS専用ワークベンチ前提へ更新
- 11章「直近の次タスク」を Phase UI2 に更新

### v0.18 (2026-07-08)

Phase UI(GUI刷新)完了に伴う更新。

- `ContentView` を薄いルートへ分割し、執筆 / キャラクター / プロットの3モード制を実装
- キャラクターをシート型UIへ移設し、Optionalプロフィール項目を追加
- プロットを章レーン式カードボードへ移設し、伏線トラッカーをプロットモード右パネルへ移設
- 執筆インスペクタを [章メモ | この章 | 資料] に再編
- エディタ表示設定(`EditorConfiguration`)と Settings 画面を追加
- 11章「直近の次タスク」を Phase 5 に更新

### v0.17 (2026-07-08)

- デザイン言語 [STYLE.md](STYLE.md) を制定(→ D-020)。UI を触る PR は STYLE.md 準拠必須(AGENTS.md ルール8)

### v0.16 (2026-07-08)

- Phase UI(GUI刷新)を Phase 5 の前に挿入。実行計画 [UIDESIGN.md](UIDESIGN.md) を追加(→ D-019: 3モード制、章レーンボード、シート型キャラシート)
- 負債返済候補だった ContentView 分割は UI-1 に統合

### v0.15 (2026-07-08)

Phase 4 全体レビュー完了に伴う更新(修正PR: #15)。

- 添付操作と保存の相互排他を `DocumentSaveCoordinator.performExclusive` として実装(D-017 の補足を参照)
- 文字数カウントを軽量化、メタデータ破損時の専用エラー種別を追加
- 11章を Phase 5 前提に整理し、負債返済候補(ContentView 分割ほか)を明記

### v0.14 (2026-07-08)

Phase 4-6(資料添付)完了に伴う更新。

- `Attachment` / `AttachmentManaging` を NovelCore に追加し、資料操作を保存形式から抽象化
- `NovelpkgRepository` に資料一覧・追加・削除・Finder 表示用 URL 解決を追加
- インスペクタに「資料」タブを追加し、fileImporter 取り込み、一覧、削除確認、Finder 表示を実装
- 添付の追加後保存保持、削除反映、ファイル名衝突連番のテストを追加
- 11章「直近の次タスク」を Phase 5 に更新

### v0.13 (2026-07-08)

Phase 4-5(伏線・フラグ管理)完了に伴う更新。

- `FlagID` / `Flag` / `NovelDocument.flags` と伏線操作ヘルパーを追加
- 章削除時に紐付く伏線の `plantedChapterID` / `resolvedChapterID` を外す整合処理を追加
- `.novelpkg` の `flags.json` 保存・読み込みを追加し、不正章参照を読み込み時に矯正
- インスペクタに「伏線」タブを追加し、未回収一覧、回収済み折りたたみ、章ジャンプ、順序警告を実装
- 11章「直近の次タスク」を Phase 4-6 に更新

### v0.12 (2026-07-08)

Phase 4-4(プロット / シーンカード・最小)完了に伴う更新。

- `PlotCardID` / `PlotCard` / `NovelDocument.plotCards` とカード操作ヘルパーを追加
- 章削除時に紐付くプロットカードの `chapterID` を外す整合処理を追加
- `.novelpkg` の `plot.json` 保存・読み込みを追加し、不正章参照を読み込み時に矯正
- インスペクタに「プロット」タブを追加
- 11章「直近の次タスク」を Phase 4-5 に更新

### v0.11 (2026-07-08)

Phase 4-3(キャラクター ⇄ 本文の連携)完了に伴う更新。

- キャラクター名・ふりがなから本文内の登場章を都度検索して表示
- 登場章リストから該当章・該当位置へジャンプする UI を追加
- キャラクター名を既存検索UIへ流し込む操作を追加
- 11章「直近の次タスク」を Phase 4-4 に更新

### v0.10 (2026-07-08)

Phase 4-2(キャラクター管理・最小)完了に伴う更新。

- `CharacterID` / `Character` / `NovelDocument.characters` と人物操作ヘルパーを追加
- `.novelpkg` の `characters.json` 保存・読み込みを追加
- インスペクタに「キャラクター」タブを追加
- 11章「直近の次タスク」を Phase 4-3 に更新

### v0.9 (2026-07-08)

Phase 4-1(メタデータ基盤 + 章メモ + 文字数)完了に伴う更新。

- `.novelpkg` の保存形式を formatVersion "2" に更新。読み込みは "1" / "2" を受理し、次回保存で "2" へ移行
- `notes/<ChapterID>.md` に章メモを保存。空メモはファイルを作らない
- 保存時にパッケージ直下の未知ファイル/ディレクトリを保持
- 右インスペクタに「メモ」タブを追加し、章メモ編集UIを実装
- 本文文字数(改行を除いた Character 数)と400字詰め換算を表示
- 11章を 4-2 着手へ更新

### v0.8 (2026-07-08)

- Phase 4 をサブフェーズ 4-1〜4-6 に分解し、実行計画を [PHASE4.md](PHASE4.md) として追加(必須: 4-1/4-2/4-4、推奨: 4-3/4-5、任意: 4-6)
- メタデータの保存配置と formatVersion "2" 方針を決定(→ D-018)
- 8章 Phase 4 と 11章を PHASE4.md 参照に更新

### v0.7 (2026-07-08)

Phase 3(基本操作強化)完了に伴う更新。

- 章タイトル編集UI、章削除(確認ダイアログ付き)、検索ジャンプ、スナップショット保存を追加
- `applicationShouldTerminate` で終了前に未保存分を保存するようにし、D-016 の Cmd+Q 直後の既知の制限を解消(→ D-017)
- 保存要求を revision ベースで直列化し、章並べ替えなどの高速操作でも古い保存が後勝ちしにくい形に変更
- scaffold 由来の `placeholderVersion` 定数を削除
- 11章「直近の次タスク」を Phase 4 の内容に更新

### v0.6 (2026-07-08)

Phase 2(Editor基盤強化)完了に伴う更新。

- 4.4 を実装済みの最終 API に更新: `EditorAction` に `range:` と `allowSkippingRemaining` を追加、`EditorPluginPipeline` を追加。既定パイプラインは IMEGuard → Indent
- 4.5 を確定ルール(R1〜R4)に書き換え。自動字下げ・会話文の字下げ解除・IMEガードが動作する状態
- 11章「直近の次タスク」を Phase 3 の内容に更新

### v0.5 (2026-07-08)

- Phase 1 実装完了に伴う決定を追記: XcodeGen によるプロジェクト生成(→ D-015)、新規作品の既定保存先と自動保存の方針(→ D-016)

### v0.4 (2026-07-07)

- CI/CD はローカル実行のみに変更。GitHub Actions を廃止し、`Scripts/check.sh` に置き換え(→ D-014)。D-013 の「CI での iOS コンパイル保証」もローカルスクリプトで行う

### v0.3 (2026-07-07)

未決事項3件をすべて解決(→ DECISIONS.md D-011〜D-013)。

- 縦書きは非対応で確定。TextKit 2 採用の再評価条項を削除し、非目標に追加
- 配布は GitHub Releases(直接配布)。App Sandbox 非採用、セキュリティスコープ付きブックマーク不要
- iOS 対応は二段構え: Phase 0 から CI で iOS コンパイルを保証、iOS アプリ本体は Phase 7(Phase 5 完了後)

### v0.2 (2026-07-07)

v0.1 のレビュー結果を反映。アーキテクチャの骨格(モジュール分割・依存方向・プラグイン方式・`.novelpkg`)は v0.1 のまま承認。

- 章ファイル名を連番(`0001.md`)から ChapterID ベースに変更(並べ替え時の全リネームを回避)
- `Chapter.order` を削除(配列順との二重管理を排除)
- `DocumentRepository` を URLベース + async に変更、`loadRecent` を App 層の責務に移動
- エディタの「テキスト所有権ルール」を明文化(IME巻き戻り対策の核心)
- TextKit 2 の明示採用、最低ターゲット macOS 14、swift-testing、NovelKit パッケージ構成を決定事項として追加
- 自動保存のデバウンス方針、App Sandbox / ブックマークへの言及を追加

### v0.1 (2026-07-07)

初版。

## 未決事項

現在なし。v0.1 レビュー時の未決事項3件(縦書き / 配布形態 / iOS時期)は v0.3 ですべて解決済み(→ [DECISIONS.md](DECISIONS.md) D-011〜D-013)。
