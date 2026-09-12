# クロスプラットフォーム設計契約

**現行: `.novelpkg`読込v1〜v3／出力v3、Snapshot Sync v2、Auth wire v1 / 照合: 2026-09-12**

各OSで同じ原稿を安全に扱うため、portable形式、同期wire、domainの意味、純粋ロジックの入出力を共有する。通常保存は各端末のSQLite v2で、DBファイル自体を端末間へ渡さない。Swift側の共有実装は存在するが、WindowsはW0未完了で、Windowsアプリ／reader／writerの実装完了を示すものではない。

上位契約は [DESIGN.md](DESIGN.md)、D-036／D-080／D-088、同期の厳密仕様は [SNAPSHOT_SYNC_V2.md](SNAPSHOT_SYNC_V2.md) と [sync/v2](sync/v2/README.md)、認証は [AUTH.md](AUTH.md)。旧wireとCloudKitはliveへ戻さない。

## 1. 共有するもの／OSごとに実装するもの

| 境界 | 共有するもの | OS側の責任 |
| --- | --- | --- |
| `.novelpkg` | 本書・version別schema・golden/failure fixture | Import／Export codecとfilesystem安全性 |
| Sync v2 | canonical bytes、hash、closed schema、sealed command、account fence、3択、restore | SQLite driver／HTTP／native UI |
| local durability | atomic checkpointとrestart時の結果 | 各OSの独立DB。Apple版初期object bytesはSQLite BLOB |
| domain・順序 | 作品→章→話、ID、配列順、空要素 | Swift／C#の型へ対応付け |
| 編集規則 | 字下げ、ルビ／傍点、文字数、UTF-16とgraphemeのfixture | native IME／selection／Undo |
| 出力 | TXT／Markdown／EPUBの論理結果とfixture | platform別exporter |
| UI | 機能と操作の意味 | native control／layout／shortcut／accessibility |

Apple版はNovelKitを共有し、WindowsはWindows 11のみを対象に、WinUI 3 + C# / .NETで同じ境界を独立実装する(D-088)。配布はMSIなどのインストーラー形式とし、特定の形式や作成ツールはこの決定だけでは固定しない。SwiftUI、AppKit、UIKit、TextKit、Windows handleを保存／wire／共有domainへ持ち込まない。

## 2. `.novelpkg` 相互運用契約

以下は維持する互換要件。各項目が現行reader／writerで完全実装済みとは限らず、未完了の検証体系を4章で扱う。コードが要件と違う場合、仕様を黙って緩めず、差分と補修を記録する。


### 2.1 基本形

- `.novelpkg` は **単一ファイルではなくディレクトリ**である。macOS の package 表示は Finder の UI 上の扱いにすぎず、Windows では拡張子付きフォルダとして扱う
- OS 間の受け渡しで利用する ZIP 等は transport にすぎず、`.novelpkg` の保存形式には含めない。転送手段がディレクトリを保てない場合だけ package 全体を圧縮し、利用前に展開する
- D-080の通常利用ではactive stateとobject bytesをplatform別app-private SQLite v2へ保存し、利用者がportable packageを扱うのは明示的なImport／Export境界だけとする。`.novelpkg`をDB dumpや同期containerにせず、公開互換の受け渡しartifactとして維持する
- パッケージ内のパスは相対パスだけを使う。絶対パス、ドライブ文字、`\` 区切り、セキュリティスコープ付き bookmark、OS 固有 handle を保存しない
- 既知のルート名と ID ベースのファイル名は ASCII とし、パス区切りを JSON 値へ埋め込まない
- 読み込みは v1 / v2 / v3、保存は v3 とする。未対応メジャーは推測で開かず、明示的な非対応エラーにする
- 章順は `manifest.json` の `chapters`、話順は各章の `episodes` の配列順だけを正とする。ファイル列挙順、更新日時、ロケール順を順序として使わない

### 2.2 文字・識別子・日時

- JSON と `.md` は UTF-8 (BOM なし)で読み書きする。JSON のキー名は現在の camelCase を維持する
- 本文、メモ、タイトルなどの Unicode 文字列は、保存時に NFC / NFD 変換や改行変換を暗黙に行わない。入力された値を保持する
- 改行の正規化が必要な出力形式は [PHASE5.md](PHASE5.md) の Export 境界で行い、`.novelpkg` の読み書きでは本文を書き換えない
- JSON内のUUID値はハイフン付き36文字を受理し、英字の大小を区別せず解釈する。新規保存時のJSON値とIDファイル名は大文字形式をcanonicalとする。IDファイル名はcanonicalな大文字名を要求し、JSON値と大小文字だけ異なるファイルを本文欠損として黙って扱わない
- Snapshot Sync境界では同じUUID logical valueをlowercaseでcanonical化する。Importはpackage UUIDをcase-insensitive parseしてからlowercase SQLite／wire値へ変換し、Exportはuppercase package値／IDファイル名へ戻す。packageのraw UUID表記をObjectIDへ直接hashしない
- ChapterIDとEpisodeIDは文書全体で一意、その他のentity IDは各domain内で一意とする。重複IDは後勝ちで上書きせず、読み込み／書き出し前検証で型付きエラーにする
- `manifest.json` の `createdAt` / `updatedAt` は ISO 8601 の UTC 文字列とする。`createdAt`は作品の初回作成時に設定し、Import／Export／OS間round-tripで保持する。`updatedAt`はpackage writerが書き出す際に現在UTCへ更新する。表示時だけ各 OS のローカル日時へ変換する。W0のschemaでreaderの受理文法、writerのcanonical書式と精度を固定する
- v3のwire表現は現行writerを基準にschemaへ列挙する。`formatVersion`はJSON文字列であり、UUIDも項目により直接の文字列または`{"rawValue":"UUID"}`形式を使う。C#モデル側の都合で平坦化して保存形式を変えない

### 2.3 ファイル名と大小文字

- 既知ルート名 (`manifest.json`、`episodes`、`episode-notes` など)の照合は仕様上の綴りを正とする。異なる大小文字の既知項目を別項目として作らない
- macOS / Windows の一般的な大小文字を区別しないファイルシステムを前提に、同一directoryの衝突判定keyは、元のUnicode scalar列へ **Unicode 15.1.0** のNFCを適用し、同版`CaseFolding.txt`のDefault Full Case Folding（status `C`／`F`、Turkic `T`は不使用）を適用し、同版NFCを再適用したUTF-8 bytesとする。Unicode 15.1.0の`UnicodeData.txt`／`CompositionExclusions.txt`／`CaseFolding.txt`から生成したtableとsource hashをpackage互換fixtureへ固定し、Foundation、ICU、locale、Rust／.NET標準APIのversion依存結果をauthorityにしない。元のfile名、本文、タイトル自体は正規化しない
- 新しく取り込む添付ファイル名は Windows でも作成可能な名前へ制限する。`< > : " / \ | ? *`、U+0000〜U+001F、末尾の空白／ピリオドを許可しない。大文字小文字を無視し、ファイル名の最初のピリオドより前が `CON` / `PRN` / `AUX` / `NUL` / `COM1`〜`COM9` / `LPT1`〜`LPT9` / `COM¹`〜`COM³` / `LPT¹`〜`LPT³` になる名前も許可しない(`NUL.tar.gz` も不可)
- portable pathはrootからのrelative component列で検証し、depthは16以下、各original componentはUTF-8で255 bytes以下かつUTF-16で240 code units以下、`/`でjoinしたrelative pathはUTF-8で768 bytes以下かつUTF-16で512 code units以下とする。separatorもrelative budgetへ数え、normalization後の長さへ読み替えない。Export先のabsolute pathはOS別上限を採用直前にも検査する。writerの一時file／一時package名は保存先basenameへUUID等を付け足さず、同じ親に短い固定prefix＋UUIDで作る
- 既存作品に非互換な添付名がある場合、黙って欠落・上書きしない。移行前の名前と変更後の名前をユーザーへ示したうえで安全に改名するか、読み取り専用で開いて修復を促す

### 2.4 前方互換と安全性

- 同一 `formatVersion` の追加機能は、既存の `project.json` / `world.json` と同様に独立したルート項目として追加する。古い writer が失う可能性のある新フィールドを `manifest.json` へ安易に足さない
- package codecの保存・複製とImport／Export／OS間round-tripで、既知でない非hiddenのルートファイル／ディレクトリを保持する。将来の正式なルート項目はhidden名にせず、`.DS_Store`等のOSメタデータは互換データに含めない
- package 内の symlink / junction / reparse point を辿って package 外を読み書きしない。`..` や絶対パスとして解釈できる入力を拒否する
- 壊れた JSON や不正参照を黙って正常値に見せない。manifestが参照する話本文と`world.json`が参照する世界観本文は必須で、欠損・I/O失敗・invalid UTF-8を型付きエラーにする。空の話メモはファイル省略可能だが、メモファイルが存在する場合はvalid UTF-8を要求する
- 旧実装の「本文ファイル欠損は空本文」という救済はD-039で廃止した。修復が必要な作品は元packageを直接変更せず、後続のPackage Validatorが作る検証済み修復コピーを利用者に選ばせる

### 2.5 保存の成立条件

- 「一時パッケージを保存先と同じ親ディレクトリへ完全に作る → 最低限の構造を検証する → 既存パッケージと入れ替える」という結果を両 OS で満たす
- OS API が異なるため、macOS の `replaceItemAt` と同じ API の使用は要求しない。Windows では rename / backup / recovery を組み合わせ、完成前のデータで既存の正常な作品を上書きしない
- file lock、ウイルス対策ソフト、同期クライアント等により入れ替えできない場合は保存失敗として通知し、メモリ上の dirty 状態と既存パッケージを維持する
- Windows writerはW1で`destination` / `temp` / `backup`の状態遷移を定義し、各rename地点へ障害注入する。commit完了後だけdirtyを解除し、rollbackにも失敗した場合はbackupを消さず回復手順を通知する。起動時の回復優先順位とsharing violationのretry上限もADRへ記録する
- package 内部のファイルを複数端末から同時編集することは当面サポートしない。クラウド同期フォルダ利用時も競合解決機能があるとは表現しない
- live同期はSQLite v2のSnapshot／objectを複製する別契約であり、packageの同時編集ではない。Importは新WorkIDを作り、同じdocument ID／titleでもremote workへ自動再接続しない。Exportはactive WorkID／session／account bindingを変えない。
- `NovelSyncV2PortableBridge`が検証済みpackageとv2モデルを変換する。unknown portable resourceはlocal SQLite mirrorへ保全し、通常checkpointでresource引数を省略しても消さない。明示Import／clearだけが置換する。clone／keepBothは参照とbytesを同一transactionで複製する(D-080 item 10)。
- opaque resourceをSnapshot identity／online wireへ混ぜない。package由来の履歴ファイルをv2の履歴へ暗黙変換せず、remote取得だけで別端末の未知resourceまで復元されたと表示しない。
- Exportは一時packageのlogical read-backとresource一致を確認して採用する。検出不一致は失敗にし、sourceと既存destinationを保全する。外部processやhard linkを含む完全なTOCTOU対策は、部分的なread-back検証だけから保証しない。

## 3. Windows / WinUI版の層構成

Windows 11向けコードは同じrepositoryの`Windows/`へ置く計画。Core、Storage.Sqlite、Storage.Novelpkg、Sync.Protocol、Sync.Http、Export、Editor rules、Editor.WinUI、App.WinUIを責務として分ける。実在しないprojectや検証scriptへ「実装済み」とリンクしない。

Coreは依存なし、Storage.Novelpkg／Export／Editor rulesはCoreへ、SQLiteはCore／Sync domainへ、HTTPはSync domainへ依存する。Appがnative UIと各境界を組み立て、保存層へWinUI型を出さない。DB file、path、bookmark、UI設定は同期・portableデータへ入れない。

編集中の正はnative editorとし、IME中にモデル同期・自動介入をしない。本文置換は明示した文書／話切替・安全な採用境界に限定する。Windowsの日本語IME、Undo、NTFS、picker、配布はWindows実機で検証する。

## 4. 互換性fixtureと品質Gate

2026-09-12のcheckoutには`CompatibilityFixtures/`と`Windows/`の実装体系を確認できない。NovelStorage／portable bridgeの個別testsと、sync v2 fixtureは存在するが、それだけでpackage W0や双方向Windows互換が完了したことにはしない。

### 4.1 W0の完了条件

- v1／v2／v3の独立したschemaまたはフィールド表、全既知項目・添付・旧package履歴・非hidden未知rootを含むfixture。
- 日本語、絵文字、結合文字、NFC／NFD、全角空白、空章／空話、CRLF／CR／LFの値保持。
- 論理モデルと相対path＋SHA-256 inventory。JSONは意味比較、本文／添付／未知resourceはbyte比較。ACL／xattr／ADS／file timestampは互換対象外。
- UUID・日時・必須項目・duplicate ID・不正参照、Windows予約名、Unicode 15.1 collision key、depth／path budget、case variantの成功／失敗fixture。
- symlink拒否、Windows junction／reparse pointの期待結果、短い一時名、採用前検証、障害時の元データ保持。
- Mac内のImport→SQLite→Exportで、既知内容・作成日時・添付・unknown resourceを失わないこと。旧package snapshotはportable resourceとして保持し、v2 historyへ混同しない。
- TXT／Markdown／EPUBの期待結果と、純粋Editor ruleの共通入出力fixtureを揃える。
- 共通fixtureを標準ローカル検証へ統合する。missing／invalid UTF-8拒否など部分補修だけでW0完了としない。

### 4.2 W1の相互運用完了条件

Mac writer→Windows reader、Windows writer→Mac reader、双方を経由する往復で上記の値とresourceを保持する。Windowsのsharing violation、rename途中失敗、backup／rollback失敗、caseとpath境界は動的に検証する。dirty解除は採用完了後だけとし、失敗backupを消さない。

Windows reader／writerが存在する段階からは、互換変更の同一commitに対する両OSの結果を記録する。Windows側check scriptはW1で追加し、restore、format/analyzer、unit、fixture、buildをローカルで実行する(D-014)。

## 5. 実装順と判断の時点

| 段階 | 成果 |
| --- | --- |
| W0 | package契約と共通fixture、Swift実装差分の補修 |
| W1 | C# Core／SQLite／package codec、双方のround-tripとrestart |
| W2 | WinUI最小執筆、native IME／Undo／accessibility |
| W3 | Sync v2／Auth境界、account／conflict／historyの実機接続 |
| W4 | 執筆支援parityとWindows配布 |

D-088でWindows 11のみの対応と、MSIなどのインストーラー配布を採択した。W0は引き続き未完了。W1開始時に.NET SDK、Windows App SDK、具体的なインストーラー形式・作成ツールを要件に合わせて選び、採用内容を記録する。W2前にnative editorを選ぶ。Windows認証の入口は現行Apple-only契約の下で別途設計し、未実装providerを先出ししない。

Windows側のportable取込はfolderとして扱う。書き出し先の親folderとportable名を選び、`.novelpkg`directoryを生成する。通常の「開く／新規」を外部packageの直接編集へ読み替えない。

## 6. 作業の受け渡し

schema／fixture／Swift側とC#／Windows固有実装の担当を分け、同じbranchを両OSで同時編集しない。互換契約変更は本書・schema・fixtureを同時更新する。互換性へ影響する実装変更は、Windows実装前はMac、実装後は両OSの同一commitに対する検証を添える。

作業ごとの検証はD-086の「なし／軽い／中ぐらい／重たい」を変更の影響で選ぶ。今回のような方針記録・説明変更は「なし」、局所文言・表示等は「軽い」限定確認、単一機能は「中ぐらい」の対象testとbuild、保存・認証scope・互換・共有層へ影響する変更は「重たい」の全体`Scripts/check.sh`と関連境界検証を使う。mergeだけを理由に全体検証へ格上げしない。今回の方針追記は検証なしで、W0／W1の完了証拠を追加したものではない。

## 7. Sync v2の相互運用

Sync v2のexact JCS UTF-8 bytes、SHA-256、lowercase UUID、closed command／entity schema、SQLite／PostgreSQL DDL、account隔離、exact retry、single conflict／3択、2-parent restoreは [versioned contract](sync/v2/README.md) を直接参照する。wire値やresource上限を本書へ重複転載しない。

初版server object bytesはPostgreSQL BYTEA、clientはSQLite BLOB。S3／外部CASは将来の別migration／Gateであり、v1設計から戻さない。Auth wire epoch 1とSync epoch 2を混同せず、同期はFUMINIWA AccountID／sessionを使い、Apple tokenをsync bearerへ流用しない。

Swift／Rustの検証成功を将来C#の互換成功として扱わない。conformance、server integration、staging、実機の各証拠を分け、公開条件は [技術Gate](COMMERCIALIZATION_IMPLEMENTATION.md) で追跡する。

## 8. 履歴

[旧v1計画・Note／Work／Episode互換契約の全文](archive/product-guidance-20260912/CROSS_PLATFORM.md)を保存する。旧CloudKitとv1のmigration／fallbackは現行実装へ追加しない。旧データへの削除操作は文書整理の範囲外。
