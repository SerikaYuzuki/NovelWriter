# FUMINIWA Device Sync 契約

> **状態**: D-059承認、S1実装中。portable protocol、CloudKit実装、署名済み実機検証はいずれも未完了
>
> **対象**: macOS 14以降、iOS / iPadOS 17以降。将来のWindows / Android実装を妨げない
>
> **正とする上位契約**: [DESIGN.md](DESIGN.md)、[DECISIONS.md](DECISIONS.md) D-059、[IOS.md](IOS.md)、[CROSS_PLATFORM.md](CROSS_PLATFORM.md)

## 1. 目的と安全境界

Device Syncは、Macで編集中の話をiPhoneへ引き継ぎ、必要ならiPhone側で明示的に強制継続し、後で両方の本文を失わず統合できるようにする。

保存と同期の境界は次のとおり分離する。

- app-privateな`.novelpkg`は、各端末でdurableに保存する作業コピーであり、最新同期revisionをmaterializeしたportable snapshotでもある
- `.novelpkg`自体をiCloud DriveやFile Provider上でopen-in-placeにして同期しない。package内部のファイル単位競合をDevice Syncの競合解決に流用しない
- live syncは、`.novelpkg`とは別の **話単位revision protocol** で行う。共有head、lease、mutation、revision graphをrecordとして扱う
- 編集中本文の正は引き続きnative editorである。端末内保存の正はapp-private `.novelpkg`、端末間で合意した版の正はremote episode headであり、SwiftDataや一時的なView stateをcanonical sourceにしない
- remote送信前に必ずnative editorから本文をcaptureし、端末内packageとpackage外journalへdurableに保存する。通信成功をローカル保存の代用にしない
- `.novelpkg` v3 schemaはS1で変更しない。sync binding、lease、remote revision ID、device ID、journalをpackageへ保存しない

これにより、外部原本のopen-in-placeを除外したD-056 / D-057の境界を維持したまま、app-private作業コピー同士を同期する独立trackを追加する。

## 2. 現在の範囲

### 2.1 S1で扱うもの

- 既に同じsync workへbinding済みで、両端末のpackageに同じEpisodeIDが存在する **1話の本文**
- 同じ話を一度に1端末だけが書くsoft lease
- MacからiPhone、iPhoneからMacへの通常handoff
- iPhone側の明示的な強制継続と、旧writerのfencing
- 通信断前にauthorityを持っていたwriter、またはforceをまだ観測していない旧writerの本文を失わないoffline fork journal
- base / local / remoteによる保守的な3-way mergeと手動解決
- mutation retry、push欠落、process終了、通信失敗からの再開

### 2.2 S1で扱わないもの

- CloudKit上の作品一覧、別端末への初回download、import不要のbootstrap、複数作品のsync library
- 章／話の追加・削除・タイトル・順序、作品情報、メモ、人物、プロット、伏線、世界観、資料、snapshotの同期
- attachmentやpackage全体の転送
- Files / iCloud Drive / File Provider上の原本を直接編集するopen-in-place
- 同じ話を複数人または複数端末が同時に入力するlive collaboration、CRDT、逐次keystroke配信、共同cursor
- Apple以外の実transport、CloudKit Web Services、自前server

S1は、App層から有効な`SyncBinding`を渡された1作品・1話のengine境界を先に成立させる。作品の発見／初回binding UIが実装されるまでは開発fixtureだけで接続し、出荷UIへ「全作品を同期」「別端末から作品を取得」等を出さない。対象外の構造が両端末で一致しない場合は推測で作成・並べ替えせず、本文同期を停止して明示的な不一致として扱う。

## 3. 層と依存方向

```text
App / AppState
├── app-private .novelpkg + DocumentSaveCoordinator
├── native editor capture / install boundary
└── DeviceSyncCoordinator
    ├── NovelSync              (OS・transport非依存)
    │   ├── portable wire DTO
    │   ├── state machine / CAS command
    │   ├── journal contract
    │   └── three-way merge
    └── AppleCloudKitSync      (Apple platform adapter)
        ├── CloudKit / CKSyncEngine
        ├── CKRecord mapping
        ├── account / push / retry
        └── app-private journal storage
```

`NovelSync`の公開型、error、fixtureへ`CKRecord`、`CKRecord.ID`、`CKSyncEngine`、`CKContainer`等のCloudKit型を出さない。SwiftUI、AppKit、UIKit、SwiftData型も出さない。Apple adapterはportable commandをCloudKitへ写像するだけとし、CloudKit固有のchange tagやsubscriptionをdomainへ漏らさない。

Windows版はC#、Android版はKotlin等で同じwire、state、CAS、merge fixtureを再実装する。Swift packageやCloudKit adapterを直接移植することは前提にしない。将来別backendを追加しても、時計によるlast-write-winsへ置き換えず、この契約を満たすtransactional adapterを要求する。

Swift側のtarget graphは実装PRで固定する。少なくとも`NovelSync`から`NovelStorage`、EditorKit、CloudKitへ依存せず、App層がpackage保存、native editor、sync engineを調停する。

## 4. Identityとportable wire

### 4.1 Identity

- `syncWorkID`: remote revision graphの作品identity。app-private package名や`NovelDocument.id`から暗黙生成しない
- `episodeID`: `.novelpkg`のEpisodeIDと同じ論理ID。S1では既存episodeだけをbindingする
- `deviceID`: installationごとに生成するrandom opaque ID。端末名、利用者名、hardware serialを使わない
- `sessionID`: その話のwriter sessionごとに生成するrandom opaque ID。app再起動や再openで再利用しない
- `revisionID`: immutable revisionごとのrandom ID
- `mutationID`: 利用者操作をremoteへpublishする試行系列のidempotency key。network retryで変えず、本文を作り直した新操作では新しくする
- `leaseEpoch`: EpisodeControl上の0以上のsigned 64-bit整数。所有権の移動または強制継続ごとにexactly 1増やし、overflow時は同期を停止する

`SyncBinding`と各IDはpackage外のapp-private metadataへ保存する。exportした`.novelpkg`だけではsync accountやremote workへ自動再接続しない。

### 4.2 Wire規約

- protocolはversion付きUTF-8 JSONとし、BOMを付けない
- keyはlower camel case、IDはcanonicalな大文字UUID文字列、`leaseEpoch`は0以上のJSON整数とする
- 本文はJSON stringとして論理表現し、decoded stringをUTF-8へencodeしたbytesのSHA-256を`bodyDigest`とする
- 本文へNFC / NFD変換、改行変換、末尾空白除去を行わない
- 未知のminor fieldは保持または無視できるが、未知のmajor `protocolVersion`は拒否する
- 日時は診断／表示用に限り、head選択、publish可否、merge winnerの判断へ使わない
- decode上限、本文byte上限、親revision数、record batch数を実装前に定数化し、上限超過を部分適用しない

publish commandの論理例を次に示す。fixtureではfield省略、`null`、canonical encode、上限、Unicodeを固定する。

```json
{
  "protocolVersion": 1,
  "mutationID": "E21455B4-4E84-43E3-91CB-82F0B2C56D0D",
  "syncWorkID": "4D875891-E4A9-45CC-B0E3-9CB9024EAA18",
  "episodeID": "635158B4-E377-4D24-9338-9691442CFF94",
  "expectedRemoteHeadRevisionID": "91B89B3D-6935-4219-A49E-014D7B98B80F",
  "lease": {
    "holderDeviceID": "8B4D8AF4-64B5-4611-81F3-E10DD82A302C",
    "holderSessionID": "5FFBFE99-90FE-4D0B-ACF9-D3D26475A756",
    "epoch": 12
  },
  "revision": {
    "revisionID": "1FB99183-7C62-49EC-8B64-081B15C2E56C",
    "parentRevisionIDs": [
      "91B89B3D-6935-4219-A49E-014D7B98B80F"
    ],
    "body": "　本文です。\n「続きます」",
    "bodyDigest": "sha256-lowercase-hex"
  }
}
```

通常revisionの親は0件または1件、競合解決後のmerge revisionはexactly 2件とする。親配列の順序は`remote head`、`local fork`で固定する。revisionは作成後に本文、digest、親を変更しない。

## 5. 論理recordとCloudKit mapping

### 5.1 Transport非依存record

| Record | 主なfield | 契約 |
| --- | --- | --- |
| `SyncWork` | `syncWorkID`, `protocolVersion` | sync graphのroot。S1では既存bindingの検査にだけ使う |
| `EpisodeControl` | `syncWorkID`, `episodeID`, `headRevisionID`, `holderDeviceID`, `holderSessionID`, `leaseEpoch`, advisory lease metadata | headとleaseを1つのCAS対象にして、forceとpublishの競合を直列化する |
| `EpisodeRevision` | `syncWorkID`, `revisionID`, `episodeID`, `parentRevisionIDs`, `body`, `bodyDigest`, `mutationID` | immutable。通常版、fork、2-parent mergeを同じgraphへ残す |
| `MutationReceipt` | `syncWorkID`, `mutationID`, command digest, `resultRevisionID`, resulting head / epoch | 応答消失後のretryをexactly-once相当にする。既存IDと内容が違えば拒否する |
| `HandoffRequest` | `syncWorkID`, `requestID`, `episodeID`, requester device / session, observed head / epoch | 現writerへ通常handoffを依頼する一時record。lease権限にはならない |

全recordは`syncWorkID`を検証し、EpisodeIDやrevision IDだけで別workのrecordを参照しない。固定zone内のrecord nameもwork IDをscopeに含める。

soft leaseの期限やheartbeatはUX上の「応答がない」判定にだけ使う。local wall clock、recordの表示日時、push到着順はpublish権限を与えない。権限の正は、最新`EpisodeControl`のholder / session / epochとremote CASだけである。

### 5.2 Apple private CloudKit

- Apple版は利用者のprivate CloudKit databaseを使い、自前serverを置かない
- S1はprivate database内にversion付きの **単一固定custom record zone** を1つ作り、全sync workのrecordを同じzoneへ置く。作品ごとにzoneを増やさず、各recordのopaque `syncWorkID` fieldと、work IDを含む衝突しないrecord nameで分離する。zone IDとrecord nameへ作品名や話タイトルを含めない
- `EpisodeControl`をCloudKitのserver record change tag付きrecordへ写像する。publish / grant / forceは`.ifServerRecordUnchanged`相当の条件付き保存を使う
- revision、mutation receipt、更新後controlは同じzoneのatomic batchで保存する。atomicityを提供できない経路ではpublish成功にしない
- `EpisodeRevision.body`はportable wire上はstringのままだが、Apple adapterは上限と大本文を考慮し、canonical UTF-8 payloadを`CKAsset`へ写像できる。metadataのdigest / byte countを検証してからinstallする
- `CKSyncEngine`はchange tracking、pending change、push後のfetch、retry token管理に使う。lease / expected head / mutationIDのdomain検査を`CKSyncEngine`任せにしない
- pushは通知契機であって配送保証ではない。起動、foreground復帰、handoff / force直前にもserver changesをfetchする

mutation適用順は次のとおりとする。

1. 同じ`mutationID`のreceiptがあれば、command digestが一致する場合だけ既存resultを返す。一致しなければID再利用として停止する。
2. receiptがなければ、最新controlのheadが`expectedRemoteHeadRevisionID`、holder / session / epochがcommandと完全一致することを検査する。
3. immutable revision、receipt、更新後controlを同じ固定zoneの1 atomic transactionで保存する。
4. server acknowledgementとread-backでresultを確認した後だけoutboxを完了にする。timeoutは成功とも失敗とも決めつけず、同じ`mutationID`で照会／再試行する。

headまたはepoch不一致を、更新日時が新しい本文で上書きしない。競合としてfetch / fork / mergeへ移る。

## 6. 端末内journalと状態機械

package外のapp-private `SyncJournal`は、少なくとも次をatomicに保持する。

- binding、episode、base / local / remote revision IDとexact body / digest
- 最後に確認したhead、holder / session / epoch
- pending mutationとreceipt確認状態
- handoff / force / fence / mergeの状態
- native editorからcapture済みか、package保存済みか、remote acknowledgement済みか

journalは`.novelpkg`保存やexportの置換対象外とし、package保存失敗で上書きしない。S1では未解決forkとその本文を自動削除しない。merge後のretention / purgeは別Decisionとし、少なくともmerge revisionのremote read-backと全親revisionの存在確認前には削除しない。

| State | 編集可否 | 意味 |
| --- | --- | --- |
| `unbound` | localのみ | sync workへ接続していない |
| `observing` | read-only | remote headを表示するがleaseを持たない |
| `writer` | 可 | 最新controlのholder / session / epochと一致する |
| `flushing` | 一時停止 | IME commit、capture、local save、remote publish中 |
| `handoffRequested` | 現writerのみ可 | 別端末から通常移動を要求された |
| `granting` | 不可 | flush済みheadから次holderへepochを移すCAS中 |
| `fetching` / `installing` | 不可 | 新writerがgrant後headを取得し、localへ反映中 |
| `fenced` | 不可 | local sessionのepochがremoteより古い |
| `forked` / `resolving` | 不可 | base / local / remoteをjournalへ保全し、統合待ち |
| `blocked` | 不可 | account、schema、digest、resource、durability等の安全条件を満たさない |

network reachabilityだけで`writer`へ遷移しない。state遷移はjournalへ先に記録し、process終了後に同じ段階から再開できるようにする。

## 7. 通常handoff

holderが空の初期状態では、端末は最新control / headをfetchし、空holderとobserved epochを条件にfresh sessionをholderとして設定し、epochをexactly 1増やすacquire CASを行う。grantと同様にheadをfetch / verify / local installしてからwriterにする。advisory期限が切れただけの既存holderを自動取得せず、通常handoffまたは明示forceを使う。

端末Bが、端末Aで開いている同じ話を続ける通常経路は次の順序に固定する。

1. Bは最新control / headをfetchし、自分がwriterでないことを確認して`HandoffRequest`を作る。BのEditorはread-onlyのままにする。
2. Aはrequestを受け、対象作品・話・sessionを再検査し、新規入力を一時停止する。
3. Aはnative editorのactive compositionを明示的にcommitする。commitできない間はhandoffを進めない。
4. Aは確定本文をnative editorからcaptureし、同じ本文をpackageの既存保存直列化経路とjournalへdurableに保存する。どちらかが失敗したらgrantしない。
5. Aはpending本文を`mutationID + expected remote head + current lease epoch`でpublishし、server acknowledgement / receiptを確認する。
6. Aは最新headを保持したまま、controlをBのdevice / sessionへ移し、epochをexactly 1増やすgrant CASを行う。CAS競合なら再fetchし、推測でgrant済みにしない。
7. Bはgrantされたcontrolとhead / revisionをfetchし、digestと親を検証する。
8. Bは自端末のactive compositionがないことを確認し、packageへremote headをmaterializeして保存した後、native editorへinstallする。
9. remote install時はその話のnative Undo / Redo historyを破棄し、新しいremote baselineを跨ぐUndoを許さない。利用者へ履歴更新を内容非開示で示す。
10. package保存とEditor installの両方が成功した後だけ、Bを`writer`にする。Aは`observing`へ移る。

Aがcommit、capture、local save、remote flush、grantの途中で失敗した場合、Bへ書込権を渡さない。Bは待機／再試行または明示的な強制継続を選ぶ。

## 8. iPhoneでの強制継続とfencing

強制継続は「応答が遅いので自動的に上書き」ではなく、remoteに未到達の旧writer本文があり得ることを示したうえで利用者が明示する操作とする。

1. iPhoneはonlineで最新control / headをfetchする。fetchできない場合はleaseを奪わずread-onlyのまま待つ。
2. iPhoneは観測したcontrolのchange tagを条件に、holderを自分のdevice / fresh sessionへ変更し、epochをexactly 1増やすforce CASを行う。
3. CAS成功後、最新remote headを検証してpackage / Editorへinstallし、Undo / Redoを破棄してからwriterを有効にする。古いlocal本文をremote headへ暗黙合成しない。
4. 旧writerの同時publishとforceが競合した場合、remote CASで一方だけが先に成立する。publishが先ならiPhoneは新headをfetchしてforceを再確認し、forceが先なら旧publishをstale epochとして拒否する。
5. 旧writerがonlineならforce通知時、offlineなら次のfetch時にepoch不一致を検出して即座にfenceする。新しいremote本文をactive composition中のnative editorへ書き込まない。
6. 旧writerはIMEをcommitし、native editorの全文をcaptureしてpackageへ保存する。その本文を`base`、`local`、force後の`remote`とともにpackage外journalへdurableに保全する。保存できない場合はremote installせずblockedにする。
7. stale writerの本文を旧epochでretryせず、時計が新しいという理由でheadへ戻さない。解決は必ずfork / merge経路を通す。

強制継続後も旧端末の本文は「敗者」ではなくimmutable fork候補である。remoteへ未送信だったlocal forkにはstable revision IDを割り当て、解決時にbaseを親とするimmutable `EpisodeRevision`として先に保存する。

## 9. Offline動作

- 現在のlease holderはoffline中もnative editor、package、journalへ保存できる。ただしremote acknowledgement前は「この端末に保存」と「同期済み」を区別する
- leaseを持たない端末はofflineではread-onlyを維持する。remote状態を確認せず自動的にwriterへ昇格しない
- 別端末がforceした間も旧offline writerは入力できてしまうが、再接続後の最初のpublishはepoch CASで拒否される。拒否時にcapture / local save / fork journalを完了してからremoteを扱う
- `offlineFork`は、通信断前にremote authorityを保持していたwriterが通信断中に継続した本文、またはforceをまだ観測していない旧writerの本文を保全する状態だけを指す。非holderが通信不能のまま「強制継続」を開始する入口にはしない
- push欠落、app suspension、process kill後はchange tokenとjournalからfetchを再開する。local pendingを破棄してremoteだけを採用しない
- iCloud account不明、signed out、restricted、temporarily unavailableは別状態として表示し、accountが変わったjournal / bindingを別accountへ送らない

## 10. 3-way merge

merge入力は、共通祖先`base`、旧writerまたはoffline forkの`local`、現在remote headの`remote`である。digestとrevision ancestryが証明できない場合は自動mergeしない。

### 10.1 自動merge

- normalizationしないUnicode scalar列に対して、base→localとbase→remoteのedit hunkを決定論的に求める
- base上の変更区間が互いに交差せず、同一挿入点、相手の置換／削除境界、対応が曖昧な反復領域を共有しないことを **証明できる場合だけ** 自動適用する
- 算出上限、曖昧なmapping、digest不一致、親欠損、同じ箇所への両側挿入はoverlapとして手動解決へ送る
- hunk適用順と結果をSwift / C# / Kotlinで同じfixtureへ固定する。日本語、emoji、結合文字、改行、全角空白を含める

### 10.2 overlap解決

overlap時はbaseを参照可能にし、少なくとも次を同じ画面で提示する。

- localを保持した本文
- remoteを保持した本文
- 手動で統合した本文

「localを採用」「remoteを採用」も片方のrevisionを削除する操作ではない。まずlocal fork revisionをremoteへdurableに保存し、選ばれた本文から **2-parent merge revision** を新規作成する。親は`[remoteHead, localFork]`とし、keep remoteなら本文がremoteと同一、keep localならlocalと同一でも新しいmerge revisionを作る。新headへのpublishは現在のlease epochとexpected remote headでCASし、両親とmutation receiptの存在をread-backする。

元のbase / local / remote revisionとjournalは勝敗にかかわらず自動削除しない。競合画面を閉じる、appを終了する、別話へ移る操作でも未解決forkを保持する。

## 11. Native editorとの統合

- handoff、force、話／作品切替、remote installの開始時はdocument operation gateとeditor command sessionで対象identityを固定する
- remote install前に現在のnative editorへcomposition commitを要求する。`NSTextView.hasMarkedText`または`UITextView.markedTextRange`がactiveな間は外部本文を流し込まない
- commit後にexact全文をcaptureし、現在のpackage / journalへ保存する。capture対象をSwiftUIの古いBindingへ読み替えない
- remote本文のinstallは、episode変更時と同等の明示的なexternal replacement境界だけで行う。通常のSwiftUI updateから`textView.string` / `UITextView.text`を変更しない
- active composition中にforce / remote changeを受けた場合はpending remoteとして保持し、新規publishを止め、composition終了後にcapture / fence / installを再開する
- remote install時は選択とscroll位置を安全な範囲へ調整し、その話のUndo / Redo stackを破棄する。別baselineの本文へ旧Undo transactionを適用しない
- remote本文が同じdigestならEditor全置換を省略できるが、lease / state更新とreceipt検査は省略しない

## 12. Security / Privacy

- private CloudKit databaseはApple IDに紐づくFUMINIWAのprivate領域であり、公開databaseやCloudKit sharingをS1で使わない
- FUMINIWA運営者の自前serverは不要だが、話本文、revision、opaque ID、必要な診断metadataはAppleのCloudKitへ送られる。clipboard機能とは別の明示的なcloud境界として説明する
- transport／保存時暗号化をApple platformへ依存することと、FUMINIWA独自のend-to-end encryptionは同義ではない。E2EEを実装・検証するまでその表示をしない
- 作品名、話タイトル、端末名、利用者名、local path、bookmark、hardware identifierをrecord name、zone name、診断logへ入れない
- 本文、fork、asset URL、CloudKit error payloadを通常log、analytics、crash breadcrumbへ記録しない。診断はopaque ID、状態分類、byte count等のcontent-free値に限定する
- remote payloadのdigest、size、protocol version、parent、episode / work bindingを検証してからpackageまたはEditorへinstallする
- account変更時は旧accountのbinding / journalをquarantineし、利用者の明示確認なしに新accountへuploadしない
- package外journalも原稿を含むため、Apple platformのapp-private data protectionとatomic file replacementを使う。backup / retention方針は実装PRで明示する

## 13. Apple capabilityと外部Gate

Apple版はprivate CloudKit + `CKSyncEngine`を採用し、SwiftDataはcanonical storeにしない。最低OSは現行のmacOS 14 / iOS 17と一致する。

macOS / iOSはbundle IDが別でも、同じTeamのApp IDへ同じiCloud containerを割り当てれば同じprivate databaseを利用できる。adapterはdefault container推測に依存せず、承認済みidentifierを`CKContainer(identifier:)`へ明示する。両targetの署名済みentitlementには少なくともCloudKit serviceと同じcontainer identifier、Push Notifications環境が必要で、iOSのInfoには`UIBackgroundModes = remote-notification`が必要になる。環境別の実値はXcode capability / provisioning profileを正とし、source上のplaceholderをproduction containerとして作成しない。

実装・検証には、コードだけでは完了できない次の外部作業が必要である。

1. Apple Developer Program上で、変更しないproduction用iCloud container identifierを決める
2. macOSとiOSの別App IDを同じTeamで管理し、同じCloudKit containerを両方へ割り当てる
3. 両targetへiCloud / CloudKitとPush Notifications capabilityを付け、同じcontainer entitlementを署名profileへ含める
4. iOSへBackground Modesのremote notificationsを付ける。macOSはpush entitlementを持つが、iOSのBackground Modes設定を機械的に流用しない
5. development schemaを作成し、index / record typeを検査してからproductionへ明示deployする
6. 同じiCloud accountで署名済みMac実機とiPhone / iPad実機を使い、foreground、background、push欠落、offline、account変更を検証する
7. Developer ID配布用macOS buildとiOS配布profileの両方でentitlement / container environmentをread-backする

macOSはD-011どおり非Sandboxの直接配布を維持する。CloudKitのために`com.apple.security.app-sandbox`を追加せず、CloudKit / container / pushに必要なentitlementだけを署名済みtargetへ付ける。iOSの`remote-notification` Background ModeをmacOS設定へ機械的に追加せず、macOSはpush entitlementと起動／foreground fetchで取りこぼしを回収する。iOS targetがSandboxであることをmacOS配布判断へ逆流させない。

container作成、App IDへの割当、capability有効化、profile再発行、production schema deploy、実機account状態はAccount Holder / Admin等の権限とApple Developer portal / CloudKit Consoleを要する外部Gateである。署名なしbuild、Simulator、mock transport、`CODE_SIGNING_ALLOWED=NO`のローカルCIだけではCloudKit同期完了を証明しない。

Package Validator GateとExternal Change / Conflict Gateも未完了のままである。Device Syncはapp-private packageに対する別protocolであり、これらを完了扱いにせず、外部原本open-in-placeの許可根拠にも使わない。

## 14. Test計画

### 14.1 Pure / fixture

- portable JSONのcanonical encode / decode、未知version、上限、invalid UTF-8、digest mismatch
- mutationID retry、応答消失、同じIDの異なるcommand、expected head mismatch
- stale holder / session / epoch拒否、通常grant、force CAS、epoch overflow
- publishとforceの両順序、duplicate / reordered change、push欠落
- process終了を全journal遷移へ注入し、base / local / remoteとpending mutationが残ること
- non-overlapだけの3-way merge、同一挿入点／隣接境界／反復文字列の保守的conflict
- 日本語、全角空白、`「」`、`『』`、emoji、ZWJ、結合文字、CR / LF、空本文、大本文
- Swift fixtureを将来のC# / Kotlin実装でも読み、state / merge / digest結果を一致させる

### 14.2 App / editor integration

- 実`NSTextView` / `UITextView`でIME commit → capture → local save → remote flush → grantを順序検証する
- marked text中のremote change / forceで外部全置換せず、確定後にfork保存してからinstallする
- remote installでUndo / Redoが破棄され、別baselineへ旧operationを適用しない
- 話／作品／document session切替中のlate callbackを別対象へ適用しない
- package保存失敗、journal保存失敗、remote asset破損、digest mismatchでwriter権限を渡さない
- S1対象外の章順、話タイトル、資料等が不一致なら本文だけを推測適用しない

### 14.3 CloudKit / 実機

- fake transactional storeによる決定論的な2端末test
- development containerでrecord mapping、atomic modify、change token、retry、zone deleteを検証する
- 署名済みMac + iPhone / iPadを同じiCloud accountで使い、通常handoffを往復する
- MacをofflineにしてiPhoneで強制継続し、Mac再接続後にfence / fork / 2-parent mergeする
- app kill、background、push無効／欠落、network切替、account sign-out / switch、容量不足を検証する
- production schema deploy後、production entitlementの配布候補buildで再検証する

実機で一度成功しただけでは完了にしない。各mutation、head、epoch、journal stateをcontent-free traceで照合し、旧本文とremote本文がrevision graphまたはjournalのどちらかに必ず残ることを確認する。

## 15. 実装順

1. **S1-0 Contract / Fixture**: D-059、本書、portable JSON schema、state / merge fixture、resource limitを固定する
2. **S1-1 NovelSync Pure Domain**: CloudKit型なしのID、wire、state、CAS command、3-way merge、fake transactional storeを実装する
3. **S1-2 Durable Local Journal**: package外journal、outbox、process-kill recovery、package saveとの順序を実装する
4. **S1-3 Editor / Save Integration**: IME commit、native capture、local package save、remote install、Undo破棄、session fencingを接続する
5. **S1-4 Apple CloudKit Adapter**: private custom zone、record mapping、atomic CAS、mutation receipt、CKAsset、CKSyncEngine change trackingを接続する
6. **S1-5 Normal Handoff**: request、flush、grant、fetch、install、read-only UIをMac / iPhoneへ接続する
7. **S1-6 Force / Merge**: iPhoneの明示force、旧writer fence、fork保全、auto / manual / keep local / keep remoteの2-parent mergeを接続する
8. **S1-7 External / Release QA**: container、App ID、entitlement、profile、development / production schema、署名済み実機を検証する

各段階は未実装の操作をUIへ出さない。S1-1のpure test成功をCloudKit利用可能、S1-4のdevelopment成功をproduction同期完成、S1-5のhandoff成功を構造／資料／library／live collaboration対応とは表現しない。Windows / Android transportはportable fixture確定後の独立trackとする。
