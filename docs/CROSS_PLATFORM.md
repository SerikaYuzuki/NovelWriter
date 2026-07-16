# クロスプラットフォーム設計契約

**契約版: 1 / 対象: macOS (SwiftUI + AppKit)・Windows (WinUI 3)**

**状態: 契約承認、W0未完了。** 現行macOS writerが本書のportable filename・path traversal要件をすべて保証済みという意味ではない。Windows W1へ進む前にW0でschema・golden fixture・macOS側の検証と必要な補修を完了する。Windows reader / writerとの双方向round-tripはW1の完了条件であり、W0には要求しない。

本書は、macOS 版と将来の Windows 版が同じ作品を安全に開き、編集し、再保存するための言語・UI フレームワーク非依存の契約である。アーキテクチャ全体は [DESIGN.md](DESIGN.md)、決定記録は [DECISIONS.md](DECISIONS.md) D-036 を正とする。

## 1. 共有するもの／OS ごとに実装するもの

| 対象 | 共有方法 | 備考 |
| --- | --- | --- |
| `.novelpkg` v1〜v3 の読み込み、v3 の保存仕様 | 本書、言語非依存 schema、golden fixture | 最優先の互換境界。macOS が保存した作品を Windows で開き、その逆も成立させる |
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
- 壊れた JSON や不正参照を黙って正常値に見せない。現行仕様で救済が明記された「本文ファイル欠損は空本文」以外は、型付きエラーまたは明示的な修復導線にする

### 2.5 保存の成立条件

- 「一時パッケージを保存先と同じ親ディレクトリへ完全に作る → 最低限の構造を検証する → 既存パッケージと入れ替える」という結果を両 OS で満たす
- OS API が異なるため、macOS の `replaceItemAt` と同じ API の使用は要求しない。Windows では rename / backup / recovery を組み合わせ、完成前のデータで既存の正常な作品を上書きしない
- file lock、ウイルス対策ソフト、同期クライアント等により入れ替えできない場合は保存失敗として通知し、メモリ上の dirty 状態と既存パッケージを維持する
- Windows writerはW1で`destination` / `temp` / `backup`の状態遷移を定義し、各rename地点へ障害注入する。commit完了後だけdirtyを解除し、rollbackにも失敗した場合はbackupを消さず回復手順を通知する。起動時の回復優先順位とsharing violationのretry上限もADRへ記録する
- package 内部のファイルを複数端末から同時編集することは当面サポートしない。クラウド同期フォルダ利用時も競合解決機能があるとは表現しない

## 3. Windows / WinUI 版の層構成

Windows 版は同じリポジトリの `Windows/` 配下に置く。ツールチェーンは分けるが、仕様・fixture・変更履歴を同じコミットで参照できる monorepo とする。

```text
Windows/
├── NovelWriter.Windows.sln
├── NovelWriter.Core             (C#、OS/UI 非依存モデルと純粋ロジック)
├── NovelWriter.Storage.Novelpkg (.novelpkg の読み書き)
├── NovelWriter.Export           (Core のみに依存する出力)
├── NovelWriter.Editor           (UI 非依存のEditor rules / actions)
├── NovelWriter.Editor.WinUI     (IME、Undo、選択範囲、native adapter)
├── NovelWriter.App.WinUI        (window、navigation、picker、AppState 相当)
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
   - invalid UTF-8、I/O失敗、壊れたJSON、不正参照、重複ID、version別必須項目の欠落を、空値や旧versionとして黙って救済しない。空メモのファイル省略等、互換のため残す救済だけをschemaに列挙する
   - Windows予約名、既知ルート名のcase variant、大小文字／Unicode正規化衝突、component / full path予算を添付取込時とpackage検証時に拒否する
   - 通常保存・別名保存・snapshot作成／復元で保存先basenameに依存しない短い一時名を使い、置換前に一時packageの最低限の構造を検証する。失敗注入で既存packageとdirty状態の保持を確認する
   - UUID・IDファイル名・日時のcanonical出力とreaderの受理範囲をschemaどおり検証する
   - snapshotの論理作成日時はファイル名のtimestampを正とし、作成日時／更新日時などOSのファイル属性へ依存しない
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

macOS の次タスク Phase 6 と Windows の W0 は独立に進められる。Windows reader / writerが存在する前の `.novelpkg` schema変更は、本書・schema・fixture・macOS検証を同じPRで更新する。W1以降はWindows検証も完了条件へ加える。

W1開始時にWindows用ADRを追加し、対象.NET SDK、Windows App SDK / WinUI 3のversion、最低対応Windows、packaged / unpackaged配布方針を固定する。`global.json`と中央package管理でローカルビルドを再現可能にする。W2開始前にnative editor controlを選定し、日本語IME composition・Undo / Redo・選択範囲・アクセシビリティの状態遷移とテスト方針を記録する。

Windowsで`.novelpkg`を開くときはFolderPickerを使う。新規作成／別名保存は親フォルダを選び、アプリ内でportable filename規則に適合する作品名を入力して、その配下へ`.novelpkg`ディレクトリを作る。単一ファイル用のFileSavePickerをpackage保存に流用しない。

## 6. Windows 上で Codex を使う作業方法

- WinUI 3、Windows App SDK、Windows の日本語 IME、NTFS、picker、署名／配布は Windows 実機でしか十分に検証できないため、Windows 版の実装主体は Windows 上の Codex とする
- Windows でもこのリポジトリを clone し、`Windows/` を作業対象にする。同じ branch を Mac と Windows から同時に編集せず、機能単位の branch / PR で受け渡す
- Windows 用 `AGENTS.md` はW0、ローカル検証スクリプトはW1の最初に追加し、本書、D-036、`.novelpkg` fixture を読む手順を必須化する
- macOS 側の Codex は schema / fixture / Mac reader-writer、Windows 側の Codex は C# / WinUI と Windows 固有テストを担当し、互換 PR では双方の結果を照合する
