# ふみにわ 設計書 v0.68

> v0.1 をレビューし、承認した設計。変更点は末尾の「変更履歴」を参照。
> 個別の決定と未決事項は [DECISIONS.md](DECISIONS.md) に記録する。

## 1. 目的

**ふみにわ（FUMINIWA）**は、長編・中編小説の執筆を支援する **macOS ファーストのマルチプラットフォーム小説執筆アプリ** である。
macOS 版を先行実装としつつ、同じ `.novelpkg` を Windows の WinUI 版でも安全に開き、編集し、再保存できることを製品要件とする。将来的には Windows、iOS / iPadOS 対応、AI支援、PDF出力、校正、要約、差分管理などを追加できるようにする。

初期段階では、以下を最優先する。

- 小説本文を快適に書けること
- 章単位で管理できること
- データが壊れにくいこと
- 開けない原稿を空の新規作品に見せかけず、利用者が安全に復旧できること
- 後から機能追加しやすい設計にすること
- AIエージェントが実装しやすいよう、責務を分離すること

## 2. 開発方針

### 2.1 基本方針

- まずは macOS版を優先するが、保存形式とドメイン仕様は Windows / iOS からも実装できる言語非依存の契約にする
- Apple 向けライブラリ群は Swift の multiplatform library として作成し、Windows 版は同じ境界を .NET class library で再実装する
- iOS / iPadOS は後から対応する
- Windows 版は WinUI 3 + C# / .NET で別実装し、Swift ソースの直接共有ではなく schema・fixture・純粋ロジックの入出力仕様を共有する
- AppKit / UIKit などのプラットフォーム依存処理は EditorKit 内に閉じ込める
- NovelCore はプラットフォーム非依存の純粋なモデル層にする
- 保存形式は将来拡張しやすい `.novelpkg` を採用する
- EditorView は肥大化させず、入力処理はプラグイン化する

### 2.2 技術スタック(決定事項)

- **macOS UI**: SwiftUI をアプリシェルに採用。ただし本文エディタの実体は AppKit の `NSTextView`(`NSViewRepresentable` 経由)。SwiftUI の `TextEditor` は日本語IME・長文性能・制御性の面で本用途に不適のため使用しない
- **Windows UI (将来)**: WinUI 3 + C# / .NET。Windows 固有コードは `Windows/` 配下へ置き、macOS と同じ保存・ドメイン境界を対応する .NET class library で再実装する(→ [CROSS_PLATFORM.md](CROSS_PLATFORM.md), D-036)
- **テキストエンジン**: TextKit 2 を明示採用(縦書き非対応が確定したため再評価不要 → D-012)。`layoutManager` への誤アクセスによる TextKit 1 フォールバックを防ぐため、デバッグビルドでアサーションを入れる
- **配布**: GitHub Releases による直接配布。App Sandbox は採用しない(→ D-011)
- **最低ターゲット**: macOS 14(`@Observable` の要件。実機は macOS 27 なので余裕あり)
- **テスト**: swift-testing(`@Test`)を使用
- **プロジェクト構成**: Xcode アプリプロジェクト + ローカル Swift Package(`NovelKit`)。NovelCore / NovelStorage / NovelExport / EditorKit / NovelUI / PreviewSupportに加え、AIの純粋domainだけを持つNovelAIをNovelKit内の独立targetとして扱い、署名不要の`swift test`を回せるようにする。NovelAIを追加してもprovider、sidecar、UIが実装済みとは扱わない(D-043)
- **Xcodeプロジェクト生成**: XcodeGen(`project.yml` が正、`*.xcodeproj` はコミットしない → D-015)
- **AI実験構成**: `FUMINIWA_ENABLE_EXPERIMENTAL_AI`を定義する別app target／scheme `FUMINIWAExperimental`だけに`NovelAI`、fake provider、共通AI UIを組み込む。通常の`FUMINIWA` app targetはAI adapter、Node／CLI／sidecar resource、AI menu／shortcut／設定をtarget dependencyとcompile条件の段階で含めない。別bundle ID／既定保存rootと生成projectの分離監査まで実装し、旧製品のrecent URL／設定はExperimentalへ自動移行しない(D-046)

## 3. モジュール構成

```text
FUMINIWA
├── NovelApp                     (Xcode アプリターゲット)
│   ├── AppDependencies.swift
│   ├── AppState.swift
│   └── ContentView.swift
│
├── NovelAppExperimental         (Experimental targetだけが追加compile)
│   ├── AIProofreadingOperation.swift
│   ├── AIProofreadingPanelView.swift
│   └── ExperimentalFakeAIProvider.swift
│
└── NovelKit                     (ローカル Swift Package)
    ├── NovelCore
    │   └── Models.swift
    ├── NovelStorage
    │   └── NovelpkgRepository.swift
    ├── NovelExport
    │   ├── NovelExporter.swift
    │   ├── TextRenderers.swift
    │   └── EPUBRenderer.swift
    ├── NovelAI                     (純粋domainのみ。provider / process / UI非依存)
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

作品データの保存・読み込みを担当する。`.novelpkg` はフォルダ形式のパッケージであり、画像・資料などを追加しやすい。AIのprompt、response、diff、provider設定はD-043の初期契約ではpackageへ追加しない。

> **v3形式(D-028、UI-FIX-2a実装済み)**: 本文は `episodes/<EpisodeID>.md`、メモは `episode-notes/<EpisodeID>.md` に保存し、manifest の `chapters[].episodes[]` が話順を持つ。v1 / v2 は読み込み時に各旧章を「同じIDの章 + 本文1話」へ変換する。

保存形式:

```text
MyNovel.novelpkg/
├── manifest.json
├── project.json                            … あらすじ(空なら省略)
├── world.json                              … 世界観ノート順・タイトル(空なら省略)
├── world-notes/<WorldNoteID(UUID)>.md      … 世界観ノート本文
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
- manifestが参照する話本文と`world.json`が参照する世界観本文は必須payloadとして読み、欠損・I/O失敗・invalid UTF-8を空文字にしない。空の話メモはファイル省略可能だが、メモファイルが存在する場合はvalid UTF-8を要求する(D-039)
- duplicate ID、不正参照、symlink、resource limit、孤児payloadの保全と修復コピーは次のPackage Validator Gateで一体的に実装する。上記payload検査だけでW0完了または完全なpackage検証済みとは扱わない

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

- `replace` に `range:` を追加 — IndentRules の R3/R5 は「行頭の空白全体」など提案範囲と異なる範囲を置換する必要があるため
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

確定済みルール(UI-POL-1 / D-033 実装済み。テスト仕様そのもの):

- **R1'**: 行の内容にかかわらず改行 → 新しい行を全角スペース(U+3000)1つで開始。字下げが不要な行はユーザーが削除する
- **R3**: 行の内容がちょうど `　`(全角スペース1つ)でキャレットが行末のとき `「` または `『` を入力 → 全角スペースを鉤括弧に置き換える(会話文は字下げしない作法)
- **R4**: 日本語IME変換中は一切介入しない(IMEGuardPlugin がパイプライン先頭で保証)
- **R5**: IME確定後、キャレット直前が `「` / `『` で、その行が `　「` / `　『` のとき、行頭の全角スペースを削除する。削除は undo 可能な正規置換経路で行う

対象は単一の `\n` 挿入(R1')と単一の `「`/`『` 挿入(R3)のみ。複数行ペースト等は素通し(将来の PasteSanitizerPlugin の領分)。R5はIME確定後のキャレット位置に基づく局所判定である。`NSRange` ⇄ `String.Index` の変換は `Range(_:in:)` 経由に閉じ込め、絵文字・サロゲートペアで壊れないことをテストで保証している。

### 4.6 NovelUI

再利用可能なSwiftUI部品を置く。

初期実装: `SidebarRow`

将来的に追加するもの: Project Sidebar 行 / Outline 行 / 検索バー / 設定画面部品 / キャラクターカード / プロットカード。AI用部品はプライバシー・同意・失敗時挙動を含む機能設計が承認されるまで追加しない(D-040)

NovelUI は可能な限りプラットフォーム非依存にする。

### 4.7 PreviewSupport

プレビュー用の固定データを置く。

- 各Previewでダミーデータがバラつくのを防ぐ
- UIの確認をしやすくする

### 4.8 NovelExport

`NovelDocument`の値から配布用原稿を生成する。`NovelCore`だけに依存し、`NovelStorage`、`.novelpkg`の内部構造、`AppState`、UIを参照しない。

- 作品→章→話を一度だけ走査する共通原稿展開で、順序、空タイトル、空章／空話、改行正規化を確定する
- TXT / Markdown / EPUB 3の形式別レンダラは共通原稿だけを入力にする
- 公開APIは `NovelDocument` / `ExportOptions` / `Data` / `URL` ベースとし、生成物は同じ親の一時ファイルからアトミックに置き換える
- EPUBは再現可能なZIP、OPF、nav、章XHTMLを生成し、保存層や外部プロセスに依存しない
- Phase 6.5でPDFを追加する際も共通原稿と公開APIを維持し、macOS固有コードだけを `Platform/macOS/` に置く

### 4.9 NovelAI

AI機能のprovider-neutralな純粋domainを担当する。初期targetはFoundationのoutbound値型、protocol、draft → version付きinstruction ID、単一`applicationPrompt`、version付きexact response schemaを持つpreview → `AIApplicationPayload`を封印したconfirmed requestの状態遷移、raw structured outputのstrict decode、結果／型付きerror、決定論的fakeだけを持ち、NovelCore、NovelStorage、EditorKit、SwiftUI、AppKit、network、subprocess、Keychain、provider SDKへ依存しない。

- 最初のtaskは利用者が明示選択した本文範囲の校正案だけとする
- 固定指示のversionをinstruction IDで表し、`selected_text`を未信頼データとして扱い、その中の命令に従わず選択外の文脈／ファイルを参照しないことを固定する。instructionを変えるときはIDも更新して再確認する
- instruction、exact selected textからadapterがそのまま渡す単一`applicationPrompt`を決定論的に生成する。responseはversion付きschema ID（初版`proofreading-result-v1`）とexact `applicationResponseSchema`をdomainで固定し、schema変更時もIDを更新して再確認する
- confirmed requestはpreviewで封印したprovider、purpose、instruction ID、`applicationPrompt`、response schema ID／exact schema、budget、app-provided input文字／UTF-8 byte数だけを持つ。adapterによるpromptの再構築／追記と、schemaのcanonical JSON value tree／digestの変更を許可しない。Provider wrapperへのstrict parse／写像とwire上のescape／key順は許容するが、property追加・削除・緩和は禁止し、document session、editor surface、episode、UTF-16範囲、source digest、pathを混ぜない
- providerの完了eventはraw structured outputとusageをdomain境界へ渡し、exact schemaでstrict decodeした`AIResult`だけを公開する
- domain所有executorが不変provider descriptorを照合し、同じconfirmed requestのcopy／並行呼出しをone-shot leaseで最初の1回だけ実行権取得可能にする。cancel済みまたはstream破棄が先行したrequestでは実行権取得またはproviderの外部副作用を拒否する
- provider能力はstreaming、cancellation、usage reportingを必須とする。streamingは非同期event streamを表し、部分的な置換本文を必須にはしない。`outputTokens`は必須かつ非負、`inputTokens`は省略可能だが存在時は非負とし、usageを費用capそのものとして扱わない
- domainはexecutor呼出しからのwall timeout、app-provided input、raw response、delta、decoded resultの文字／UTF-8 byte、注意点件数、usageを強制し、細切れdeltaをboundedに集約する。provider descriptorは不変O(1)とし、実providerのupstream token parameter、wire event／process resource limitはadapter Gateで別途保証する
- provider adapterはdomain protocolへ適合し、SDK固有型やHTTP／process errorを公開APIへ漏らさない
- domain自身はretry、fallback、provider選択、永続化、本文適用を行わない
- 初期のprompt、response、diffはmemory onlyで、`.novelpkg`やsnapshotを変更しない

EditorKitはopaque selection transaction、surface／本文／選択revision、UTF-16 range／exact source、one-shot／1 Undo適用を所有し、NovelAIから`NSTextView`へ触れない。App側はdocument session／episode／source digestをconfirmed outboundと別のmemory-only contextへ保持し、送信前／適用前のstale判定へ結合する。Codex Node sidecarとOpenRouterは別adapterとし、AppDependenciesが利用者の明示選択に基づいて一つだけを注入する。

App側にはprovider-neutralな校正operation orchestratorを一つだけ置き、Codex SDK経路とAPI経路で同じ選択snapshot、exact preview、送信確認、進行／cancel、結果、diff、stale、Copy、明示Applyの状態機械とUIを使う。process／HTTP、credential、model設定、保持情報、typed error mappingだけをadapterごとに分離する。詳細は[AI_INTEGRATION.md](AI_INTEGRATION.md)を正とする(D-043 / D-046)。

## 5. App側の設計

### 5.1 AppDependencies

依存関係を組み立てる。例: `NovelpkgRepository`、将来のAIクライアント、設定ストア。
App本体は具象クラスを直接作りすぎない。

AI adapterを組み立てるPRでは、CodexとOpenRouterを別の具象依存として扱い、利用者が選んだ一つだけをprovider-neutral protocolへ注入する。失敗時に別providerを自動生成・自動選択しない。D-046の個人用Experimental Gateを通した実providerは別app target／scheme `FUMINIWAExperimental`へ登録できるが、D-043の全sidecar／配布Gateと公開Releaseの承認が未完了の間は通常の`FUMINIWA` app targetへprovider target／resource／UIを登録しない。

書き出しはAppStateの保存依存ではなく `ExportPresenter` の実行境界へ注入する。保存パネル確定後に `AppState.document` を値スナップショットとして一度だけ取得し、`NovelExporter` の生成／書込みをMainActor外で実行する。

### 5.2 AppState

アプリ全体の状態を管理する。

```swift
@Observable
final class AppState {
    var document: NovelDocument
    var startupState: AppStartupState
    var selectedChapterID: ChapterID?
    var selectedEpisodeID: EpisodeID?
    var workspaceSelection: WorkspaceSelection
    var outlinePresentation: OutlinePresentationState
}
```

主な責務:

- 現在開いている作品
- 起動の`loading` / `ready` / `recovery`状態と、安全な再試行・別作品選択・明示的新規作成
- 現在作品の保存完了後にだけ新規作成・別 URL 読み込み・別名保存を確定するトランザクション
- 選択中の章ID / 話ID
- 選択中のProject SidebarセクションとOutline項目
- Outline検索バーの表示状態
- 選択中章 / 話の取得
- 選択中話本文・メモの更新
- 最近開いた作品の記録(ファイルパス)
- `Cmd+S`、自動保存、終了前保存を同じ`DocumentSaveCoordinator`へ合流させる明示保存

章選択は `ChapterID` で管理する。`Chapter` オブジェクトそのものを選択状態として持たない。

UIの正は `WorkspaceSelection`(Project Sidebar + Outline)に寄せる。旧3モード制で使った `AppMode` は Phase 4.5-1 で撤去済みであり、新UIへ再導入しない。

### 5.3 ContentView

画面構成を担当する。

```text
ContentView
├── loading: StartupLoadingView
├── recovery: StartupRecoveryView
└── ready: NovelWorkbenchView
    ├── NavigationSplitView
    │   ├── ProjectSidebarView
    │   ├── content(Outline / セクション一覧)
    │   │   └── OutlineContainerView / CharacterListView / …
    │   └── detail(Editor / セクション詳細)
    │       └── EditorPaneView / CharacterDetailView / …
    └── WorkbenchStatusBarView
```

主な操作: Project Sidebar のセクション選択 / Outline での章・話選択 / 章追加 / 章並べ替え / 本文編集 / 検索 / 明示保存 / 自動保存

新UIの画面構成は D-021 / D-024 / D-032 / D-040 と [UIDESIGN.md](UIDESIGN.md) / [TOOLBAR.md](TOOLBAR.md) / [UIREFRESH.md](UIREFRESH.md) が正である。Outlineを持つ執筆・プロット・登場人物・世界観・資料は、左から Project Sidebar、Outline(content)、Detail を `NavigationSplitView` で並べる。作品情報・設定はOutlineを置かず、Project SidebarとDetailだけの2列で表示する。通常Releaseの下部は保存状態・文字数・検索結果だけを示すstatus barとし、未実装AIのplaceholderや開閉導線を置かない。別app target／scheme `FUMINIWAExperimental`では、実providerへ接続済みの選択範囲校正UIだけを同じWorkbenchへ追加できる。本文執筆では content に章一覧、detail に本文を出す。

起動中は編集可能なWorkbenchを生成しない。前回作品またはFinder指定作品を開けなかった場合はRecovery画面で止まり、recent URLとディスク上の作品を保持したまま、再試行・Finder表示・別作品選択・明示的新規作成を提示する(D-039)。

`ContentView` 自体は肥大化させず、状態の受け渡しと共通コマンドの入口に留める。本文エディタの実体は従来どおり EditorKit の `EditorView` であり、App側の `EditorPaneView` は本文と選択反映を担当する。

上部 chrome は D-024 と [TOOLBAR.md](TOOLBAR.md) を正とする。Toolbar-1 で3列基盤と標準 Sidebar 開閉・Outline の作品名 + 章数を成立させ、Toolbar-2 で `EditorTopBarView` と展開式検索行を撤去し、編集操作を macOS 標準の toolbar カスタマイズ対象にした。保存状態は下部 status bar、選択章名は Outline を正とし、上部で重複表示しない。

補足: v1 では `DocumentGroup`(ドキュメントベースApp)は使わず、単一ウィンドウ + 明示的な Repository 構成とする。オートセーブやバージョン管理を自前で持つ代わりに、ウィンドウ管理・状態管理がシンプルになる。複数作品対応の際に再評価する。

## 6. 初期機能要件

### 6.1 作品管理

- 起動時は`loading`で最近の作品またはFinder指定作品を読み込み、成功後だけ`ready`にする
- 読み込みに失敗したら新規作品へ自動fallbackせず`recovery`にし、失敗したURLとrecent記録を保持する
- 最近の作品がない場合だけ新規作品を先に保存し、保存成功後に現在作品として採用する
- Recoveryからの再試行・別作品選択・明示的新規作成を提供する
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
- `Cmd+S`は自動保存・終了前保存と同じrevision直列化経路で直ちに保存する。`ready`でない間は保存しない
- スナップショットの保存・一覧・復元を提供し、復元前に現在状態を別snapshotへ退避する
- 作品の開く／新規／別名保存／復元／資料操作はFIFOに直列化する。現在作品に属する非同期操作は呼び出し時のsession tokenを保持し、待機中に作品・URL・世代が変わった場合は別作品へ適用せず中止する(D-041)
- 別名保存のURL切替、snapshot復元の退避・書き戻し・installは通常保存と同じ排他境界で確定する。lock順はdocument operation gate → revision保存直列化とし、逆順取得しない
- 作品切替・別名保存・復元・終了前は、フォームと表示中のIME変換を旧作品へ確定してモデルへ同期し、最終保存／installまでWorkbench全体の変更を停止する。同じ子IDを持つ複製作品も本文install世代でEditorを再読込し、本文が変わらない別名保存ではcaret／Undoを維持する。終了要求後は新しい作品操作を受け付けない(D-041)
- 削除確認やsnapshot／資料の一覧項目は、表示時のsession tokenを対象値と一体で保持する。同じIDを持つ複製作品へ古い確認を適用しない

### 6.5 世界観ノート

- ノート一覧を表示し、追加・選択・並べ替え・削除できる
- 各ノートはタイトルと本文を持つ
- 本文は `EditorView` で編集し、`world.json` + `world-notes/<WorldNoteID>.md` に保存する
- Phase 5 v1 の出力対象には含めない(D-032)

## 7. 将来機能

### 7.1 検索

作品内検索 / 話内検索 / 検索結果ジャンプ / ハイライト表示

### 7.2 キャラクター管理

名前 / ふりがな / メモ / 関係性 / 登場章 / AI用キャラクター要約

### 7.3 プロット管理

シーンカード / 時系列 / フラグ管理 / 未回収伏線リスト / 章との紐付け

### 7.4 書き出し

現在利用可能な形式はプレーンテキスト / Markdown / EPUB 3。PDFは未実装のまま公開UIへ出さず、実装面の公開Gateの後にAIとは独立して技術的な受け入れ条件を定める(D-037 / D-040 / D-042)。

書き出しは `.novelpkg` の内部構造を読まない独立した `NovelExport` 機能として実装する。入力は `NovelDocument` の不変スナップショットだけとし、本文・作品名・章名・話名だけを対象にする。TXT / Markdown / EPUBは同じ共通原稿展開を使い、生成物を同じ親の一時ファイルへ完成させてから置き換える。EPUBは横書きの最小仕様に留め、画像埋め込み・縦書きは対象外とする。Phase 6.5のPDFもこの境界を再利用する。詳細な仕様は [PHASE5.md](PHASE5.md) を正とする。

### 7.5 AI支援

AI機能はアプリ本体から独立したFeatureとして扱う。最初の機能は、Editorで利用者が明示選択した範囲だけを送る校正案である。章の要約、矛盾検出、口調／伏線チェック、続きを含む生成は、この境界が安全に成立した後の別機能とする。

方針:

- AIは任意機能とし、アカウント、API key、ネットワーク、providerなしで執筆／保存／書き出しを完結できるようにする
- version付きinstruction ID、`selected_text`を未信頼データとして扱う固定指示、exact selected text、adapterがそのまま渡す単一`applicationPrompt`、version付きexact response schema、provider、model、送信範囲、技術的に確認した保持／学習利用情報をrequestごとにpreviewし、明示確認なしに送らない。instruction／schema変更時はIDを更新して確認を取り直す
- 送信中も本文編集をブロックせず、cancelとtyped errorを提供する。AI失敗時も原文と保存機能を維持する
- 結果は初期版ではmemory onlyとし、`.novelpkg`、snapshot、UserDefaults、通常ログへ保存しない。ただしprovider／SDK側の履歴非保持を意味しない
- 結果を自動適用せず、局所diffを確認した明示操作だけをEditorKit commandとして1 Undo単位で反映する
- document session、editor surface、episode、UTF-16範囲、source textのいずれかが変わった結果はstaleとし、現在選択への読み替えや本文検索による再束縛をせず適用を拒否する
- 最初の実providerはCodex SDKとし、続くHTTP API adapterの第一候補をOpenRouterとする。両者は独立adapterとし、provider間およびOpenRouter内の自動fallbackを行わない
- CodexとOpenRouterは同じprovider-neutralなoperation orchestratorとUIを使う。選択snapshot、preview、確認、cancel、diff、stale、Copy、Applyを共有し、process／HTTP、credential、model設定、保持情報、errorだけをadapterごとに分離する
- providerはstreaming、cancellation、usage reportingを必須とし、raw structured outputをdomainでstrict decodeする。usageは`outputTokens`必須、`inputTokens`は不明なら省略可能とし、いずれも存在値は非負に限定する。usageは事後報告であり費用上限そのものではない
- domain executorはprovider descriptor一致とconfirmationのone-shot実行権を強制する。取消済み／stream破棄後はproviderの実行権または最初の外部副作用を拒否し、再試行は新しいpreviewと確認から始める
- CodexはSwift-native SDKでないため、provider実装／更新PRごとにreviewしたstable non-alpha TypeScript SDKをsemver rangeなしでexact pinしたNode sidecarを候補とする。2026-08-09の調査baselineは`0.147.0`である。B3ではarm64固定21-file packagerとExperimental native manifest verifierをidentity candidateとして実装し、B4-Aではcandidate生成から独立したempty production catalog付きapproval契約を固定した。B4-Bではcanonical raw path／`realpath`／`F_GETPATH`、owner／mode／`nlink`／size／SHA-256、strict thin／fat Mach-O、no-network Security validity／requested architecture別CDHashを512 MiB上限で観測する非実行Experimental native inspectorを追加した。B4-Cでは固定argv／empty environment／`/private/var/empty`／null stdioでchildを`POSIX_SPAWN_START_SUSPENDED`起動し、actual PIDのprocess／dynamic code identityを照合するExperimental-only probeを追加した(D-052)。成功時もresumeせず`SIGKILL` + direct `waitpid`で回収し、architecture／CDHashの非authority観測だけを返す。B4-DではExperimental-only／mock-onlyのabstract interactive transportを追加し、content-freeに開いたfresh 1-request channelへ`hello`だけを書き、exact request／runtimeの単独`ready`とdecoder frame boundaryを照合した後にだけexact sealed `start`を書くsequencing契約を固定した(D-053)。応答は`started` → 単一terminal → EOFを必須とし、terminal後は最大1秒のEOF drainでduplicate／late／partial／missing EOFをfail-closedにする。production catalogは空のままで、具体production channel／factory／callsite、process／Node／SDK／CLI／network／key／実原稿は0件。B4-C childはresumeされずB4-Dへ変換されていないため、これを実runtime B4-Dの完了／GOと扱わない。candidate／self manifest／B4-B／B4-C observation／local probeを自動承認せず、anti-rollbackも未実装である。same-uid外部`SIGCONT`拒否、B4-B SHA／approvalとの結合、Node version、complete inventory、immutable verify-to-use、OS-level隔離は未達である。次のB4-Eでclosed linker／native broker／helperとapproval／identity／OS-level read／exec隔離を結合する。個人用Experimentalでもrequest専用empty cwd + `skipGitRepoCheck: true`／専用`CODEX_HOME`、environment allowlist、Keychain、OS-level file隔離、cancel後のprocess tree回収は緩めない。arm64／x86_64、bundling、nested signing／notarizationは公開Release Gateへ延期する。実repositoryや検査回避用の偽Git repositoryをcwdにしない
- 利用中Codex SDKにtool完全無効化やupstream output token capがなければ、Experimental UIで未保証と明示し、FUMINIWA側のresource limitを代替の上流capと表現しない。公開Releaseでは未達Gateとして残す
- 公開TypeScript SDKにephemeral thread optionが確認できないため、「履歴を保存しない」「zero retention」と主張しない
- provider／serviceの保持期間、SDK／CLI local artifactの場所・範囲・保持期間、providerの料金単位とrequest上限の表示根拠は、確認できた値と未保証を区別して送信前に示す
- 別app target／scheme `FUMINIWAExperimental`だけが実装済みAI UIを表示できる。通常の`FUMINIWA` app targetではprovider target／artifactとpanel、入力欄、状態、設定、ショートカットをbuild時に除外する(D-040 / D-043 / D-046)

request state、snapshot、provider／sidecar Gate、保存範囲、PR分割は[AI_INTEGRATION.md](AI_INTEGRATION.md)を正とする。

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

- Project Sidebar(作品情報 / 執筆 / プロット / 登場人物 / 世界観 / 資料 / 設定)
- Outline(原稿・章・シーン一覧、文字数、更新状態、ドラッグ並び替え、スクロール連動検索)
- Editor Pane(広い本文領域、章タイトル、検索、履歴、プレビュー、保存状態)
- AI Assistant Panel(下部開閉パネル + collapsed status bar。履歴上は実装済みだが、未実装機能を先出ししないD-040により出荷UIから撤去)
- 旧3モード制と右インスペクタ中心の導線を撤去

### Phase 4.5: 安定化・作品ライフサイクル

詳細なサブフェーズと完了条件は **[PHASE5.md](PHASE5.md)** を参照。

- 保存状態の可視化と保存失敗時の再試行導線
- 新規作品 / 開く… / 別名で保存… / Finder で表示
- スナップショットの復元導線と、添付・スナップショットがある作品の保存性能基準

### Phase 5: 出力

詳細なサブフェーズと出力仕様は **[PHASE5.md](PHASE5.md)** を参照。

- `NovelExport`(NovelCore のみに依存)を追加
- プレーンテキスト / Markdown / EPUB 3出力
- ネイティブ保存パネル、進捗、失敗・キャンセル表示

### 商業化基盤: Product Trust / Package Safety / Release

- **対象範囲**: 実装・機能・UI/UX・データ安全・性能・アクセシビリティ・互換性・ビルド／配布技術だけを扱う。価格、法務、販促、決済、事業運用は明示依頼がない限り対象外(D-042)
- **実装済み**: ふみにわ / FUMINIWAへの改名と旧設定移行(D-038)、Safe Launch(D-039)、参照payloadのvalid UTF-8検査、明示的な`Cmd+S`、未実装AIの非表示、既定のシステム外観追従と明示的なLight／Dark選択(D-040 / D-044)、起動／作品ライフサイクルの競合防止(D-041)、横一行で行全体を開閉できる章Disclosure(D-045)
- **AIの現在地**: `NovelAI`、EditorKit selection transaction、App-level local context、fake provider、provider-neutralな共有UI、`FUMINIWAExperimental` target分離、Codex sidecar v1、canonical deployment manifest v1、exact SDK 0.147.0の合成CLI capture、Darwin native process supervisor、arm64固定21-file packager、Experimental native manifest verifier、B4-A compile-time approval契約、B4-B非実行exact Node inspector、B4-C probe-only suspended actual-process identity、B4-D Experimental-only／mock-only abstract interactive transport sequencingまで実装済み。B4-Dはcontent-free factory、fresh one-request class-bound channel、run開始時のabsolute request deadline、独立30秒以下のattestation timeout、単独`ready`のexact照合後だけのsealed `start`、`started` → 単一terminal → EOF、terminal後最大1秒のEOF drain、cancel／timeout first-wins、global live-channel reuse拒否、cleanup安全error優先とraw error redactionを合成54 testで固定し、5 suites 54/54、Experimental全体205/205を通した。ただし具体production channel／factory／callsiteは0件、process／Node／SDK／CLI／network／key／実原稿も0件で、B4-C childはresumeもtransportへの変換もされていない。production catalogは意図的に空で、承認済みcandidate／Node／SDK／CLIと実行経路は0件。Node version、complete loaded inventory、immutable verify-to-use、Keychain、OS-level隔離、parent death後の回収は未実装であり、これは実runtime B4-D完了／GOではない(D-043 / D-046〜D-053)
- **公開Releaseの次**: Package Validator Gate。duplicate ID／不正参照、symlink、resource limit、孤児payloadの保全、修復コピー、保存前検証を一単位として扱う。外部変更／競合検出は続く独立Gateにする
- **実装面で残るGate**: AppIcon、Developer ID署名・公証済み成果物、更新機構、実機／アクセシビリティQA。現段階を実装面の公開準備完了とは扱わない

### Phase 6: AI支援

- **6-0（純粋domain、完了）**: `NovelAI`のprovider-neutralなdraft／instruction IDと単一`applicationPrompt`／response schema IDとexact schemaを持つpreview／provider・purpose・budget・input countとともに`AIApplicationPayload`を封印したone-shot confirmed outbound、domain所有executor、raw structured outputのstrict decode、provider descriptor、budget、result／error、event stream protocol、決定論的fake。local identity、stale判定、network、process、UI、`.novelpkg`変更なし
- **6-1（Editor bridge、完了）**: EditorKitのopaque selection transaction、surface／本文／選択revision、UTF-16 range／exact source、one-shot／1 Undo適用と、providerへ渡さないApp-level document session／episode／source digestを結合。送信前／適用前staleをfakeで固定
- **6-2（共有Experimental UI、完了）**: provider-neutralなoperation orchestratorと、exact preview、明示確認、cancel、diff、stale、Copy、明示Applyからなる一つのUIをfake providerで接続。別app target／scheme／bundle／保存root `FUMINIWAExperimental`だけに含める
- **6-3（Codex SDK route、B4-D abstract interactive sequencing完了）**: fixed protocol／manifest、SDK 0.147.0合成capture、Darwin supervisor、B3 packager／verifier、B4-A empty approval contract、B4-B非実行Node inspector、B4-C suspended identity probeに加え、B4-DのExperimental-only／mock-only abstract transportを実装した。content-free factory openは引数を受けずfresh one-request class-bound channelを返し、process-wide weak registryがlive channelの再利用を拒否する。run entryでsealed payload budgetだけからabsolute request deadlineを固定し、独立したattestation timeout（最大30秒）内に`hello`だけを書き、exact request／runtimeの単独`ready`とframe boundaryを確認した後にだけexact sealed `start`を書く。`started` → 単一terminal → EOF、terminal後最大1秒のEOF drain、cancel／timeout first-wins、late delivery抑止、atomic channel cancellation、cleanup safety error優先／raw error redactionを固定した。ただし具体production channel／factory／callsite、process／Node／SDK／CLI／network／key／実原稿は0件で、production catalogは空、B4-C childはresumeもB4-Dへの変換もされていない。次はB4-E closed execution closure／native broker／helperとapproval／identity／OS-level read／exec隔離であり、残Gate完了まで`codex_sdk`と実送信はNO-GOである(D-047〜D-053)
- **6-4（API route）**: OpenRouterをCodexとは独立したnative HTTPS adapterとして追加し、同じUIへ登録する。provider間とOpenRouter routingの自動fallbackなしをfailure testで保証する
- **6-5（公開Release）**: Package Validator、External Change / Conflict、bundled universal runtime、hash、arm64／x86_64、nested signing、公証、実機／アクセシビリティQA後に別Decisionで公開AIの有効化を判断する。それまでは通常ReleaseへAI target／resource／UIを含めない
- 要約、講評、矛盾検出、伏線確認、続きの提案は選択範囲校正の安全境界を流用できるか個別に設計し、暗黙に送信範囲を拡張しない

### Phase 6.5: PDF出力

- 実装面の公開Gateの後に、AIとは独立した機能としてA4横書き・章／話見出し・ページ番号・日本語／絵文字対応のPDFを追加する(D-037 / D-040 / D-042)
- `NovelExport/Platform/macOS/` に実装を閉じ込め、既存の共通原稿展開とアトミック書込みを再利用する

### Phase 7: iOS / iPadOS 対応

- UITextView アダプタ(EditorKit/Platform/iOS)
- iOS アプリターゲット + UI 調整
- Phase 5 完了後に着手(需要次第で Phase 6 と順序入れ替え可 → D-013)

### Windows 並行トラック: WinUI 版

詳細な相互運用契約と実装順は **[CROSS_PLATFORM.md](CROSS_PLATFORM.md)** を正とする。

- W0: 言語非依存 schema、golden fixture、Windows 互換ファイル名規則を固定
- W1: C# の Core / `.novelpkg` Storage を実装し、macOS ↔ Windows の双方向 round-trip を成立させる
- W2: WinUI の最小執筆環境(日本語 IME / Undo / 自動保存を含む)
- W3: 執筆支援機能の parity
- W4: Export と Windows 配布

Windows トラックは macOS の商業化基盤 / Phase 6 / 7 と独立に進めてよい。ただし W1 より先に W0 を完了し、保存形式変更は両 OS の fixture を更新する。

## 9. 実装ルール

### 9.1 依存方向

```text
NovelApp (通常FUMINIWA)
├── NovelCore
├── NovelStorage
├── NovelExport
├── NovelUI
└── EditorKit

FUMINIWAExperimental
├── 通常NovelAppの共有source
├── Experimental専用App／AI UI
├── NovelAI
└── 通常FUMINIWAと同じ5 product

NovelStorage → NovelCore
NovelExport  → NovelCore
NovelUI     → NovelCore
EditorKit   → NovelCore
NovelAI     → 依存なし

NovelCore → 依存なし
```

NovelCore は絶対にUIやStorageに依存しない。

Windows 版も `App.WinUI → Core / Storage / Export / Editor`、`Storage / Export / Editor → Core`、`Core → 依存なし`という同じ意味の依存方向を C# project reference で強制する。Swift module と C# assembly の直接共有は前提にしない。

### 9.2 プラットフォーム依存

- AppKit / UIKit は EditorKit の Platform 配下に閉じ込める。将来のPDF用AppKit実装はNovelExportのPlatform配下に閉じ込める
- WinUI / Windows App SDK 型は Windows 側の App / Editor project に閉じ込め、Core・保存 schema・Export の公開 API に出さない
- Public API に `NSTextView` や `UITextView` を出さない
- iOS未実装部分はダミーViewでよい

### 9.3 保存形式

- 保存形式の詳細は NovelStorage に閉じ込める
- App側は `DocumentRepository` のみを見る
- `.novelpkg` の内部構造をApp側に漏らさない
- `.novelpkg` は macOS / Windows 間の公開互換境界とし、詳細は [CROSS_PLATFORM.md](CROSS_PLATFORM.md) を正とする
- schema 変更時は言語非依存 fixture を先に更新する。Windows reader / writerの実装前はschema・fixture・macOS検証、実装後はmacOS → Windows、Windows → macOS、双方向round-tripまでを完了条件にする
- OS 固有パス・bookmark・handle・UI設定を package に保存しない。未知ルート項目はどちらの writer も保持する

### 9.4 Editor拡張

- EditorView に直接機能を増やしすぎない
- 入力処理は EditorPlugin として追加する
- 純粋な判定ロジックは Rules 配下に置く
- 可能な限り単体テストを書く
- 編集中に外部から textStorage を書き換えない(テキスト所有権ルール)

### 9.5 クロスプラットフォーム実装

- 共有の単位は Swift のソースコードではなく、`.novelpkg` schema、ドメインの意味、純粋ロジックの入出力 fixture、Export 仕様、日本語 UI 用語とする
- macOS / Windows の UI は各 OS の慣習へ合わせる。SwiftUI の View 階層、AppKit toolbar、ショートカットを WinUI へ機械的に移植しない
- `NovelDocument`、Chapter / Episode の配列順、ID、空要素、保存トランザクション、テキスト所有権の意味は両 OS で一致させる
- Windows 版は同一リポジトリの `Windows/` 配下に置き、共通文書と fixture を一つの変更履歴で管理する
- OS 間互換に関わる PR は、両 OS のローカル検証結果を記録する。クラウド CI を使わない方針(D-014)は維持する

### 9.6 AI統合

- AIの純粋domainは`NovelAI`に置き、provider SDK、network、process、Keychain、SwiftUI、AppKit、EditorKitへ依存させない。初期domainはpreviewで封印したprompt／response schemaを含むconfirmed outboundだけをproviderへ渡し、local session／surface／range／pathを持たない
- 選択snapshotの取得と本文適用はApp / EditorKit bridgeへ閉じ込め、D-005のテキスト所有権とD-041のsession tokenを迂回しない
- 結果適用は同じdocument session、editor surface、episode、UTF-16範囲、exact sourceの一致を必要とし、staleな結果を現在選択へ再束縛しない
- provider adapterはCodexとOpenRouterで分離し、失敗時の自動fallbackを実装しない
- provider-neutralなoperation orchestratorとUIは一つだけとし、Codex SDKとOpenRouter APIでsnapshot、preview、確認、cancel、diff、stale、Copy、Applyの実装を分岐させない
- provider adapterはconfirmed prompt／schemaを追記・再構築せず、実送信直前のSDK／HTTP request captureでhidden追加がないことを検証する。fakeはpreviewとsealed payloadの完全一致を検証する
- providerの不変descriptor照合とconfirmed requestのone-shot leaseはdomain executorで行い、adapter自身にstream生成や比較値の選択をさせない。adapterは外部副作用より先にcancellation handlerを登録する
- providerはstreaming／cancellation／usage reportingを必須とし、domainがraw structured outputをexact schemaでstrict decodeする。domain budgetに加え、adapterは利用可能なupstream maximum output token parameterとwire event／process limitを設定・検証する。Codex SDKにupstream capがないExperimental実行では未保証とpreviewへ明示し、local limitで代替できたと扱わない
- prompt、response、diff、provider設定で`.novelpkg` schemaを変更しない
- Codex sidecarの実装／配布条件は[AI_INTEGRATION.md](AI_INTEGRATION.md)6章を正とする。Experimental Gate未達なら個人用AI UIへ含めず、Public Gate未達なら通常Releaseへtarget、resource、UIを含めない

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

Phase 0 / 1 / 2 / 3 / 4 / 旧 Phase UI / Phase UI2 / Phase 4.5 / Toolbar-1 / Toolbar-2 / UI-FIX-1〜5 / UI-REV-1〜9 / UI-REF-1〜6 / UI-POL-1〜4 / Phase 5(TXT / Markdown / EPUB 3、macOSアプリ統合)は完了済み(→ 変更履歴)。商業化基盤のうちブランド移行、Safe Launch、参照payloadのvalid UTF-8検査、Product Truth / system appearance、起動／作品ライフサイクルの競合防止は実装済み(D-038〜D-041)。

一般公開を延期したため、直近の個人用AI実装は **Phase 6-3のCodex SDK sidecar隔離feasibility B4-E** である。B4-Dまでにpure domain、Editor transaction、共有orchestrator／UI、Experimental分離、sidecar protocol、canonical manifest v1、exact SDK 0.147.0の合成capture、Darwin supervisor、B3 packager／verifier、empty compile-time approval contract、非実行exact Node inspector、probe-only suspended actual-process identity、abstract mock interactive sequencingを完了した。B4-Dはcontent-free factory open、fresh one-request channel、単独`ready`照合後だけのsealed `start`、`started` → 単一terminal → EOF、first-wins cancellationとcleanup境界を合成で固定しただけで、具体production channel／factory／callsiteとprocess／Node／SDK／CLI／network／key／実原稿は0件である。B4-C childはactual identity観測後もresumeせず回収され、B4-D transportへ変換されない。production catalogは空で、candidate／self manifest／proposal／B4-B／B4-C observation／local probeを自動承認せず、anti-rollbackを実装済みとは扱わない。次はB4-Eでclosed execution closure／native broker／helperとapproval／actual identity／OS-level read／exec隔離を結合し、complete loaded artifact inventoryとimmutable verify-to-useを固定する。その後も監査済みlauncher／parent-death、専用cwd／`CODEX_HOME`、environment allowlist、memory／CPU／process limit、Keychainを実証し、全Gate後にCodex adapter、続いて独立したOpenRouter adapterを同じUIへ接続する(D-046〜D-053)。

公開Releaseの次Gateは引き続き **Package Validator Gate** である。duplicate ID／不正参照、package rootと既知pathのsymlink拒否、深さ・件数・byte数のresource limit、孤児payloadの隔離保全、元作品を直接変更しない修復コピー、置換前検証を共通の検証境界として設計・実装する。Finder移動や削除、同期サービス、別プロセスとの外部変更／競合検出は、責務と受け入れ条件を混ぜないよう続く独立Gateとする。完了後もAppIcon、Developer ID署名・公証、更新機構、locked Macを含む配布QAが残るため、Experimental AIの動作を実装面の公開準備完了とは表現しない。今後の「商業化」作業は実装・機能品質に限定する(D-042)。実装状況は [COMMERCIALIZATION_IMPLEMENTATION.md](COMMERCIALIZATION_IMPLEMENTATION.md) を参照。

D-043の原稿・送信安全契約は個人利用でも維持する。別app target／scheme `FUMINIWAExperimental`では実処理のあるAI UIを公開Gateより先に追加できるが、通常の`FUMINIWA` app targetはcompile／link／bundle時にproviderと入口を除外する。詳細は[AI_INTEGRATION.md](AI_INTEGRATION.md)を正とする。

Phase 5 の作品→章→話の配列順、空章・空話、空タイトル、改行の共通規則は [PHASE5.md](PHASE5.md) を正とする。UI-REV完了記録は [UIREVISION.md](UIREVISION.md)。上部 chrome の現行設計は [TOOLBAR.md](TOOLBAR.md) / D-032。

Windows 並行トラックは **W0「schema / golden fixture / portable filename 契約の固定」**から開始する。詳細と完了条件は [CROSS_PLATFORM.md](CROSS_PLATFORM.md) を正とし、W0完了後にWindows上でW1(Core + Storage)へ進む。

Phase UI2 の完了記録は **[UIDESIGN.md](UIDESIGN.md)**。現在の出荷UIは Project Sidebar / Outline / Editor と下部status barで構成し、当時のAI Assistant placeholderはD-040により撤去済みである。

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

### v0.68 (2026-08-09)

Codex content GateのB4-Dとして、Experimental限定／mock限定のabstract interactive transport sequencing契約を追加した(D-053、[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md))。

- 引数0のcontent-free factory openがfreshな1-request／class-bound channelを返す契約、open cancelのacknowledgement + join、fresh late channelのprocess-wide claim後cleanup、duplicateの先行owner非破壊、weak reuse registryを固定
- sealed payload budgetだけからrun entryでabsolute request deadlineを決め、独立したattestation timeoutを30秒以下に制限。`hello`だけを書き、exact request／runtimeの単独`ready`とdecoder frame boundaryの確認後にだけexact sealed `start`を書く
- `started` → 単一terminal → EOFを必須とし、request deadline前のterminal claim後は最大1秒のEOF drainを開始。duplicate／late／partial／missing EOFをfail-closedに拒否
- cancel／timeoutのfirst-wins、wire terminal後／delivery前のlocal cancelによるresult破棄とwire cancel 0件、optional cancel frame + I/O unblockをchannelのatomic cancellationに所有させる契約、finalizing中のcancelがI/Oを追加しない境界を固定
- cleanup安全errorを先行結果より優先し、raw channel／factory errorを分類codeへredact。同一transportの並行runとglobal live-channel reuseを拒否し、settled後のcancelはno-op
- 合成B4-D 5 suitesの54 testは54/54、`FUMINIWAExperimental`全体は205/205 pass。具象production channel／factory／callsite、process／Node／SDK／CLI／network／key／実原稿は0件
- production catalogは空のままで、B4-C childは一度もresumeされずB4-Dへ変換されない。これはtransport sequencing feasibilityであり、実runtime B4-Dの完了／GOではない
- 次はB4-E closed execution closure／native broker／helper + approval／identity／OS-level read／exec隔離。残Gate完了まで`codex_sdk`と実送信はNO-GO

### v0.67 (2026-08-09)

Codex runtime identityのB4-Cとして、Experimental限定のprobe-only suspended actual-process inspectorを追加した(D-052、[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md))。

- 固定argv／empty environment／`/private/var/empty`／null stdio／新PGIDで`POSIX_SPAWN_START_SUSPENDED`起動
- actual PIDのprocess identityとdynamic SecCode／no-network exact caller-supplied CDHash／非ad-hocを二重照合
- 成功時も`SIGCONT`せず`SIGKILL` + direct `waitpid`で回収し、architecture／CDHashの非authority値だけを返す。production catalogは空のまま
- timeoutはbest-effortのchild lifecycle境界でありasync hard return上限ではない。same-uid外部`SIGCONT`、mapped-vnode／in-place mutation、B4-B SHA／approval結合、loaded closure、OS隔離は未達
- 合成ad-hoc helperのconstructor／`main` marker 0 + 拒否／回収とOS署名helperの成功を検証。実Node／SDK／CLI／network／key／原稿は0件
- 次はB4-D interactive `hello` → `ready` → `start`、続いてB4-E closed execution closure。残Gate完了まで`codex_sdk`はNO-GO

### v0.66 (2026-08-09)

Codex runtime identityのB4-Bとして、非実行のexact Node native inspectorを追加した(D-051、[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md))。

- canonical raw path／`realpath`／`F_GETPATH`、regular file／owner／mode／`nlink`、size／SHA-256の安定観測を固定
- 512 MiB上限でthin 64-bit／fat32／fat64 Mach-Oのarchitecture／slice／load commandをstrict parse
- Security frameworkのstrict／all-architectures／no-network検証とrequested architecture別CDHashを観測するが、universal Mach-Oも含めinvalid／unsigned／unavailableも非authority値として扱う
- observationはpath／FD／launch capabilityを返さず、production catalogは空、spawn／SDK／CLI／network／key／原稿は0件
- 次はB4-C suspended actual-process identity、B4-D interactive transport、B4-E closed execution closure。Node version／same-user post-verify swap／complete inventory／immutable binding／OS隔離は未達で、`codex_sdk`はNO-GO

### v0.65 (2026-08-09)

Codex runtime identityのB4-Aとして、実行と分離したcompile-time approval契約を追加した(D-050、[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md))。

- `CodexRuntimeApprovalPolicy`、非authorityの`CodexRuntimeApprovalProposal`、private initializerを持つ`CodexApprovedRuntimeIdentity`とnested `ProductionCatalog`の境界を固定
- production catalogは意図的に空で、B3 candidate／self manifest／observed runtime／local probeからの自動昇格、lookup成功、launch capabilityは0件
- deployment candidateと8 inventory role、4 content identityを分離し、不正な組合せをfail-closedに検証
- policy generationだけではanti-rollbackを主張せず、通常`FUMINIWA` targetを変更しない
- process／SDK／CLI／network／key／原稿は使わない。次はB4-B exact Node inspector、B4-C suspended launch、B4-D interactive transport、B4-E closed execution closureで、`codex_sdk`はNO-GO

### v0.64 (2026-08-09)

Codex deployment identityのB3として、arm64固定allowlist packagerとExperimental native manifest verifierを追加した(D-049、[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md))。

- SDK／CLI 0.147.0とdarwin-arm64 packageのexact metadata／lock SRIを実行せず検査し、固定21 fileをroot 0700／directory 0755／file 0644または0755でreal copy
- source SHA-256とdestination canonical manifestを一致させ、resultはpath／capabilityを持たないcandidate digestだけ。self manifestは非authority
- destination作成後のfailureはrecursive cleanupせずtyped partial rootを保持し、既存destinationを変更／削除しない。partial rootは手動隔離／削除し、別の新規empty pathで再生成
- Swift verifierはNodeの278-byte oracleと一致し、filesystem type／mode、resource cap、content／inode／directory mutationをfail-closedに検出
- compile-time approved digest、exact Node、complete loaded inventory、immutable verify-to-use、実SDK／CLI／key／network／原稿は未実装。実送信と`codex_sdk` runtimeはNO-GO

### v0.63 (2026-08-09)

Codex sidecar外側のDarwin native process supervisorを合成helperだけで固定した(D-048、[`Sidecars/Codex/SUPERVISOR.md`](../Sidecars/Codex/SUPERVISOR.md))。

- `FUMINIWAExperimental`だけにactorを追加し、canonical absolute executable／cwd、exact argv／明示environmentを`posix_spawn`して新process groupを所有
- macOS 27の`pipe2` runtime probe、`CLOEXEC_DEFAULT`、stdin／stdout／stderr同時処理、stdin／stdout 512 KiB、stderr 16 KiBを固定。stderr内容はresultへ保持しない
- cancel／timeout／cap／自然exitのfirst-wins、TERM→grace→KILL、`waitid(WNOWAIT)` anchor、direct child `waitpid`、post-reap `ESRCH`を合成testで検証
- normal leader exit後のlive descendantを`lingeringDescendant`とし、grandchild reap、group脱出、appのSIGKILL／crash／power loss後cleanup、実SDK／CLI、credential、network、manifest verifier、OS-level隔離は未保証
- 実送信は引き続きNO-GO。次はallowlist packager／native verifier、exact Node、監査済みlauncher／parent-death境界、専用filesystem／environment／credential隔離

### v0.62 (2026-08-09)

Codex SDK 0.147.0の合成CLI captureとcanonical deployment manifest v1のNode primitiveを追加した(D-047、[AI_INTEGRATION.md](AI_INTEGRATION.md))。

- SDK／CLI packageをlockfileへexact pinし、実provider通信なしでargv、stdin、response schema temporary file、environment、usage、cancel、errorをcapture
- literal U+2028／U+2029を含む同じCLI出力がNode 22.23.1ではexact round-tripしNode 26.4.0ではSDK内部で分断される差、生stderr／error保持、direct childだけのAbortをNO-GO条件として固定
- 合成deployment treeのcanonical record、root digest、symlink／hardlink／危険mode／改ざん／resource limit拒否を固定
- 実配布rootのpackager、native verifier、launcher shim、process-group supervisor、credential、networkは未実装のため、実送信を引き続き禁止

### v0.61 (2026-08-09)

Codex sidecar protocol v1をNode／Swift mockで固定した(D-047、[AI_INTEGRATION.md](AI_INTEGRATION.md))。

- 原稿を含まない`hello`／`ready`でruntime identityを照合した後だけconfirmed payloadの`start`を許可
- UTF-8 LF framing、厳密field、frame／累計byte、JSON depth／surrogate／integer、budget上限を両peerでfail-closedに検証
- valid start後の`started` → 単一terminal、cancel race、duplicate／late terminal、EOFを決定論的にテスト
- 実instruction／schemaと合成選択だけをgolden fixtureへ使い、実原稿、credential、path、raw errorを除外
- protocol mockは実SDK／CLI接続、OS-level隔離、process tree回収、個人用送信Gateの完了を意味しない

### v0.60 (2026-08-09)

個人用Experimental AIの誤適用防止境界と共通fake UIを実装した(D-043 / D-046、[AI_INTEGRATION.md](AI_INTEGRATION.md))。

- document session／章／話／Editor transaction／source digestをproviderへ送らないApp local contextへ封印
- 送信前／適用前のstale検査、one-shot送信／適用、cancel後の遅延完了破棄、終了時runtime drainを決定論的にテスト
- exact preview、明示確認、進行／cancel、diff、stale、Copy、明示Applyを一つのprovider-neutral UIとしてfakeへ接続
- `FUMINIWAExperimental`を別target／scheme／bundle ID／既定保存rootに分離し、通常版への`NovelAI`／AI UI混入を生成projectで機械監査
- Experimentalは旧製品のrecent URL／設定を自動移行せず、既存作品は利用者が明示的に開く
- 次の個人用実装をCodex sidecar protocol／隔離feasibilityへ更新。実provider、Keychain、networkは未実装

### v0.59 (2026-08-09)

一般公開を延期し、個人用Experimental AIをCodex SDKから実装して同じUIへOpenRouter API経路を追加する方針へ変更した(D-046、[AI_INTEGRATION.md](AI_INTEGRATION.md))。

- 個人用`FUMINIWAExperimental` app target／schemeと通常の`FUMINIWA` app targetをbuild graphで分離
- Editor bridge → provider-neutralな共有orchestrator／UI → Codex SDK → OpenRouter APIの順へPhase 6を更新
- CodexとOpenRouterでsnapshot、exact preview、確認、cancel、diff、stale、Copy、Applyを共有し、自動fallbackを禁止
- 個人用ではdual architecture、bundling、署名／公証をUI開発の前提から外す一方、Keychain、file隔離、内容非ログ、process回収、artifact inventoryを維持
- Package ValidatorとExternal Change / Conflictは公開Release Gateとして維持

### v0.58 (2026-08-08)

章Disclosureの操作範囲と情報密度を改善し、アプリのchrome外観を利用者が選べるようにした(D-044 / D-045)。

- 章名・話数・文字数・現在行の保存状態を横一列へ集約し、章label全体を話一覧の開閉領域に変更
- 外観設定へ「システムに合わせる／ライト／ダーク」を追加し、メイン／設定ウィンドウへ即時反映・永続化
- 本文キャンバスの本文色・背景色はアプリ外観から独立した設定として維持

### v0.57 (2026-08-08)

AI統合をCodex SDK first / OpenRouter secondのprovider-neutralな純粋domainから始める技術契約を追加した(D-043、[AI_INTEGRATION.md](AI_INTEGRATION.md))。

- 最初の機能を選択範囲校正に限定し、exact preview、requestごとの明示確認、memory-only result、自動適用禁止、stale適用拒否を固定
- `NovelAI`をprovider／UI／Storage非依存のoutbound domain境界として追加し、初回PRをdraft／version付きinstruction IDと単一`applicationPrompt`／version付きexact response schemaのpreview／provider・purpose・budget・input countとともに封印するone-shot confirmed capability、raw structured outputのstrict decode、payload値型、protocol、fake、決定論的契約テストに限定。stale判定はlocal identityを持つ次のEditor bridgeへ分離
- Codexの署名済みNode sidecar候補にhash固定、request専用empty cwd + `skipGitRepoCheck: true`／`CODEX_HOME`、environment allowlist、Keychain、OS-level file隔離、process tree回収、両architecture、署名／公証Gateを設定
- OpenRouterを独立adapterとし、自動provider fallbackを禁止。`.novelpkg`は変更しない
- Package ValidatorとExternal Change / Conflictを先に出荷するD-040の順序を維持し、AI基盤／PoCだけを非出荷・UI非表示で並行可能とした

### v0.56 (2026-08-08)

今後の「商業化」作業を実装・機能品質へ限定し(D-042)、改名前のXcodeGen生成物によるビルド失敗を再発防止した。

- 価格、法務、販促、決済、事業運用を明示依頼がない限り開発ロードマップの対象外に変更
- 実装・機能・UI/UX・データ安全・性能・アクセシビリティ・互換性・ビルド／配布技術を継続対象として固定
- `Scripts/generate-project.sh`をXcodeGenの共通入口とし、旧`NovelWriter.xcodeproj`を安全に退避して`FUMINIWA.xcodeproj`を生成

### v0.55 (2026-08-08)

PRレビューで発見した起動と作品ライフサイクルの競合を、対象作品の固定を含めて解消した(D-041)。

- 同時bootstrapを一つの実行Taskへ合流し、初回I/O中のFinder openまで待ってから起動完了とする
- 開く／新規／別名保存／資料／snapshot／終了前保存をFIFOの高レベル操作境界へ集約
- 呼び出し元session tokenが古くなった復元・別名保存・資料操作等をRepository変更前に拒否
- 別名保存のURL切替とsnapshot復元のinstallを保存排他区間内で確定
- IME変換を旧作品へ確定してから入力を止め、終了要求後の作品操作を遮断
- 章／話／人物／プロット／伏線／世界観ノートの古い削除確認もsession tokenで拒否
- 復元×Finder open、旧snapshot要求×作品切替、別名保存中の編集／追記保存失敗を決定論的回帰テストで固定

### v0.54 (2026-08-07)

商業化基盤のSafe LaunchとProduct Truth方針を現行設計へ反映した(D-039 / D-040)。

- 起動をLoading / Ready / Recoveryの三状態にし、読込失敗時はrecent URLと原稿を変更しない
- manifest / world参照payloadと存在するメモにvalid UTF-8を要求し、空文字への黙示救済を停止
- 未実装AIのpanel・状態・`Cmd+J`を出荷UIから撤去し、下端を保存／文字数status barへ限定
- chromeはシステムLight／Darkへ追従し、本文キャンバス設定とは分離。`Cmd+S`を保存直列化へ接続
- 直近の次タスクをPackage Validator Gateへ変更し、残る配布・法務・サポートGateを明記

### v0.53 (2026-08-07)

製品名を「ふみにわ / FUMINIWA」へ変更し、外向きのブランドと既存作品の互換境界を分離した(D-038)。

- Xcode project / scheme / app bundle / executableを`FUMINIWA`、日本語表示名を「ふみにわ」へ変更
- 旧bundle domainのrecent URLとEditor設定をallowlist方式で移行し、旧作品は移動しない
- 新規作品の既定フォルダを`FUMINIWA`へ変更
- `.novelpkg` v1〜v3とNovelKit系ドメイン名、legacy toolbar IDは維持
- 同じ`.novelpkg`を「ふみにわ作品」として扱うUTType / Document Typesを追加

### v0.52 (2026-07-16)

Phase 5のTXT / Markdown / EPUB 3とmacOSアプリ統合を完了し、PDFをAI実装後へ延期した(D-037、[PHASE5.md](PHASE5.md))。

- `NovelExport`、共通原稿展開、アトミック書込み、TXT / Markdown / EPUB 3レンダラを追加
- Fileメニューと`workbench.export`から共通Presenterへ接続し、形式選択、保存パネル、非同期スナップショット書き出し、進捗／結果表示を追加
- PDFをPhase 6.5へ移し、直近の次タスクをPhase 6へ更新

### v0.51 (2026-07-16)

Windows / WinUI 版を前提にしたクロスプラットフォーム設計を追加(D-036、[CROSS_PLATFORM.md](CROSS_PLATFORM.md))。

- `.novelpkg` を macOS / Windows 間の公開互換境界として固定
- 共有対象を schema・fixture・純粋ロジック仕様とし、SwiftUI / AppKit と WinUI は OS ごとの実装に分離
- Windows 並行トラック W0〜W4、monorepo の `Windows/` 構成、双方向 round-trip 品質ゲートを追加
- Windows 禁止ファイル名、大小文字、UUID、UTF-8、ISO 8601、未知項目保持、保存失敗時の安全性を明文化

### v0.50 (2026-07-11)

UI-POL-4完了に伴い、Workbench toolbar を D-035 どおり再配置([UIPOLISH.md](UIPOLISH.md))。

- toolbar ID を `novelwriter.workbench.v3` へ版上げ
- 一覧追加(章・人物・ノート・資料)を Outline 上へ、話追加を Editor 左端へ移動
- 「この章」toolbar アイコンとペーン内の重複追加ボタンを撤去。世界観メニューを追加

### v0.49 (2026-07-11)

UI-POL-3完了に伴い、執筆アクセサリバーの視認性を改善([UIPOLISH.md](UIPOLISH.md))。

- `EditorAccessoryBar` のボタンを `.bordered` + `.controlSize(.small)` へ変更
- ラベルを `ルビ` / `傍点` に短縮。STYLE.md 8章に「…」省略の例外を追記

### v0.48 (2026-07-11)

UI-POL-2完了に伴い、傍点記法を D-034 どおり更新([UIPOLISH.md](UIPOLISH.md))。

- `EditorNotationRules.bouten` を1文字ずつの `｜字《・》` 方式へ変更
- 傍点ボタンを選択範囲の直接変換へ切り替え(選択なしは disabled)。ルビは従来どおり入力シート
- `EditorCommandSession.hasNonEmptySelection` と `MacTextAdapter` の選択変更通知で disabled 状態を同期

### v0.47 (2026-07-11)

UI-POL-1完了に伴い、自動字下げルールを D-033 どおり更新([UIPOLISH.md](UIPOLISH.md))。

- 旧 R2 を廃止し、改行時の常時字下げ(R1')へ変更
- IME確定後の鉤括弧字下げ解除(R5)を `IndentRules` / `MacTextAdapter` に追加
- DESIGN 4.5 の確定ルールを R1'/R3/R4/R5 へ同期

### v0.46 (2026-07-11)

- UI磨き上げ計画 [UIPOLISH.md](UIPOLISH.md)(UI-POL-1〜4)を追加し、Phase 5-1 の前に挿入(→ D-033: 常時字下げ + IME確定後の鉤括弧字下げ解除 / D-034: 傍点を1文字ずつのルビ点方式へ改訂 / D-035: ツールバー再配置)。4.5 の確定ルール改訂(R2廃止・R5新設)は UI-POL-1 実装時に反映する

### v0.45 (2026-07-11)

UI-REF-6完了に伴い、Workbench再調整の完了状態とPhase 5-1への移行先を各文書へ同期した(D-032、[UIREFRESH.md](UIREFRESH.md))。

- 現行Project Sidebarから廃止済みの「企画」表記を除去
- UI-REF-1〜6を完了として記録し、次タスクをPhase 5-1へ統一
- overview専用コードと旧世界観placeholderが残っていないことを確認
- 未使用の `WritingInspectorView` を削除し、資料一覧/詳細を `AttachmentModeView.swift` へ分離

### v0.44 (2026-07-11)

UI-REF-5完了に伴い、世界観ノートのWorkbench UIを実装(D-032、[UIREFRESH.md](UIREFRESH.md))。

- Outline 一覧（タイトル＋文字数）、追加・削除・並べ替え、確認付き削除
- Detail のタイトル入力と `EditorView` 本文編集（`WorldNoteID` キー）
- `AppState.selectedWorldNoteID` と自動保存接続

### v0.43 (2026-07-11)

UI-REF-4完了に伴い、世界観ノートのモデルと保存を追加(D-032、[UIREFRESH.md](UIREFRESH.md))。

- `WorldNoteID` / `WorldNote` / `NovelDocument.worldNotes` を NovelCore に追加
- `world.json` + `world-notes/<UUID>.md` を NovelStorage で読み書き。空一覧時は省略
- v1/v2/v3、スナップショット、別名保存のテストを追加

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
- 4.5 を確定ルール(R1' / R3 / R4 / R5)に更新。常時字下げ・会話文の字下げ解除・IME確定後処理・IMEガードが動作する状態
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
