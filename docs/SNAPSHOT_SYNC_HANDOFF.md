# Snapshot Sync 実装ハンドオフ

> **状態**: D-077／[SNAPSHOT_SYNC.md](SNAPSHOT_SYNC.md)を実装へ移すための境界と合格条件。現時点は設計のみで、server／SQLite clientは未実装。利用者から実装着手の指示があるまでコードを追加しない。

## 1. 実装者へ渡す不変条件

1. UI、editor、作品open、autosave、遷移、close、quitはremote I/Oを待たない。
2. 確定済み端末内正本はSQLite＋local CAS。`.novelpkg`はImport／Export codecだけに使う。
3. UI上の同期単位、Conflict、履歴、復元は1作品。転送だけEntityKey／object単位にdeduplicateする。
4. local current、dense local Snapshot、SyncIntentは1 SQLite transactionでcommitする。
5. 未送信Intentと一度送ったSealedAttemptを混ぜない。lost ackはexact retryする。
6. remote headはexpected `{snapshotID, generation}`のCASだけで進める。headなしは`null`、存在するgenerationは`1...9007199254740991`のJSON安全整数とし、時計、端末名、到着順でwinnerを決めない。
7. Divergenceは保存成功状態であり、candidateを削除しない。別EntityKeyでもdependency closureと作品全体invariantがvalidな場合だけclientで自動統合し、同じkey／delete対依存変更／構造不整合を3択へ送る。
8. remote callbackからactive editorへ内容を注入しない。D-041のsession／IME／generationを満たすsafe boundaryだけでmaterializeする。
9. CloudKitと新serverを二重authorityにしない。移行中のCloudKitはread-only sourceにする。
10. 旧package、journal、dirty、review、CloudKit recordをreset／上書き／削除しない。

## 2. 仕様authorityとR0成果物

実装コードやintegration testを仕様の正にしない。R0はコードを実装せず、次を同一PRでfreezeする。

```text
docs/sync/v1/
├── README.md
├── openapi.yaml
├── snapshot.schema.json
├── publish-command.schema.json
├── errors.md
├── entity-schemas/
│   ├── work-document.schema.json
│   ├── string-value.schema.json
│   ├── id-order.schema.json
│   ├── character.schema.json
│   ├── plot-card.schema.json
│   ├── flag.schema.json
│   ├── world-note.schema.json
│   └── attachment-metadata.schema.json
└── fixtures/
    ├── canonical-valid/
    ├── canonical-invalid/
    ├── entity-diff/
    ├── intent-attempt/
    ├── cursor/
    ├── conflict/
    ├── retention/
    ├── migration/
    ├── backup/
    ├── account/
    ├── portable/
    └── remote-command/
```

- JSON canonicalizationは[IETF RFC 8785 JCS](https://datatracker.ietf.org/doc/html/rfc8785)を正にする。
- valid fixtureは入力model、期待canonical bytes、SHA-256、期待decode modelを持つ。
- invalid fixtureはduplicate key、unknown field、非canonical whitespace／escape／key順、float、unsafe integer、uppercase UUID／digest、不正UTF-8、unpaired surrogate、parent／entry順不正、size超過を含める。
- scenario fixtureは初期state、command列、各stepのSQLite／server state、UI可否、期待errorを言語非依存JSONで表す。
- Swift／Rust／将来C#のfixture harnessは別実装とし、共通実装をFFIで使って一致を見せかけない。

R0完了条件は、仕様内の曖昧な`optional`、`implementation-defined`、自由文字列errorを0件にし、E2EE／account Decisionを確定することである。

現時点の`docs/sync/v1/`は`serverReadableV1`を仮置きした`designCandidate`であり、R0 freeze済みではない。E2EE／account Decision後にprotocol epoch、content-protection fields、error、limits、全canonical hashを再監査し、承認commitを明示して初めてauthorityとする。

## 3. Apple client module境界

```text
NovelCore
    ↑
NovelSnapshot          pure ID / manifest / diff / reconciliation / state machine
    ↑                         ↑
NovelLocalStore              NovelSyncHTTP
GRDB + local CAS             URLSession transport only
    ↑                         ↑
        SyncFeature coordinator
        Intent / Attempt / Inbox / lifecycle / account fence
                    ↑
           NovelApp / NovelAppIOS

NovelStorage         .novelpkg validator / codec only
NovelSyncCloudKit    read-only migration adapter after cutover begins
```

- `NovelSnapshot`はFoundationの値型までに留め、SQLite、GRDB、URLSession、CloudKit、AppKit、UIKitへ依存しない。
- `NovelLocalStore`はGRDBを内部実装に使う。GRDBはSwift 6、migration、WAL／concurrent readを提供するため採択するが、versionはR1開始時に公式releaseを再確認してpinする（[GRDB公式repository](https://github.com/groue/GRDB.swift)）。
- `LocalLibraryStore` actorだけがmutation APIを公開する。transaction内でnetworkやUI actorをawaitしない。
- `NovelSyncHTTP`はrequest／responseとtransportだけを持ち、SQLiteへ直接触れない。
- `SyncFeature`がlocal storeとHTTPをcompositionし、WorkIDごとのsingle-flight laneを所有する。
- credentialと、E2EEを選んだ場合のwork keyはKeychainへ置き、SQLite／`.novelpkg`／logへ出さない。

## 4. Local durability契約

### 4.1 SQLite

- 1 OS user／app installationにつき1 database。
- WAL、`foreign_keys=ON`、原稿commitは`synchronous=FULL`。Appleでは`fullfsync=ON`の実機可否と性能もR1で固定する。SQLite公式文書でもWAL＋FULLは各commitのWAL syncを行う（[SQLite WAL](https://sqlite.org/wal.html)、[PRAGMA synchronous](https://sqlite.org/pragma.html#pragma_synchronous)）。
- schema migrationはversion＋checksumを持つtransactional migration。decode後の再encode byte一致をmigration判定へ使わない。
- iOSのDB／CASはbackground再開と保護を両立するfile protectionをR1 fixtureで固定する。
- abnormal shutdown後は`quick_check`とCAS inventoryを行い、失敗時に空DBを自動作成しない。
- physical backupはSQLite Online Backup APIで作り、DB fileだけをcopyしない。まずbackup IDをdurable化してlocal CAS sweep barrierを取得し、専用staging DBへOnline Backupを完了する。sourceへの並行saveは止めない。staging DBの`quick_check`と記録された`library_generation`を検証し、**そのstaging DB自身から** reachable CAS root集合を導出する。sweep barrierを保持したまま、その集合をsource DBのactive backup pinとしてcommitしてからbarrierを解放する。その後、全rootを独立backup object storeへcopyし、hash／byte countをread-backし、staging DB、sorted inventory digest、commit markerをfsyncする。commit marker後だけ復元候補にし、source側pinを解放する。crash前のstagingは候補にせず、active pin後のcrashは同じbackup IDから再開する。sourceが次世代へ進んでもstaging世代へ混ぜず、restoreはcommit marker、DB `quick_check`、全backup CAS read-backが通った後だけ採用する。各段階のkill、並行save、local GC競合をfixture化する。
- backup triggerは初回原稿commit後の次idle／background、以後verified世代が24時間より古いforeground idle／background、schema migration／sync cutoverの直前と直後。通常save／closeは待たせないが、pre-migration backup失敗時は旧DBを変えずmigrationを延期する。backup CASは世代間dedupし、直近3 verified世代とpost-migration検証後30日までのpre-migration世代を保持する。容量不足でもlocal editを止めず、最後の2 verified世代を暗黙削除せず状態を表示する。corruption時はcommit marker＋DB quick check＋全CAS inventoryが通る世代だけを候補にし、空DBへfallbackしない。

### 4.2 CAS adoption

1. 同一volumeのstagingへstreamしながらSHA-256とbyte capを検査する。
2. fileをfsyncし、hash／byte countをread-backする。
3. `Objects-v1/sha256/ab/cd/<digest>`へno-overwrite renameし、必要なdirectory fsyncを行う。
4. 短いSQLite transactionから参照する。
5. 3と4の間で落ちたorphanはgrace後のmark-and-sweepだけが削除する。

symlink、junction／reparse point、hard-link依存、path traversal、special file、途中変更をrejectする。CAS pathへtitle、attachment name、WorkIDを含めない。CAS object rowはObjectID＋byte countだけをidentityとし、content typeはSnapshotEntry／logical reference側に置く。remote presenceはimmutable server instance ID＋protocol epoch＋opaque account ID＋credential-bound account fence＋ObjectIDの複合keyへ分離し、同じAccountIDでもfenceが変われば再利用せず、server missing照会とfinalize／read-backを最終正にする。

local reference採用とGC deleteはObjectIDごとの`CASMutationGate`で直列化する。sweepは`quarantined`後もdelete直前にLocalLibraryStore transactionで全rootを再検査し、deletion token付き`deleting`をcommitしてからgate内でexact fileだけをunlink／directory fsyncする。referenceが先ならquarantineをcancelし、deleteが先ならsaveはstaging bytesを削除後に再adoptしてからreferenceをcommitする。gate内でawaitせず1 objectごとに解放し、process-kill後はtoken／file／rootの3面を照合するfixtureを必須にする。

AppleではCAS fileの採用前に`F_FULLFSYNC`の成否を検査し、directory durabilityを含むplatform adapterの保証／非対応errorを実機process-kill fixtureで固定する。

### 4.3 Portable Import／Export

- UUIDはpackageの大小文字非依存36文字を128-bit logical valueへparseし、SQLite／EntityKey／Snapshot payloadではlowercase、v3 Export JSON／ID filenameではuppercaseへ出す。raw package表記をhashせず、uppercase package→lowercase wire ObjectID→uppercase Exportのfixtureを共有する。
- validated package tree全itemからexact consumed known pathとattachment pathを引き、残るopaque／orphan file、directory、raw legacy `snapshots/`をlocal-only inventoryへ残す。v1／v2 `chapters/`／`notes/`とv3 payload root内のorphanも含む。
- inventory pathはrelative component列＋kind＋元の綴りで持つ。collision keyはUnicode 15.1.0 NFC→同版Default Full Case Folding（`CaseFolding.txt` status `C`／`F`、Turkic除外）→同版NFCのUTF-8 bytesとし、generated table／Unicode source hashをR0へ固定してOS／locale APIを使わない。known namespace、Windows禁止名、component UTF-8 255 bytes／UTF-16 240 units、relative UTF-8 768 bytes／UTF-16 512 units、depth 16を検査し、後の既知payloadと衝突しても上書きしない。
- attachmentはImport intentでUUIDを一度予約してmigration ledgerへ先にcommitし、retryで変えない。初期orderもvalidated original filenameのUTF-8 byte辞書順から同じtransactionで封印し、locale／filesystem順や再scanで並べ直さない。v1 `displayName`はportable filename、UUIDがidentityであり、同名の別UUIDはdependency Conflictにする。packageにauthorityがないMIMEはv1 metadata／hashへ入れず、OS推定／byte sniffを同期identityに使わない。
- portable inventoryのattestation順は元のrelative path componentをUTF-8 byte辞書順で比較し、prefix directoryをdescendantより先にする。元の綴り／bytesを正規化しない。
- any valid known Snapshotはv3 packageへmaterialize可能でなければならない。package depth 16、item 20,000、total 2 GiB、各string-value／world-note本文のraw UTF-8 1 MiB、known JSON 64 MiB、manifest 16 MiB、attachment 250 MiBを共通fixtureにする。local-only inventory込みで超過した場合はbytes／編集を保全し、ExportだけをrepairRequiredにする。online quotaとは分離する。
- Export read-backはknown modelのlogical equality、portable document ID／createdAt policy、Export時だけ更新するupdatedAt、attachment／opaque／raw legacy snapshotのpath・kind・bytesを別々に比較する。package全体のbyte一致は要求しない。
- restoreはlocal-only inventoryを変えない。keep-bothはnew Workへ参照をatomic copyし、同じCAS bytesに独立GC rootを作る。v1 Exportはimported raw legacy snapshot subtreeだけを戻し、新しいSQLite historyをpackageへ合成しない。

### 4.4 Save／Intent

- 最初の未保存変更から最大2秒のcoalescing windowでdense local Snapshotを作り、追加入力で期限を延長しない。同じ内容＋同じparentならno-op。
- dense autosaveは直前のautosaveをparentに連鎖させず、`works.stable_checkpoint_snapshot_id`をparentにするleafとして作る。`works`はstable checkpointと対応local generationを一緒に持つ。manual／lifecycleではcurrent leafへ保護occurrenceを追加して同じSnapshot IDをstable checkpointへatomic promotionする。online ackはattempt sourceへのoccurrenceを常に追加するが、source generationが現stable checkpoint generation以上の場合だけpointerを進め、古いlost-ACK replayで新しいcheckpointを後退させない。未保存内容がある境界は従来のstable checkpoint直下に新leafを作って即promotionする。最新leafをparentに別checkpointを作らないため、古いdense sibling leafは祖先化せずpruneできる。
- lifecycle境界はdebounceをflushする。local commitに失敗した場合、遷移／close／quitを成功扱いにしない。
- 同期binding済みworkは同じtransactionで`SyncIntent(latestLocalSnapshotID)`をupsertする。
- Intentは未送信ならcoalesce可能。manual／lifecycle occurrenceは別の`checkpoint_replication_intents`へlocal Snapshot、capture時remote base、reason、ensure-pinned、bindingを保存し、`snapshot_remote_equivalents`でread-back済みremote Snapshotへ対応付ける。manualは既定ensure-pinned=true、lifecycleはfalse。manual／pinned intentはcoalesceせず、lifecycleだけ同じUTC retention bucketの新しい未送信intentへ置換できる。manual reason自体は永久rootにせず、明示unpin後はbucket／payload release対象にする。local Snapshot自体はretention保護する。
- 初回設定で利用者がonline保存とexact account scopeを選んだ後、そのscopeが確認済みの状態で作るworkは作成時にbindする。account不明／別account中に作ったunbound workは、後のloginだけでautomatic adoptせず、対象scopeを明示確認してからbindする。

## 5. Worker state machine

```text
idle
  ├─ Intentなし → idle
  └─ Intentあり → observeRemote
observeRemote
  ├─ auth/version/account mismatch → parked
  ├─ remote == base → buildBranchCandidate
  └─ remote != base → reconcile
buildBranchCandidate / reconcile
  ├─ safe union → sealAttempt
  └─ same-key conflict → needsChoice
sealAttempt → uploadObjects → registerSnapshot → publishCAS
publishCAS
  ├─ applied → readBack → acknowledge → idle
  ├─ timeout/lost ack → retrySameAttempt
  ├─ divergence → persistDivergence → reconcile
  ├─ 401/403 → parkedAuth
  ├─ version fence → parkedVersion
  └─ retryable 5xx/network → retryScheduled
```

- laneはWorkID単位、in-flight attemptは1件。
- state-changing APIは共通`sealed_remote_commands` journalを使う。create／finalize upload、publish、classify、Conflict resolve、pin、checkpoint、restore、payload releaseはoperation ID、binding scope、canonical request bytes／digestをnetworkへ1 byte送る前にcommitし、restartではpending commandをexact retryする。local-origin head mutationはsource local generation／Snapshotもsealする。receipt＋resource／head／state read-back後だけfeature stateを完了するが、remote baseline／feature stateを進めてもsourceより新しいcurrent／Intentをclear・materializeせず、active editorへ注入せず次reconcileへ回す。
- object transferはSealedAttempt＋ObjectIDごとにcreate command、upload ID、complete PUT状態、finalize command、expiry／resultを耐久化する。complete PUTは同じopen upload IDへ全byteを再送できる。typed `uploadExpired`時はserverのexpired stateとquota reservation releaseをread-backし、旧session／receiptをretiredとして残した後だけ新create operation IDをsealする。
- worker wakeは約5秒quiet、最長約30秒、lifecycle、通信復帰を既定とし、連続入力中のremote publish数をboundedにする。UI lifecycleはworker完了をawaitしない。
- `SealedAttempt`はoperation ID、JCS command bytes／digest、expected head、candidate、source local generation／Snapshotを保存する。networkへ1 byteでも出した後はimmutable。
- process restartはexpired local leaseを回収し、SealedAttemptを最優先でexact retryする。
- ack後はattemptのsource generation／Snapshot以下を指すIntentだけをclearする。local generationが進んだ／Intentが別Snapshotを指す場合は新しいIntentを残して次に処理する。
- checkpoint laneはlocal entriesからcapture時baseをparentに持つremote-equivalent Snapshotをregisterし、`recordSnapshotCheckpoint`をsealed commandとして送り、head／generationを変えずmanual／lifecycle occurrenceとensure-pinnedを記録する。ensure-pinned=falseは既存pinを解除せず、unpinは明示`setSnapshotPin`だけが行う。receipt＋history＋effective pin＋Snapshot read-back後だけmapping／intentを完了する。latest-head attemptとcheckpoint attemptを1件ずつ交互に進め、Sをpin後Tへ編集してもSはhistory、Tだけがheadになる。初回headなしではlatest root publish＋library read-backまでcheckpointをblockし、serverも`workHeadRequired`でfail closedする。
- remote fast-forwardは`current_local_snapshot_id == last_remote_equivalent_local_snapshot_id`、pending Intent／Attempt／transfer／Divergence／Conflictなし、未保存editor／form／IMEなし、session／surface一致を必要条件とし、materialize transaction内でexpected current＋local generation CASを再検査する。不成立時はInboxへ保持してreconcileし、clean editorだけを根拠にcurrentを進めない。
- retryはbounded exponential backoff＋jitter。serverの`Retry-After`を上限内で尊重する。
- auth、quota、version、permanent schema errorをnetwork retryへ畳み込まない。いずれもlocal editは継続する。

## 6. Reconciliation fixture

完全manifestをmapとして、各keyの`base/local/remote`を比較する。

| local | remote | 結果 |
| --- | --- | --- |
| baseと同じ | changed | remote |
| changed | baseと同じ | local |
| 同じObjectIDへchanged | 同じObjectIDへchanged | そのObjectID |
| 異なるObjectIDへchanged | 異なるObjectIDへchanged | needsChoice |
| delete | unchanged／delete | delete |
| entity groupのdelete | 同group edit／参照追加 | dependency closure全体がneedsChoice |
| baseなし／schema不明 | 任意 | needsChoice |

raw key diffの後、entityの全payload key、所属order、参照元／参照先をdependency closureへ展開する。同一IDの異なる追加、delete対同group edit、削除entityへの他方の新規参照は、keyが直接重ならなくてもneedsChoiceである。safe unionはEntityKey順にcanonical manifestを作り、local branch＋remote headのparentもdigest辞書順にした後、作品全体invariantを再検証する。`serverReadableV1` serverもbase／local／remoteからdescriptor closureとinvariantを独立再計算してclient候補を検証するが、payload内部をmerge／生成しない。E2EE採択時はこのserver validation境界をprotocol epochで置換する。invalidまたは違反を一意なclosureへ帰属できない候補は自動publishしない。本文string内部、order array内部はmergeしない。

3択は競合dependency closureだけlocal／remoteを選び、closure外の安全なdeltaを両方保持する。選択後もinvalidになる交差参照では、validになるまで保守的に変更集合全体のlocal／remote選択へ広げる。どの選択も元WorkIDへ2-parent resolutionをpublishする。全選択で送信前flush時のsource local generation／Snapshot、選択、resolution Snapshot、sealed commandを`pending_conflict_resolutions`へ耐久化する。送信後の追加入力は新しいcurrent／Intentへ残し、ACKはsource以下だけを解決済みにする。currentが進んでいれば解決後headを新baseに再reconcileし、use-onlineでもactive editorへ注入しない。

「両方」はnew WorkID／0-parent rootを1つの`pendingKeepBoth`へ予約し、そのcloneの通常publish laneをblockする。cloneへの追加入力はroot後のIntentに積む。専用resolve commandが元Work head、新Work root、Conflict、receipt、change eventを1 PostgreSQL transactionでall-or-nothingに確定し、lost ack read-back後だけlaneを解放する。local／remote staleでは同じ予約を再利用し、再提示ごとにcloneを増やさない。new WorkIDが別operation所有だったtyped collisionだけは両head未変更をread-backし、同じpending行で予約WorkID／root／operationを1組だけ差し替える。local clone state自体を複製しない。表示後にlocal generationまたはremote headが進んだらstaleにして再計算する。

manifest validatorはJSON Schemaだけで完了しない。空作品でも`work/document`、`work/title`、`work/synopsis`、6つの`work/*-order`を各1件必須とし、`work/document`のportable document IDとcalendar-validなUTC秒精度の`documentCreatedAt`を検証する。未使用WorkIDの最初のrootがWork anchorを確立し、以後の全Snapshotはparentless migration candidateも同じObjectIDを使う。さらにchapter orderとchapter key集合、各episodeの唯一の所属とtitle／body／memo、各metadata orderとentity集合、payload IDとEntityKey、attachment metadata／bytes、portable filename衝突、全参照先を作品全体でexact照合する。server-readableではclient／server、E2EEではencrypt前／decrypt後のclientで同じfixtureを通す。

local-only履歴の復元はlocal graph内でcurrent＋selectedの2-parent Snapshotを作るが、その未登録parent鎖をserverへuploadしない。復元後entriesは通常Intentからremote head直下のbranch candidateにする。専用online restore commandは、選択元Snapshotがserver上で`available=true`の場合だけcurrent remote＋selected onlineの2-parent publishに使う。server transactionはexpected old headへの`restoreBefore` occurrence＋pin、new head、change、receiptをatomicにし、resultのprotected Snapshot ID／effective pinとhistory availabilityをread-backする。staleでは全変更0、lost ACKはsame command receipt replayとする。

## 7. Rust server境界

推奨stackはAxum＋Tokio＋SQLx＋PostgreSQL＋S3-compatible object store。clientはPostgreSQL／S3へ直接接続しない。

server domainを次へ分ける。

```text
sync-domain       typed IDs, limits, manifest validation, command results
sync-api          Axum routes, auth, body limits, typed errors
sync-postgres     transaction, receipt, head, cursor, Conflict, quota
sync-object       streaming/finalize S3 adapter
sync-auth         dev token / Production OIDC adapter
sync-testkit      fake clock禁止のdeterministic scenario runner
```

OpenAPIで少なくとも次をfreezeする。

- capabilities／minimum client／server instance／protocol epoch
- bootstrap barrier、library pagination、change cursor／expiry
- object missing、stream or temporary upload、finalize、download
- Snapshot register／get
- expected head publish CAS／receipt replay
- Divergence／Conflict list、classify、idempotent resolve
- `keepBoth`の元Work resolution＋new Work root atomic resolve
- history／pin／availability、明示payload release、quota、Snapshot内容のrestore

bootstrapはlibrary head全pageだけで終えず、各Workのunclassified／unresolved Divergence、unresolved Conflict、retained History occurrence／pin／availability全pageをstagingへ読む。scan中の全mutationが元transactionでbarrier後eventを出すことをserver invariantにし、scan後`changes(after: barrier)`をcurrentまでreplayしてexact resourceをrefetch、ID／occurrence IDでdedupeする。library＋review＋history＋cursorをclient SQLiteへ一括installし、install前crash／cursor expiry／page不整合はstageを破棄してfull restartする。

remote work trash／hard deleteはwire v1 scope外であり、破壊的endpointを追加しない。

`releaseSnapshotPayload`はwork／occurrenceを削除せず、explicit unpin済みの非current Snapshotだけをlineage stubへ縮退する。clientはlocal current／pending Intent・Attempt・transfer・checkpoint・migrationを先にguardする。serverはremote head、effective pin、server-known in-progress operation、Divergence／Conflict／migration等を同じtransactionで再検査し、並行publish／pin／resolveとlockで直列化する。hard rootなら`snapshotPayloadProtected`で変更0、安全ならavailability=false、entry refsとcanonical manifest payloadのstub化、manifest quotaのexactly-once減算、user-released marker、retention event、receiptをatomic commitする。explicit releaseはautomatic bucket retentionをoverrideし、schedulerが暗黙rehydrateしない。manual／restoreBefore reason自体はpermanent rootではない。local copyは変更せず、object quotaはgrace後のphysical GC時だけ減算する。明示的なsame-Snapshot registerはquota preflightと全payload検証後にatomic rehydrate／manifest再課金し、replay deltaは0、quota failureは変更0とする。

PostgreSQL transactionはreceipt lookup、request digest検査、head lock、lineage／object検査、head更新またはDivergence、対応History occurrence、change event、receipt insertをatomicに行う。通常publish／auto-union／Conflict resolution／keep-both clone／restoreのapplied headは各reasonとoccurrence IDを返し、no-op／stale／Divergence／receipt replayでduplicate occurrenceを作らない。keep-bothの両Work occurrenceも同じall-or-nothing transactionに含める。object keyと全unique keyはtenantを含む。receiptはprotocol epoch／accountの存続中は保持してresponseを再生するが、object GC rootにはしない。未分類／未解決Divergenceと未解決Conflictはcandidate manifest／objectのGC rootであり、retention間引きで利用不能にしない。

server object rowは`available／quarantined／deleting`、immutable storage incarnation key、deletion tokenを持つ。registerはObjectID辞書順lock＋root insert、GCはlock＋root再検査＋old incarnationの`deleting` CASで直列化する。GCが先ならtyped `objectAvailabilityChanged/replanObjectTransfer`でmissing照会へ戻し、finalizeはdelete完了後に別incarnation keyをadoptする。S3 delete後はtoken／incarnation一致時だけrowを確定し、lost ACK／process-killで新incarnationをold GCが消せないfixtureを必須にする。

finalizeはcreate時にupload ID、quota reservation、request digest、temporary／予定incarnation key、open stateを耐久化し、temporary bytesの実hash／size検査→immutable incarnation keyへのcopy／adopt→そのkeyのread-backを先に行う。その後だけobject lifecycle rowをlockし、current incarnation、quota、remote presence、finalize receiptを同じPostgreSQL transactionでcommitする。S3成功後・DB commit前crashは同じoperation ID／予定keyをretryまたはreconcilerがadoptし、DB成功後のlost ACKはreceipt replayする。PGは確認済みbytesより先に`available`／success receiptを出さず、未採用S3 keyは参照不能orphanとしてgrace後に削除する。

expiry workerとfinalizeはupload rowをlockして`open→expired|finalized`をCASする。expired transactionはreserved quota release、temporary cleanup intent、quota eventをexactly-onceでcommitし、finalize側は`uploadExpired`となる。finalize transactionがreserved→usedへ進んだ場合expiryはno-op。create receipt replayはexpired upload IDを返しても再予約せず、cleanup crashはintentから再開する。

同一tenant／ObjectIDの複数finalizeはobject lifecycle lockで直列化する。winnerだけがincarnation採用＋reserved→used、valid loserは既存bytes read-back＋自分のreservation解放＋cleanup intent＋`alreadyAvailable` receipt、invalid loserはrejected＋reservation解放＋cleanupを各1 transactionで確定する。loser／receipt replayのused deltaは0とする。

S3 uploadは全bodyをmemoryへ載せない。proxy stream中にdigest／sizeを検査するか、temporary uploadの実byteをserver finalizeで検査する。未finalize objectをmanifestから参照できない。

## 8. 192.168.11.5 integration境界

- development／integration専用。Production endpointやbackup完成の証拠にしない。
- ZimaOS上の既存container、network、volume、portをread-only inventoryしてから専用directory／Compose project nameへ置く。
- 2026-08-15のread-only確認ではTCP 8080が使用中だったため、固定portを前提にしない。配置時に再確認する。
- PostgreSQL／MinIOはloopbackまたはinternal Docker networkだけへbindする。公開するAPIもLAN／VPN＋HTTPSに限定する。
- secretは`.env`へcommitせず、画面／test logへ出さない。配置後はpassword SSHではなく公開鍵へ切り替える。
- Compose起動、health、authorized capabilities、object→Snapshot→CAS→lost-ack replay→Divergence→3択resolve→cursorのsmokeを自動化する。
- host外へPostgreSQL＋object storeの整合backupを作り、空の別環境へrestoreするまで運用合格にしない。

## 9. PR列と完了条件

| PR | scope | 完了条件 |
| --- | --- | --- |
| R0 | OpenAPI／schema／fixture／Decisionだけ | ambiguity 0、cross-language expected bytes確定 |
| R1 | `NovelSnapshot`＋GRDB／CAS | kill、disk full、corruption、backup focused PASS |
| R2 | Import／Export codec | v1〜v3＋unknown resource round-trip PASS |
| R3 | local棚／autosave／履歴／復元 | networkなしMac／iOS lifecycle PASS |
| R4 | Rust server＋Compose | domain／Postgres／S3 integrationと192.168.11.5 smoke PASS |
| R5 | Swift HTTP worker | lost ack、cursor、account fence、safe materialization PASS |
| R6 | auto-union／3択／online history | 2〜3端末、再起動、stale、全選択 PASS |
| R7 | legacy inventory／migration／cutover | checkpoint kill、2回実行、rollback、read-back PASS |
| R8 | Production hardening | 選択済みauth／content protectionのauditとkey recovery、TLS、quota、monitoring、off-site restore、signed devices PASS |

各PRで`./Scripts/check.sh`を通す。通常App compositionの切替、旧CloudKit write停止、旧source削除はそれぞれ別PR／Decisionとし、R0〜R6へ混ぜない。

## 10. 実装中の禁止事項

- packageとSQLiteの長期dual-write
- CloudKitと新serverへのdual-publish
- autosave／close／quitでnetwork完了をawait
- `Date`、server arrival、端末名によるwinner
- active `NSTextView.string`／`UITextView.text`へのremote callback注入
- `String`内部の自動3-way merge、CRDT、order fieldの追加
- operation IDをretryごとに再生成
- account未確認workのautomatic adopt
- 1作品のcorruptionを棚全体の空DB fallbackへ変換
- migration成功前の旧bytes／journal／review／CloudKit record削除
- fixed dev token／HTTP構成のInternet公開
- server実装から逆算してOpenAPI／fixtureを書き換えること

## 11. Lunaへ依頼するときの最初の指示

最初の依頼はR0最終化だけに限定する。design candidateは既にあるため、利用者のE2EE／account Decisionを反映し、fixtureを独立検証してfreezeするところから始める。

> D-077、`docs/SNAPSHOT_SYNC.md`、本書、`docs/sync/v1/README.md`を読み、利用者が決定したcontent protection／account方式をdesign candidateへ反映してください。OpenAPI、JSON Schema、canonical valid／invalid fixture、全scenario fixtureを独立に検証し、差分とhash変更を提示してください。実装コードは追加せず、R0のcross-language expected bytesが承認されるまでRust serverとGRDB storeへ進まないでください。
