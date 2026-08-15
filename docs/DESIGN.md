# ふみにわ 設計書 v0.94

> v0.1 をレビューし、承認した設計。変更点は末尾の「変更履歴」を参照。
> 個別の決定と未決事項は [DECISIONS.md](DECISIONS.md) に記録する。

> **D-079 current-code note (2026-08-16):** 本書のD-071〜D-076節に登場する
> `NovelSyncCloudKit`、iCloud、CKSyncEngine、旧runtimeの記述は履歴資料である。
> 現行targetからCloudKit adapter／entitlement／bootstrap／専用testを削除し、
> SQLite local canonical＋Rust Snapshot Sync＋Sign in with Appleだけを実行経路とする。

## 1. 目的

**ふみにわ（FUMINIWA）**は、長編・中編小説の執筆を支援する **macOS ファーストのマルチプラットフォーム小説執筆アプリ** である。
macOS 版を先行実装としつつ、iOS / iPadOS版と将来のWindows WinUI版でも同じ作品を、通信を待たず安全に編集・復元できることを製品要件とする。D-077により、通常編集の端末内正本はapp-private SQLite、byte payloadはcontent-addressed store、`.novelpkg`は検証済みImport／Export用portable artifactとする。保存と同じtransactionで作品全体のdense SnapshotとSyncIntentを確定し、workerが送信直前にSealedAttemptを作ってRust serverへ変更objectだけを非同期複製する。画面遷移／close／quitはremoteを待たず、通信復帰後に自動再開する。同じ論理entityが分岐した場合は、この端末／オンライン／両方を別作品として残す、の3択にし、時計で勝者を決めない。`.novelpkg`はImport／Export専用とし、旧CloudKit Note実装はアプリから利用しない。新規同期設計の正はD-077〜D-079と[SNAPSHOT_SYNC.md](SNAPSHOT_SYNC.md)である。

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
- iOS / iPadOS はPhase 7として着手し、Swiftの共有domain／保存／editor ruleを再利用しつつ端末別の適応UIを実装する(D-056)
- Windows 版は WinUI 3 + C# / .NET で別実装し、Swift ソースの直接共有ではなく schema・fixture・純粋ロジックの入出力仕様を共有する
- Device SyncはSQLiteのlocal commitを常に先に完了し、同じtransactionでimmutable whole-work SnapshotとSyncIntentを作る。workerはcurrent remoteを確認してSealedAttemptを固定し、Rust serverへのobject upload、head CAS、cursor pullをdocument gate外で自動再開する。起動、編集、autosave、画面遷移、close、quitを待たせない。物理転送はentity／attachment単位のcontent addressingとし、利用者にとっての同期・競合・履歴単位は1作品のままにする(D-077／D-079)
- 通常起動はSQLiteの単一作品棚から始め、WorkIDだけをidentityにする。local pathやDBを見せず、Finder / Open With／Files pickerは外部原本を直接編集せずImport→new WorkIDとする。local workはofflineで開き、remote-only workの初回取得だけonline＋account確認を必要とする。account未確認で作った作品を後から現れたaccountへautomatic adoptしない(D-063 / D-077)
- AppKit / UIKit などのプラットフォーム依存処理は EditorKit 内に閉じ込める
- NovelCore はプラットフォーム非依存の純粋なモデル層にする
- 通常保存はSQLite＋local CAS、portable受け渡しは`.novelpkg` v1〜v3を採用する。SQLite database自体を端末間で共有しない
- EditorView は肥大化させず、入力処理はプラグイン化する

### 2.2 技術スタック(決定事項)

- **macOS UI**: SwiftUI をアプリシェルに採用。ただし本文エディタの実体は AppKit の `NSTextView`(`NSViewRepresentable` 経由)。SwiftUI の `TextEditor` は日本語IME・長文性能・制御性の面で本用途に不適のため使用しない
- **iOS / iPadOS UI**: SwiftUIの適応シェル + UIKitの`UITextView`(`UIViewRepresentable`経由)。iPadは複数列、iPhoneは`NavigationStack`を基本とし、本文はTextKit 2、共有`IndentRules`、D-063のcloud library／app-private import / edit / export境界で実装する(→ [IOS.md](IOS.md), D-056 / D-063)
- **Windows UI (将来)**: WinUI 3 + C# / .NET。Windows 固有コードは `Windows/` 配下へ置き、macOS と同じ保存・ドメイン境界を対応する .NET class library で再実装する(→ [CROSS_PLATFORM.md](CROSS_PLATFORM.md), D-036)
- **テキストエンジン**: macOSの`NSTextView`とiOSの`UITextView`をTextKit 2で明示使用する(縦書き非対応が確定したため再評価不要 → D-012)。`layoutManager`への誤アクセスによるTextKit 1フォールバックを防ぐ
- **macOS配布**: GitHub Releases による直接配布。macOS App Sandbox は採用しない(→ D-011)。iOSの配布判断へこの非Sandbox決定を流用しない
- **最低ターゲット**: macOS 14、iOS / iPadOS 17(`@Observable`の要件 → D-007 / D-056)
- **Snapshot Sync（D-077／D-078／D-079）**: 端末内はSQLite＋CAS、remoteはRust HTTP API＋PostgreSQL＋S3互換object storeとする。autosave／lifecycle checkpointはcurrent state、immutable Snapshot、SyncIntentをatomicにcommitし、network workerが送信前にSealedAttemptを固定して自動再開する。expected `{generation, snapshotID}`によるhead CAS、operation receipt、cursor pull、3択Conflict、online history、attachment transferを共通protocolにする。v1はserver-readableでE2EEなし、Production認証はSign in with Appleを使う。旧CloudKit adapterは削除し、CloudKitを同期経路・entitlement・package migration sourceとして扱わない。公開endpointとquotaは技術既定を置き、Release NO-GOを維持する(→ [SNAPSHOT_SYNC.md](SNAPSHOT_SYNC.md), [AUTH.md](AUTH.md), D-077〜D-079)
- **テスト**: swift-testing(`@Test`)を使用
- **プロジェクト構成**: Xcode アプリプロジェクト + ローカル Swift Package(`NovelKit`)。NovelCore / NovelStorage / NovelExport / EditorKit / NovelUI / PreviewSupportに加え、Device SyncのOS非依存domainを持つ`NovelSync`、Mac／iOSで共有するlocal library状態・attestation・registry値型の`NovelLibrary`、SQLite canonical storeの`NovelLocalStore`、`NovelAuth`／`NovelAuthApple`、test専用の`NovelSyncTesting`を扱う。`NovelLibrary`はNovelCore／NovelSync（必要な保存検証はNovelStorage API境界）だけを参照し、SwiftUI／AppKit／UIKit／CloudKitへ依存しない。旧Apple adapterの記述は履歴であり、現行targetへ追加しない。AI provider targetはD-075で削除し、再開時は最新APIを別Decisionで再設計する
- **Xcodeプロジェクト生成**: XcodeGen(`project.yml` が正、`*.xcodeproj` はコミットしない → D-015)
- **AI支援構成**: 現行の通常版はprovider／networkへ接続せず、校正／アドバイス用promptをsystem clipboardへ明示コピーするだけである。EditorKitは将来の外部提案にも使える選択transaction・IME・stale・one-shot置換境界を保持する。停止中のExperimental provider／fake UI／sidecarはD-075で削除し、再開時は旧実装を自動再利用しない

## 3. モジュール構成

```text
FUMINIWA
├── NovelApp                     (Xcode アプリターゲット)
│   ├── AppDependencies.swift
│   ├── AppState.swift
│   └── ContentView.swift
│
├── NovelAppIOS                  (FUMINIWAIOS targetのiPhone / iPad source)
│   ├── iOS platform adapters
│   └── adaptive navigation shell
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
    ├── NovelLibrary              (共有local library状態／attestation／registry値型)
    ├── NovelSync                  (source実装済みのOS・transport非依存domain)
    ├── NovelLocalStore            (SQLite canonical store／CAS／Snapshot worker)
    ├── NovelAuth / NovelAuthApple (FUMINIWA session／Sign in with Apple)
    ├── NovelSyncTesting           (test専用fake。製品targetへlinkしない)
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
    │       ├── macOS
    │       │   └── MacTextAdapter.swift
    │       └── iOS
    │           └── IOSTextAdapter.swift
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

### 4.2 NovelLocalStore / NovelStorage

D-077の通常保存は、新しい`NovelLocalStore`境界でSQLite databaseとapp-private CASを所有する。1 local profileの作品棚、current entity pointer、immutable Snapshot、SyncIntent、SealedAttempt、Inbox、Conflict、migrationを1 transaction境界へまとめ、専用actorを唯一のwriterにする。Apple adapterはGRDBを採用し、WAL、foreign key、`synchronous=FULL`、対応環境の`fullfsync`、transactional schema migration、起動時integrity check、SQLite Online Backup APIによる世代backupを使い、migration／integrity失敗を空の新規作品へfallbackしない。大きいattachmentはCASへstream copy、hash／byte count read-back、same-volume renameした後だけSQLiteから参照する。network I/O中にDB transactionを保持しない。公開APIはURLではなくWorkIDを受ける`LocalWorkStore`、`WorkHistoryStore`、`WorkResourceStore`とし、`DocumentSaveCoordinator`のrevision coalescingはWorkID commitへ差し替えて維持する。

`NovelStorage`は`.novelpkg` v1〜v3のreader、Package Validator、Import／Export codec、golden fixtureを所有する。`.novelpkg` はフォルダ形式のportable packageであり、画像・資料などを追加しやすい。通常Appはこれをautosave先や同期working copyにせず、外部原本を変更しないImportと、committed Snapshotからのatomic Exportだけに使う。AIのprompt、response、diff、provider設定、SQLite schema、SyncIntent／SealedAttempt、account、server URLはpackageへ追加しない。

現行`NovelpkgRepository`／URL-based `DocumentRepository`はSQLite client cutoverまでの実装である。先に`PackageBackedWorkStore` adapterでAppをWorkID APIへ移し、次にSQLite実装へ切り替える。1作品をpackageとSQLiteへ長期dual-writeしない。

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

本文エディタを提供する。macOSは`NSTextView`、Phase 7のiOS / iPadOSは`UITextView`をSwiftUIから利用し、どちらも薄いplatform adapterとして同じ`EditorView`公開APIと純粋ruleへ接続する。

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
- **R3**: 行の内容がちょうど `　`(全角スペース1つ)でキャレットが行末のとき `「` / `『` または対応する括弧ペアを入力 → 全角スペースを鉤括弧へ置き換える(会話文は字下げしない作法)。対応する括弧ペアでは、一括入力に加えて `「`→`」` / `『`→`』` と開閉が別々に届く通常入力も扱い、字下げの有無や文中位置にかかわらずキャレットを空ペア内へ置く
- **R4**: 日本語IME変換中は一切介入しない(IMEGuardPlugin がパイプライン先頭で保証)
- **R5**: IME確定後、その行が `　「` / `　『` / `　「」` / `　『』` のいずれかで、キャレットが開き括弧直後、括弧内、または括弧ペア直後にあるとき、行頭の全角スペースを削除する。IMEがmarked rangeを保持したまま `insertText` で確定する実経路も確定前のdelegateで記録する。対応する括弧ペアでは、字下げの有無や文中位置にかかわらずキャレットを括弧内へ置く。字下げ削除は undo 可能な正規置換経路で行う

対象は単一の `\n` 挿入(R1')と `「`/`」`/`『`/`』` または対応する括弧ペアの挿入(R3)のみ。閉じ括弧単体は、直前が対応する開き括弧の空ペアだけを対象にする。複数行ペースト等は素通し(将来の PasteSanitizerPlugin の領分)。R5はIME確定後のキャレット位置に基づく局所判定である。`NSRange` ⇄ `String.Index` の変換は `Range(_:in:)` 経由に閉じ込め、絵文字・サロゲートペアで壊れないことをテストで保証している。

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

**D-075で実装・targetを削除済み。以下は旧provider-neutral domain案の履歴であり、現行APIや将来実装の保持契約ではない。** 将来provider統合を再開する場合は、最新の公式API／SDKと現在の要件から新しいdomainを設計する。EditorKitの選択transaction（surface／本文／選択revision、UTF-16 range、exact source、one-shot apply）はproviderから独立して残す。

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

旧NovelAI案では、EditorKitがopaque selection transaction、surface／本文／選択revision、UTF-16 range／exact source、one-shot／1 Undo適用を所有し、providerから`NSTextView`へ触れない境界を定めていた。現在も残すのはこのEditorKitの安全境界だけで、provider／sidecar／adapterはD-075で削除済みである。

provider統合を再開する場合、App側にはprovider-neutralな校正operation orchestratorを一つだけ置き、Codex SDK経路とAPI経路で同じ選択snapshot、exact preview、送信確認、進行／cancel、結果、diff、stale、Copy、明示Applyの状態機械とUIを使う。process／HTTP、credential、model設定、保持情報、typed error mappingだけをadapterごとに分離する。現在の通常版clipboard支援はこのdomain／orchestratorを使わず、prompt生成とsystem clipboard writeだけを独立して持つ。詳細は[AI_INTEGRATION.md](AI_INTEGRATION.md)と[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)を正とする(D-043 / D-046 / D-054)。

### 4.10 NovelLibrary

D-077実装後はMac／iOSのSQLite作品棚で共有する値型とrepository protocolの境界を担当する。`NovelCore`／`NovelSync`に依存できるが、SwiftUI、AppKit、UIKit、CloudKit、HTTP、OS固有DB root、filesystem actorへ依存しない。SQLite table／row ID、`.novelpkg`の内部ファイル名やURLを公開APIへ漏らさず、local database I/Oは`NovelLocalStore`、portable read／writeは`NovelStorage`を通す。現行package attestation／JSON registry型は非破壊migrationが完了するまで互換境界として保持する。

- `LibraryRecordState`、`LocalPackageAttestation`、`LibraryRecord`、`LibraryInventory`、registryのエラーといった、OS間で意味が同じ状態・値・検証だけを持つ
- `accountQuarantined`／`legacyPreserved`を含む状態supersetを一つの実装で表し、Mac／iOSがenumやvalidationを複製しない
- `Codable`／`Hashable`／`Sendable`を基本とし、保存・読込・actor所有のI/Oは各Appへ注入する
- Mac／iOS固有のprivate root決定、filesystem actor、Files／Finder操作、CloudKit composition、legacy migration policyは各Appまたは`NovelSyncCloudKit`へ残す

### 4.11 NovelSync

D-077のSnapshot、canonical manifest、SyncIntent／SealedAttempt、head CAS、cursor、Divergence／Conflict、retentionに必要なOS / transport非依存domainを担当する。`NovelCore`へ依存してよいが、NovelStorage、SQLite具象、EditorKit、CloudKit、HTTP client、SwiftUI、AppKit、UIKitへ依存しない。Swift／Rust／将来C#のcanonical bytes、hash、resource上限、CAS resultをgolden fixtureで一致させる。

- 論理同期単位は1 WorkIDの作品全体、物理転送単位はcontent-addressed entity／attachment objectとする
- local commitとSyncIntent durabilityをremote I/Oより先に完了し、一度送ったSealedAttemptの同じoperation ID／requestをexact retryする。attemptはsource local generation／Snapshotを持ち、ackで通信中の新しいIntentをclearしない
- headは`{generation, snapshotID}`としてexpected head CASを行い、時計LWWを禁止する
- 共通baseから変更EntityKeyが非重複でもdependency closureと作品全体invariantを検証し、validな場合だけ2-parent Snapshotへ決定的に統合する。同一key、delete対同entity／参照変更、構造不整合は3択Conflictにし、本文内部の自動mergeはしない
- remoteはInboxへstageし、active editorへ注入せずD-041のsafe boundaryでmaterializeする
- current head、SealedAttempt、latest Intent、checkpoint replication、必要なlineage、未分類／未解決Divergence、未解決Conflict、effective-pinned Snapshotをretention／GCから保護する。manual／restore-beforeは作成時にpinするがreason自体を永久rootにせず、明示unpin後だけbucket／online payload release対象にする

以下のNote entity記述はSQLite client cutover前の現行D-071実装とmigration inputであり、新しいprotocolへ分岐を足さない。

- 同期対象は作品タイトル／あらすじ、章・話の構造／タイトル／配列順、本文／メモ、人物、プロット、伏線、世界観である。attachment／資料binary、snapshot履歴、端末設定、選択状態、path、cloud catalog／account／binding metadataを含めない
- live単位はentity record（`work`／`chapter`／`episode`／`character`／`plotCard`／`flag`／`worldNote`）である。作品全体の1 snapshotをwireの転送単位にしない
- D-063の`SyncWorkLibraryEntry`はWorkIDと表示用タイトルをidentity／hintとして持つ。document ID／title／structureをidentityにせず、work recordが無いworkを別端末で開けるentryにしない。whole revision ID／snapshot digestをdownloadの唯一条件にしない
- remote bootstrapは表示時のWorkIDを再検査し、durable pending-openの後にそのWorkIDのentity一式を取得してapp-private packageへ組み立てる。attachment／snapshot履歴／unknown root／端末設定を復元したと扱わない
- `NoteSyncWireProtocol.currentVersion = 1`はD-059 Episode wire v1、D-061 Work wire v1とは別namespaceで、同じversion番号を互換性の根拠にしない
- local mutationはFIFOで直列化し、network I/Oをlane外で行う。package保存後のdirty entity IDだけをpendingにし、通信中の追加入力を古い応答で上書きしない
- 衝突は同じentityのlocal dirtyとserver change tag不一致だけで検出する。3-way merge、時計LWW、自動winnerは定義しない。衝突したらこの端末／iCloud／両方を別作品として残す、を返す
- 通常UIへrevision／branch／merge／journal／leaseを出さない

D-059／D-060のEpisode本文Device Sync domainと、D-061のWork snapshot／revision／merger／file journalは実装履歴と互換資料として削除しない。ただし現行通常AppはNote経路へcutoverし、旧clientとの同時利用は相互の更新を観測できない。一般配布前に全端末更新を強制できるminimum client version fenceまたは明示migrationを実装・検証するまで出荷不可とし、mixed client安全性を主張しない。

通常Mac／iOSのproduction compositionは `workTransport: nil` とし、Work同期を組み立てない。`WorkSyncTransport` の注入は旧test／互換runtimeに限り、target分離が完了するまで履歴sourceを保持する（D-076 R5a）。

D-059／D-060 Episode trackとD-061 Work trackの保持契約は、DEVICE_SYNC.mdの履歴節を正とする。App側の論理順は **native editor → model → DocumentSaveCoordinatorによるpackage保存 → dirty set → remote pending** である。remote taskはEditor入力とlocal保存を待たせない。詳細は[DEVICE_SYNC.md](DEVICE_SYNC.md)を正とする。

### 4.12 NovelSyncCloudKit

現行Apple版Device Syncのplatform adapterであり、SQLite／Rust client cutover後は **read-only migration adapter** とする。private databaseのNote／legacy Work／Episode record、engine state、account fence、package外binding metadataとdirty setを正確に読み、local／remote／conflict候補を別Snapshotへ移す。D-077 clientからCloudKitへ新しいmutationを送らず、新serverと二重authorityにしない。旧sourceとdataはmigration、rollback、Export read-backが完了するまで削除しない。

以下はcutover前の現行runtime契約である。

D-071のlive経路では、`CKSyncEngine`にpending recordを登録し、batch providerからsave／deleteする。fetchしたmodification／deletionをdomainへ渡す。D-059のEpisode recordとD-061のWork control／revision asset／receiptを通常Appからwrite／decodeしない。CloudKit型、change tag、account token、asset、engine stateを`NovelSync`の公開API / wire / fixtureへ出さない。

account確認不能でも既存bindingのpackage外journalを開いてlocal保存できるようにし、remote transportだけを停止する。旧account scopeとのlive再確認が成功するまで旧account transportへ送らず、別accountへ旧revisionを送信しない。一時的なtransport／CloudKit unavailableはofflineとしてbootstrapを再試行し、no account／account変更／entitlement・設定不整合は設定確認として区別する。

CloudKit bootstrap、account、entitlementの確認に失敗しても、既存bindingはapp-private local metadataとjournal resolverへfallbackする。remote descriptorが得られない状態を同期可能と見なさず、local package／WAL／journalだけを進める。一時的なbootstrap unavailableではlocal-first編集を続けながら再試行する。unbound作品もlocal package編集を継続し、remote workへ暗黙bindingしない。

D-063のWork catalogはheadを持つremote workをMac／iPhone／iPad共通の「iCloudの作品」へ列挙し、利用者が選んだremote-only workのbootstrapに使う。`SyncWorkID`だけをidentityとし、`sourceDocumentID`、ordered structure digest、title一致は表示／continuity hintに限る。表示しただけでautomatic binding／downloadせず、選択時のexact headを再取得してからdurable pending-openへ進む。account identityを確認できない／変更した場合は旧remote row／titleをquarantineし、local registryだけから新accountへuploadしない。CloudKit型、change tag、account token、asset、engine stateを`NovelSync`の公開API / wire / fixtureへ出さない。

remote catalog cacheは最大1,088件（binding 1,024件＋unbound pending-open最大64件を覆う）にbounded化し、local-bound／pending workを優先する。refresh failureで既存cacheを空にせず、malformed remote controlは当該rowだけを隔離してvalid／local行を残す。以前確認済みsame account scopeの一時offlineではcached remote-only行を残してdownload不可にするが、accountRequired／unscoped／mismatchではlocal packageのないremote row／titleをquarantineする。cached local packageはpackage attestationが通る場合だけoffline openへ進める。

source実装、署名なしbuild、Simulator、fake / codec testは、Developer Program上のcontainer / App ID / capability / profile、CloudKit schema、同一accountの署名済みMac / iPhone実機を完了した証拠ではない。外部Gateは[DEVICE_SYNC.md](DEVICE_SYNC.md) 13章を正とする。

## 5. App側の設計

### 5.1 AppDependencies

依存関係を組み立てる。例: `NovelpkgRepository`、将来のAIクライアント、設定ストア。
App本体は具象クラスを直接作りすぎない。

AI adapterは現在組み立てない。再開時はCodex／OpenRouter等の候補を独立に評価し、利用者が選んだ一つだけをprovider-neutral boundaryへ注入する設計を新Decisionで定める。失敗時の自動fallback、通常targetへのprovider target／resource／UI登録は行わない。

書き出しはAppStateの保存依存ではなく `ExportPresenter` の実行境界へ注入する。保存パネル確定後に `AppState.document` を値スナップショットとして一度だけ取得し、`NovelExporter` の生成／書込みをMainActor外で実行する。

D-077のclient切替では、AppDependenciesが`LocalWorkStore`／`WorkHistoryStore`／`WorkResourceStore`、Snapshot domain、HTTP transport、background worker、portable package codecを組み立てる。AppState／`IOSDocumentStore`／EditorKitはSQLite handle、SQL、HTTP、PostgreSQL、S3型を直接扱わない。App層はnative capture、WorkID／session固定、local commit、safe materialization、短い3択だけを所有し、Intent／Attempt upload／pullをdocument gate外のworkerへ渡す。account／serverが不能でもnew／Import／edit／Snapshot／Exportをlocal-firstで完了する。`accountRequired`／unbound／different account中に作ったworkを後から現れたaccountへautomatic adoptせず、diagnostic logへ原稿、title、path、WorkIDを出さない。現行`NovelSyncCloudKit` compositionはmigration期間の旧runtimeとして別factoryへ隔離する。

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
- 起動の`loading` / `documentSelection` / `ready` / `recovery`状態と、Work catalog＋検証済みlocal registryをmergeした安全な作品選択・refresh・再試行・明示的新規／取込
- 新規／取込／remote-only openをsame-root stagingへ作り、portable read-backとWorkSnapshot attestation後にだけno-overwrite installするトランザクション
- current sessionをflushした後、active URL／session／WorkID／bindingを変えずに`.novelpkg`全体を検証済みExportするトランザクション
- 選択中の章ID / 話ID
- 選択中のProject SidebarセクションとOutline項目
- Outline検索バーの表示状態
- 選択中章 / 話の取得
- 選択中話本文・メモの更新
- 旧作品の明示Import／legacy recoveryに限るrecent path互換。D-063の通常library identityやstandard open対象には使わない
- `Cmd+S`、自動保存、終了前保存を同じ`DocumentSaveCoordinator`へ合流させる明示保存

章選択は `ChapterID` で管理する。`Chapter` オブジェクトそのものを選択状態として持たない。

UIの正は `WorkspaceSelection`(Project Sidebar + Outline)に寄せる。旧3モード制で使った `AppMode` は Phase 4.5-1 で撤去済みであり、新UIへ再導入しない。

### 5.3 ContentView

画面構成を担当する。

```text
ContentView
├── loading: StartupLoadingView
├── documentSelection: StartupDocumentSelectionView
├── recovery: StartupRecoveryView
└── ready: NovelWorkbenchView
    ├── local WorkSync recovery gate: StartupWorkSyncGateView / WorkConflictResolutionView
    ├── NavigationSplitView
    │   ├── ProjectSidebarView
    │   ├── content(Outline / セクション一覧)
    │   │   └── OutlineContainerView / CharacterListView / …
    │   └── detail(Editor / セクション詳細)
    │       └── EditorPaneView / CharacterDetailView / …
    └── WorkbenchStatusBarView
```

主な操作: Project Sidebar のセクション選択 / Outline での章・話選択 / 章追加 / 章並べ替え / 本文編集 / 検索 / 明示保存 / 自動保存

新UIの画面構成は D-021 / D-024 / D-032 / D-040 / D-061 / D-063 と [UIDESIGN.md](UIDESIGN.md) / [TOOLBAR.md](TOOLBAR.md) / [UIREFRESH.md](UIREFRESH.md) が正である。Outlineを持つ執筆・プロット・登場人物・世界観・資料は、左から Project Sidebar、Outline(content)、Detail を `NavigationSplitView` で並べる。作品情報・設定はOutlineを置かず、Project SidebarとDetailだけの2列で表示する。通常Releaseの下部status barは文字数・検索結果等の既存workspace情報に使えるが、Editorのlocal保存／同期状態はMac／iOSとも上部の小さな記号を正とし、下部と重複表示しない。provider処理のないAI panel、状態、送信導線を置かない。D-075のclipboard支援は実在する非通信機能なので、各章／話の操作と本文context menuに「校正用プロンプトをコピー」「アドバイス用プロンプトをコピー」を置いてよい。本文執筆では content に章一覧、detail に本文を出す。

macOSの通常起動は`loading`後に`documentSelection`へ入り、同じwindow内の1 paneに小さなアプリアイコン／名称、「作品を取り込む…」「新しい作品」、1つの「iCloudの作品」Listを表示する。Listはprivate CloudKitのWork catalogと検証済みapp-private registryをWorkIDでmergeし、local path／保存場所／Finder／recent detailを出さない。cached exact／local pendingはofflineでもlocal package attestation後に開き、remote-onlyはonline＋account確認後にexact headを再検査してからprivate stagingへdownloadする。Finder / Open Withも外部原本を直接開かず、Import→new WorkIDとする(D-063)。

`loading`／`documentSelection`／`recovery`中は編集可能なWorkbenchを生成しない。chooserのcached work／remote-only／明示的新規／取込とRecovery再試行は、AppStateのactivation／install経路でlocal packageの検証を待つ。network／account／transport確認不能だけでは既存local copyの編集を止めない。remote-only downloadはonline＋live account scope確認を必須とするが、new／Importのlocal reserve→private package→registryはoffline／account未確認でも完了できる。選択work、download、import、新規作成を安全にinstallできなかった場合はRecoveryまたはwork単位のunavailableへ進み、外部原本、既存final、registry、current documentを変更しない。Recoveryにも内部working copy path／Finder入口を出さない(D-039 / D-063 / D-071)。

`ContentView` 自体は肥大化させず、状態の受け渡しと共通コマンドの入口に留める。本文エディタの実体は従来どおり EditorKit の `EditorView` であり、App側の `EditorPaneView` は本文と選択反映を担当する。

上部 chrome は D-024 / D-060 と [TOOLBAR.md](TOOLBAR.md) を正とする。Toolbar-1 で3列基盤と標準 Sidebar 開閉・Outline の作品名 + 章数を成立させ、Toolbar-2 で `EditorTopBarView` と展開式検索行を撤去し、編集操作を macOS 標準の toolbar カスタマイズ対象にした。D-060によりEditorの保存／同期状態だけは上部native toolbarの小さな記号へ置き、通常はチェック、同期中、offline、統合必要、設定確認を簡潔に表す。選択章名はOutlineを正とし、上部で重複表示しない。

補足: v1 では `DocumentGroup`(ドキュメントベースApp)は使わず、単一ウィンドウ + 明示的な Repository 構成とする。オートセーブやバージョン管理を自前で持つ代わりに、ウィンドウ管理・状態管理がシンプルになる。複数作品対応の際に再評価する。

iOS / iPadOSはD-057 / D-058の段階navigationを維持し、D-063によりroot作品棚を1つの「iCloudの作品」へ置き換える。作品棚は同時に複数作品を編集するdocument UIではなく、remote catalogとiOS private WorkID registryから現在作品を1つ選ぶ入口である。iPhoneは作品棚 → 作品ホーム → 作品情報／執筆／プロット／登場人物／世界観／資料／設定の各画面へ進む`NavigationStack`、iPadは同じ情報階層をProject Sidebar / Outline / Detailへ適応的に展開する。Files / iCloud Drive等は標準pickerからnew WorkIDの作業コピーへ取り込む入口だけを出し、外部原本や内部working-copy pathを独自一覧へ混ぜない。

D-063／D-071のDevice Syncもこのapp-private境界を使う。`.novelpkg`全体をcloud folderで同時編集せず、各端末の作業コピーを正本としてlocal-first保存する。作品タイトル／あらすじ、章・話構造／順序／タイトル、本文／メモ、人物、プロット、伏線、世界観をentity recordとして同期する。D-063はcatalog列挙を維持し、D-071のremote-only openはentity一式を初回downloadする。attachment／snapshot履歴／unknown root／端末設定は同期せず、完全backupと表示しない。競合は上部の小さな警告からこの端末／iCloud／両方を別作品として残す、へ進み、cloud review中もEditorを止めない。remoteをactive editorへ注入せず、安全な作品遷移境界でだけpackageへ入れる。詳細は[DEVICE_SYNC.md](DEVICE_SYNC.md)を正とする。

## 6. 初期機能要件

### 6.1 作品管理

- macOSの通常起動は`loading`の後にSQLiteから単一paneの`documentSelection`を即時表示し、作品、明示的新規、明示的Importから利用者が1 workを選ぶまでactive documentを切り替えない。remote catalog取得を棚表示の前提にしない
- 作品棚はWorkIDだけをidentityにし、document ID／title／structure／package名でdeduplicateしない。複製は新しいWorkIDとroot Snapshotを作る。remote work trash／hard deleteはSnapshot wire v1に含めず、後続Decisionで30日trashとoffline edit conflictを設計する
- local workはSQLite integrityとSnapshot参照を確認してofflineでも開く。remote-onlyはonline＋account確認後に表示時headを再検査し、Inbox staging→hash／size read-back→safe materialization後だけ`ready`にする
- Finder / Open Withと「作品を取り込む…」は外部原本を直接開かず、Package Validator後にnew WorkIDとしてSQLite＋CASへImportする。原本と旧visible packageを移動・削除・rekeyしない
- 「新しい作品」とImportはaccount／networkに依存せずlocal transactionを完了する。unboundならlocal-onlyとして編集可能にし、後から現れたaccountへ自動binding／publishしない。明示account bindingはD-078のopaque AccountID＋AccountFenceだけへ行い、Apple subject／emailを作品へ保存しない
- 読込／download／新規／取込に失敗しても新規作品へ自動fallbackせず、外部原本、既存private final、registry、current documentを変更しない。Recoveryに内部path／Finder入口を出さない
- chooser／RecoveryのactivationはAppStateでlocal WorkSync preflightを待つ。曖昧なlocal recovery中は通常mutationをgateするが、root recovery choiceは操作可能に保つ
- 通常保存はSQLite＋local CASへ行う。`.novelpkg`はImport／Exportだけに使う
- iOS / iPadOSはapp-private作品棚から1作品を選択して開ける。複数作品の同時編集は行わない

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
- 本文データへ空行を追加せず、本文末尾の下に常時96ptの執筆用表示余白を確保する
- プラグイン置換で改行や字下げを適用した後は、移動後のキャレットを明示的に可視範囲へスクロールする
- iOS Editorは重複する本文見出し／話タイトル入力／文字カウンターを常設せず、保存状態を上部toolbarへ置く。Mac EditorもD-060のlocal保存／同期状態だけは上部記号へ揃える。本文直下またはIME直上に`……` / `――` / `ルビ` / `傍点`の執筆補助バーを置き、`EditorCommandSession`から選択snapshotを取得してUndo可能な1置換として実行する(D-058 / D-060)

### 6.4 保存

- commit済み端末内正本はSQLite、attachment／大きいbyte payloadはlocal CASに保存する。SQLite databaseを同期／Exportしない
- 章順／話順はdomain配列の意味を保ったSQLite relationとしてcurrent Snapshotと同じtransactionで更新し、モデルへ別の`order` fieldを追加しない
- 自動保存は入力停止約2秒後にcurrent entity、dense Snapshot、SyncIntentを1 transactionでcommitする。SQLite commit成功だけを「この端末に保存済み」の根拠にする
- 話切替、画面遷移、background／sleep、window close、quit、`Cmd+S`はIME／formを確定してlocal checkpointを強制する。remote upload完了を待たず、通信復帰／次回起動でIntentまたはSealedAttemptを自動再開する
- スナップショットの保存・一覧・復元をlocal／onlineで提供する。local dense historyとonline acknowledged checkpointをTime Machine型で間引き、effective pin、current、SealedAttempt、latest Intent／checkpoint replication、Conflictを消さない。manual／復元前版は作成時にpinし、利用者がunpinした非current版だけonline payloadをlineage stubへ明示releaseできる。復元は過去内容を持つ新Snapshotを作り、現在headを直接巻き戻さない(D-074 / D-077)
- `.novelpkg` Exportはcommitted Snapshotから生成し、既知data、attachment、local保全した未知resourceをread-back後にatomic採用する。Import／Exportでcurrent session／WorkID／bindingを変えない
- 作品activation／新規／取込／remote bootstrap／package書出／復元／資料操作はFIFOに直列化する。現在作品に属する非同期操作は呼び出し時のsession tokenを保持し、待機中に作品・URL・世代が変わった場合は別作品へ適用せず中止する(D-041 / D-063)
- 新規／取込／remote bootstrapのprivate installとsnapshot復元の退避・書き戻しは通常保存と同じ排他境界で確定する。lock順はdocument operation gate → revision保存直列化とし、逆順取得しない。既存finalを別内容で上書きしない
- 作品切替・取込・remote bootstrap・復元・終了前は、フォームと表示中のIME変換を旧作品へ確定してモデルへ同期し、最終保存／installまでWorkbench全体の変更を停止する。同じ子IDを持つ別WorkIDも本文install世代でEditorを再読込する。package書出はcurrent sessionをflushするがactive URL／session／WorkID／binding／caret／Undoを変更しない。終了要求後は新しい作品操作を受け付けない(D-041 / D-063)
- 削除確認やsnapshot／資料の一覧項目は、表示時のsession tokenを対象値と一体で保持する。同じIDを持つ複製作品へ古い確認を適用しない

### 6.5 世界観ノート

- ノート一覧を表示し、追加・選択・並べ替え・削除できる
- 各ノートはタイトルと本文を持つ
- 本文は `EditorView` で編集し、`world.json` + `world-notes/<WorldNoteID>.md` に保存する
- Phase 5 v1 の出力対象には含めない(D-032)

## 7. 将来機能

話内検索ジャンプ、キャラクター最小管理と登場話ジャンプ、プロットカード／伏線、世界観ノート、資料、TXT / Markdown / EPUB 3、clipboard prompt は実装済みである。ここには未実装または延期だけを残す。

### 7.1 検索

作品全体検索／置換、本文ハイライトの永続表示は未実装。話内検索ジャンプは実装済み。

### 7.2 キャラクター管理

名前／ふりがな／メモ／登場話ジャンプは実装済み。関係性グラフと AI 用要約は未実装。

### 7.3 プロット管理

カードと伏線トラッカーは実装済み。時系列ビューは未実装。

### 7.4 書き出し

現在利用可能な原稿形式はプレーンテキスト / Markdown / EPUB 3。D-063により、portableな作品受け渡しとして`.novelpkg`も同じ「書き出す…」から選べる。PDFは未実装のまま公開UIへ出さず、実装面の公開Gateの後にAIとは独立して技術的な受け入れ条件を定める(D-037 / D-040 / D-042)。

書き出しは `.novelpkg` の内部構造を読まない独立した `NovelExport` 機能として実装する。入力は `NovelDocument` の不変スナップショットだけとし、本文・作品名・章名・話名だけを対象にする。TXT / Markdown / EPUBは同じ共通原稿展開を使い、生成物を同じ親の一時ファイルへ完成させてから置き換える。EPUBは横書きの最小仕様に留め、画像埋め込み・縦書きは対象外とする。Phase 6.5のPDFもこの境界を再利用する。詳細な仕様は [PHASE5.md](PHASE5.md) を正とする。

`.novelpkg`書出は`NovelExport` rendererではなく、`PortableDocumentPackageRepository`（`DocumentCopyingRepository`を含む）の別境界で現在のapp-private package全体を検証済みcopyする。現在Macに存在するattachment、snapshot履歴、非hidden未知root itemを保持し、destinationのread-backを終えてもactive URL、document session、recent、WorkID、binding、journalを変更しない。capabilityがなければ`DocumentRepository.save`へfallbackしない。remote bootstrapはWorkSnapshotしか取得しないため、別端末から未転送の資料／snapshotまでpackage exportに含まれるとは主張しない。

### 7.5 AI支援

AI支援は任意機能とし、アカウント、API key、ネットワーク、providerなしで執筆／保存／書き出しを完結できるようにする。D-054により、現在の通常版ではFUMINIWAがAIを実行するのではなく、利用者が任意のAI chatへ手動で渡すplain text promptをsystem clipboardへコピーする。

現在の方針:

- purposeは「校正」と「アドバイス」、scopeはIME確定済みの本文選択、1話、1章とする
- 選択scopeはexact non-empty selectionだけ、話scopeは話タイトル／本文だけ、章scopeは章タイトルと配列順の各話タイトル／本文だけを含む
- 作品名、あらすじ、メモ、人物、プロット、伏線、世界観、資料、ID、session、range、digest、URL／pathを暗黙にpromptへ加えない
- 対象本文を命令ではなく引用データとして扱う固定指示を持ち、校正は意味／文体を保つ修正案、アドバイスは長所／課題／具体策を求める
- 各章／話と本文context menuから「校正用プロンプトをコピー」「アドバイス用プロンプトをコピー」へ到達できるようにする
- FUMINIWAはAI chatを開かず、自動paste／送信を行わず、response、diff、Apply、Undo、cancel、retryを扱わない
- system clipboardは他アプリ、clipboard manager、Universal Clipboardから読まれ得る共有境界であり、secure erase、履歴非保持、外部AIの保持／学習利用を保証しない
- promptや本文をログ、UserDefaults、snapshot、`.novelpkg`へ保存せず、copy操作で本文、モデル、revision、Undoを変更しない
- 通常版clipboard支援はprovider、Codex／OpenRouter、Node／CLI／sidecar、network、Keychain、subprocessへ依存しない

旧`NovelAI`、fake provider／共有UI、Codex sidecar B1〜B4-DはD-075で実装を削除した。安全要求と検討経緯はDecision／feasibility文書に残すが、production channel／factory／callsiteや将来APIの根拠にはしない。再開時は最新stable SDK／APIを新Decisionで再評価する。

clipboard scope、UI、privacy、testは[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)、延期したSDK調査の結果は[CODEX_SDK_FEASIBILITY_REPORT_2026-08-09.md](CODEX_SDK_FEASIBILITY_REPORT_2026-08-09.md)を正とする。provider統合を再開する場合のrequest state、snapshot、sidecar Gate、保存範囲は[AI_INTEGRATION.md](AI_INTEGRATION.md)を正とする。

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
- 履歴上の新規作品 / 開く… / 別名で保存… / Finder表示。D-063のmacOS標準UIではcloud library、新規、Import、identity不変のExportへ置き換え、path／Finderを隠す
- スナップショットの復元導線と、添付・スナップショットがある作品の保存性能基準

### Phase 5: 出力

詳細なサブフェーズと出力仕様は **[PHASE5.md](PHASE5.md)** を参照。

- `NovelExport`(NovelCore のみに依存)を追加
- プレーンテキスト / Markdown / EPUB 3出力
- ネイティブ保存パネル、進捗、失敗・キャンセル表示

### 商業化基盤: Product Trust / Package Safety / Release

- **対象範囲**: 実装・機能・UI/UX・データ安全・性能・アクセシビリティ・互換性・ビルド／配布技術だけを扱う。価格、法務、販促、決済、事業運用は明示依頼がない限り対象外(D-042)
- **実装済み**: ふみにわ / FUMINIWAへの改名と旧設定移行(D-038)、Safe Launch(D-039)、参照payloadのvalid UTF-8検査、明示的な`Cmd+S`、provider-backed AI placeholderの非表示、既定のシステム外観追従と明示的なLight／Dark選択(D-040 / D-044)、起動／作品ライフサイクルの競合防止(D-041)、横一行で行全体を開閉できる章Disclosure(D-045)、provider非依存のclipboard prompt支援(D-054)、D-063のcloud library／private copy／Import／identity不変のpackage Export。D-063はmacOS／iOS / iPadOSともsource complete／local automated GOである。remote update／delete、paired device／Production deployを含む公開Releaseは未完了である
- **AIの現在地**: 通常版は校正／アドバイス×本文選択／話／章のpromptをsystem clipboardへ明示コピーするだけで、provider／network／key／process依存は0件。Experimental provider／fake UI／sidecar実装はD-075で削除済み。EditorKitの選択transactionとclipboard境界は残す。実providerを再開する場合は最新stable SDK／APIの明示再評価と新Decisionから始める(D-075)
- **公開Releaseの次**: Package Validator Gate。duplicate ID／不正参照、symlink、resource limit、孤児payloadの保全、修復コピー、保存前検証を一単位として扱う。外部変更／競合検出は続く独立Gateにする
- **実装面で残るGate**: AppIcon、Developer ID署名・公証済み成果物、更新機構、実機／アクセシビリティQA。現段階を実装面の公開準備完了とは扱わない

### Phase 6: AI支援

- **6-C（clipboard prompt支援、通常版）**: 校正／アドバイス×本文選択／話／章の6組合せを決定論的にplain textへ組み立て、利用者の明示操作でsystem clipboardへコピーする。provider、network、key、process、応答取込、Applyなし。scope外data、path、local identityを含めず、clipboard共有境界を明記する(D-075)
- **6-P（provider統合、停止）**: 旧`NovelAI`、fake UI、Codex sidecarの実装はD-075で削除した。将来再開時は最新stable SDK／APIを調査し、新Decisionとthreat modelから再設計する。旧feasibility reportは検討履歴としてのみ参照する
- **6-R（公開Release、未判断）**: providerを再開した場合もPackage Validator、External Change / Conflict、runtime identity／隔離、arm64／x86_64、nested signing、公証、実機／アクセシビリティQA後に別Decisionで公開AIの有効化を判断する。それまでは通常Releaseへprovider target／resource／UIを含めない

### Phase 6.5: PDF出力

- 実装面の公開Gateの後に、AIとは独立した機能としてA4横書き・章／話見出し・ページ番号・日本語／絵文字対応のPDFを追加する(D-037 / D-040 / D-042)
- `NovelExport/Platform/macOS/` に実装を閉じ込め、既存の共通原稿展開とアトミック書込みを再利用する

### Phase 7: iOS / iPadOS 対応

IOS-1〜5実装済み(D-056)。詳細な受け入れ条件と未完了の実機QAは **[IOS.md](IOS.md)** を正とする。

- **IOS-1 Build Graph（実装済み）**: iOS / iPadOS 17 app / test targetを追加し、D-059以前のbase appは通常macOS版と同じ5つのNovelKit productだけをlinkする。現在はDevice Sync用の`NovelSync`と`NovelSyncCloudKit`だけを追加し、AI provider／SDK／Node／CLI／sidecar／credentialはcompile／link／bundleしない
- **IOS-2 Shared App Boundary（実装済み）**: 作品／保存／session処理と、Files picker、scene lifecycle、first responder確定、clipboardを小さなiOS adapterへ分離する
- **IOS-3 UITextView Adapter（実装済み）**: TextKit 2、text view所有権、`IMEGuardPlugin → IndentPlugin`、共有`IndentRules`、D-055のR1' / R3 / R4 / R5、Undo / Redo、末尾96pt表示余白とcaret revealを実`UITextView`で成立させる
- **IOS-4 Document MVP / Adaptive Shell（実装済み）**: 外部原本を変更しないapp-private import / edit / export、Safe Launch / Recovery、iPadの適応的複数列、iPhoneの段階遷移を接続する
- **IOS-5 Clipboard Prompt（実装済み）**: 校正／アドバイス×本文選択／話／章を`UIPasteboard`へ明示コピーする。AI provider、送信、応答、Applyは持たない
- **IOS-6 Parity / Release QA（未完了）**: 残るmacOS機能、round-trip、実機IME、scene遷移、VoiceOver / Dynamic Type、性能と配布を検証する
- **Library-first shell（D-057）**: app-private作品棚、作品ホーム、作品情報／執筆OutlineからEditorへ進む段階導線と、初回Dark／System・Light・Dark選択を追加する。外部providerは標準pickerからの取込だけとする
- **Feature parity shell（D-058）**: プロット／伏線、登場人物、世界観、資料、設定を既存domainと保存境界へ接続し、iPhoneの段階画面とiPadのProject Sidebar / Outline / Detailから選べるようにする。iOS Editorは保存状態を上部へ移し、本文キャンバスと同じ背景の執筆補助バーから4つの明示commandを実行する
- **Cloud library shell（D-063、source complete／local automated GO）**: root作品棚をMacと同じWorkID catalog／registry projectionによる1つの「iCloudの作品」へ切り替える。remote-only exact download、cached offline open、account／kill fence、local-first new／Files Import、identity不変のportable Export、旧iOS private-copy明示recoveryを接続する。現行focused 28 / 28件、先行Device Sync device cases 89 / 89件／fresh top-level 86 / 86件、hosted App 79 / 79件、generic build／build-for-testing、fresh `./Scripts/check.sh`を通過した

MVPではFiles / File Provider上の原本を直接編集せず、取り込んだapp-private作業コピーだけを既存のrevision保存経路で扱う。open-in-placeはPackage ValidatorとExternal Change / Conflictを完了し、file coordination、security-scoped bookmark、競合UI、保存所有者を別Decisionで固定した後に限る。Phase 7と公開Release Gateは安全に並行できるが、一方の進捗で他方を完了扱いにしない。

### Snapshot Sync: SQLite local-first／Rust server（D-077、設計採択・client未実装）

D-077により、新しい保存／同期／履歴を同じimmutable whole-work Snapshot schemaへ統合する。UIはSQLiteのlocal projectionだけを読み、local commitとSyncIntentをremote I/Oより先に完了する。Rust APIはPostgreSQLのhead／receipt／Divergence／ConflictとS3互換object storeを所有し、expected head CASで作品を進める。

- 同期対象は作品タイトル／あらすじ、章・話の構造／タイトル／順序、本文／メモ、人物、プロット、伏線、世界観、attachment metadata／bytes
- 論理単位は作品全体、物理転送はcanonical entity payload／attachment object。変更hashだけを送る
- autosave、遷移、close、quitはnetworkを待たず、workerが通信復帰後にIntent／Attemptを自動再開する
- 非重複EntityKeyはdependency closureと作品全体invariantがvalidな場合だけ2-parent Snapshotへ決定的に統合し、同一key／delete対依存変更／構造不整合をこの端末／オンライン／両方の3択にする。本文内部の自動merge、時計LWWは行わない
- remoteはInboxへstageし、active editorへ注入せずIME／Undo／sessionを確認したsafe boundaryだけでmaterializeする
- local／online historyは同じretentionとrestore契約を使い、attachmentもonline復元対象にする。未知portable resourceはlocal round-tripだけに保全する
- CloudKitと新serverを二重authorityにせず、旧CloudKitはread-only migration sourceとする

client実装、Sign in with Apple認証、server-readable運用保護、署名済み実機、server backup、旧CloudKit migrationが完了するまでRelease NO-GOである。詳細は[SNAPSHOT_SYNC.md](SNAPSHOT_SYNC.md)と[AUTH.md](AUTH.md)を正とする。

### 現行CloudKit runtime: メモ型local-first／entity record同期（D-071、移行前の実装）

D-071により現行通常Mac／iOS Appのlive同期を、作品全体1資産のWorkSnapshot経路からentity record経路へ切り替える。各変更はapp-private packageへ先に保存し、変わったentity IDだけを`CKSyncEngine`へpendingする。衝突は同じentityの`serverRecordChanged`だけで検出し、合成しない。選択肢はこの端末／iCloud／両方を別作品として残す、の3つである。

- 同期対象は作品タイトル／あらすじ、章・話の構造／タイトル／順序、本文／メモ、人物、プロット、伏線、世界観
- attachment／資料binary、snapshot履歴、非hidden未知root item、アプリ外観／本文フォント等の端末設定は対象外
- local mutationはFIFO、networkはlane外、通信中の追加入力を古い応答で上書きしない
- active editorへremoteを注入せず、IME／Undo／selection／sessionを確認したsafe boundaryだけでpackageを更新する
- cloud conflict中はlocal編集を継続する。内部語（revision／branch／merge／journal／lease）を通常画面へ出さない
- D-063の作品棚、WorkID identity、account fence、Import／Exportは維持する
- D-061／D-063のwhole-work local証跡は旧経路の履歴であり、D-071実装済みへ流用しない

D-071 runtimeはD-077の非破壊migrationが完了するまで残す。CloudKit zone、旧sync metadata、package、reviewをreset／削除せず、新しい機能分岐をNote経路へ足さない。現行コードとmigration inputの詳細は[DEVICE_SYNC.md](DEVICE_SYNC.md) 0-current章を正とする。

#### D-059／D-060 Episode本文track（履歴）

D-059によりmacOS / iOSのapp-private作業コピー間で1話本文を引き継ぐ安全基盤を実装し、基準commit `508947d2`で全ローカル回帰を固定した。D-060はそのCAS／fencing／revision graphを維持したまま、remote writerとlocal Editor入力を分離し、pure DomainとMac／iOS App／UI sourceを実装した。`NovelSync` 94 / 94件（local-first 33件、既存coordinator 18件）、`NovelSyncCloudKit` 48 / 48件、Mac 45 / 45件とprivate-root 1 / 1件、iOS Simulator 42 / 42件とnative focused 2 / 2件が通過済みである。host in-memory local fake／Simulator回帰をpaired native Mac↔iPhone、実OS kill、実CloudKitの完了へ読み替えない。詳細なwire、state、CloudKit mapping、merge、実装順は **[DEVICE_SYNC.md](DEVICE_SYNC.md)** を正とする。

- `.novelpkg`は各端末のdurable / materialized / portable snapshotとし、live syncはpackage外のimmutable episode revision graphで行う
- 確定本文をnative editor → model → package → journalの順に保存してからremote taskを開始し、CloudKit処理で入力／local保存を待たせない
- package commit前のfull-body WALはapp-privateなprocess-kill recovery guardに限定し、package／wire／portable fixtureへ混ぜない。packageとjournalのexact acknowledgement前に端末内保存済みとしない
- transport非依存`NovelSync`はwire protocol v1のportable JSON、journal schema v2、stable branch、revision、mutation、lease、CAS、3-way mergeだけを持ち、NovelStorage、EditorKit、CloudKit、SwiftData、UI型を含めない
- EpisodeIDごとのholder / session / monotonic epochによりremote writerを1端末へ限定するが、全端末のlocal Editorはonline／offline、holder、account確認に依存せず編集できる
- 非authority変更はdetached branchへ保存し、remote不変なら直接publish、同一結果ならcollapse、非重複なら2-parent auto merge、overlap／祖先不明だけreviewとする
- publishはmutationID、expected remote head、lease epochをremote CASし、時計LWWを使わない。古いepochの本文を新しいheadへ上書きしない
- review中もEditorを止めず、採用／手動統合はいずれも2-parent revisionにする。remote、package、journal checkpoint完了まで元本文を保持する
- remote本文はnative surface、digest、IME、Undo／Redo、selection、Editor世代を再検査する明示境界だけで反映し、通常のSwiftUI updateや古いcallbackから全置換しない
- 通常UIへforce／lease／forkを出さず、Editor上部の小さな記号と必要時だけのreview警告を使う
- 現行wire v1に`HandoffRequest`は追加せず、別holderはexact head／digest／epoch CAS takeoverで扱う。cooperative request／grantは将来の別Decision／protocolとする

S1は初回binding時に構造が一致し、そのbinding snapshotに含めたEpisodeIDのbodyだけを扱う。Apple adapterが列挙するのはexact structure一致の明示binding候補であり、作品棚のcloud libraryやpackage bootstrapではない。後から章・話を追加しても既存対象話は継続するが、新規話はlocal-onlyでremoteへ暗黙作成しない。章・話構造、メモ、作品補助data、資料、snapshot、attachment、live collaborationは後続であり、未実装の同期状態やcloud badgeを出さない。CloudKit container / App ID / capability / profile / schema deployment / 署名済み実機は外部Gateで、Package Validator / External Change / Conflict Gateも未完了のままである。

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
├── EditorKit
├── NovelSync
└── NovelSyncCloudKit

FUMINIWAIOS
├── NovelCore
├── NovelStorage
├── NovelExport
├── NovelUI
├── EditorKit
├── NovelSync
└── NovelSyncCloudKit

NovelStorage → NovelCore
NovelExport  → NovelCore
NovelUI     → NovelCore
EditorKit   → NovelCore
NovelSync   → NovelCore
NovelSyncCloudKit → NovelSync / NovelCore / CloudKit
NovelCore → 依存なし
```

NovelCore は絶対にUIやStorageに依存しない。`NovelSync`はNovelStorage、EditorKit、CloudKit、SwiftData、SwiftUI、AppKit、UIKitへ依存せず、Apple固有のCloudKit / CKSyncEngine型は`NovelSyncCloudKit`へ閉じ込める。D-056の通常iOS target「5 productだけ」はD-059によりDevice Sync S1の`NovelSync` / `NovelSyncCloudKit`追加に限って置き換える。AI provider / SDK / Node / CLI / sidecar / credentialは通常targetへ含めない。

Windows 版も `App.WinUI → Core / Storage / Export / Editor`、`Storage / Export / Editor → Core`、`Core → 依存なし`という同じ意味の依存方向を C# project reference で強制する。Swift module と C# assembly の直接共有は前提にしない。

### 9.2 プラットフォーム依存

- AppKit / UIKit は EditorKit の Platform 配下に閉じ込める。将来のPDF用AppKit実装はNovelExportのPlatform配下に閉じ込める
- CloudKit / CKSyncEngine、account、push、asset、record change tagは`NovelSyncCloudKit`へ閉じ込め、`NovelSync`の公開API / wire / fixtureへ出さない
- WinUI / Windows App SDK 型は Windows 側の App / Editor project に閉じ込め、Core・保存 schema・Export の公開 API に出さない
- Public API に `NSTextView` や `UITextView` を出さない
- Phase 7の中間PRではtarget graphを先に固定するためiOS placeholderを許可するが、IOS-3完了時に`EditorView`のUIKit分岐を実`IOSTextAdapter`へ置き換える

### 9.3 保存形式

- 保存形式の詳細は NovelStorage に閉じ込める
- App側は `DocumentRepository` のみを見る
- `.novelpkg` の内部構造をApp側に漏らさない
- `.novelpkg` は macOS / iOS / Windows 間の公開互換境界とし、詳細は [CROSS_PLATFORM.md](CROSS_PLATFORM.md) を正とする
- schema 変更時は言語非依存 fixture を先に更新する。iOS実装後はmacOS → iOS → macOS、Windows reader / writer実装後はmacOS → Windows、Windows → macOSのround-tripまでを完了条件にする
- OS 固有パス・bookmark・handle・UI設定を package に保存しない。未知ルート項目はどちらの writer も保持する
- Device Syncのdirty set、CKSyncEngine state、account binding、CloudKit metadataをpackageへ保存しない。app-private packageは各端末の正本として既存保存経路を使い、live record protocolは[DEVICE_SYNC.md](DEVICE_SYNC.md)へ分離する
- D-063のApple版working copyは`SyncWorkID`から導出するplatform別app-private pathへ置き、path／registry／account scopeをpackageへ保存しない。外部packageはImportでnew WorkID、利用者向けpackageはidentity不変のExportで作り、active copyをopen-in-place／Save As先へ切り替えない

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

- 通常版の現行AI支援は[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)を正とする。校正／アドバイス用promptの生成とsystem clipboard writeだけを実装し、provider、network、Keychain、subprocess、Experimental sourceへ依存させない
- clipboardへ含める原稿scopeは明示選択、1話、1章に限定し、作品metadata、メモ、人物、プロット、伏線、世界観、資料、local identity、URL／pathを暗黙追加しない。copy操作で本文、Undo、revision、`.novelpkg`を変更しない
- 章／話の操作はdocument sessionと対象ID、本文操作はEditorKitの生存中surface／valid selection／IME状態をactivation時に検査し、別作品や現在選択へ読み替えない
- system clipboardは共有境界であり、履歴非保持、他deviceへの非同期、secure erase、外部AIの保持／学習利用を保証しない。自動送信、chat起動、response取込、Applyを追加しない

以下はD-075後にprovider統合を将来再開する場合の設計条件であり、現在の実装ではない。

- provider domainの配置・APIは未決定とし、provider SDK、network、process、Keychain、SwiftUI、AppKit、EditorKitとどのように境界を切るかを再設計時に決める。confirmed outboundへlocal session／surface／range／pathを持たせない要求は維持する
- 選択snapshotの取得と本文適用はApp / EditorKit bridgeへ閉じ込め、D-005のテキスト所有権とD-041のsession tokenを迂回しない
- 結果適用は同じdocument session、editor surface、episode、UTF-16範囲、exact sourceの一致を必要とし、staleな結果を現在選択へ再束縛しない
- provider adapterはCodexとOpenRouterで分離し、失敗時の自動fallbackを実装しない
- provider-neutralなoperation orchestratorとUIは一つだけとし、Codex SDKとOpenRouter APIでsnapshot、preview、確認、cancel、diff、stale、Copy、Applyの実装を分岐させない
- provider adapterはconfirmed prompt／schemaを追記・再構築せず、実送信直前のSDK／HTTP request captureでhidden追加がないことを検証する。fakeはpreviewとsealed payloadの完全一致を検証する
- providerの不変descriptor照合とconfirmed requestのone-shot leaseはdomain executorで行い、adapter自身にstream生成や比較値の選択をさせない。adapterは外部副作用より先にcancellation handlerを登録する
- providerはstreaming／cancellation／usage reportingを必須とし、domainがraw structured outputをexact schemaでstrict decodeする。domain budgetに加え、adapterは利用可能なupstream maximum output token parameterとwire event／process limitを設定・検証する。Codex SDKにupstream capがないExperimental実行では未保証とpreviewへ明示し、local limitで代替できたと扱わない
- prompt、response、diff、provider設定で`.novelpkg` schemaを変更しない
- 旧Codex sidecarの実装／配布条件は[AI_INTEGRATION.md](AI_INTEGRATION.md)6章とfeasibility reportに履歴として残るが、現行task・再利用契約ではない。再開には最新stable SDK／APIの明示再評価と新Decisionを必要とし、通常Releaseへprovider target、resource、UIを含めない

## 10. AIエージェント向け実装指示の基本方針

依頼するときは、以下の単位で小さく投げる。

悪い例: 「小説アプリを全部作って」

良い例: 「`EditorView`の公開APIと共有`IndentRules`を変えず、UIKitの通知順だけを吸収するTextKit 2の`IOSTextAdapter`を追加してください。R1' / R3 / R4 / D-055後のR5を実`UITextView`で統合testしてください。」

作業単位:

1. モデル追加
2. Repository追加
3. EditorPlugin追加
4. UI追加
5. テスト追加
6. 保存形式変更
7. リファクタリング

## 11. 直近の次タスク

Phase 0〜5（PDF除く）、Phase 7のIOS-1〜5、D-063のiCloud作品棚、D-071〜D-074のNote同期／明示同期／package snapshotは現行sourceとして入っている。D-077は次世代設計だけを採択した段階で、Rust server、SQLite client、同期切替は未実装である。コードの現行経路と移行負債は[CODE_HEALTH.md](CODE_HEALTH.md)、新設計は[SNAPSHOT_SYNC.md](SNAPSHOT_SYNC.md)、実装委譲は[SNAPSHOT_SYNC_HANDOFF.md](SNAPSHOT_SYNC_HANDOFF.md)を正とする。

D-077の着手順:

1. **R0 Contract freeze（実装なし）**。D-078の`serverReadableV1`／Sign in with Apple、versioned sync＋auth OpenAPI、JSON Schema、RFC 8785 canonical fixture、Intent／Attempt／cursor／Conflict／auth scenarioを固定する
2. **R1 Snapshot domain＋SQLite／CAS**。pure domain、GRDB、WorkID API、transactional migration、autosave、Online Backup、process-kill／DB corruption recovery
3. **R2 Portable Import／Export**。Package Validator、`.novelpkg` v1〜v3 Import／v3 Export、unknown resource保全、read-back
4. **R3 Networkなしlocal product**。作品棚、autosave、dense history、restore、Mac／iOS lifecycleをfeature flag内で完成させる
5. **R4 Rust sync server＋Apple auth**。Axum＋Tokio＋SQLx、PostgreSQL、S3互換object store、receipt、head CAS、cursor、Divergence、provider-neutral auth table／FUMINIWA session／AccountAuthEpoch、Apple verifier、Docker Compose、`192.168.11.5` integration
6. **R5 Swift Apple auth＋HTTP worker**。`NovelAuthApple`／HTTP／Keychain、FUMINIWA bearer、SyncIntent／SealedAttempt、exact retry、Inbox、cursor、account fence、safe materialization
7. **R6 Conflict／online history**。dependency-safeなEntityKey統合、同一key／構造競合の3択、local／remote stale、attachment、retention、restore、quota、VoiceOver／Dynamic Type
8. **R7 非破壊migration**。全旧package／journal／CloudKit inventory、work単位cutover、minimum-version／epoch fence、rollback／Export read-back
9. **R8 Production hardening＋account lifecycle**。R1〜R6へ実装したSign in with Apple／FUMINIWA session／server-readable content protectionのaudit、server保存時暗号化keyとbackup recovery、TLS、off-site backup／monitoringに加え、後続Decisionで固定したアプリ内account deletion開始、猶予／取消／retention、Apple token revoke、remote削除完了read-back、署名済みMac＋iPhone
10. **Windows W0以降**。`.novelpkg`に加えSQLite論理schema、canonical Snapshot、HTTP fixtureをC#で独立再実装する。[CROSS_PLATFORM.md](CROSS_PLATFORM.md)

Release NO-GOのまま残るもの: D-077 server／client、D-078 Sign in with Apple／FUMINIWA session／server-readable運用保護、production endpoint、migration、minimum-version fence、server backup restore、versioned account-lifecycle contractとアプリ内削除／Apple revoke／remote完了read-back、AppIcon、Developer ID署名・公証、更新機構、IOS-6実機QA。設計文書やlocal fixtureだけで「公開同期完成」と書かない。

通常版 AI はclipboard copyだけ（[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)）。B4-E／実providerは明示再評価と新Decisionまで着手しない。次世代同期契約は[SNAPSHOT_SYNC.md](SNAPSHOT_SYNC.md)、移行前のCloudKit runtimeは[DEVICE_SYNC.md](DEVICE_SYNC.md) **0-current章**。GitHubへ載せる手順はCODE_HEALTH.md 7章。

## 12. 非目標

現行ロードマップでは以下はやらない。

- 縦書き対応(執筆・出力とも非対応で確定 → D-012)
- iOS / iPadOSでの外部原本のopen-in-place(Package Validator / External Change / Conflict後に別Decision → D-056)
- 未検証のunknown portable resource、端末表示設定、SQLite database自体のonline同期と、それらまで含む完全mirrorの表示
- Snapshot wire v1からのremote work trash／hard delete（後続Decisionで30日trashとして設計）
- `accountRequired`／unscopedで作ったlocal-only workを、後から現れたaccountへautomatic adopt／uploadすること（D-077ではexact scopeを示す明示の「オンラインにも保存」だけがbindできる）
- 複数作品同時編集、外部provider横断ライブラリ、外部原本とapp-privateコピーを混在させる一覧
- AI本文自動書き換え
- EPUB/PDFの高度な組版
- リアルタイム共同編集
- 独自レンダリングエンジン
- 本文内部の自動3-way merge、Gitの内部用語を見せる履歴画面、同期処理の管理を利用者へ要求する画面
- 編集時刻によるwinner選択

Phase 7では、macOS版の安全契約を崩さずiPhone / iPadでapp-privateな最小執筆環境を完成させる。D-077はSQLiteのlocal libraryへ移行し、attachmentとretained Snapshotをonline復元対象へ広げるが、外部原本のopen-in-place、unknown portable resource／端末設定同期、リアルタイム共同編集へ拡張しない。

---

## 変更履歴

### v0.94 (2026-08-16)

- D-078でSnapshot Sync v1を`serverReadableV1`／E2EEなしに固定し、将来E2EEを非互換protocol migrationへ分離
- Production v1の外部identity providerをSign in with Appleだけにし、opaque AccountID、FUMINIWA session、AccountAuthEpoch fenceをproviderから分離
- 将来providerの明示link境界は設計するが、Apple以外のadapter／button／設定をv1へ出さない方針とauth contract／fixture Gateを追加

### v0.93 (2026-08-15)

- D-077を採択し、通常保存の正をSQLite＋local CAS、`.novelpkg`をImport／Export専用portable artifactへ変更
- immutable whole-work Snapshot、SyncIntent／SealedAttempt、Rust API＋PostgreSQL＋S3互換object store、expected head CAS、非重複entity統合、3択Conflict、online historyを設計
- 現行CloudKit Note runtimeを非破壊migration inputとして分離し、R0 contract freeze→SQLite local product→Rust server／worker→migration／Production hardeningの順へロードマップを更新

### v0.92 (2026-08-14)

太い App / iOS ファイルを責務ごとの extension へ分け、Note coordinator の組み立てを CloudKit adapter へ寄せた。

- `AppState.swift` 本体は状態と `init`。chooser / lifecycle / outline / 人物・プロット / 資料 / 保存 / スナップショットは別ファイル
- iOS CloudLibrary は models / refresh / open / mutations。Mac 執筆 UI は Outline と Editor pane を分離
- `AppleDeviceSyncServices.makeNoteSyncCoordinator` を Mac / iOS production runtime が共有する。CloudKit 型は NovelCore へ出さない
- 保存 coordinator と TextKit 2 は触っていない。N4 / Production schema / Package Validator は未実施のまま

### v0.91 (2026-08-14)

コードの簡素化として、Mac/iOS で同じ Device Sync ログを使い、AppState のスナップショット処理を extension へ分け、iOS のプロット／世界観／執筆一覧にも Editor と同じ保存・同期 chrome を付けた。

- `DeviceSyncLog` は `NovelApp/DeviceSyncLog.swift` に1つだけ置き、iOS target からも同じファイルをコンパイルする。CloudKit 型は NovelCore へ出さない
- スナップショットの作成・予約・復元は `AppState+Snapshots.swift`。保存 coordinator は触っていない
- iOS のプロット／世界観の Outline／詳細と執筆 Outline の上部 toolbar から、保存記号・「iCloudと同期」・スナップショットへ到達できる。Editor と同じ部品を再利用する
- N4 署名済み paired／Production schema／Package Validator は未実施のまま

### v0.90 (2026-08-14)

エージェント向けに、live 経路と履歴経路を分け、11章から件数・cutover 手順の再掲を外した。

- [CODE_HEALTH.md](CODE_HEALTH.md) を追加し、太いファイル、Mac/iOS 複製、Work 経路の残し方、GitHub への載せ方を固定した
- 7章を未実装／延期だけに直し、実装済みの検索・人物・プロットを将来機能として読ませない
- Device Sync の次作業はコードではなく N4 操作者検証のまま

### v0.89 (2026-08-14)

D-074として、編集後の作品全体自動スナップショットと Time Machine 型の間引きを追加した。

- 定期タイマーではなく、本文・人物・プロット・伏線・世界観などの編集があってから約5分後に1件残す。最小単位は5分
- アプリを退避するときも、未退避の編集があれば同じ作品全体を残す
- 直近1時間は密に残し、24時間は時間ごと、30日は日ごと、1年は週ごと、それより前は月ごとに間引く。手動保存は消さない
- snapshot履歴は従来どおりiCloudへ送らない。N4署名済みpaired／Production schemaは未実施のまま

### v0.88 (2026-08-14)

D-073として、自動保存を端末内に限り、iCloud送信を明示同期へ分けた。

- 話切替／デバウンス保存は`.novelpkg`とdirty setまで。CKQuery失敗をオフライン表示にしない
- 結線済み作品の`Cmd+S`とtoolbar／iOSの「iCloudと同期」だけがsend／pullする
- Editor openのlocal preflightオフラインは明示同期の送信禁止にしない。失敗は`[FUMINIWA] note-sync`のtokenで分類する
- Development schemaでqueryできないときはworkと子entityをrecord IDで取る
- N4署名済みpaired／Production schemaは未実施のまま

### v0.87 (2026-08-14)

CKQueryがCKError 12 / 2015（`recordName`未QUERYABLE）でも、明示保存した作品を棚へ戻せるようにした。

- catalogは失敗したqueryを空とせず、既知WorkIDをrecord IDで取り直す
- `createWork`後のpending createはcatalog listを待たず、同じrecord ID確認で完了する
- D-071のnil-head Note行は、local packageと一致すれば`cachedRemote`へ上げ、自動再送しない
- 別端末のremote-only発見は引き続きDashboardの`recordName`／`workID` QUERYABLEが必要。N4署名済みpairedは未実施

### v0.86 (2026-08-14)

D-072の明示「iCloudに保存」を、signed-in後の空catalog／Note type未作成によるcatalog失敗でも出せるようにした。

- 作品棚の読込失敗をiCloud未設定と同一視しない。`.unavailable`のlocal-only／localPendingでも明示保存できる
- 新規後のWorkbench toolbarとFileメニュー、iOS作品ホームにも同じ項目を出す
- 既存のlocal bindingがあっても、明示保存はcatalog listの前にzone作成と`createWork`を再試行する。chooserは保存後のcatalog待ちでボタンを灰のままにしない
- `FUMINIWANoteWorkV1`のCKQueryがCKError 12 / CKInternalErrorDomain 2015（型未作成または`recordName`未QUERYABLE）のときは、cached remoteがなければ空のavailable catalogとして扱う
- 初回createWorkがrecord IDで成功したあと、catalog queryなしでpending createを完了できる
- `accountRequired`／different account／offlineでは出さない。automatic adoptは禁止のまま

### v0.85 (2026-08-14)

D-072として、作品棚に明示的な「iCloudに保存」、複製、この端末からの削除を追加した。

- automatic adoptは禁止のまま。connection availableのlocal-only／localPendingだけ明示保存でき、失敗を隠さない
- 複製は新しいWorkIDのportable copyで、chooser／棚に留まる
- 削除はregistryとhidden packageだけ。CloudKit tombstoneは置かない
- N4署名済みpaired／Production schema／Package Validatorは未実施のまま

### v0.84 (2026-08-13)

D-071 N2〜N4として、Note entityのCloudKit adapter、通常Appの短い3択、in-memory paired simulationを追加した。

- N2: `FUMINIWANote*V1` 7 type、`CKSyncEngine` pending save／fetch、catalog／bootstrapをnote work recordへ切替。inline JSONと話本文だけのentity `CKAsset`
- N3: Mac／iOSでpackage保存先行、dirty enqueue、この端末／iCloud／両方を別作品、の短い3択。統合案は出さない。production runtimeだけが`NoteSyncCoordinator`を注入し、既存D-061 App testは旧経路のまま
- N4: in-memoryの2 client往復、offline再送、process-kill dirty復元、account分離。署名済みMac＋iPhone paired／実CloudKitは未実施
- 完了報告は (a) source＋unit (b) Simulator／fake (c) 署名済み実CloudKit を分離する。N2〜N4 local成功を同期完成、出荷可能、N4完了へ読み替えない
- 現行local証跡は`./Scripts/check.sh`の`All checks passed`、`NovelSync` 156 / 156件（18 suites）、`NovelSyncCloudKit` 91 / 91件（25 suites）、macOS Device Sync 90 / 90、iOS Device Sync 87 / 87、hosted NoteSync 3択 Mac 2 / 2・iOS 2 / 2。停止中のExperimental buildはD-075で削除済みで、以後は通常macOS／iOS targetのbuildを検証する

### v0.83 (2026-08-13)

D-071 N1として、`NovelSync`にメモ型entity record、dirty set、衝突3択、作品組み立てのdomainとunit testを追加した。

- 変わった話・人物等だけをdirtyにし、同じentityの両側変更は合成せず3択にする
- dirty setは原稿本文を持たない。通信前の欠けるfetchを削除とみなさない
- 通常Appのlive経路とCloudKit adapterは未切替。次はN2
- N1成功を同期完成、出荷可能、N4完了へ読み替えない

### v0.82 (2026-08-13)

D-071により、通常Appのlive Device SyncをAppleメモ型のlocal-first／entity record同期へ切り替える契約を追加した。

- 画面は `.novelpkg` を正とし、起動・復帰・執筆開始で通信を待たない
- 送る単位は作品全体の1資産ではなく、話・人物等のentity record。`CKSyncEngine` が実際にsave／fetchする
- 衝突は合成せず、この端末／iCloud／両方を別作品として残す、の3択
- 内部語（revision／branch／merge／journal／lease）を通常画面へ出さない
- D-063のiCloud作品棚、account fence、Import／Export、active editor非注入は維持
- D-061 whole-work `CKAsset`／3-way merge／3面reviewは履歴。契約時点の次タスクはN1 domainだった

### v0.81 (2026-08-12)

D-063のiCloud作品libraryをmacOS専用からApple版共通契約へ拡張し、iOS / iPadOSのsource実装とlocal automated GOを記録した。

- iOS root作品棚をpackage名identityの「このデバイスの作品」から、WorkID catalog／registry projectionによる1つの「iCloudの作品」へ置換
- remote-only exact download、cached offline open、local-first new／Files Import、same-scope resume／account quarantine、cold Open With待機を追加
- iOS private WorkID package／1 work 1 registry、bind→mark kill復旧、no-overwrite install、利用者向けerror／logのpath・WorkID非公開を固定
- identity不変のportable `.novelpkg` Exportと、D-063以前のiOS private packageをnew WorkIDへ明示copyして旧bytesを保持するlegacy recoveryを追加
- macOSの`NovelSyncCloudKit` 84 / 84件と、署名済み実Macから既存1作品を初回publishしてregistry `synced`／journal outbox 0・`synchronized`／catalog cache 1件をread-backした証跡を追加
- iOS extensionはsource実装済みとし、Simulator focused 28 / 28件（1 suite）、先行Device Sync device cases 89 / 89件／fresh top-level 86 / 86件（4 suites）、hosted App 79 / 79件、generic build／build-for-testing、fresh `./Scripts/check.sh`の`All checks passed`を現行証跡として固定する。Mac／D-061の既存件数は流用しない
- remote update／delete、paired Mac↔iPhone、Production deploy、実account switch／offline／kill、手動VoiceOver、Package Validator、External Change / Conflict、production migrationはRelease NO-GOとして維持

### v0.80 (2026-08-12)

D-063により、macOS通常起動をiCloud作品libraryと見えないapp-private working copyへ切り替える契約を追加した。

- 同一windowの単一paneへ小さなアプリアイコン／名称、「作品を取り込む…」「新しい作品」、1つの「iCloudの作品」Listだけを置き、path／保存場所／Finder／detail paneを撤去
- WorkIDだけでremote catalogと検証済みlocal registryをmergeし、title／document ID／structureによるdedupeを禁止。remote cacheを1,088件（binding 1,024＋pending-open 64）へbounded化し、refresh失敗でもcached rowsを保持
- active copyを`SyncWorkingCopies-v2/<WorkID>.novelpkg`へ隠し、1 work 1 atomic registry、deterministic package inventory、work単位のcorrupt／orphan quarantineを追加
- cached localはoffline openし、new／Importもoffline／account未確認でlocal installできる。remote-onlyだけはonline＋account確認後にdurable pending-open→exact head fetch→same-root staging→read-back→no-overwrite install。account mismatchでも検証済みlocal packageは開けるがuploadせず、旧remote title／binding／pendingとlocal packageのないremote-only行をquarantine
- new／Importはnetwork／accountに依存せず毎回new WorkIDのprivate copyをlocal installする。以前確認済みscopeの一時offlineなら同scopeだけ自動再開し、unscoped workは将来accountへautomatic adopt／uploadしない。Finder / Open WithもImportとして外部原本を保持し、old visible packageは自動移動／削除／rekeyしない
- `.novelpkg`を「書き出す…」へ追加し、package全体の検証済みcopyでattachment／snapshot／unknown rootを現在Macから保持しつつ、active URL／session／WorkID／bindingを変更しない
- exact local attestation＋account-scoped remote receipt一致時だけ「iCloudと同期済み」を表示し、same-scope pending／unscoped local-only／account-quarantined local／remote-only／offline／review／破損を区別。MVPにdelete UI／APIを置かない
- remote bootstrapはWorkSnapshotだけとし、attachment／snapshot履歴／unknown root／端末設定まで完全backup済みとは表示しない
- development CloudKit zone＋旧local sync metadata／journal／registry reset、全test端末同一buildをcutover条件とし、outbox／staged／pending／reviewがあるblind resetを禁止。全hidden packageをregistry再構築／保全または検証済みExportで回収し、hidden root自体は削除しない
- 現行source freezeは`NovelSync` 142 / 142件（14 suites、near-cap 270,439,704 bytes）、`NovelSyncCloudKit` 84 / 84件、freshな`./Scripts/check.sh`、署名済みDebug macOS／iOS entitlement read-backを通過。初回same-account `.signIn`再検証、clean zone／type未生成bootstrap、root revisionの空parent field省略を固定した。署名済み実Mac Appは既存1作品を初回publishしてregistry `synced`／journal outbox 0・`synchronized`／catalog cache 1件をread-backし、最終署名済みiOS generic Debug buildもstrict codesign valid、Development container／CloudKit／APNs `development`をread-backした。Package Validator、External Change / Conflict、実CloudKit remote update／delete／paired device、Production deploy、実account switch／実OS kill／手動VoiceOver、production migration／minimum-version fenceはRelease NO-GOとして維持

### v0.79 (2026-08-12)

D-062により、macOS通常起動を明示的な作品選択へ切り替えた。

- `loading`／`documentSelection`／`ready`／`recovery`の4状態とし、通常起動では前回作品を自動で開かず、recentが無い場合も新規作品を自動作成しない
- Finder / Open Withの指定URLはchooserを経由せず直接開き、失敗時はD-039どおりURL／recent／原稿を保持してRecoveryへ進む
- chooserを直近1件のlocal URLだけに限定し、作品棚／cloud library／remote descriptor／new-device bootstrapと区別
- 通常chooser／RecoveryのactivationはAppStateでlocal WorkSync preflightを待ち、cold Finderは既存scene startup境界を維持。曖昧なlocal recovery中は通常mutationをgateしつつroot recovery choiceを操作可能に維持
- 標準`NavigationSplitView`、System／Light／Dark、標準List selection／button階層、keyboard／VoiceOverの画面契約を固定

### v0.78 (2026-08-11)

D-061により、現行通常AppのDevice SyncをEpisode本文から作品全体のlocal-first snapshot同期へ切り替えた。

- 同期scopeを作品タイトル／あらすじ、章・話構造／タイトル／順序、本文／メモ、人物、プロット、伏線、世界観へ拡張
- package外Work journalへのstage→package保存→exact confirm→networkのlocal durability順を固定
- Episode wire v1とは別namespaceのWork wire v1、whole revision `CKAsset`、head ID＋snapshot digest CAS、mutation receiptを追加
- 非重複自動mergeと、overlap／delete対edit・move・reorder／順序競合／祖先不明のこの端末・iCloud・統合案3面reviewを追加
- active editor非注入、safe materialization、cloud review中のlocal編集継続、曖昧なlocal recoveryだけの編集gateを明記
- snapshot 48 MiB、revision 50 MiB、journal 320 MiB、outbox 3、store 5、conflict 512、descriptor値1 KiBのresource capと、到達可能なjournal 270,439,704 bytesの保存／再読込回帰を固定
- attachment／snapshot履歴／端末設定／cloud library／new-device bootstrapを除外し、mixed Episode／Work clientを非対応とした。開発data reset＋全test端末同一buildを必須とし、production migration／version fenceまで出荷不可
- Work Domain 44 / 44件、`NovelSyncCloudKit` 59 / 59件、Mac 60 / 60件、iOS 56 / 56件、generic iOS build／build-for-testingをD-061のlocal証跡として固定。D-059／D-060の基準commitと既存test件数は別履歴として保持し、signed real CloudKit／paired native／実OS kill／手動VoiceOver／production migration fenceは未完了として分離

### v0.77 (2026-08-11)

D-060のpure Domain source実装と、App／外部検証を分けた現在地へ更新した。

- wire protocol v1／journal schema v2、observed baseline、offline detached branch、exact authority takeoverを実装済みとして固定
- bounded multi-hunk Unicode scalar merge、2-parent review解決、upload tail／process再開を`NovelSync` 94 / 94件で確認
- pending 5／競合保持3／materialization 4／fresh relay込み5、journal 80 MiB、最大実測75,506,494 bytesをportable resource契約へ反映
- full-body pre-package WALをapp-private recovery guardとして追加し、`.novelpkg`／wireへ含めない境界を明記
- 現行v1に`HandoffRequest` recordがないことを訂正し、cooperative handoffを将来のadditive Decision／protocolへ分離
- Mac 45 / 45件、iOS Simulator 42 / 42件、iOS native focused 2 / 2件を通過として追加し、paired native Mac↔iPhone、署名済み実CloudKit、手動VoiceOver、実OS kill、same-UID adversaryとExternal Change / Conflict Gateは未完了として維持

### v0.76 (2026-08-11)

D-060により、D-059のremote CAS／fencingを維持したままDevice Syncをremote single-writer／全端末local-first編集へ変更する計画を固定した。

- native editor → model → package → journal → remoteの保存順と、CloudKitから独立したlocal durabilityを固定
- 非authority／offline変更をdetached branchへ保存し、collapse、非重複2-parent auto merge、overlapだけのreviewを定義
- remote本文のnative editor非上書き、通常UIからforce／lease／forkを除外し、上部状態記号とVoiceOverを定義
- wire protocol v1維持／journal schema v2、Windows／Android fixture、source／Simulator／実CloudKitを分離した実装・報告順を追加
- D-059の実装済み・全ローカル回帰通過記録は基準commit `508947d2`の履歴として維持

### v0.75 (2026-08-11)

D-059により、app-private作品の話本文Device Syncと、iPhone強制継続後のfork統合trackを追加した。

- `.novelpkg`を端末内durable / materialized / portable snapshot、live syncを別の話単位record protocolとして分離
- OS非依存`NovelSync`、package外file journal、`NovelSyncCloudKit`のprivate CloudKit + CKSyncEngine adapterをsource実装し、1話1 writerのsoft lease、mutation / head / epoch CASを追加
- force後の旧writer fencing、package外journal、保守的3-way merge、2-parent merge revisionを安全境界として固定
- S1対象を初回構造一致後のbinding snapshotへ含めたepisode bodyへ限定し、明示binding候補をcloud library / package bootstrapと区別して、構造 / 資料 / live collaborationを後続へ分離
- CloudKit外部設定と署名済み実機、Package Validator、External Change / Conflictを未完了Gateとして維持

### v0.74 (2026-08-11)

iOS / iPadOSの作品ホーム以降をD-058の機能parity導線へ拡張し、Editor chromeと執筆補助を整理した。

- プロット／伏線、登場人物、世界観、資料、設定を既存`NovelDocument`／Repositoryとrevision保存へ接続
- iPhoneは各一覧／詳細への段階遷移、iPadはProject Sidebar / Outline / Detailから同じ機能へ到達
- iOS Editorの重複した本文見出し、話タイトル入力、文字カウンターを外し、保存状態を上部toolbarへ移動
- 本文キャンバスと同じ背景の執筆補助バーへ`……` / `――` / `ルビ` / `傍点`を追加し、selection commandとUndoの既存契約を再利用
- `.novelpkg` schema、EditorKitの字下げ／鉤括弧、TextKit 2、通常版のAI依存境界は変更しない

### v0.73 (2026-08-10)

iOS / iPadOSの作品選択と機能選択をD-057のlibrary-first導線へ整理した。

- app-private作業コピーを一覧・再選択できる作品棚を追加し、Files / iCloud Driveは標準pickerからの取込入口として分離
- 作品棚 → 作品ホーム → 作品情報または執筆Outline → 既存Editorの段階遷移へ変更
- 同一document IDの複数取込をpackage名で区別し、破損・hidden staging・symlink・root外pathを局所的に隔離
- iOSの初回chromeをDark既定にし、System／Light／Darkをapp-private設定として選び直せるようにした
- EditorKit、字下げ／鉤括弧、Undo / Redo、`.novelpkg` schema、外部原本を直接編集しない境界は変更しない

### v0.72 (2026-08-10)

Phase 7のIOS-1〜5を実装し、Simulator / generic iOS device / ローカルCIで検証した。実機・Accessibility / Release QAは未完了としてIOS-6へ分離した。

- iOS / iPadOS 17 app / test targetと、通常5 productだけをlinkする生成project／target separation検査を追加
- app-privateな新規／取込／revision保存／書出、Safe Launch / Recovery、適応的なiPhone / iPadシェルを追加
- `UITextView` + TextKit 2 adapterで共有`IndentRules`、D-055後の括弧入力、IME pending確定、Undo / Redo、96pt表示余白、caret revealを実装
- 校正／アドバイス×本文選択／話／章のclipboard prompt copyだけを追加し、provider／network／credentialを通常iOS targetから除外
- 実機IME、VoiceOver / Dynamic Type、hardware keyboard、scene／termination、完全round-tripをIOS-6の未完了条件として維持

### v0.71 (2026-08-10)

Phase 5完了後のPhase 7へ着手し、iOS / iPadOS 17のapp-private文書MVPを決定した(D-056、[IOS.md](IOS.md))。

- iPadの適応的複数列とiPhoneの`NavigationStack`、通常5 productだけをlinkするiOS targetを計画
- 外部`.novelpkg`を原本へ書き戻さず、app-private作業コピーとして取り込み／編集／保存／書き出すMVP境界を固定
- open-in-placeをPackage ValidatorとExternal Change / Conflict後の別Decisionへ分離
- `UITextView` + TextKit 2で共有`IndentRules`を使い、旧R2／旧R5を戻さずD-055後のR1' / R3 / R4 / R5を実機IMEで検証する契約を追加
- 通常iOS targetの`NovelAI`、Experimental、provider／SDK／Node／CLI／sidecar／network／credentialを0件とし、D-054のclipboard prompt copyだけを許可
- IOS-1〜6のPR順とBuild、Document safety、Editor、Clipboard / Accessibilityの完了条件を追加

### v0.70 (2026-08-10)

長文執筆時のキャレット可視性、括弧ペア入力時のキャレット位置、IME確定後の字下げ解除を修正した(D-055)。

- 本文末尾の下へ96ptの表示専用スクロール余白を追加し、`.novelpkg`へ保存される本文には改行・空白を加えない
- プラグインによる改行／字下げ置換後、移動したキャレットを明示的に可視範囲へスクロール
- R5を `　「」` / `　『』` と括弧内キャレットへ拡張し、IME確定後も行頭の全角スペースを削除
- 直接入力・IME確定とも、字下げなしの行頭や文中を含む任意位置の `「」` / `『』` でキャレットを括弧内へ移動
- AppKitの実入力に合わせ、開閉括弧が別々に届く経路と、IMEがmarked rangeを`insertText`で確定する経路を追加
- TextKit 2、IME変換中不介入、Undo / Redoの既存境界を維持した回帰testを追加

### v0.69 (2026-08-09)

実provider統合を最新stable SDK／APIの明示再評価まで延期し、通常版のAI支援をAIチャット用clipboard prompt copyへ切り替えた(D-054、[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md))。

- 当時はB1〜B4-DのExperimentalコード、fixture、test、Decisionを削除せず、production catalog空／production runtime接続0の研究成果として[日付固定レポート](CODEX_SDK_FEASIBILITY_REPORT_2026-08-09.md)へ記録。コード、fixture、testはD-075で削除し、文書と安全要求だけを履歴として残す
- B4-E、Codex／OpenRouter adapter、network、credential、実原稿送信を現行ロードマップから外し、再開時は旧0.147.0の値を流用せず最新stable境界をゼロから再評価
- 通常版で校正／アドバイス×本文選択／話／章のplain text promptを明示操作でsystem clipboardへコピーする非通信境界を追加
- promptへscope外data、local identity、URL／pathを加えず、provider、network、key、process、`NovelAI`、response、diff、Applyへ依存しない
- system clipboardを他アプリ、clipboard manager、Universal Clipboardから読まれ得る共有面として明記し、履歴非保持、secure erase、外部AIの保持／学習利用を保証しない
- provider延期をPDFその他の独立機能の永久blockerにせず、公開Releaseの次GateはPackage Validator、続いてExternal Change / Conflictを維持

### v0.68 (2026-08-09)

Codex content GateのB4-Dとして、Experimental限定／mock限定のabstract interactive transport sequencing契約を追加した(D-053、[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md))。

- 引数0のcontent-free factory openがfreshな1-request／class-bound channelを返す契約、open cancelのacknowledgement + join、fresh late channelのprocess-wide claim後cleanup、duplicateの先行owner非破壊、weak reuse registryを固定
- sealed payload budgetだけからrun entryでabsolute request deadlineを決め、独立したattestation timeoutを30秒以下に制限。`hello`だけを書き、exact request／runtimeの単独`ready`とdecoder frame boundaryの確認後にだけexact sealed `start`を書く
- `started` → 単一terminal → EOFを必須とし、request deadline前のterminal claim後は最大1秒のEOF drainを開始。duplicate／late／partial／missing EOFをfail-closedに拒否
- cancel／timeoutのfirst-wins、wire terminal後／delivery前のlocal cancelによるresult破棄とwire cancel 0件、optional cancel frame + I/O unblockをchannelのatomic cancellationに所有させる契約、finalizing中のcancelがI/Oを追加しない境界を固定
- cleanup安全errorを先行結果より優先し、raw channel／factory errorを分類codeへredact。同一transportの並行runとglobal live-channel reuseを拒否し、settled後のcancelはno-op
- 合成B4-D 5 suitesの54 testは54/54、`FUMINIWAExperimental`全体は205/205 pass。具象production channel／factory／callsite、process／Node／SDK／CLI／network／key／実原稿は0件
- production catalogは空のままで、B4-C childは一度もresumeされずB4-Dへ変換されない。これはtransport sequencing feasibilityであり、実runtime B4-Dの完了／GOではない
- v0.68時点の後続候補はB4-E closed execution closure／native broker／helper + approval／identity／OS-level read／exec隔離だった。v0.69／D-054で実装を延期し、残Gate完了まで`codex_sdk`と実送信をNO-GOとする境界だけを維持

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

Snapshot Sync R0前のE2EE／Production identity方式はD-078で解決済みである。公開前にはremote work／account deletion、削除猶予と保持、Appleが唯一のidentityだった場合の回復範囲を後続Decisionで確定する必要があり、それまではProduction Release NO-GOとする。v0.1レビュー時の未決事項3件（縦書き／配布形態／iOS時期）はv0.3で解決済み（→ [DECISIONS.md](DECISIONS.md) D-011〜D-013）。
