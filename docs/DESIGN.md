# 小説執筆アプリ 設計書 v0.12

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

public struct Chapter: Codable, Sendable, Identifiable {
    public var id: ChapterID
    public var title: String
    public var content: String
    // order は持たない。章順は NovelDocument.chapters の配列順が唯一の正
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

保存形式:

```text
MyNovel.novelpkg/
├── manifest.json
├── chapters/
│   ├── 7B0C…D4E1.md      ← ファイル名は ChapterID(UUID)。連番にしない
│   └── 3F2A…9C08.md
└── attachments/
```

**章ファイル名は ChapterID ベースにする(v0.1 の連番 `0001.md` から変更)。**
理由: 連番だと並べ替えのたびに全ファイルのリネームが発生し、破損リスクと将来の同期・差分管理の複雑さが増す。章順は manifest.json だけが持つ。

`manifest.json` の責務:

- 作品ID / 作品タイトル
- フォーマットバージョン
- 章の順序付きリスト(章ID + 章タイトル)
- 作成日時 / 更新日時

`chapters/*.md` の責務:

- 各章の本文をプレーンテキスト(Markdown互換)として保存する。メタデータは持たせず、manifest.json に一元化する

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
- モデル → View への反映は**章切り替え時のみ**。編集中に外から `setString` しない
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

将来的に追加するもの: 章リスト / ツールバー / 検索バー / 設定画面部品 / キャラクターカード / プロットカード

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
    var selection: ChapterID?
}
```

主な責務:

- 現在開いている作品
- 選択中の章ID
- 選択中章の取得
- 選択中章本文の更新
- 最近開いた作品の記録(ファイルパス)

章選択は `ChapterID` で管理する。`Chapter` オブジェクトそのものを選択状態として持たない。

### 5.3 ContentView

画面構成を担当する。

```text
NavigationSplitView
├── Sidebar
│   └── Chapter List
└── Detail
    └── EditorView
```

主な操作: 章選択 / 章追加 / 章並べ替え / 本文編集 / 自動保存

補足: v1 では `DocumentGroup`(ドキュメントベースApp)は使わず、単一ウィンドウ + 明示的な Repository 構成とする。オートセーブやバージョン管理を自前で持つ代わりに、ウィンドウ管理・状態管理がシンプルになる。複数作品対応の際に再評価する。

## 6. 初期機能要件

### 6.1 作品管理

- 起動時に最近の作品を読み込む
- 作品がなければ新規作品を作成する
- 保存は `.novelpkg` 形式で行う
- 将来的には複数作品を選択して開けるようにする

### 6.2 章管理

- 章一覧を表示できる
- 章を選択できる
- 章を追加できる
- 章を並べ替えできる
- 章タイトルを保持できる
- 章本文を保持できる

### 6.3 本文編集

- 本文を編集できる
- 章を切り替えても本文が保持される
- 日本語IME入力で不自然な巻き戻りが起きない
- Undo / Redo が可能
- 改行時に自動インデントできる

### 6.4 保存

- `.novelpkg` に保存する
- 章本文は `chapters/<ChapterID>.md` として保存する
- 章順は `manifest.json` で管理する
- 保存はアトミックに行い、データ破損を起こしにくくする
- 自動保存はデバウンス(例: 入力停止2秒後 + 章切り替え時 + アプリ非アクティブ時)
- 将来的にスナップショット保存を追加する

## 7. 将来機能

### 7.1 検索

作品内検索 / 章内検索 / 検索結果ジャンプ / ハイライト表示

### 7.2 キャラクター管理

名前 / ふりがな / メモ / 関係性 / 登場章 / AI用キャラクター要約

### 7.3 プロット管理

シーンカード / 時系列 / フラグ管理 / 未回収伏線リスト / 章との紐付け

### 7.4 書き出し

Markdown / EPUB / PDF / プレーンテキスト

### 7.5 AI支援

AI機能はアプリ本体から独立したFeatureとして扱う。

想定機能: 章の要約 / 矛盾検出 / キャラクター口調チェック / 伏線チェック / 続きの提案 / 表現の言い換え / 誤字脱字チェック / 世界観メモ生成

方針:

- 本文編集をブロックしない
- AIが失敗しても執筆機能は壊れない
- AI処理結果はサイドパネルに出す
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

### Phase 5: 出力

- Markdown / EPUB / PDF出力

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

Phase 0 / 1 / 2 / 3 は完了済み(→ 変更履歴)。次は Phase 4(小説執筆支援機能)。

**Phase 4 の作業指示は [PHASE4.md](PHASE4.md) に一本化した。** 4-1(メタデータ基盤 + 章メモ + 文字数)、4-2(キャラクター管理・最小)、4-3(キャラクター ⇄ 本文の連携)、4-4(プロット / シーンカード・最小)は完了済み。次は 4-5(伏線・フラグ管理)。4-6 は任意(実施可否はユーザーに確認)。1サブフェーズ = 1PR、完了時は PHASE4.md のチェックボックスとこの章を更新すること。

## 12. 非目標

初期段階では以下はやらない。

- 縦書き対応(執筆・出力とも非対応で確定 → D-012)
- iOS完全対応(Phase 7 まで着手しない。CIでのコンパイル保証のみ → D-013)
- クラウド同期
- 複数作品管理UI
- AI本文自動書き換え
- EPUB/PDFの高度な組版
- リアルタイム共同編集
- 独自レンダリングエンジン

まずは、macOSで快適に小説を書ける最小機能を完成させる。

---

## 変更履歴

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
