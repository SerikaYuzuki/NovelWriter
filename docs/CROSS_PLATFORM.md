# クロスプラットフォーム設計契約

**契約版: `.novelpkg` 1 / Work Sync wire 1・journal schema 1 / Episode Sync wire 1・journal schema 2（履歴） / 対象: macOS・iOS / iPadOS・Windows・将来Android**

**状態: `.novelpkg`契約承認、W0未完了。D-063のApple Work catalog、platform別app-private work registry、remote WorkSnapshot bootstrap、Import／identity不変のExportを含む作品全体Work Syncは、macOS／iOS / iPadOSともsource complete／local automated GOである。現行fresh `./Scripts/check.sh`は`All checks passed`で、`NovelSync` 142 / 142件（14 suites）、root parent修正focused 28 / 28件を含む`NovelSyncCloudKit` 84 / 84件、macOS Device Sync 88 / 88 top-level（5 suites）、iOS Device Sync 86 / 86 top-level（4 suites）、hosted iOS App 79 / 79件、generic iOS build／build-for-testingを通過した。先行iOS xcresultのdynamic device casesは89 / 89件である。最終署名済みiOS generic Debug buildはstrict codesign validで、Development container／CloudKit／APNs `development`をread-backした。署名済み実Mac Appから既存1作品の初回publishも成功し、registry `synced`、journal outbox 0／`synchronized`、catalog cache 1件をread-backした。** D-059〜D-061とD-063 Mac-eraの既存件数は各段階の別履歴として維持し、iOS extensionの現行証跡へ流用しない。Work wire v1とEpisode wire v1は別namespaceで相互観測せず、mixed clientは非対応である。D-063開発検証はdevelopment CloudKit zone＋旧local sync metadata／journal／registryの保全付きresetと全test端末の同一buildを必須とし、production migration／minimum client version fenceまでは出荷不可とする。paired native Mac↔iPhone、remote update／delete、実account switch／offline、実OS kill、手動VoiceOver、Production deploy、C# / Kotlin再実装、Package Validator、External Change / Conflictは未完了である。

本書は、macOS版、iOS / iPadOS版、将来のWindows / Android版が同じ作品を安全に扱うための言語・UI framework非依存の境界を定める。portable snapshotは`.novelpkg`、現行live syncは別namespaceの作品全体Work wire、端末内の未同期作品はpackage外Work journal、Apple版の作品列挙／初回取得はD-063 catalog／bootstrapとし、四者を混同しない。アーキテクチャ全体は[DESIGN.md](DESIGN.md)、package決定は[DECISIONS.md](DECISIONS.md) D-036、sync決定はD-059〜D-063と[DEVICE_SYNC.md](DEVICE_SYNC.md)を正とする。

## 1. 共有するもの／OS ごとに実装するもの

| 対象 | 共有方法 | 備考 |
| --- | --- | --- |
| `.novelpkg` v1〜v3 の読み込み、v3 の保存仕様 | 本書、言語非依存 schema、golden fixture | 最優先の互換境界。macOS が保存した作品を Windows で開き、その逆も成立させる |
| Work Sync wire v1／journal schema v1／library projection | [DEVICE_SYNC.md](DEVICE_SYNC.md) 0章、portable JSON、whole snapshot / revision / journal / merge、library projection契約／focused test | 作品全体revision、expected head ID＋snapshot digest CAS、mutation receipt、stage／confirm、作品全体merge、WorkID＋exact headを持つcatalog／bootstrapの意味を共有。CloudKit型、account token、native editor状態は共有しない。C#／Kotlinの独立fixture実装は未完了 |
| Episode Sync wire v1／journal schema v2（履歴） | [DEVICE_SYNC.md](DEVICE_SYNC.md) 1〜15章、既存fixture | D-059／D-060の話本文revision／lease／detached branchの実装・検証履歴。Work wireと相互decode／mixed運用しない |
| 作品→章→話、各 ID、配列順、空要素の意味 | 仕様と fixture | Swift の型を C# から直接参照せず、同じ意味のモデルを各言語で実装する |
| 自動字下げ、ルビ・傍点、検索、文字数、モデル操作 | 入出力例と共通テストケース | 純粋ロジックとして移植する。UTF-16 範囲と grapheme の差を fixture で固定する |
| Export の順序・見出し・改行規則 | [PHASE5.md](PHASE5.md) と出力 fixture | レンダラ実装は Swift / C# で別でも、同じ入力から同じ論理結果を得る |
| 日本語 UI 文言、機能名、ショートカットの意図 | 設計文書 | 実際のキー割当と配置は各 OS の慣習へ合わせる |
| アイコン原案、サンプル作品、テストデータ | リポジトリ内アセット | OS 標準シンボル名やレンダリングは共有しない |
| Swift の `NovelCore` / `NovelStorage` / `EditorKit`、SwiftUI View | 共有しない | WinUI 版では C# / .NET の対応層として再実装する |
| `NSTextView`、TextKit 2、AppKit のパネル／toolbar | 共有しない | Windows のエディタ、IME、Undo、picker、windowing で置き換える |
| UI レイアウトとデザイン言語 | 振る舞いだけ共有 | macOS は [STYLE.md](STYLE.md)、Windows は WinUI / Windows の慣習に沿う別ガイドを実装着手時に作る |

「コードを最大限共有する」こと自体を目的にしない。共有の中心は、保存形式、ドメインの意味、純粋ロジックの入出力例、golden fixture である。

## 2. `.novelpkg` 相互運用契約

### 2.1 基本形

- `.novelpkg` は **単一ファイルではなくディレクトリ**である。macOS の package 表示は Finder の UI 上の扱いにすぎず、Windows では拡張子付きフォルダとして扱う
- OS 間の受け渡しで利用する ZIP 等は transport にすぎず、`.novelpkg` の保存形式には含めない。転送手段がディレクトリを保てない場合だけ package 全体を圧縮し、利用前に展開する
- D-063のApple版通常利用ではactive `.novelpkg`をplatform別app-private working copyとして隠し、利用者がportable packageを得るのは明示的なImport／Export境界だけとする。これは`.novelpkg`の公開互換性を下げる決定ではなく、作業中の保存場所と受け渡しartifactを分離するUI／lifecycle契約である
- パッケージ内のパスは相対パスだけを使う。絶対パス、ドライブ文字、`\` 区切り、セキュリティスコープ付き bookmark、OS 固有 handle を保存しない
- 既知のルート名と ID ベースのファイル名は ASCII とし、パス区切りを JSON 値へ埋め込まない
- 読み込みは v1 / v2 / v3、保存は v3 とする。未対応メジャーは推測で開かず、明示的な非対応エラーにする
- 章順は `manifest.json` の `chapters`、話順は各章の `episodes` の配列順だけを正とする。ファイル列挙順、更新日時、ロケール順を順序として使わない

### 2.2 文字・識別子・日時

- JSON と `.md` は UTF-8 (BOM なし)で読み書きする。JSON のキー名は現在の camelCase を維持する
- 本文、メモ、タイトルなどの Unicode 文字列は、保存時に NFC / NFD 変換や改行変換を暗黙に行わない。入力された値を保持する
- 改行の正規化が必要な出力形式は [PHASE5.md](PHASE5.md) の Export 境界で行い、`.novelpkg` の読み書きでは本文を書き換えない
- JSON内のUUID値はハイフン付き36文字を受理し、英字の大小を区別せず解釈する。新規保存時のJSON値とIDファイル名は大文字形式をcanonicalとする。IDファイル名はcanonicalな大文字名を要求し、JSON値と大小文字だけ異なるファイルを本文欠損として黙って扱わない
- ChapterIDとEpisodeIDは文書全体で一意、その他のentity IDは各domain内で一意とする。重複IDは後勝ちで上書きせず、読み込み／保存前検証で型付きエラーにする
- `manifest.json` の `createdAt` / `updatedAt` は ISO 8601 の UTC 文字列とする。`createdAt`は作品の初回保存時に設定し、通常保存・別名保存・OS間round-tripで保持する。`updatedAt`はwriterが保存ごとに現在UTCへ更新する。表示時だけ各 OS のローカル日時へ変換する。W0のschemaでreaderの受理文法、writerのcanonical書式と精度を固定する
- v3のwire表現は現行writerを基準にschemaへ列挙する。`formatVersion`はJSON文字列であり、UUIDも項目により直接の文字列または`{"rawValue":"UUID"}`形式を使う。C#モデル側の都合で平坦化して保存形式を変えない

### 2.3 ファイル名と大小文字

- 既知ルート名 (`manifest.json`、`episodes`、`episode-notes` など)の照合は仕様上の綴りを正とする。異なる大小文字の既知項目を別項目として作らない
- macOS / Windows の一般的な大小文字を区別しないファイルシステムを前提に、同一ディレクトリの衝突判定は NFC 正規化後の ordinal case-insensitive で行う。保存済みの本文・タイトルは正規化せず、ファイル名の衝突判定キーだけに使う
- 新しく取り込む添付ファイル名は Windows でも作成可能な名前へ制限する。`< > : " / \ | ? *`、U+0000〜U+001F、末尾の空白／ピリオドを許可しない。大文字小文字を無視し、ファイル名の最初のピリオドより前が `CON` / `PRN` / `AUX` / `NUL` / `COM1`〜`COM9` / `LPT1`〜`LPT9` / `COM¹`〜`COM³` / `LPT¹`〜`LPT³` になる名前も許可しない(`NUL.tar.gz` も不可)
- W0で、APFS / NTFS双方の1 component上限とWindowsのfull path上限を考慮した長さ予算をfixtureで固定する。writerの一時ファイル／一時パッケージ名は保存先basenameへUUID等を付け足さず、同じ親に短い固定prefix + UUIDで作る
- 既存作品に非互換な添付名がある場合、黙って欠落・上書きしない。移行前の名前と変更後の名前をユーザーへ示したうえで安全に改名するか、読み取り専用で開いて修復を促す

### 2.4 前方互換と安全性

- 同一 `formatVersion` の追加機能は、既存の `project.json` / `world.json` と同様に独立したルート項目として追加する。古い writer が失う可能性のある新フィールドを `manifest.json` へ安易に足さない
- 通常保存、別名保存、スナップショット、OS 間 round-trip のすべてで、既知でない非hiddenのルートファイル／ディレクトリを保持する。将来の正式なルート項目はhidden名にせず、`.DS_Store`等のOSメタデータは互換データに含めない
- package 内の symlink / junction / reparse point を辿って package 外を読み書きしない。`..` や絶対パスとして解釈できる入力を拒否する
- 壊れた JSON や不正参照を黙って正常値に見せない。manifestが参照する話本文と`world.json`が参照する世界観本文は必須で、欠損・I/O失敗・invalid UTF-8を型付きエラーにする。空の話メモはファイル省略可能だが、メモファイルが存在する場合はvalid UTF-8を要求する
- 旧実装の「本文ファイル欠損は空本文」という救済はD-039で廃止した。修復が必要な作品は元packageを直接変更せず、後続のPackage Validatorが作る検証済み修復コピーを利用者に選ばせる

### 2.5 保存の成立条件

- 「一時パッケージを保存先と同じ親ディレクトリへ完全に作る → 最低限の構造を検証する → 既存パッケージと入れ替える」という結果を両 OS で満たす
- OS API が異なるため、macOS の `replaceItemAt` と同じ API の使用は要求しない。Windows では rename / backup / recovery を組み合わせ、完成前のデータで既存の正常な作品を上書きしない
- file lock、ウイルス対策ソフト、同期クライアント等により入れ替えできない場合は保存失敗として通知し、メモリ上の dirty 状態と既存パッケージを維持する
- Windows writerはW1で`destination` / `temp` / `backup`の状態遷移を定義し、各rename地点へ障害注入する。commit完了後だけdirtyを解除し、rollbackにも失敗した場合はbackupを消さず回復手順を通知する。起動時の回復優先順位とsharing violationのretry上限もADRへ記録する
- package 内部のファイルを複数端末から同時編集することは当面サポートしない。クラウド同期フォルダ利用時も競合解決機能があるとは表現しない
- D-061のDevice Syncもこの制限の例外としてpackageを同時編集する仕組みではない。app-private packageを各端末のdurable / materialized snapshotとし、別record protocolのremote Work headをsafe boundaryで既存保存経路へmaterializeする。package外部変更の検出と競合解決は引き続きExternal Change / Conflict Gateで扱う。D-059／D-060のremote Episode head installは履歴として維持する
- D-063のImportは外部原本を変更せず、network／accountに依存しないlocal reserveとして新しい`SyncWorkID`のapp-private copyを作る。同じdocument ID／タイトル／構造、または以前Exportした同じpackageでもremote workへautomatic rebind／deduplicateしない。以前確認済みaccount／tenant scopeの一時offlineなら同じscopeのpendingだけを再開し、unscopedまたはdifferent-account中に新しく作ったunbound local-only workは後から現れたscopeへautomatic adopt／uploadしない。旧scopeへexactに結び付いた検証済みcopyだけをaccount-quarantinedとして扱う。Exportはactive URL／session／WorkID／bindingを変えず、`DocumentCopyingRepository`を含むportable package能力がない場合はplain document saveへfallbackしない
- Import／Exportはsourceと同じ内容を持つsibling staging packageをpre／post treeとlogical read-backで検証してからdestinationをno-overwrite／atomicに確定する。検出した不一致はfail-closedにするが、copy中のhard-link／外部process変更を完全に防ぐTOCTOU耐性は主張せず、Package Validator／External Change / Conflict Gateを未完了として維持する。現在端末のsource packageに存在するattachment、snapshot履歴、非hidden未知root itemを保持するが、D-063 remote bootstrapが別端末から取得するのはWorkSnapshotだけであり、これらのresourceが復元されたとは扱わない

## 3. Windows / WinUI 版の層構成

Windows 版は同じリポジトリの `Windows/` 配下に置く。ツールチェーンは分けるが、仕様・fixture・変更履歴を同じコミットで参照できる monorepo とする。

```text
Windows/
├── Fuminiwa.Windows.sln
├── Fuminiwa.Core             (C#、OS/UI 非依存モデルと純粋ロジック)
├── Fuminiwa.Storage.Novelpkg (.novelpkg の読み書き)
├── Fuminiwa.Export           (Core のみに依存する出力)
├── Fuminiwa.Editor           (UI 非依存のEditor rules / actions)
├── Fuminiwa.Editor.WinUI     (IME、Undo、選択範囲、native adapter)
├── Fuminiwa.App.WinUI        (window、navigation、picker、AppState 相当)
└── Tests
```

依存方向は macOS 版と同じ意味に揃える。

```text
App.WinUI ──→ Core / Storage.Novelpkg / Export / Editor.WinUI
Storage.Novelpkg ──→ Core
Export ──→ Core
Editor.WinUI ──→ Core / Editor
Editor ──→ Core
Core ──→ 依存なし
```

- WinUI 型を `Core`、保存 schema、Export の公開モデルへ出さない
- 別名保存は`NovelDocument`だけで再構築しない。Windows Storageにも`SaveCopy(document, sourcePackage, destinationPackage)`相当、またはsource packageを保持する`DocumentSession`を設け、App層へpackage内部構造を漏らさず未知項目・添付・スナップショットを引き継ぐ
- UI の選択状態、最近使った作品、ウィンドウ位置、toolbar のカスタマイズは `.novelpkg` に保存しない
- Windows エディタでも「編集中テキストの正は native editor」「モデルからの全置換は話切り替え時だけ」「IME 変換中はモデル同期・自動介入をしない」を守る
- `NSTextView` の挙動を表面的に模倣せず、WinUI の IME / Undo / accessibility で同じ利用者向け結果を実現する

## 4. 互換性 fixture と品質ゲート

Windows 実装着手前の W0 で、`CompatibilityFixtures/` に次を追加する。

- v1 / v2 の読み込み fixture と、全既知項目を含む v3 基準 fixture
- 日本語、絵文字、結合文字、NFC / NFD、全角スペース、空章、空話、CRLF / CR / LF を含む作品
- characters / plot / flags / project / world / world-notes / attachments / snapshots / 未知ルート項目を含む作品
- 言語非依存の JSON Schema または同等のフィールド表。Swift の `Codable` 実装だけを仕様にしない
- Export の期待結果と、純粋な Editor rule の入出力 fixture
- Windows予約名(多重拡張子・上付き数字を含む)、大小文字／正規化衝突、component / full path境界、短い一時名、symlink拒否のfixture。junction / reparse pointは拒否すべき宣言的test vectorをW0で定義し、実体を使う動的テストはW1で追加する
- fixtureごとに期待論理モデルと相対パス + SHA-256 inventoryを持つ。JSONは意味比較、本文・添付・未知項目はbyte比較とし、ACL / xattr / ADS / ファイル時刻は互換対象外にする

### 4.1 W0 の完了条件

1. v1 / v2 / v3を別々に検証できるschemaまたは同等のフィールド表と、上記fixtureがリポジトリに入っている
2. macOS reader / writerが共通fixtureを読み書きし、既知データ・添付・スナップショット・非hidden未知ルート項目をMac内round-tripで失わない
3. 現行macOS実装に残る次の差分を補修し、失敗fixtureで検証する
   - package rootと既知pathの各componentでsymlinkを辿らない。Windows側でjunction / reparse pointを拒否するための期待結果もfixtureに定義する
   - **macOS補修済み、fixture体系への統合は未完了**: manifest / world参照payloadの欠損・I/O失敗・invalid UTF-8と、存在するメモのinvalid UTF-8を空値へ救済しない。空メモのファイル省略だけを維持する
   - **未完了**: 壊れたJSON、不正参照、重複ID、version別必須項目の欠落を、空値や旧versionとして黙って救済しない。互換のため残す救済だけをschemaに列挙する
   - Windows予約名、既知ルート名のcase variant、大小文字／Unicode正規化衝突、component / full path予算を添付取込時とpackage検証時に拒否する
   - 通常保存・別名保存・snapshot作成／復元で保存先basenameに依存しない短い一時名を使い、置換前に一時packageの最低限の構造を検証する。失敗注入で既存packageとdirty状態の保持を確認する
   - UUID・IDファイル名・日時のcanonical出力とreaderの受理範囲をschemaどおり検証する
   - snapshotの論理作成日時はファイル名のtimestampを正とし、作成日時／更新日時などOSのファイル属性へ依存しない。自動スナップショットは`auto-<timestamp>.novelpkg`とし、`auto-`は種別だけを表す。timestampの読み方は手動分と同じとする(D-074)
4. `./Scripts/check.sh` が共通fixture検証を含み、macOS上で全通しする

W0ではWindowsアプリやWindows reader / writerの存在を要求しない。W0完了後に、確定したschemaとfixtureを入力としてW1を開始する。

### 4.2 W1 の相互運用完了条件

1. macOS writer → Windows reader で全既知データが一致する
2. Windows writer → macOS reader で全既知データが一致する
3. macOS → Windows 保存 → macOS、および逆方向の round-trip で未知ルート項目・添付・スナップショットが失われない
4. 両 writer が v3 を出力し、配列順・UUID・日時・Unicode の契約を満たす
5. Windows のcase-insensitive・Unicode正規化衝突、禁止添付名、path長境界、保存先lock、途中失敗をテストする

macOS の `./Scripts/check.sh` と、W1で追加する `pwsh -File Windows/Scripts/check.ps1` は、それぞれ共通fixtureを必ず検証する。Windows側はrestore、format / analyzer、unit、fixture、buildの順に実行する。クラウドCIを使わない方針(D-014)は維持する。W1以降、またはWindows reader / writerが存在する状態で相互運用契約を変えるPRは、同一commit SHAに対する両OSの検証結果をマージ前に記録する。

## 5. 実装順

1. **W0: 契約固定** — schema / fixture / ファイル名 portability test を macOS 側へ追加する
2. **W1: Windows Core + Storage** — v1〜v3 読み込み、v3 保存、双方向 round-trip を先に成立させる
3. **W2: 最小 WinUI 執筆環境** — 新規・開く・保存、章／話 Outline、日本語 IME、Undo / Redo、自動保存
4. **W3: 執筆支援 parity** — メモ、人物、プロット、伏線、世界観、資料、検索、スナップショット
5. **W4: Export / 配布** — Phase 5 の共通規則に合わせた出力と Windows 配布

macOS の次タスクPackage Validator GateはW0の一部と重なるため、同じschema・fixture・失敗分類を使って進める。ただしPackage Validatorの一部を実装しただけでW0完了とはしない。Windows reader / writerが存在する前の `.novelpkg` schema変更は、本書・schema・fixture・macOS検証を同じPRで更新する。W1以降はWindows検証も完了条件へ加える。

W1開始時にWindows用ADRを追加し、対象.NET SDK、Windows App SDK / WinUI 3のversion、最低対応Windows、packaged / unpackaged配布方針を固定する。`global.json`と中央package管理でローカルビルドを再現可能にする。W2開始前にnative editor controlを選定し、日本語IME composition・Undo / Redo・選択範囲・アクセシビリティの状態遷移とテスト方針を記録する。

Windowsで`.novelpkg`を開くときはFolderPickerを使う。新規作成／別名保存は親フォルダを選び、アプリ内でportable filename規則に適合する作品名を入力して、その配下へ`.novelpkg`ディレクトリを作る。単一ファイル用のFileSavePickerをpackage保存に流用しない。

## 6. Windows 上で Codex を使う作業方法

- WinUI 3、Windows App SDK、Windows の日本語 IME、NTFS、picker、署名／配布は Windows 実機でしか十分に検証できないため、Windows 版の実装主体は Windows 上の Codex とする
- Windows でもこのリポジトリを clone し、`Windows/` を作業対象にする。同じ branch を Mac と Windows から同時に編集せず、機能単位の branch / PR で受け渡す
- Windows 用 `AGENTS.md` はW0、ローカル検証スクリプトはW1の最初に追加し、本書、D-036、`.novelpkg` fixture を読む手順を必須化する
- macOS 側の Codex は schema / fixture / Mac reader-writer、Windows 側の Codex は C# / WinUI と Windows 固有テストを担当し、互換 PR では双方の結果を照合する

## 7. D-071 Note Syncのクロスプラットフォーム契約

現行通常Appのlive syncは、作品を棚の1項目として扱い、転送はentity record（`work`／`chapter`／`episode`／`character`／`plotCard`／`flag`／`worldNote`）とする。Windows／AndroidはCloudKit型を持たず、同じportable JSON／fixtureを再実装する。

- 含める: 作品タイトル／あらすじ、章・話のstable ID／所属／タイトル／配列順、本文／話メモ、人物、プロットカード、伏線、世界観ノート
- 含めない: attachment／資料binary、手動スナップショット履歴、外観／本文フォント等の端末設定、selection／navigation、local path／bookmark
- `.novelpkg` v3は各端末の正本のまま変更せず、CloudKit metadata、dirty set、engine stateをpackageへ保存しない
- 衝突は同じentityのlocal dirtyとserver version不一致だけで検出する。3-way mergeと時計LWWはportable契約に含めない。選択肢はこの端末／remote／両方を別WorkIDとして残す
- `NoteSyncWireProtocol.currentVersion = 1`はEpisode wire v1、Work wire v1とは別namespaceである

D-061の`WorkSnapshot`／whole revision／3-way merge契約は履歴であり、通常Appのlive経路ではない。詳細は[DEVICE_SYNC.md](DEVICE_SYNC.md) 0章と[DECISIONS.md](DECISIONS.md) D-071を正とする。

## 7-hist. D-061 Work Syncのクロスプラットフォーム契約（履歴）

### 7.1 Portable snapshotとscope

当時の通常Appのlive syncは、`NovelDocument`全体をcanonical化した`WorkSnapshot` v1を共有単位にしていた。

- 含める: 作品タイトル／あらすじ、章・話のstable ID／所属／タイトル／配列順、本文／話メモ、人物、プロットカード、伏線、世界観ノート
- 含めない: attachment／資料binary、snapshot履歴、外観／本文フォント等の端末設定、selection／navigation、local path／bookmark、cloud catalog／account／binding metadata。D-063のlibrary／new-device bootstrapは別protocol境界としてWorkSnapshotを列挙・取得するが、catalog metadata自体をsnapshotへ埋め込まない
- `.novelpkg` v3はportable／materialized snapshotのまま変更せず、Work binding、revision、mutation、journal、CloudKit metadataをpackageへ保存しない
- ID順にcanonical化するentity本体と、利用者の表示順を表すorder列を分離する。OSのfile列挙順、locale、timestampを順序へ使わない

canonical `WorkSnapshot`は48 MiB、各StringはUTF-8 1 MiB、canonical `WorkRevision`は50 MiBを上限とする。file journalは320 MiB、outboxは3 revision、journal revision storeは5件、conflict descriptorは512件、各descriptor比較値は1 KiBである。descriptorはprefix＋SHA-256へbounded化できるが、完全なbase／local／remote／proposed snapshotをrevision／reviewへ保持する。5 revision、完全なproposed snapshot、bounded conflictsを持つ到達可能な270,439,704 bytesのjournal保存／再読込回帰を通過させる。上限超過時は切り詰め、部分同期、暗黙winner選択をしない。

### 7.2 Local durabilityとstate

各platformは **native editor／form → model → package外Work journalへstage → app-private `.novelpkg`保存 → exact journal confirm → remote** の意味を同じにする。

- staged revisionはpackage保存前のwrite-ahead intentで、confirm前はpublish不可
- stage失敗時もpackageを保存し、次回preflightでpackage snapshotをlocal revisionとして回収
- package保存失敗時はstageをremote headへ昇格しない
- local mutationはFIFOで直列化し、network I/Oはlane外で行う
- responseはsealed mutation／revisionとcurrent journal observationの一致を再検査してから適用し、network中のlocal tailを古い応答で上書きしない
- active WorkSyncで`lastKnownRemoteHead`が存在するのにcurrent remote headがnilなら、初回publishへ読み替えずtyped `remoteHeadMissing`でpublish前に停止する。local head、outbox、last-known remote head、sealed publishをmemory／journalで保持し、remote復帰時に同じlocal revisionを再送する
- package／stage／pending remoteのmaterializationが再起動時に曖昧なら、推測せず利用者選択まで作品編集をgateする

remote snapshotはnative editorへcallbackから直接注入しない。各platform adapterは作品／session／surface／世代、expected digest、IME composition、selection、Undo／Redo、未保存変更を確認し、local saveを終えたsafe boundaryだけでpackageへmaterializeする。packageを再読込したsnapshotがexact一致した場合だけjournalをacknowledgeする。

### 7.3 Portable Work wire v1とmerge

`WorkSyncWireProtocol.currentVersion = 1`はEpisode用`SyncWireProtocol.currentVersion = 1`とは別namespaceである。Swift、将来のC#／Kotlin実装はWork専用fixtureから次を一致させる。

- canonical UTF-8 JSON、canonical UUID、snapshot／revision digest、親順
- immutable whole revisionと最大2 parent
- `mutationID + expected head revision ID + expected head snapshot digest`のCAS
- mutation receiptによる同じcommandのidempotent retryと、同じID／別commandの拒否
- local FIFOとnetwork response observation CAS
- stable ID／field／orderを使う作品全体3-way merge

片側変更と証明済み非重複変更だけを自動mergeする。同じfield／本文範囲、delete対edit／move／reorder、両側の異なるorder変更、同一IDの異なる追加、祖先不明、resource budget超過は、この端末／iCloud／統合案の3面reviewへ送る。review中もlocal編集を継続し、追加local headと新remote headを捨てず再評価する。

Apple adapterは同じprivate custom zone内でEpisodeとは別の`FUMINIWAWorkControlV1`、`FUMINIWAWorkRevisionV1`、`FUMINIWAWorkMutationReceiptV1`を使う。whole canonical revisionを`CKAsset`へ保存し、revision／receipt／controlをatomicに更新する。CloudKitでは0-parent root revisionの`parentRevisionIDs` fieldを省略し、nilを空parentへdecodeする。これは空Listのfield型推論を避けるadapter表現であり、portable Work revisionの0-parent契約を変えない。将来の非Apple backendも同じCAS、receipt、immutable revision、read-backの意味を提供しなければならないが、CloudKit record layoutをportable APIにはしない。

### 7.4 Cutoverと完了条件

D-061／D-063は一般配布前のdevelopment cutoverである。Work headとEpisode headは独立して相互の更新を観測せず、D-063のcatalog projection／locator／registryも旧buildと互換運用しないため、旧Episode-only／D-061-only clientとの同時利用は非対応である。real CloudKitへdeploy／出荷していない前提で、development CloudKit custom zoneと旧local sync metadata／journal／registryを対象version確認後にresetし、全test端末を同じD-063 buildへ更新して検証する。staged revision、outbox、pending materialization／create／bind／open、未解決reviewがある場合はresetしない。全hidden packageをexact inventoryし、registry再構築／保全または検証済みExportで回収する。attachment／snapshot／unknown rootはremoteから戻らないためhidden root自体をmetadata resetで削除せず、未到達／未知version／不整合／Export失敗が1件でもあればresetを停止する。production upgradeを行う場合は別Decisionでdata migrationまたはminimum client version fenceを実装・検証する。それまでは出荷不可で、mixed-client compatibilityをfixtureや成功条件に含めない。

D-061のSwift側local証跡は、Work Domain focused 44 / 44件（5 suites）、CloudKit schema focused 3 / 3件を含む`NovelSyncCloudKit` full 59 / 59件（15 suites）、Mac `NovelAppDeviceSyncTests` 64 / 64件（integration 57＋edit-intent 4＋root 3）、iOS focused 56 / 56件（integration 49＋UI 7）である。generic iOS build／build-for-testingも通過した。Work conflict UIは既存Mac focused coverageを含め最終source監査した。

D-063 macOSの現行local証跡は、near-cap 270,439,704 bytesを含む`NovelSync` 142 / 142件（14 suites）と`NovelSyncCloudKit` 84 / 84件である。署名済み実Mac Appから既存1作品のroot Work revision／control／receiptをDevelopment環境へ初回publishしてread-backし、registry `synced`、journal outbox 0／`synchronized`、catalog cache 1件を確認した。`Invalid Arguments`／rate mitigationの再発はない。D-063外部Gate変更前の履歴としてFUMINIWA macOS full xcresult device cases 208 / 208件、iOS full 137 / 137件、Experimental 205 / 205件、fresh local CI、実Mac visual／Accessibility tree PASSを維持するが、これらをiOS cloud-library extensionの現行差分へ流用しない。iOS / iPadOS extensionはWorkID棚、remote-only download、local-first new／Import、portable Export、legacy private-copy recoveryまでsource実装済みで、現行Simulator focused 28 / 28件（1 suite）、先行Device Sync device cases 89 / 89件、fresh checkの同target 86 / 86 top-level（4 suites）、hosted App 79 / 79件、generic build／build-for-testingを通過した。fresh `./Scripts/check.sh`も`All checks passed`であり、先行dynamic device casesとfresh top-level件数は集計単位が異なる。Experimentalは既存研究targetの分離回帰であってD-063や通常版provider機能のportable実装を、Accessibility tree確認は手動VoiceOver完了を証明しない。これらが存在しても、次を完了扱いにしない。

- C#／KotlinによるWork wire／journal／merge fixtureの独立再実装
- paired native Mac↔iPhone、実account／offline／account switch、実OS process kill、手動VoiceOver／実機IME
- Developer Program上のcontainer／profile／schema deployと署名済み実CloudKit
- attachment／snapshot履歴／端末設定の同期（D-063では意図的にWorkSnapshot対象外）
- Package Validator、External Change / Conflict、W0／Windows round-trip

### 7.5 D-063 Work library／bootstrapのportable意味

D-063はApple private CloudKitを最初のadapterとして実装するが、domain上は次の意味をCloudKit record layoutから分離する。

- library entryのidentityは`SyncWorkID`であり、完全タイトルdigest／byte countを伴うbounded表示タイトルと、exact head revision ID／snapshot digest／byte countを持つ
- headが存在しないworkは別端末で開けるcatalog entryにしない。表示日時は並び順hintであり、identity／CAS／merge winnerに使わない
- remote-only openはonline＋account／tenant scope確認後だけ表示時headを検証し、durable pending intentをasset fetchより先に作り、full revisionのwork／parents／digest／byte countをread-backしてからapp-private packageへmaterializeする
- local working copyは`SyncWorkID`から導出するcanonical locatorを使い、local path／bookmarkをwire、package、remote recordへ保存しない。diagnostic logにもapp-private path／WorkIDを出さない
- new／Importは作成予定snapshotのexpected package attestationをWorkID reservationへstaging前にdurable化する。legacy package／expected attestation nil reservationはdocument ID一致で採用せずquarantineする。package installはsame-root staging、完全read-back、no-overwrite atomic renameとし、既存finalがexact prepared stateでない場合は置換せずreviewへ送る。staging read-back不一致はstagingを破棄し、再起動後もworking copyへ採用しない
- local registryはoffline openのinventoryだがaccount binding authorityではない。account／tenant変更時も検証済みlocal packageは開いて編集できるが、旧scopeのremote title／binding／pending revisionとlocal packageのないremote-only entryをquarantineし、新scopeへautomatic uploadしない
- Domain bind→registry mark間で終了しても、exact package／pending projection／outbox-free journalが一致すればofflineかつremote catalog 0件から当該WorkIDだけを復旧する
- remote catalog cacheはbounded recent setとし、refresh failureで既存cacheを空にしない。malformed rowは当該rowだけを隔離する。以前確認済みsame scopeの一時offlineではremote-only行を表示できてもopen／download不可とする。`accountRequired`／unscoped／mismatchではlocal packageのないremote row／titleとApp `remoteOpenPending` rowをquarantineして棚から除外する。connection availableのcurrent catalogからacknowledged WorkIDが欠落した場合は`.cloudUnavailable`とし、checkmark／open／uploadを停止してlocal packageを保持する
- new／Importはnetwork／accountおよびremote catalog refresh成否に依存せず毎回new WorkIDのprivate copyをlocal installできる。以前確認済みaccount／tenant scopeの一時offlineなら同scope pendingだけを自動再開し、unscopedまたはdifferent-account中に新しく作ったunbound workは将来scopeへautomatic adopt／uploadしない。明示の「iCloudに保存」はD-072。旧scopeへexactに結び付いた検証済みcopyだけをaccount-quarantinedとして扱う。Exportはactive identity不変とし、document ID／title／structureによるdedupe／automatic rebindを行わない
- iOS / iPadOSのD-063以前のprivate packageは自動upload／削除／rekeyせず、利用者の明示操作でnew WorkIDのportable copyへ取り込み、new copyのinstall／read-back後も旧bytesを保全する。これはApple adapter固有のlegacy recoveryであり、portable package identityをremote WorkIDへ埋め込むmigrationではない
- cold Files / Open Withの外部packageはaccount／catalog確認中に破棄せず、platform bootstrap完了後のImportへ直列化する。外部原本をopen-in-placeせず、作品棚へ戻るnavigationでactive WorkID／packageを切り替えない
- この端末のlocal removeと複製はD-072。CloudKit tombstone／複数端末retentionは別Decisionにする

将来のWindows／Android backendが同じlibrary UXを実装する場合も、CloudKit record typeは再利用せず、上記identity、account／tenant fence、durable intent、exact head fetch、no-overwrite install、Product Truthを満たすadapterを選ぶ。Apple版のcatalog実装だけでC#／KotlinのWork library互換を完了扱いにしない。

`.novelpkg` Exportはportable artifactのままで、現在端末に存在するattachment、snapshot履歴、非hidden未知root itemを保持する。remote WorkSnapshot bootstrapにはそれらが含まれないため、別端末でExportしたpackageが元端末の完全mirrorとは限らない。UI／仕様でDevice Syncを完全backup、package全体同期、E2EEと表現しない。

## 8. D-059／D-060 Episode Sync契約（実装・検証履歴）

### 8.1 `.novelpkg`との境界

- `.novelpkg`はOS間で持ち運べる作品snapshotであり、各端末のapp-private領域でdurableに保存する。CloudKit固有metadataを加えない
- 確定本文は各OSで **native editor → model → `.novelpkg` → package外journal → remote** の順に扱い、transportをEditor入力やlocal保存の待ち条件にしない
- package commit前のfull-body WALは各platformのapp-private process-kill recovery guardであり、portable `.novelpkg`、Device Sync wire、journal schema v2の一部ではない。各platformはscope／sequence／digestを検査してpackageとjournalへ回収した後だけmarkerを削除する同等の耐久性を実装する
- Apple版WALのreview用`preservedMarkers`は最大3本文とし、さらに未知／不整合なbranchが来た場合は既存package／active WAL／preserved本文を保持してchoice／remote mutationなしのlocal integrity errorへfail-closedにする。このapp-private capをportable wire／journal schemaの値へ読み替えない
- live syncはpackageとは別の`NovelSync` wireを使い、EpisodeIDごとのimmutable revision、remote head、soft lease、mutation receiptを扱う。remote writerは1端末だが、全端末のlocal Editorはholder／network／account確認に依存せず編集できる
- sync work ID、local working copy／replica／device／session ID、lease epoch、remote revision ID、outbox、detached branch journalをpackageへ保存しない。export / importだけでremote accountへ自動再接続しない
- remote revisionをactiveなnative editorへ突然installしない。各OS adapterはsurface／作品／話／Editor世代、expected digest、IME composition、Undo／Redo、selection、未journaled本文を検査するexternal replacement境界を持ち、安全でなければjournalへpending materializationとして延期する
- Apple版のWAL／merge recovery rootは信頼済みapp-private ancestorへanchorし、中間／最終symlinkと通常のroot identity差し替えをfail-closedにする。ただし、同時renameを行う悪意あるsame-UID processへの完全なTOCTOU耐性はportable契約に含めず、External Change / Conflict Gateを未完了として維持する
- S1で`.novelpkg` schemaと`formatVersion`を変更しない。将来sync metadataをportable packageへ加える場合はD-036どおりschema / fixture / macOS / iOS / Windows round-tripを同時に更新する別Decisionを必要とする

### 8.2 Portable protocol

共有する正は[DEVICE_SYNC.md](DEVICE_SYNC.md)の**wire protocol version 1**、**package外journal schema version 2**、canonical JSON / journal / state / merge fixtureである。D-060で`SyncWireProtocol.currentVersion`は1のまま維持し、local working copy identity、detached branch、remote未確認、review draft、pending materialization等はjournal schema v2へ置いた。現行Swiftにはwire v1 canonical JSON、journal v1／v2 migration、local-first state、multi-hunk merge fixtureを`NovelKit/Tests/NovelSyncTests/Fixtures/`とscenario testへchecked-in済みである。Swiftの`Codable`実装だけを仕様にはせず、Windows / Android実装開始時は同じfixture / scenarioを言語非依存の共通配置から各testへ入力できる形にし、期待結果を変更せず再利用する。

- UTF-8 JSON、lower camel case、canonical UUID、0以上のsigned 64-bit lease epochを使う
- 本文を正規化せず、decoded bodyのexact UTF-8 bytesをSHA-256で検証する
- `mutationID + expectedRemoteHeadRevisionID + holderDeviceID + holderSessionID + leaseEpoch`をpublish条件とし、時計LWWを禁止する
- remote authorityのclaim／internal takeoverは、epochだけでなく観測したremote revision IDとcontent digestも同じcontrol CASで検査する。headが進んでいればholder / epochを変更せず再評価する。現行wire v1に`HandoffRequest` recordはなく、cooperative request／flush／grantは将来のadditive Decision／protocolとする。これらを通常UIの操作やlocal Editorの入力許可にしない
- 通常revisionは0または1 parent、競合解決は`[remoteHead, localFork]`の2 parentを持つimmutable merge revisionとする
- transportは同じmutationIDのretryをidempotentにし、head / epochのcompare-and-swapとrevision / receipt / controlのatomic commitを提供する
- OSごとの日時精度、push順序、filesystem timestamp、locale、case-foldingをwinner選択へ使わない

本文入力、paste、delete、Undo、Redo、ルビ、傍点等で本文が実際に変わった場合だけedit intentを作り、選択、copy、scrollだけではremote stateを変えない。Editor表示時のobserved baselineはexplicit edit／pending revisionを作らずclaim／publishもしない。祖先不明時のreviewもauthorityを変更しない。authorityのない変更もstable detached branchとして先にjournalへ保存する。再接続時はremote不変なら自動publish、同一結果ならcollapse、証明済み非重複なら2-parent auto merge、同一範囲変更または祖先不明だけreviewとする。review中の追加編集と、review中に進んだremote headも別revisionとして保持する。

`NovelSync`のSwift型自体をWindows / Androidから参照しない。Swift、C#、Kotlinの各実装は同じwire v1／journal schema v2／state fixtureから、decode結果、migration、state遷移、CAS command、digest、merge結果／conflict分類を一致させる。diff / mergeはnormalizationしないUnicode scalar列を基準にし、UTF-16 indexやnative editor rangeをwire／journalへ保存しない。multi-hunk mergeは各入力4 MiB／1,000,000 scalar、edit distance 1,024、diff work 16,000,000の固定budgetとし、超過をreviewへ分類する同じ期待結果をfixture化する。

journalのportable resource fixtureは、pending revision最大5件、競合保持3件、materialization graph 4件、fresh-session relay込みpending 5件、JSON 80 MiBを固定する。1 MiBのJSON control character本文を全revisionへ置いた最大状態は75,506,494 bytesで、encode／save／loadの期待結果をSwift、C#、Kotlinで一致させる。上限超過時は切り詰めや部分適用をせずfail-closedにする。

### 8.3 Platform adapter

| Platform | Domain | Transport adapter | Native editor |
| --- | --- | --- | --- |
| macOS | Swift `NovelSync` | `NovelSyncCloudKit`（private CloudKit + CKSyncEngine） | NSTextView / TextKit 2 |
| iOS / iPadOS | Swift `NovelSync` | `NovelSyncCloudKit`（private CloudKit + CKSyncEngine） | UITextView / TextKit 2 |
| Windows（将来） | C#でprotocolを再実装 | 未決定。CloudKit型やCloudKit Web Servicesをdomainへ持ち込まない | WinUI native editor |
| Android（将来） | Kotlin等でprotocolを再実装 | 未決定 | Android native editor |

D-059／D-060 Episode trackのApple版はprivate database内の単一固定custom zoneを使い、全workをopaque `syncWorkID` field / record nameで分離する。作品ごとにzoneを増やさない。CloudKit record change tag、CKAsset、account、push、change tokenは`NovelSyncCloudKit`内だけで扱い、portable wire / fixtureへ出さない。この履歴trackのremote descriptorはstructure一致の **明示binding候補** と既存binding検査にだけ使い、D-063の作品棚／package bootstrap／automatic bindingとは別物である。SwiftDataはcanonical storeにしない。

account／CloudKit bootstrap／entitlement確認不能でも、既存bindingをapp-private local metadata／journal resolverから復元し、package、WAL、package外journalへのlocal保存を継続する。remote descriptorがない状態ではtransport mutationを送らず、旧account scopeのlive再確認が成功するまで旧account transportへ送らない。一時的なtransport／CloudKit unavailableはofflineとしてbootstrapを再試行し、no account／account変更／entitlement・設定不整合は設定確認として区別する。accountが変わっていれば旧scopeのrevision／binding／journalを新account transportへ渡さない。Windows / Androidの将来adapterもaccount／tenant境界を同じtransport fenceとして実装する。

Windows / Android対応時は、その時点のbackendを別Decisionで選ぶ。CloudKit Web Servicesや自前serverを今から前提にせず、Apple adapterのrecord layoutをそのまま公共APIともしない。ただし別backendもmutation receipt、expected head / epoch CAS、atomic commit、immutable revision、fencingを同じ意味で提供できなければならない。

### 8.4 S1範囲と実装順

S1は、初回binding時に構造が一致し、package外のbinding snapshotへ含めたEpisodeIDのbody handoffだけを扱う。後から追加した話はlocal-onlyとし、既存対象話まで停止させず、remoteへ新しい構造を暗黙生成もしない。作品cloud library / package bootstrap、章・話構造、タイトル、メモ、作品補助data、資料、snapshot、attachment、live collaborationは後続である。構造が一致しない作品へ本文だけを推測installしない。

Apple S1のD-059基準はcommit `508947d2`の全ローカル回帰で固定した。この履歴を維持したまま、D-060のjournal v2、authority非依存local-first保存、observed baseline、automatic collapse／bounded multi-hunk 2-parent merge、exact authority takeoverを実装し、`NovelSync` 94 / 94件（local-first 33件、既存coordinator 18件）と`NovelSyncCloudKit` 48 / 48件が通過した。Mac 45 / 45件とprivate-root 1 / 1件、iOS Simulator 42 / 42件とnative focused 2 / 2件、host上2 coordinatorのin-memory local fakeも通過した。完了報告は **source実装**、**Simulator／local fake server**、**署名済みMac＋iPhoneによる実CloudKit** を分離し、paired native Mac↔iPhone、手動VoiceOver／実OS kill、cooperative handoff protocol、外部Gateを完了扱いにしない。詳細は[DEVICE_SYNC.md](DEVICE_SYNC.md) 15章を正とする。WindowsのW0〜W4は引き続き`.novelpkg` trackの順序であり、Apple S1の完了をW0 / W1へ読み替えない。Windows / Androidの将来sync実装はwire v1／journal schema v2／state・merge fixtureを入力として独立開始できる。
