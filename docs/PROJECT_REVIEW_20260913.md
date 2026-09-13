# FUMINIWA プロジェクトレビュー — 2026-09-13

対象は `codex/large-snapshot-import-20260913`、開始commit `6cbff1801`。現行のSwift・Rust・設定・契約・関連テストを横断した。コード修正は行っていない。

**優先するのは、連続入力の保存期限、iOSの話の誤削除、macOSの作品削除後の保存停止、認証前の大量データ受信である。** 大規模な作り直しより、既存の保存・操作・認証境界を最後まで一貫させる修正を先に行う。SQLite正本、remote workerの分離、test composition、現行v2への依存整理は維持する。

Claude CLI 2.1.270から、Claude公式接続の **`claude-fable-5-1`** に同じ開始commitの独立レビューを依頼し、正常終了を確認した。こちらの発見や途中レポートは渡していない。Fableの指摘を現行source・規範・反例と再照合し、採用・補正・保留を下記へ統合した。主要修正候補は14件（P1が4件、P2が10件）。別に表示改善と公開経路の確認事項がある。

Fableの実行時間は約14.6分。CLIが報告した料金見積りは **18.41 USD**（list価格による見積りで、請求明細の確認値ではない）。許可された追加使用量で実行した。先行するZ.ai接続の残高不足による失敗は、このレビュー結果に含めない。

## 優先順位

P1は原稿保全またはサービスの継続利用に直結する修正、P2は条件付きの不具合・性能上の問題。実機で発生を確認したという意味ではなく、根拠の種類は各項目に記す。

| ID | 優先度 | 問題 | 今回の確認 |
| --- | --- | --- | --- |
| R1 | P1 | 連続入力中、自動保存が無期限に延期される | 現行coordinatorの縮小再現 |
| R2 | P1 | iOSで保存待ち中の削除が別の話へ適用される | 現行境界メソッドの縮小再現 |
| R3 | P1 | 認証前に大きなupload本文をメモリへ読む | sourceとAxum公式仕様 |
| R10 | P1 | macOSで編集中作品を削除すると保存・終了が詰まる | Fable指摘を現行呼出経路で再照合 |
| R4 | P2 | 遅延したApple通知が再ログイン後のsessionを失効させる | 現行SQL・契約の追跡 |
| R5 | P2 | Appleへの失効要求が4xxでも完了扱いになる | transport→永続状態の追跡、Apple公式仕様 |
| R6 | P2 | 同一accountの認証世代変更で削除待ちが解消不能になる | server→account移行→UI再試行の追跡 |
| R7 | P2 | 完全削除後も取り込んだ付随データがDBに残る | 現行schema・削除SQLで再現 |
| R8 | P2 | 大量履歴の採用経路に深い再帰が残る | 現行呼出経路の追跡 |
| R9 | P2 | 同じ添付データを履歴数だけメモリへ複製する | SQLiteのコピーから保持先まで追跡 |
| R11 | P2 | 明示snapshot・通常添付が自動保存と競合する | Fable指摘を世代比較と呼出側で再照合 |
| R12 | P2 | 日本語本文の長さをserverだけbyte数で制限する | Fable指摘を規範と両実装で再照合 |
| R13 | P2 | 認証失効がaccount表示と再ログイン案内へ反映されない | Fable指摘を復旧導線まで再照合 |
| R14 | P2 | 同期先で利用不能になった作品の理由・回復案内が足りない | Fable指摘をD-092・wire契約で再照合 |

## 具体的な修正点

### R1 — 最初の未保存変更からの期限を保持する

[V2DocumentSaveCoordinator.swift:51](/Volumes/Files/GitHub/NovelWriter/NovelApp/DocumentLifecycle/V2DocumentSaveCoordinator.swift:51) は入力のたびに前の待機をcancelし、再び2秒待つ。両OSで同じcoordinatorを使うため、2秒未満の間隔で入力を続けると保存が始まらない。クラッシュや強制終了では、最後に入力を止めて保存された後の執筆を失い得る。正常な終了や明示保存のflushがあることは、この間の異常終了を防がない。

D-077の「最初の未保存変更から最大2秒・追加入力で期限を延長しない」とも異なる。修正済みのautosave自己cancel・保存中revision競合とは別件。

現行coordinatorをそのまま使い、受け渡す文書型だけを最小の合成値に置き換えた。待機100ms、入力25ms間隔を20回続けると、約0.525秒経過しても保存0回。入力停止後150msで保存1回・revision 20になった。タイマーの縮小再現であり、アプリ全体・実DB・実IMEの試験ではない。

**修正案:** 最初のdirtyで期限を固定し、期限内の変更をまとめて保存する。保存中に増えたrevisionの追従保存は維持する。回帰検証は「入力が続いても期限でcommitする」と「保存中の入力を失わない」を組み合わせる。

### R2 — 話の位置を保存待ちの前にIDへ変換する

[IOSDocumentStore+EditingV2Boundary.swift:31](/Volumes/Files/GitHub/NovelWriter/NovelAppIOS/Features/Writing/IOSDocumentStore+EditingV2Boundary.swift:31) は `IndexSet` を捕捉して保存を待ち、その後の配列へ適用する。[削除本体:116](/Volumes/Files/GitHub/NovelWriter/NovelAppIOS/Features/Writing/IOSDocumentStore+Editing.swift:116) は実行時点の位置からIDを取り直す。

保存が遅れている間に同じ行の削除を重ねると、最初の削除で位置が詰まり、2回目が別の話を消せる。並べ替えも同じ位置依存を持つ。一覧の `.onDelete` / `.onMove` は待機中も使用でき、通常保存は作品遷移の禁止flagを立てない。EditorKitのprepareも重複要求を拒否する排他機構ではない。

現行boundaryファイルを読み、保存待ちと最小store・ID・配列操作を合成実装にした再現では、A/B/Cの先頭を2回指定すると両方成功し、残ったのはCだった。実際の画面操作やDBでの再現ではない。

**修正案:** 操作時のEpisodeID、並び、session/accountを固定し、document gate内で適用条件を再検査する。削除の重複要求は同じIDへの冪等操作にする。単に直列化しても、待機前に捕捉した古い位置を使う限り問題は残る。

### R3 — upload本文を読む前に認証する

[http.rs:943](/Volumes/Files/GitHub/NovelWriter/SyncServerV2/src/http.rs:943) の `Bytes` extractorは、handler内の `principal`（956行）より先に本文を読み込む。routeの上限は250 MiBで、1件の上限はあるが、認証前の並行受信量は制限されていない。小さなUUID形式のupload先を指定するだけで本文読取へ到達する構成になっている。

未認証の並行uploadでメモリを圧迫し、同期サーバーを停止させ得る。後段のbearer認証・upload capabilityはデータの受理を防ぐが、先行するメモリ確保を防がない。Axum 0.8.9の抽出順・本文読取は[公式仕様](https://docs.rs/axum/0.8.9/axum/extract/index.html)で確認した。

**修正案:** bodyを消費しない認証extractorまたはmiddlewareで先に拒否する。そのうえでuploadの並行数・時間・総メモリ量を制限する。認証済みuploadについても必要ならstreamingを使う。負荷試験やOOMは再現していない。Cloudflare側の実際の制限設定は未調査であり、リポジトリのCaddy/Composeから上流での防御を保証しない。

### R4 — Apple通知と再認証の時系列を照合する

[auth_postgres.rs:108](/Volumes/Files/GitHub/NovelWriter/SyncServerV2/src/auth_postgres.rs:108) の古い通知の判定は、過去の通知時刻だけを比較し、直前の検証済み再ログイン時刻を見ない。失効イベント→再ログイン成功→古い通知到着の順では、123〜129行が新sessionを失効させ、新credentialの失効要求まで予約する。

署名検証、通知IDによる重複防止、row lockは存在するが、この順序には対応しない。[通知契約:37](/Volumes/Files/GitHub/NovelWriter/docs/auth/v1/apple-notification.md:37) と不一致。端末内原稿の消失を確認したものではなく、ログイン・同期が不必要に失効する問題である。

**修正案:** identityごとに検証済み再認証の時点・世代を記録し、それより古い通知で新sessionを巻き戻さない。契約にあるprovider確認待ちとdurable retryへ移す。DBで通知と再ログインの順序を入れ替える回帰試験が必要。

### R5 — 失効要求のエラーを完了へ変換しない

[auth_apple.rs:255](/Volumes/Files/GitHub/NovelWriter/SyncServerV2/src/auth_apple.rs:255) は成功・5xx以外を一律 `InvalidExternalIdentity` にする。[auth_postgres.rs:219](/Volumes/Files/GitHub/NovelWriter/SyncServerV2/src/auth_postgres.rs:219) はその値を成功と同じ `revoked` に確定し、再試行予定も消す。

429やclient認証設定のエラーでも、Apple側で失効していないtokenを失効済みと記録する。[Appleの仕様](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens)では、失効成功と既に失効していた場合は200であり、エラー時は応答のerror codeを確認する。通信失敗・5xxの再試行処理は既に存在する。

**修正案:** 成功、明確なtoken無効、一時障害、client設定不良を区別する。失効を確認できない結果には再試行可能な永続状態と診断を残す。実Appleへの失効操作は行っていない。

### R6 — 再認証後の削除intentを同じaccount内で再計画する

[LocalSyncV2Store+Deletion.swift:14](/Volumes/Files/GitHub/NovelWriter/NovelKit/Sources/NovelSyncV2Store/LocalSyncV2Store+Deletion.swift:14) は保存済み削除intentと現在のbindingの完全一致を要求する。一方、同じaccountへの認証世代変更は作品bindingを更新しても削除journalを更新しない。

削除通信失敗→Appleのconsent取消→同じAppleで再ログインすると、新しいfenceに対し削除intentだけが古くなり、再試行が常に `accountMismatch` になる。作品は削除待ちとして棚に残るが開けず、再ログインを促すエラーを繰り返す。通常refreshやfenceの変わらない再ログインは対象外。

**修正案:** 同じserver/epoch/accountへの再認証に限定して、削除intentを新fenceで再計画する。別accountへ移し替える対応はしない。削除応答喪失・再起動・fence変更を組み合わせた検証が必要。今回は静的追跡のみ。

### R7 — 作品参照の削除後にresourceの保持判定を更新する

[LocalSyncV2Store+Deletion.swift:138](/Volumes/Files/GitHub/NovelWriter/NovelKit/Sources/NovelSyncV2Store/LocalSyncV2Store+Deletion.swift:138) は `gc_root=0` のresourceだけを削除する。しかし取り込み時にrootは1になり、作品参照を削除しても再計算されない。

対象は通常の登録済みattachmentとは別の、package取り込み時に保全した未知の付随データや旧package履歴である。現在のschemaを使うメモリDBへ合成resourceを入れ、作品参照を削除して現行削除SQLを実行すると、参照0でもresourceが1件、root1のまま残った。実DBやbackupの物理消去についての試験ではない。

**修正案:** 参照削除後にrootを再計算するか、対象objectに他作品の参照がないことを確認して削除する。共有resourceは保持する。SQL部分の再現は済んでおり、修正時はstoreの削除処理全体で専有・共有の両方を確認する。

### R8 — 履歴採用側も再帰を除去する

[LocalSyncV2Store+Inbox.swift:293](/Volumes/Files/GitHub/NovelWriter/NovelKit/Sources/NovelSyncV2Store/LocalSyncV2Store+Inbox.swift:293) の `topologicalSnapshots` に親を再帰訪問する処理が残り、現行の採用・競合復元経路から呼ばれる。Inbox読込は `ORDER BY snapshot_id` なので、HTTP側で親から取得しても順序が維持されない。

最新の大量履歴修正で別の探索処理は改善されているが、この経路は深い履歴でstackを消費し続ける。既存の1万件テストは `validateAcyclic` を対象とし、同じ採用経路を通らない。

**修正案:** 採用時の並べ替えも明示スタックまたは非再帰のトポロジカルソートにする。順序を崩した深い履歴でInbox保存→再読込→採用まで検証する。再帰の残存は確認したが、実機でのstack overflow・発生件数は未確認。

### R9 — Inboxのobject bytesをObjectID単位で共有する

[LocalSyncV2Store+Inbox.swift:473](/Volumes/Files/GitHub/NovelWriter/NovelKit/Sources/NovelSyncV2Store/LocalSyncV2Store+Inbox.swift:473) は各snapshotの全entryを個別に読んで保持する。[SQLite.swift:593](/Volumes/Files/GitHub/NovelWriter/NovelKit/Sources/NovelSyncV2Store/LocalSyncV2Store+SQLite.swift:593) は `Data(bytes:count:)` でコピーするため、同じ添付でも履歴ごとに別の実体となる。

例えば同じ5 MiBの添付を1000履歴が参照すれば、その添付だけで約4.88 GiBを保持する計算になる。これはコードからの容量計算であり、実測値ではない。通信側のcacheとDBの重複排除では、Inbox再読込時の複製を防げない。

**修正案:** 一つのgraph読込中は検証済みobject bytesをObjectIDで共有し、manifestの参照情報とは分ける。履歴数・固有object容量を別々に増やす負荷fixtureで、verify/adoptの最大メモリを測る。

### R10 — 編集中作品の削除前にdirty revisionを保存する

[macOSの削除処理:22](/Volumes/Files/GitHub/NovelWriter/NovelApp/Application/AppState+SnapshotSyncV2Deletion.swift:22) は `performExclusive` を使い、進行中の保存は待つが未保存revisionをflushしない。IME確定や直近の入力がある作品を一覧から削除すると、未保存revisionを残して52行目で `.documentSelection` へ移り、[currentDocument:301](/Volumes/Files/GitHub/NovelWriter/NovelApp/AppState.swift:301) がnilになる。

残ったdebounceが実行されると [coordinator:124](/Volumes/Files/GitHub/NovelWriter/NovelApp/DocumentLifecycle/V2DocumentSaveCoordinator.swift:124) で保存に失敗する。その後は[他作品を開く前の保存:235](/Volumes/Files/GitHub/NovelWriter/NovelApp/Application/AppState+SnapshotSyncV2Library.swift:235) と[終了前の保存:181](/Volumes/Files/GitHub/NovelWriter/NovelApp/Application/AppState+SnapshotSyncV2.swift:181) も失敗し、操作が詰まる。

Fable発見を静的に再照合した。削除直後はいったん `.saved` になるため、debounceが失敗する前なら他作品へ移れる余地がある。「削除すると必ず即座に回復不能」ではない。既存のLibraryDeletionTestsはcleanな削除を対象とし、このdirty条件を通らない。

**修正案:** document gate内でIMEを確定し、`performExclusiveAfterFlushing` で保存が成功してから削除intentを確定してeditorを外す。保存失敗なら現在作品を保持する。revisionの無条件破棄は行わない。終了失敗時の[通知不足:84](/Volumes/Files/GitHub/NovelWriter/NovelApp/Platform/macOS/ApplicationDelegate.swift:84) は別途、失敗理由・再試行・書き出しの案内を改善する。

### R11 — 明示snapshotと通常添付にも保存の排他境界を使う

[メニューのsnapshot:228](/Volumes/Files/GitHub/NovelWriter/NovelApp/Application/FuminiwaApp.swift:228)、[popover:261](/Volumes/Files/GitHub/NovelWriter/NovelApp/Features/Writing/WorkbenchToolbarContent.swift:261)、[通常添付の追加:38](/Volumes/Files/GitHub/NovelWriter/NovelApp/Features/Attachments/AppState+Attachments.swift:38) と同64行目の削除は、coordinatorを通さずcheckpointする。

[Application:89](/Volumes/Files/GitHub/NovelWriter/NovelKit/Sources/NovelSyncV2Application/SyncV2Application.swift:89) の世代読取とcheckpointの間にactorが別要求を受けられるため、自動保存と同じ世代を取得して片方が [Store:197](/Volumes/Files/GitHub/NovelWriter/NovelKit/Sources/NovelSyncV2Store/LocalSyncV2Store.swift:197) で拒否され得る。失敗側の完了が後になると `.failed` が残り、coordinatorがcleanの場合は `saveNow()` を呼んでも保存済みの表示を再発行しない。

Fable発見を静的に再照合した。ただし通常添付には失敗案内があり、「無言で失敗」は採用しない。明示snapshotや添付の再試行が成功すれば状態は戻るため、「次の入力まで回復不可」も採用しない。AI感想・アドバイスの添付保存は[既に排他されている:49](/Volumes/Files/GitHub/NovelWriter/NovelApp/Features/AssistantFeedback/AppState+AssistantFeedback.swift:49)。

**修正案:** 該当する明示操作をdocument gate・IME確定・session/account照合を伴う保存境界へ集約する。既存wrapperとの排他処理の二重取得を避ける。世代比較を外したり、古い本文を世代だけ更新して再送したりしない。修正時は直接checkpointと自動保存を意図的に競合させ、両順序を確認する。

### R12 — Rustの本文長を規範どおりUnicode scalar数へ揃える

規範の [string-value.schema.json:7](/Volumes/Files/GitHub/NovelWriter/docs/sync/v2/entity-schemas/string-value.schema.json:7) は `maxLength: 1048576`。[JSON Schemaの仕様](https://json-schema.org/draft/2020-12/json-schema-validation#name-maxlength)で、これは文字数でありUTF-8のbyte数ではない。

Swiftは [unicodeScalars:215](/Volumes/Files/GitHub/NovelWriter/NovelKit/Sources/NovelSyncV2/SnapshotValidation+Entity.swift:215) で数える一方、Rustは [text.len():230](/Volumes/Files/GitHub/NovelWriter/SyncServerV2/src/application.rs:230) でbyte数を数える。「あ」40万字は規範の文字数と構造化entityの16 MiB上限を満たしてローカル保存できるが、server側で拒否される。同じ長さ判定を使う人物・世界観の本文にも影響する。

**修正案:** Rust側をUnicode scalar数へ揃え、日本語・補助平面文字・上限前後の共通fixtureを両実装へ通す。Fableの「clientを1 MiB制限へ縮める」提案は、規範に合う保存済み原稿を拒否するため採用しない。本文上限を利用者に決め直してもらう必要はない。不一致は静的確認で、実serverへの長文uploadは行っていない。

### R13 — 失効を認証表示へ伝え、直接の再認証を案内する

[AuthSessionCoordinator:120](/Volumes/Files/GitHub/NovelWriter/NovelKit/Sources/NovelAuth/AuthSessionCoordinator.swift:120) はrefreshのterminal rejection時にvaultの認証状態を更新しない。[remote client:156](/Volumes/Files/GitHub/NovelWriter/NovelKit/Sources/NovelSyncV2Runtime/ProductionSyncV2RemoteClient.swift:156) は `authenticationRequired` を返すが、Mac側の購読は同期表示だけを更新する。そのため同期は「要サインイン」、account欄は「サインイン済み」となる。iOSも認証表示は変わらず、同期側はoffline表示へまとめられる。

Fable発見を静的に再照合した。Mac/iOSにはサインアウトの操作が残り、remote revoke失敗時もAppleログインへ戻れるため、ログインし直す方法自体はある。問題は失効理由・直接の再認証案内がなく、利用者に一度サインアウトをさせる点である。通常refreshで期限が延びるので「導入90日後に必ず発生」ではなく、長期未使用やsession失効等が条件。

**修正案:** terminal rejectionをscope付きの認証状態へ反映し、同じaccountへの再認証を案内する。ローカル原稿・保存・操作を維持し、別accountの非同期完了を適用しない。自動サインアウトという製品仕様を新しく選ぶ必要はない。

### R14 — 同期先で利用できなくなった作品に回復案内を付ける

別端末で作品を完全削除すると、serverは [削除済みWorkID:2093](/Volumes/Files/GitHub/NovelWriter/SyncServerV2/src/postgres.rs:2093) の再publishを拒否する。[D-092](/Volumes/Files/GitHub/NovelWriter/docs/DECISIONS.md:1144) と[作品削除契約:13](/Volumes/Files/GitHub/NovelWriter/docs/sync/v2/work-deletion.md:13) は、他端末の保存内容を保持する設計であり、この拒否自体は正しい。

しかしclientは [404:380](/Volumes/Files/GitHub/NovelWriter/NovelKit/Sources/NovelSyncV2Runtime/ProductionSyncV2RemoteClient+HTTP.swift:380) を汎用fatalへ変換し、画面は原因を説明しない。bound状態では別作品へコピーする通常の回復導線も出ず、同じIDの明示再試行では同期を回復できない。ローカル編集・保存は継続できる。Fable発見を静的に再照合したもので、実端末間の削除試験ではない。

**修正案:** 「同期先の作品を利用できない」と説明し、原稿を保持して書き出し、または利用者の明示操作で新WorkIDへコピーする道を作る。[wire契約:35](/Volumes/Files/GitHub/NovelWriter/docs/sync/v2/wire.md:35) は他account・不存在を区別しないため、404だけで「削除済み」と断定しない。自動消去や自動的な別作品化は行わない。

## 公開経路の追加確認 — 添付上限とupload失敗の保持

製品のobject上限は250 MiBだが、現行uploadは [単一PUT:86](/Volumes/Files/GitHub/NovelWriter/NovelKit/Sources/NovelSyncV2Runtime/ProductionSyncV2RemoteClient+HTTP.swift:86) である。公開経路はCloudflare Tunnel経由であり、[Cloudflare公式情報](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/4xx-client-error/error-413/)ではFree/Proが100 MB、Businessが200 MB、Enterpriseは最大5 GB。zone設定でさらに下げられる。

**実際の契約プラン・zone上限は未確認なので、本番が100 MB制限で停止するとは断定しない。** 先に実効上限を確認し、契約の250 MiBを通せるかを公開前の受入項目にする。

uploadが413等で拒否された場合、[recordFailure:448](/Volumes/Files/GitHub/NovelWriter/NovelKit/Sources/NovelSyncV2Runtime/ProductionSyncV2Planner.swift:448) はcommand以外の失敗状態を保持しない。原因表示だけでなく、再計画後に同じ転送を繰り返す条件も専用fixtureで確認し、恒久的なサイズ超過と一時障害を区別する必要がある。全422をサイズ超過と扱うとschema違反を隠すため、Fableの一括分類案は採用しない。

**推奨:** 現行上限を維持できる転送・配信方式を技術側で検討する。上限引下げや有料契約変更が必要になった場合に、具体的な容量・費用・既存添付への影響を提示して利用者に選んでもらう。

## 不具合と分けて進める改善

| 改善 | 推奨する進め方 |
| --- | --- |
| macOSのoffline表示（P3） | 通信例外が一律lostResponseとなり、通常のofflineも警告色の再試行待ちになる。明確なnotConnectedToInternetだけofflineへ分類し、timeout・応答喪失は区別する。警告色は `ExplicitSyncButton.swift:23` が根拠。確認した差は表示で、保存停止ではない |
| 通常checkpointのコスト | Fableは世代取得や添付の再読込・再hashも指摘した。実アプリの遅延は未測定。添付容量別のRelease測定後、世代の軽量取得と未変更objectの再利用を検討する |
| 公開版の失敗理由と履歴表示 | 同期失敗を再認証・容量・同期先利用不能等に分け、利用者が取れる操作を示す。履歴reasonの日本語化・時刻表示、AI回答の未完了理由も改善候補 |
| 校正後の色付けの計算量 | `ProofreadingChanges.swift` の全文比較が入力ごとにmain threadで走る。合成の全面変更で1000文字0.029秒、3000文字0.240秒、5000文字0.654秒だった。実原稿・実アプリの遅延測定ではない。まずRelease相当で測り、上限・差分範囲の縮小・非同期計算を検討する |
| iOSの戻る操作 | 標準Backの保存待ち後にpath/session/accountを再検査する。作品一覧へ戻る明示操作には同様の照合がある。競合する実UI操作は未再現なので、R2の操作境界修正時の確認項目にする |
| 公開運用の完成 | 30日猶予のaccount削除・取消・期限ジョブ、1年backup保持、restore後も削除状態を維持する仕組み、quota・監視の実装と受入を進める。期間とApple-only方針は決定済み。作品の即時削除D-092はaccount削除と別契約 |
| Windows着手前の互換基盤 | Windows 11／installer配布の方針は維持。W0の共通schema・独立fixture、Windowsの名前制約・Unicode・IME/Undoの受入を先に具体化する。Swiftの個別テスト成功をWindows互換完了にしない |
| 現行説明と作業履歴の分離 | AGENTSのAI説明は「1話preview」のままだが、最新実装は感想・アドバイスで複数話を選択できる。CODE_HEALTHやHANDOFFも追記が多く、解消済み残件が途中に残る。現行要約を更新し、時点付きの作業記録へ過去の証拠を寄せる |

公開HTTPSがないという指摘は採用しない。最新のTunnel文書には、Cloudflareで公開TLSを終端し内部CaddyのCAを検証する構成と確認記録がある。今回その実環境を再確認したわけではない。また、旧iOS AI画面・コピー導線の欠落、旧moduleの混在も現行sourceでは解消されており、再度の不具合として数えない。

## 利用者の判断が必要な点

R1〜R14は既定の保存・認証・互換・削除契約を守り、必要な状態と回復操作を表示する修正である。修正開始を止める製品仕様の再選択はない。

追加の判断が必要になるのは、公開経路の実効上限を確認した結果、**添付上限の引下げや有料インフラへの変更**が必要になった場合。推奨は現行250 MiB契約の維持で、費用と既存添付の扱いを具体化してから選択を求める。今の段階で曖昧な承認を求める必要はない。

Fableが提案した「保存せず終了」「AI感想の処理を話切替後も維持」は任意の製品変更で、今回の不具合修正に必須ではない。将来採用するなら、原稿保全と送信中表示への影響を整理して判断する。DBを自動resetして回復させる案は採らない。

今後の作業順については、**原稿保全と認証の修正→大量履歴と入力性能→公開運用→Windows**を推奨する。Windows先行や同時公開を希望する場合だけ優先順位の変更が必要となる。installerの具体的な作成ツールは既決方針の範囲で実装側が選べる。

アカウント削除の30日、backupの1年、Appleログイン以外の回復を作らない方針、Windows 11対応は再判断事項に戻さない。

## 修正するときの検証

最終的な段階は実装差分の影響で選ぶ。今回のレビュー結果だけを文書へ保存することを理由に、全体buildや全suiteを追加する必要はない。

| 変更 | 目安 | その修正で特に確かめること |
| --- | --- | --- |
| 方針・説明・作業履歴の整理だけ | 検証なし | 動作・schema・script入力を変更しない限り、テストやbuildを追加しない |
| 校正色付けや戻るUIの局所修正 | 中ぐらい | 該当機能、IME・Undo、古い非同期完了、対象OSのbuild。性能値はRelease相当で測る |
| R1・R2・R6〜R11の保存・削除・共有store修正 | 重たい | 既存全体検査と、連続入力deadline、ID固定、dirty削除、直接checkpointとの競合、専有/共有resource、fence変更、深い履歴のverify/adopt、最大メモリの該当項目 |
| R12のserver文字数判定 | 重たい | Unicodeの共通境界fixture、Swift/Rustの一致、既存原稿の受理、構造化entity byte上限の維持 |
| R13・R14の表示だけの変更 | 中ぐらい | 期限切れ・再ログイン・同期先利用不能の表示と回復操作。account遷移や新WorkIDコピーの保存処理も変える場合は重たい検証へ広げる |
| offline分類・限定的な表示文言 | 軽い | 明確なofflineと応答喪失を区別する最小限の関連確認 |
| R3〜R5の受信・認証修正 | 重たい | 認証前の本文未読取、通知/再認証の順序、200/429/4xx/5xxの分類と再起動後retry。DB確認は専用test DBを使う |

全体検査の成功と、実機・外部サービス・公開運用の成功は別に記録する。今回の合成再現を、そのまま修正後の成功証拠へ転用しない。

## Fableの指摘をどう扱ったか

| Fableの指摘・提案 | 統合結果 |
| --- | --- |
| dirty作品削除後の保存停止 | R10へ採用。debounce前に他作品を開ける条件を明記し、未保存revision破棄案を除外 |
| snapshot・添付とautosaveの競合 | R11へ採用。失敗案内と再試行による回復を補足し、既に排他されるAI添付を除外 |
| 文字数とbyte数の不一致 | R12へ採用。規範に合わせてRustを直す方針へ修正 |
| Cloudflare上限と添付 | 実効上限が未確認なので公開経路の確認項目。upload失敗の保持も別途指摘 |
| 失効後に再ログインできない | R13へ限定採用。既存サインアウト経由の復旧があることを補足 |
| 別端末削除後の同期失敗 | R14へ限定採用。404を削除済みと断定する案、自動消去・自動降格を除外 |
| offlineが警告表示 | P3改善へ採用し、実際の警告色を付ける箇所へ根拠を修正 |
| iOS完全削除が未実装 | 現行iOSには削除導線があるため棄却 |
| 本文上限・Apple以外の回復・他端末消去等の再判断 | 既存schema・D-087・D-092で決まっている範囲は再判断へ戻さない |

## 今回実施した確認と範囲

- 現行source・callsite・保護条件・関連テスト・仕様を、保存/同期、UI/EditorKit/AI、Rust/認証の担当に分けて読み、主要指摘は親レビューで再照合した。
- 自動保存とiOS削除の縮小再現、現行SQLite schema・削除SQLによるメモリDB再現を行った。これらは本番アプリのend-to-endテストではない。
- 同期target依存、AI境界、v2境界、test compositionの4つの既存静的検査は成功した。
- 全体 `Scripts/check.sh`、Swift/Rustの全suite、アプリbuild、実DB、実Apple/API、負荷攻撃、実機UIは実施していない。過去のbuildや同期成功を今回の成功として数えていない。
- Fableは読取専用で完了し、追加の主要指摘は別担当と親レビューで反証・規範確認を行った。Fable自身はbuild・テストを実行していない。CLIの最終resultはis_error=false、exit=0、主モデルのfirstParty応答はclaude-fable-5-1。
- 文書保存のための追加テスト・build・lint・リンク検査は実施していない（検証なし）。上記の静的検査・合成再現は、依頼されたプロジェクトレビューで行った確認として区別する。
- 原稿、実DB、credential、未追跡退避フォルダは変更していない。検査対象は製品source・関連設定と合成データである。

このレポートは一般配布の受入完了や、プロジェクトに他の不具合がないことを保証するものではない。
