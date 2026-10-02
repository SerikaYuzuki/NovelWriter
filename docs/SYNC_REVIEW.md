# Snapshot Sync v2 全体レビュー（2026-10-01）

[初回取り込みの待ち時間](INITIAL_IMPORT_LATENCY.md)を起点に、取得・取込・作品open・UI・クライアント構造・データモデル・serverを読取調査した結果。実装はまだ行っていない。各項目は実装担当（Codex）へ渡す単位で、ID・根拠・修正方針・契約影響を持つ。

- **確定**：コードを読んで成立を確認した。★はレビュー側で再確認したもの。
- **推測**：解釈・見積り。計測・再現はしていない。
- 検証段階は[AGENTS](../AGENTS.md)のD-086に従い、実装時に選ぶ。本文書の作成自体は「検証なし」。
- 端末の実DBは件数・サイズの集計のみ行い、本文は読んでいない。

## 要約

1. **時限的な不具合が2つある。** 1作品の履歴が4,096世代を超えるとpublishが恒久失敗する（S-01）。初回取り込みが途中で失敗するとその作品を端末で開けなくなる（C-01）。どちらも契約変更なしで直せる。
2. **25秒の大半は無駄な処理。** 前の世代のobjectを毎回全バイト読み戻す、起こりえない循環を毎世代探す、同じgraphを3〜4回全検証する、等。契約変更なしで数秒規模まで縮む見込み（推測）。この一部は**通常の自動保存にも効いている**。
3. **根本原因は「2秒ごとの自動保存がすべてserverの不変履歴になる」こと。** 対象作品は約1日で1,467世代、親2つの合流は0の一直線。文書は「自動保存は安定checkpointからの葉」としており、実装が契約と食い違っている可能性が高い（D-01）。
4. **構造はpackage単位では健全。** ただし作品ごとの暗黙の状態機械、層をまたぐwire解析の重複、Mac/iOSの別実装とpollingが絡んでいる。全面書き直しではなく段階的な置換で直す（R-xx）。
5. **UIは情報の誤り・過剰・欠落が混在。** 未同期・未取得の作品に「同期済み」と出る、DEBUG診断や生のエラー文が見える一方で、段階・量・中止・再試行・offlineは表示されない。macOSは取り込み中に何も表示しない（U-xx）。

## 推奨する着手順

| 順 | ID | 内容 | 契約影響 | 判断 |
| --- | --- | --- | --- | --- |
| 1 | S-01 | serverの祖先判定の上限・打切り | なし（server反映が必要） | 不要 |
| 2 | C-01〜C-03 | 中途半端な取込・中断・二重取込・account照合 | なし | 不要 |
| 3 | L-01〜L-05 | ローカル取込・自動保存の重複処理削減 | なし（download.mdの「再検証」表現は要確認） | 不要 |
| 4 | F-01〜F-06、S-02〜S-06 | 取得のCPU・通信・server性能と堅牢性 | なし | 不要 |
| 5 | U-01〜U-04 | 誤表示の修正、診断の分離、macOSの取込表示 | なし | 不要 |
| 6 | D-01 | 自動保存を葉にし、昇格時だけ登録する | Decision・state-machine・fixture | **要** |
| 7 | U-05〜U-10 | 段階付き進捗・中止・再試行・事前取込 | 割合表示のみdownloadへ追加field | 一部要 |
| 8 | R-01〜R-08 | 構造整理 | なし | 不要 |
| 9 | D-02〜D-04 | shallow取込、端末の同期証跡の整理、server保持方針 | Decision・schema・fixture | **要** |

## 1. 正しさの不具合（優先）

### S-01 ★ 履歴4,096世代でpublishが恒久失敗する

- `SyncServerV2/src/postgres.rs:35` `MAX_LINEAGE_NODES = 4096`。`snapshot_is_ancestor`（`:2612-2672`）は目的の祖先を見つけても辿るのをやめず、深さ4096で親が残っていれば`over_budget`として`LineageViolation`を返す。parkedで再試行されない。
- 呼出しはpublishのexpected head検証（`:2801`）と、current/candidateの関係判定（`:2975, :2996, :3048`）。
- `path || parent`の配列を伸ばすため、1回の判定がO(S²)のコピーになる。
- 文書側は「100,000件の探索」と記載しており、値が一致しない（推測、要照合）。
- 対象作品は約1日で1,467世代（D-01）。同じ密度で書くと数日で到達しうる（推測）。
- **修正**：祖先が見つかった時点で打ち切る。path配列をやめる（登録時に親が既存でIDが親を含むhashなので循環は構造上作れない。必要なら登録時に`depth`列を持たせるmigration）。上限は文書と揃える。4,096世代超の直線履歴でpublishできるserver統合テストを追加する。
- client側に同種の上限がないかも確認する（`ProductionSyncV2RemoteClient+SnapshotGraph.swift:246-256`の一意object 100,000上限は別物）。

### C-01 ★ 初回取り込みの途中失敗で作品が開けなくなる

1. `stageRemoteGraph`が独立transactionで`works`行とbindingを作る（`NovelKit/Sources/NovelSyncV2Store/LocalSyncV2Store+Inbox.swift:22-37`）。
2. その後verify/adoptが失敗するか、プロセスが終了すると、generation 0・`current_snapshot_id` NULLの行が残る。
3. `store.open`はこの行に`document: nil`を正常に返す（`LocalSyncV2Store.swift:159-166`）。
4. `SyncV2Application.open`は`workNotFound`のときだけremote取込へ進む（`SyncV2Application+Library.swift:42-46`）ため、再取得しない。
5. iOSは`opened.document`がnilだと何も表示せずreturnする（`NovelAppIOS/DeviceSync/IOSDocumentStore+SnapshotSyncV2Open.swift:29`、`:109`）。棚では`.cached`として表示される。macOSは「取得が完了しました。一覧を更新してから…」と誤案内する（`NovelApp/Application/AppState+SnapshotSyncV2Library.swift:355-357`）。
6. account遷移でstaged/verified inboxが`rejected`になった場合も同じ行が残る（`LocalSyncV2Store+AccountTransitions.swift`付近、推測）。

serverのデータは無事で、原稿消失ではない。当初のiPhoneでの取得エラー後にこの状態へ入った可能性がある（推測）。

- **修正**：(a) 「generation 0・current nil・未adoptのinboxあり／なし」の行を、openLocalがremote-only扱いにして再取得へ進める。(b) 残ったinboxは再開するか破棄して作り直す。(c) 既に壊れた行を持つ端末の復旧経路を用意する。remote-only初回取込の単一transaction化（L-06）が入れば新規発生は止まる。

### C-02 取込の中断・二重実行

- download完了後は`installRemoteOnly`（`ProductionSyncV2Kernel.swift:409`付近）がcancelを確認せず、約21秒走り切る。破棄はStore側のtoken照合だけなので「作品は端末に入るが画面は開かない」になる（確定）。
- iOSは`snapshotSyncV2RemoteOnlyOpenTask = nil`を即座に入れるため、旧Taskが走っている間に次のopenを始められる（確定）。新規作成・.novelpkg取込ではcancelされず、完了時に黙って捨てる（確定）。
- 名前変更が`application.open`を直接呼ぶ（iOS `IOSDocumentStore+LibraryRename.swift:18-19`、macOS `AppState+LibraryRename.swift:18-19`）。iOSは取込中の行でも名前変更を押せる（`IOSLibraryViewV2.swift:84-85`）。2本目もstageまで進み、adoptのCASで失敗し、約19MBのinboxが二重に残る（確定。CAS失敗は推測）。
- **修正**：アプリ層に`remoteOnlyOpens: [WorkID: Task]`を置いて同じWorkIDを合流させ、名前変更もこれを通す。download後・stage/verify/adoptの各段の間で`checkCancellation`とscope世代を確認する。

### C-03 install時のaccount照合がない

- `beginAccountTransitionRemoteSuspension`（`SyncV2Application.swift:217-226`）は`workerTasks`しか止めず、remote-only openは対象外。`open()`は`remoteSchedulingSuspensions`も`historyScopeGeneration`も見ない。
- `ProductionSyncV2Kernel.swift:412`はinstall開始時点の`activeBinding()`を使い、download時のsessionと照合しない。download完了からinstall開始の間にvaultが別accountへ替わると、A口座の作品をB口座に束縛してstageしうる（推測、窓は極めて狭い）。
- **修正**：`SyncV2RemoteInbox`にbindingを持たせ、installで一致を確認する。suspension中はremote経路を拒否する。

### C-04 iOSのbackground保護がない

- `beginBackgroundTask`はflush（`IOSBackgroundTaskController.swift:63-80`）でしか使わない。取込は保護されず、stageまでは全てメモリ上なので、終了すると最初からやり直し（確定）。
- **修正**：取込Taskを`IOSBackgroundTaskLease`で包み、期限切れ時はcancelする。UIで「アプリを閉じると中断します」を示す（U-07）。

### S-02 共有blobの削除とuploadの競合

- uploadが完了してもfinalize前は`account_objects`行がない。その間に別accountの作品削除・purgeが`DELETE global_blobs WHERE NOT EXISTS(account_objects)`（`work_deletion.rs:108`、`account_deletion.rs:169`）を実行すると共有blobが消え、finalizeが404でparkedになる（確定。頻度は推測）。
- **修正**：GCで`upload_capabilities`のuploaded/finalizedも参照扱いにする。

## 2. ローカル取込と自動保存の性能（契約変更なし）

測定のstage 5.3s / verify 6.8s / adopt 8.8sは、unique bytes（19MB）ではなく「Σ全世代のentry数」「Σ各世代が参照するbytes」に比例する処理を3段階で繰り返していることが主因と見る（推測）。まず既存DBで`SELECT COUNT(*), SUM(byte_count) FROM inbox_closure WHERE inbox_id=?`とInstruments Time Profilerで裏を取る。

| ID | 内容 | 根拠 | 修正 | 効果（推測） |
| --- | --- | --- | --- | --- |
| L-01 ★ | snapshotごとに参照objectを`SELECT byte_count,bytes`で全バイト読み戻し比較。前世代で入れたものも毎回 | `LocalSyncV2Store+SQLite.swift:277-292` | transaction内で`Set<ObjectID>`を持ち、unique objectごとに1回だけ確認 | 数秒。**自動保存にも効く** |
| L-02 ★ | 挿入ごとに再帰CTEで全祖先を辿り循環を探す（1,467世代で約100万行）。IDが親を含むhashかつFKが即時なので原理的に見つからない | `LocalSyncV2Store+SQLite.swift:388-404` | 新規snapshotでは親の存在確認だけにする | 数秒。**自動保存にも効く**（`LocalSyncV2Store.swift:583`→`insertEncoded`） |
| L-03 | `SnapshotCodec.decode`（canonical parse、全objectのSHA-256、全entity検証、全体decode）を`validateGraph`が全snapshotに対し、stage・verify・adoptで計3回（client側graph構築を含め4回）実行。目的はanchor確認 | `LocalSyncV2Store+Inbox.swift:193`、`SnapshotCodec+Decoding.swift:31` | full validationはstageで1回。永続inboxからの再読込ではunique object/manifestの再hashと構造検証（親閉包・到達可能性）だけ行う。anchorは`work/document`のObjectID一致で確認しdecodeは1回。検証器versionをinboxに持たせ、不一致時だけ全検証 | 数秒〜10秒 |
| L-04 ★ | `exec`/`query`が毎回`sqlite3_prepare_v2`/`finalize`。合計でΣentriesの6〜7倍のprepare。`loadInboxGraph`はentryごとにJOIN query | `LocalSyncV2Store+SQLite.swift:505-537`、`+Inbox.swift:492-507` | prepared statement cache（reset/clear_bindings）。closureとobjectsを各1 queryで読みメモリで結合 | 数秒 |
| L-05 | 挿入直後の親・entryの読み戻し（`attestEncodedRows`）。`ISO8601DateFormatter`の都度生成、`Data(hex:)`の部分文字列確保 | `+SQLite.swift:347, 489, 680-705`、`SnapshotCodec+ModelDecoding.swift:206-215` | 新規挿入時は読み戻さない。formatterを静的化。IDをbytesのまま保持 | 1秒前後 |
| L-06 | remote-only初回（generation 0・current nil・editorなし・conflictなし）を1本の`BEGIN IMMEDIATE`にまとめる | `docs/sync/v2/download.md:37,46`が通常のstage/verify/adoptと永続inboxの再検証を明記 | 専用store API。C-01の新規発生も止まる | 契約文の更新が必要 |
| L-07 | adoptが書込lockを約9秒保持。`busy_timeout`は5秒。macOSで編集中の作品のcheckpointが待たされる | `+SQLite.swift:21`、Kernel→`store.checkpoint` | L-01〜L-04で短縮。必要なら段階間でyield | 保存遅延の解消 |

## 3. 取得の性能と堅牢性（client）

| ID | 内容 | 根拠 | 修正 |
| --- | --- | --- | --- |
| F-01 ★ | ページ全体（最大24MiB）を`CanonicalJSON.validate`と`JSONSerialization`で2回parse。manifestごとにもcanonical parseと`JSONDecoder`の2回 | `ProductionSyncV2RemoteClient+DownloadPages.swift:88-92`、`SnapshotValidation.swift:96-133` | 1回の正規化parse結果から取り出し、検証済みの値の木からmanifestを組む |
| F-02 ★ | SHA-256を2回（`ObjectID(data:)`の後に`SnapshotID(data:)`/`ObjectID(data:)`） | `+DownloadPages.swift:108, 114, 121` | digestを1回計算し`rawValue`から作る |
| F-03 | base64をStringで`replacingOccurrences`5回・再encode・`String.count` | `+DownloadPages.swift:152-158`、`+SnapshotGraph.swift:282` | bytes単位の1パス厳密base64url decoder |
| F-04 | ページ取得とCPU処理が直列。256KiB超objectと旧serverへのfallbackも1件ずつ | `+DownloadPages.swift:26-57`、`+SnapshotGraph.swift:182-197` | ページN検証中にN+1を先取り。大きいobjectはTaskGroupで4〜6並列 |
| F-05 ★ | 再試行は最大3回、250ms/500ms固定・jitterなし・`Retry-After`無視。失敗すると取得済みページを捨ててページ1から | `+Download.swift:20-46` | 指数backoff＋jitterで窓を数十秒へ。取得済みページ／objectを保持してcursorから再開 |
| F-06 ★ | `timeoutInterval`の明示なし（idle 60秒、resource 7日の既定）。取込全体の期限もない。「数分待つ」と整合しうる（推測） | grepで該当なし | リクエストとresourceのtimeout、取込全体の期限を設定 |
| F-07 | download中にtokenが失効すると以後全リクエストが401→refresh→再送 | `+Catalog.swift:11` | refresh後のsessionを呼出し側へ返す |
| F-08 | graph全体・大きいobject（最大250MB）をメモリに一括保持 | `data(for:)` | 大きいobjectは`download(for:)`でファイル受け＋streaming hash（添付の多い作品のjetsam対策、推測） |
| F-09 | `ProductionSyncV2RemoteClient` actorが長い同期処理を中断点なしで実行し、他の同期・catalogを待たせる | actor | 重い検証を`nonisolated`へ |
| F-10 | 最初のページの404が「旧server」と「root不在」を区別できず、削除済み判定（`rejectKnownRemoteDeletion`）を通らない | `+DownloadPages.swift` | 区別するか、fallback後に削除判定を通す |

## 4. serverの性能・運用

| ID | 内容 | 根拠 | 修正 |
| --- | --- | --- | --- |
| S-03 ★ | download各ページで再帰CTEにより全祖先・全entryを展開してから`ORDER BY kind,id LIMIT 257`。全体でページ数×履歴量 | `snapshot_download.rs:139-158` | root単位の短TTL cache、または`depth`列で再帰をやめる |
| S-04 ★ | 1ページ最大256件を1件ずつ`fetch_optional`。object側は毎回works/deleted_worksのEXISTS | `snapshot_download.rs:173-185` | `= ANY($2)`で1ページ2クエリ |
| S-05 ★ | 圧縮なし（Cargo.toml・Caddyfileとも）。JSON内base64で約1.33倍 | — | Caddy `encode zstd gzip`。独自media type `application/vnd.fuminiwa.sync.v2+jcs`を対象に含める |
| S-06 | `missing_objects`が最大10万IDを1件ずつ。entriesのINSERTも逐次 | `http.rs:918`、`postgres.rs:2588` | `ANY`/`UNNEST`で一括 |
| S-07 | 1 objectにつきupload・finalize・read-back・registerで4回以上全バイト読込。register中はaccountロック保持 | `object_store.rs:37-47`、`postgres.rs:2344, 1873, 2397-2405` | hashはupload時1回、registerはbyte_countとaccount_objects確認に留める（不変条件のDecisionが要る） |
| S-08 | chunk uploadが`partial_bytes = partial_bytes || $3`でchunkごとにTOAST全体を書き直す | `upload_chunks.rs:104` | chunkを別行に保存し最後に1回結合（migration） |
| S-09 | pool `max_connections(10)`をsync・auth・workerで共有。acquire/statement/lock timeoutなし、download専用の同時実行制限なし、rate limitなし | `postgres.rs:451-452`、`main.rs:81-104` | timeout設定、download用semaphore、auth接続分離 |
| S-10 | 索引欠落：`account_objects(object_id)`、`snapshot_entries(account_id, object_id)`。GC時のFK確認・object GETが全表走査 | `migrations/0001_sync_v2.sql:54-110, 388-389` | migratorで追加し`expected_v2_database_objects`（`postgres.rs:108`）も更新 |
| S-11 | `SyncError::Database(_)`を全て503 retryableに写しログも出さない。恒久不具合がclientの無限再試行に見える。TraceLayer・メトリクスなし。RUST_LOG未設定でwarnが見えない可能性 | `http.rs:27-77`、`main.rs:14` | DBエラーのwarnログ、遅延ログ、RUST_LOG明示 |
| S-12 | GC対象外の孤立物：finalizeされなかったblob、`delete_work`がupload_capabilitiesを先に消すため漏れるobject、`uploaded`状態の期限切れ行 | `work_deletion.rs:23, 59-61`、`account_deletion.rs:162-170`、`upload_chunks.rs:124` | 掃除workerの追加 |
| S-13 | 重複排除のON CONFLICTと新規INSERTで書込時間が変わり、同じbytesを持つ者が他accountの保有をタイミングで推測しうる。本文は実害小、添付画像は現実的 | — | 推測。wireのDecisionが要る |
| S-14 | 「作品が存在し未削除」の判定が19か所に重複（http.rs 12か所）。`postgres.rs`が3,767行に責務混在 | — | 共通view／関数、commandごとのmodule分割 |

serverのテストはmerge DAG・256KiB超objectの除外・quarantine object・2MiB境界・4,096世代超を検証していない。

## 5. データモデル（「賢い設計か」への回答）

### 現状（確定、対象作品の実DB集計）

- manifestは作品全体の全entityを平らに並べた一覧で、snapshotごとに全量を持つ。1 entry約206B、平均27.3 entry・約6KB。履歴量はO(S×E)で、`snapshot_entries`も端末（`sqlite.sql:99`）とserver（`postgres.sql:90`）でS×E行に非正規化。
- objectはentity単位。本文は話1本まるごとで、1文字直しても話全体の新objectになる。
- 1,467 snapshotのうち自動保存1,465、移動時2。親2つの合流0の一直線。作成は2026-09-27 22:16Z〜09-28 22:52Z。
- manifest 8.7MB＋object 10.2MB。manifestが約46%を占める。
- ★自動保存のdebounceは2秒（`NovelApp/AppState.swift:195`、`NovelAppIOS/DocumentLifecycle/IOSDocumentStore.swift:232`）。★checkpointは親＝直前のcurrentとして新snapshotを作る（`LocalSyncV2Store.swift:194-202`）。★送信前に未登録の祖先をすべて親から順に登録する（`LocalSyncV2Store+Transfer.swift:44-90`、`state-machine.md:34`）。
- 端末DB 269MBのうち実データは約30MB。残りは`sealed_commands` 89MB、`remote_receipts` 34MB、`upload_transfers` 16MB、`inbox_objects` 16.7MB等の同期証跡で、いずれも削除経路がない。
- Plannerがsnapshotごとに全entryの`prepareObject`を封印・送信し（`ProductionSyncV2Planner.swift:207-219`）、serverに既にあるobjectも省かない。自動保存1回あたり約30往復（`prepareObject` 41,546件）。

### 契約との食い違い

★`docs/SNAPSHOT_SYNC_V2.md:102`は「Autosave produces dense local leaves from the stable checkpoint. Manual and lifecycle checkpoints promote a leaf」とする。実装は葉ではなく一本の鎖で、全自動保存がserverの不変履歴になっている。**これが初回取込の遅さ、S-01の上限到達、DB肥大、送信往復の共通の根本原因**。

### 端末が全履歴を必要とする箇所（確定）

| 用途 | 根拠 |
| --- | --- |
| `snapshot_parents`の親FK | `sqlite.sql:90-98` |
| Inbox取込の親存在確認、取得側の根までの走査、download契約の親閉包要求 | `LocalSyncV2Store+Inbox.swift:250-259`、`+SnapshotGraph.swift:61-120`、`download.md` |
| 競合の共通祖先検証 | `LocalSyncV2Store+ConflictLineage.swift:6-80` |
| publishの基準head探索 | `LocalSyncV2Store+PublishBase.swift:8-50` |
| 履歴からの復元 | `LocalSyncV2Store+ConflictRestore.swift:407` |

永続Undo・AI編集記録は別DBでsnapshot履歴に依存しない（`WritingSQLiteStore.swift:31-39`）。履歴一覧は端末とserverのページを合成済み（`SyncV2Application+History.swift:43-55`）。

### 既知手法との比較

| 手法 | この作品での効果 | コスト・互換性 | 判定 |
| --- | --- | --- | --- |
| 自動保存＝葉、publish＝昇格（D-01） | serverのSが10〜100分の1。manifest・行数・往復が比例して減る | manifest・wire・serverは不変。端末挙動とstate-machine改定、Decision、scenario fixture | **本命**。履歴粒度の判断が要る |
| shallow／partial clone（D-02） | 初回openが作品サイズ程度 | 端末schema（境界表・FK緩和）、Inbox・競合・PublishBaseの不足時の扱い、download契約改定 | 有効。D-01の後 |
| 木構造manifest（Merkle） | E=27では小さい。数百話で1/10以下 | schemaVersion 3、Swift/Rust/Python適合 | 大型作品で測定後 |
| packfile・delta | 通信は大きく減るが、現ボトルネックは端末処理 | 高い | まずS-05のHTTP圧縮 |
| server側squash・GC | 保存量は減る | IDが親を含むhashなのでgraft相当が要る | 速度目的の削除は境界違反。保持方針として別途 |
| CRDT／op-log | 不適 | 打鍵単位で履歴が増え、明示3択競合・EditorKit/IME境界・digest検証と衝突 | 採らない |
| 内容定義チャンク | 平均7KBの話では利得なし | payload契約変更 | 長編・添付で再検討 |

### 設計判断が必要な項目

- **D-01 自動保存を葉にする**：自動保存は安定checkpointからの葉として端末内に置き、移動・lifecycle・明示同期・一定時間の待機など公開時点だけを昇格・登録する。葉の親は確認済みheadの子孫なのでCAS・競合基準は保たれる。既存履歴は消さない。**判断点**：別端末から見える履歴の粒度が2秒単位から公開時点単位になる。
- **D-02 shallow初回取込**：headのmanifestとobjectだけ取り込んで編集を開き、残りを再開可能なcursorで後から取得する。未取得履歴は「オンラインで取得」と表示。競合の祖先判定はserverのCASを正とし、端末は確認済みheadの存在だけを要件にする。取得中のaccount切替・削除・head更新で失効させる。新Decision、端末DDL migration、download.md改定、fixtureが要る。serverには「head＋必要objectだけ」の経路と新しい順のbackfill（`(depth,id)` cursor、新しいcursor型）が必要。現行download契約の並び順`(kind,id)`固定とclientのページ順序検証（`+DownloadPages.swift:40-43`）が障害。
- **D-03 端末の同期証跡**：完了済みcommandの生bytes、採用済みinboxの重複bytesを整理する（digestと受領要約は保持）。`sqlite.sql`変更。WALの`journal_size_limit`も設定。
- **D-04 serverの保持方針**：旧snapshot・history・receipts・sealed_commands（canonical_request最大32MB）の保持。日次pg_dumpを1年保持しているため増加がそのまま効く（`ACCOUNT_RETENTION_OPERATIONS.md:13-17`）。保管画面の「7日＋日次」表示（`protection_http.rs:106`）と揃える。

契約変更なしで先にできるもの：S-01、prepare済み・server既知objectの`prepareObject`省略（registerでserverが閉包を検証するので安全と推測。wire本文に禁止規定は見当たらない）、L-01〜L-05。

## 6. クライアント構造

package単位の依存は健全で循環はない（`NovelKit/Package.swift`）。スパゲッティ化しているのは次の3か所。

```
NovelCore ← NovelSyncV2（canonical JSON / SealedCommand / Snapshot検証） ← PortableBridge
              ↑                                   ↑
          Store（actor LocalSyncV2Store）     Application（actor SyncV2Application、protocol群）
              ↑                                   ↑
              └── Runtime（ProductionKernel / Planner / RemoteClient / Gate / 組み立て）
                     ↑
        macOS AppState+SnapshotSyncV2*（約2.9k行）／iOS IOSDocumentStore+SnapshotSyncV2*（約2.8k行）
```

- **暗黙の状態機械**：`SyncV2Application.swift:25-58`にWorkIDキーの並行コレクションが14個。iOSの認証切替は4変数と導出bool 2つ（`IOSDocumentStore.swift:381-391`、`+State.swift:8-17`）。
- **状態の正本が複数**：表示用`states`がretry判定（`+Retry.swift:17`）、自動確認（`+AutomaticSync.swift:55`）、gate tokenの期待版（`+Adoption.swift:16-18`）に使われる。app側にもコピー（macOS `AppState.swift:110-120, 160-170`、iOS `IOSDocumentStore.swift:259-304`）。iOS独自の`IOSSnapshotSyncOutcome`（`+SnapshotSyncV2Core.swift:21`）はui-state.mdの「別の状態を作らない」に反する。
- **wire解析の重複**：receipt envelopeをStore（`CommandReceiptDecoder.swift:17-40`）とRuntime（`+Receipt.swift:41-66`）で別実装。command payloadをApplication（`+Worker.swift:243-295`）・Planner（`:686-704`）・RemoteClient（`+SnapshotGraph.swift:269`）で個別に`JSONSerialization`。`commandKind: String`の比較が約55か所。
- **責務の漏れ**：Kernelがremoteを保持し5種のreadを中継（`ProductionSyncV2Kernel.swift:9, 453-476`）、Applicationからremoteへの経路が2本。HTTP clientが具体的Storeに依存（`ProductionSyncV2RemoteClient.swift:214`）。AI執筆記録の同期が同じactorに同居。
- **独立したループ**：作品ごとのworker、retry timer、前面作品のhead polling（10秒、失敗時60秒固定）、app側のadoption待ちpolling（macOS 200ms×150、iOS 50ms×600。毎回SQLite読込）、削除Task、AIの`WritingSyncPulse`。単一coordinatorなし。iOSは10秒ごとに`resumePending`まで走査、macOSは再表示だけ。`stateChanges()`はmacOSだけが購読。
- **Mac/iOS重複**：account scope照合guardがiOS 82回・macOS 66回。gateが2実装（`MacSyncV2DocumentGate.swift`、`ProductionDocumentGate.swift`）。gate証明の`hasMarkedText: false`が定数。
- **テスト**：protocolの既定実装が黙って例外を投げ、実装漏れがcompileを通る（`ApplicationProtocols.swift:93-121, 192-219`）。worker競合とretryのテストは本番と別のInMemory kernel（719行）。時計を差し替えられない。app側約5.7k行はapp上のテストのみ。空の`NovelKit/Tests/NovelLocalStoreTests`。

### 整理案（価値／リスク順、段階的置換）

| ID | 内容 | 規模 | 保つ境界 |
| --- | --- | --- | --- |
| R-01 | `SyncV2CommandKind`列挙とpayload accessorを`NovelSyncV2`へ。4か所のJSONSerializationと約55か所の文字列比較を置換 | S | wire不変、NovelCore依存ゼロ |
| R-02 | receipt検証を`NovelSyncV2`の純関数1つに集約 | S | 外部仕様不変 |
| R-03 | 作品ごとの状態を`WorkLane`構造体に集約。retry・自動確認は`lane.lastFailure`、gate期待版はkernelの永続版から。`states`は表示専用に | M | SQLite確定→worker再開 |
| R-04 | `stateChanges`を`(WorkID, SyncUIState)`とadoption可能イベントのpush型にし、2つのpollingを廃止。iOSも購読 | M | IME確定→保存→install、世代チェック |
| R-05 | Mac/iOS共有の`SyncSessionController`。`OperationContext{workID, session, account, editGeneration}.isCurrent`を1つにし、remote-only open・reprojection・認証切替leaseを持つ。gateを統一、`IOSSnapshotSyncOutcome`廃止 | M | 古い完了を別作品へ適用しない |
| R-06 | 起動・前面化・network復帰を`wake(reason:)`に集約、自動pollingの所有をApplicationへ | S | networkを保存条件にしない |
| R-07 | Kernelからremote中継を外し、`LibraryProvider`を`library()`だけに。RemoteClientには読取専用`SnapshotCache` protocolを注入 | M | Storeを通常保存の内側に閉じる |
| R-08 | Storeを共有connection／transaction実行部の上でOutbox/Inbox/Conflict/Account/Deletionのrepositoryに分割し、行読取を型付きに（`row[n]`がCommandValidationだけで35か所） | L | checkpointの1 transaction確定。L-xxと同時に |


### 構造整理の実装状況（2026-10-02、pass B）

初回レビューの根拠は上記のまま残す。以下は現在のソースの実装状況であり、実機受入の完了を意味しない。

| ID | 状態 | 現在の責務・残り |
| --- | --- | --- |
| R-01 | done（pass A） | `SyncV2CommandKind`とpayload accessorを共有。wire/fixture/schemaは変更なし |
| R-02 | done（pass A） | 共有receipt validatorをStore/Runtimeから使用 |
| R-03 | done | `WorkLane`に作品別のtask/owner、retry、wake、session、取込・backfill状態を集約。worker/retry/promotionは所有者付き状態。制御はlane、`states`はUIへの投影のみ。gate期待版はkernelの永続generation/current snapshotから取得 |
| R-04 | done | WorkID付きstate変更とadoption可能イベントをpush。作品別購読で別作品の通知による取りこぼしを避け、Mac/iOSのadoption待ちを30秒の明示deadline付き購読へ変更。iOSのrootも継続購読。通知からのinstallは従来のIME・保存・document gateを通す |
| R-05 | done（gateは意味差を保持） | 共有`SyncSessionController`が`OperationContext.isCurrent`、open/prefetch/reprojectionの所有権、認証leaseとscope照合を担当。iOS独自outcome enumを共有typed resultへ置換。両gateには実際のmarked-text状態を渡す。下記の意味差があるためgate本体は統合しない |
| R-06 | done（pass A） | `wake(reason:)`とApplication所有のforeground確認を使用 |
| R-07 | done | remote readは`SyncV2RemoteReads`へ直接接続し、Kernelの5つの中継を削除。`LibraryProvider`は`library()`のみ。HTTP clientは読取専用`SnapshotCache`と別の`HistoryBackfillPersistence`を受け取り、具体的Storeを保持しない。backfillのpage/cursor transactionは維持 |
| R-08 | done（pass A / B） | pass Aの型付きrowを維持し、pass Bで内部Outbox / Inbox / Conflict / Account / Deletion / Work repositoryへ分割。公開actorは`LocalSyncV2Store`のまま。全repositoryが単一`SQLiteExecutor`を共有し、checkpoint・install/adopt・acknowledgement・account transition・deletionのtransaction開始はStoreが所有。SQL・schema/migration・wire/receiptは変更なし |

**R-08の境界**：Storeは公開APIとtransactionの調整を担当し、repositoryはactor・connectionを追加しない。`SQLiteExecutor.swift`がconnection、statement cache、query/exec/changes、既存の`BEGIN IMMEDIATE`→COMMIT/ROLLBACKを所有する。ネストは従来どおりBEGINで失敗し、rollback失敗も隠さない。schemaの移行判断と順序は`Schema.swift`に残し、CSQLite呼出しだけを`SQLiteExecutor+Schema.swift`へ移した。削除のFK順序・trigger復元とaccount退役の複数table更新は、順序を保ったhelperとして残す。repositoryのtransaction helperはStoreの開いたtransactionを使い、単独更新の既存autocommitを変えない。

**R-08の検証（ローカルCLI）**：repositoryごとのStoreテスト137件に加え、共有rollback・ネスト拒否の2件を追加し最終139件成功。Applicationは179件中178件成功、空Keychainの1件が`.status(-50)`で失敗し、pass Aでも同じ失敗を確認した。公開メソッド署名105個、transaction開始箇所41個、SQLを含む文字列リテラルの比較は一致。SwiftFormat・D-076・D-090は成功、SwiftLintは同じ規則で109件→66件の未解消指摘。`check.sh`はSwiftマクロ実行のsandbox制限で停止したため、全検証・iOS build・実機受入の完了は主張しない。

R-08でStoreが保持する複数repository／複数tableのtransaction境界（helper経由を含む）：

| 操作 | Store側の入口・transaction所有者 |
| --- | --- |
| ローカル確定・複製 | `bootstrap`、`checkpoint`→`commitCheckpointTransaction` / `commitNoChangeCheckpoint`、`prepareExplicitAccountClone`、`promoteCurrentLeaf` |
| remote取込・adoption | `stageRemote` / `stageRemoteGraph`→`stageValidatedGraph`、`installInitialGraph` / `installShallowHead`→`installPreparedGraph`、`adoptInbox`、`adoptPendingServerResolution`、`adoptInboxSubsumingPendingIntent`、`adoptPendingFastForward`、`resumeBackfill`、`applyBackfillPage` |
| Outbox・receipt・復旧 | `seal`→`persistSealedCommand`、`acknowledge`、`retryUnacknowledgedCommands`、`requestSynchronization`、`requestAutomaticSynchronization`、`replanRejectedPublish`、`persistUploadTransfer`、`quarantineUpload` |
| 競合・restore | `appendConflict`、`appendConflictFromVerifiedInbox`、`prepareUseDevice`、`prepareKeepBoth`→`persistKeepBothReservation`、`prepareRestore`→`persistRestore` / `persistLocalRestore` |
| account・削除 | `rebindWork`、`transitionAccountScopes`、`parkWork`、`prepareWorkDeletion`、`completeWorkDeletion` |
| 明示import | `commitMigration`、`quarantineMigration`。ledgerの発見・backup・stage・verifyも従来の個別transactionを維持 |

`appendConflict`のstage→verify→appendや、`prepareKeepBothResolution`の予約確定後のintent作成など、元から別段階だったtransaction／autocommitは統合しない。事前検証をtransaction内へ移す変更も行わない。

**保持したplatform差**：Mac gateは1つのarmed boundaryを持ち、明示disarmと検証失敗でもarmを解除する。Production gateはWorkIDごとのarmを持ち、token消費時にarm存在を条件にせず、失敗時のarm保持も異なる。これを同一化すると拒否・再試行の挙動が変わるため両実装を維持する。またremote-only取消はMacが即時所有権解除、iOSが非協調taskの終了待ちという既存の差を、共有controllerの明示policyとして残した。account tokenの比較項目も各platformの既存型を維持する。

## 7. UI

### 現状の問題

**誤り（確定）**

- ★macOS：`.failed(.remoteWorkDeleted)`のアイコン名に日本語文言が入り記号が出ない（`NovelApp/Application/LibraryPane.swift:270`）。`server.rack.and.arrow.down`の実在も要確認（`:277`）。
- iOS：unboundで未送信なしの作品が`.idle`＝「同期済み」と出る（`ProductionSyncV2Kernel.swift:646`、`UIState.swift:29`）。STYLE §6・TOOLBAR:16に反する。
- iOS：未取得の作品に「同期済み」と出る（`IOSDocumentStore+LibraryV2.swift:354-360`の既定`.idle`）。
- ★iOS：棚がWorkID（UUID）順（`IOSDocumentStore+LibraryV2.swift:363`）。macOSは題名順。
- macOS：取込中の表示がない。`startRemoteOnlyOpen`が受付時点でtrueを返し（`AppState+SnapshotSyncV2Library.swift:231-232, 383`）、`LibraryPane.open`が一覧windowを閉じてWorkbenchを開く（`LibraryPane.swift:227-230`）。Workbenchは「作品を選択してください」（`ContentView.swift:85-89`）のまま数十秒〜数分変化しない。task/tokenが`@ObservationIgnored`。TOOLBAR:75「成功したら一覧windowを閉じ」に反する。

**多すぎる**

- DEBUGビルドでalert末尾に`stage=remote-only-download; type=NovelSyncV2.SyncV2Failure; case=…`（`IOSDocumentStore+SnapshotSyncV2Open.swift:129-138`、`SyncV2Application+Diagnostics.swift:27-33`）。Xcodeから実機へ入れたビルドでは利用者に見える。
- `localizedDescription`の生文。「サーバー一覧: …SyncV2Failure エラー0」のような表示（`IOSLibraryViewV2.swift:109-113`、`+LibraryV2.swift:223`、`IOSRootView.swift:65`、`LifecycleV2.swift:45, 238, 240`）。
- iOS行で「サーバーのみ」と「サーバーからこの端末へ取り込み」が同義で2行。
- 「.novelpkg を取り込む」（`IOSLibraryViewV2.swift:117`）。STYLE §1の「作品を取り込む…」に合わない。

**少なすぎる**

- 段階（受信／確認／保存）・量・残り時間がない。iOSは不定スピナー「作品を取り込み中…」だけ（`IOSLibraryViewV2.swift:54-56`）。
- 中止がない。iOSで端末内の作品を開くと確認なしに取込が破棄される（`SnapshotSyncV2Open.swift:14`）。macOSも別の行のopenで黙って中止（`AppState+SnapshotSyncV2Library.swift:229`）。
- 取込中は他のremote-only行も理由表示なしでdisabled（`IOSLibraryViewV2.swift:84-85`）。
- 失敗が行に残らず、行内の再試行もない。macOSは種類を問わず1文（`:381`）、一覧取得の失敗は無言（`LibraryPane.swift:173-180`）。
- offlineの全体表示がない。空の棚が読込中・offline・本当に空を区別しない（STYLE §5）。
- 用語がばらばら（未ダウンロード／サーバーのみ／取り込み）。STYLE §6は「未取得」。
- 完了すると利用者の操作と無関係に作品ホームへ自動遷移（`IOSWorkbenchViewV2.swift:455-460`）。
- 進捗にaccessibilityLabel/Valueがなく、完了・失敗のannouncementもない。disabledの理由とhintがない。macOSの状態アイコンにラベルがない。
- `LibraryWindowView.swift:13`の`.font(.system(size: 48))`はSTYLE §3違反（範囲外の指摘）。

### 改善案

| ID | 内容 | 下層に必要なもの | 契約影響 |
| --- | --- | --- | --- |
| U-01 | 誤表示の修正：macOSアイコン、unboundは「この端末のみ」、`.idle`を「同期済み」と出すのはboundかつhead確認済みのときだけ、未取得は「未取得」 | 既存のavailability/accountState | なし |
| U-02 | 行を「タイトル／状態1行」に。未取得は`arrow.down.circle`＋「未取得」。文言生成を`NovelSyncV2Application`で共有し両OSで同じに。並び順を両OSで揃える | 同上 | なし |
| U-03 | DEBUG診断・`localizedDescription`をalertから外し、ログか「詳細」へ。`SyncV2Failure`を種別で保持し`remoteOnlyOpenErrorMessage`を両OSで使う | 種別の保持 | なし |
| U-04 | macOS：取込中のWorkIDをobservableにし行に進捗を出す。window切替は取込完了後 | 同上 | なし |
| U-05 | 段階付き進捗：「サーバーから受信中 8.2 / 19 MB」→「内容を確認中…」→「この端末に保存中…」→「開いています…」。内部語（snapshot・manifest）は出さない | `open`/`downloadRemoteOnly`/`installRemoteOnly`に`AsyncStream<ImportPhase>`等。受信量はclientで計算可。保存段階は版数Nに対する処理済み件数で% | **割合（総byte・総件数）はdownloadの初回ページに追加fieldが要る**（additive、Decision・schema・fixture） |
| U-06 | 15秒ほど経過したら「履歴が多い作品は数分かかることがあります。ほかの作品はこのまま使えます。」 | なし | なし |
| U-07 | 中止と継続：行のボタン／context menuで「取り込みを中止」。別作品を開くときは「取り込みを中止して開きますか？」。完了時に自動遷移せず「『題名』をこの端末に取り込みました」と通知して棚を更新。iOSでは「アプリを閉じると中断します」 | 中止の安全性（C-01・C-02）、background lease（C-04） | なし |
| U-08 | 失敗を行内に残す：「取り込めませんでした・通信が途切れました」＋[再試行]。alertは補助 | WorkIDごとの最後の失敗種別 | なし |
| U-09 | offlineと一覧エラー：棚上部に「オフライン・未取得の作品は接続後に取り込めます」。空状態は`ContentUnavailableView`で未取得／読込中／offlineを分ける | 一覧取得失敗の種別保持 | なし |
| U-10 | 事前取込：context menu「この端末に取り込む」（開かずに取得のみ）。必要ならcatalogに概算容量「約19 MB」 | `prefetch(workID:)`（openのdownload＋installを切り出し）。容量はcatalogへのfield追加 | 容量表示のみ要 |
| U-11 | accessibility：進捗のlabel/value（「取り込み中、40パーセント」）、完了・失敗の`UIAccessibility.post(.announcement)`、disabledの理由hint、macOSアイコンのラベル | U-05 | なし |

事前取込（U-10）は、C-02の合流・C-03の照合・C-01の中途状態・L-07のlock時間を先に直してから入れる。通信量・Wi-Fi条件などの自動取込は製品判断。

## 利用者の判断が必要な点

1. **D-01**：別端末から見える履歴を、2秒ごとの自動保存単位から、移動・明示同期・一定時間の待機などの公開時点単位にしてよいか。文書の記述とは一致する。
2. **D-02**：最新本文だけ先に開き、履歴は後から取得する方式を採るか。D-01の後の着手を推奨。
3. **U-05**：進捗を割合で出すため、downloadの初回ページに総量fieldを追加してよいか（追加のみで互換）。
4. **D-03・D-04**：端末の同期証跡とserverの旧履歴・受付記録の保持期間。
5. **U-10**：開かずに取り込む操作を出すか。自動の事前取込をするなら条件（Wi-Fiのみ等）。

## 判断結果（2026-10-01、利用者）

| 項目 | 結果 |
| --- | --- |
| D-01 自動保存を葉にし、公開時点だけ登録 | 採用 |
| D-02 最新本文を先に開き、履歴を後から取得 | 採用（D-01の後） |
| U-05 downloadの初回ページへ総量fieldを追加 | 採用 |
| D-03・D-04 同期証跡・旧履歴の整理 | **採用しない。可能な限り保持する**。容量削減を目的とした削除・刈込みを行わない。S-12の孤立物掃除も保留 |
| U-10 開かずに取り込む操作 | 採用（手動操作。自動の事前取込は行わない） |

それ以外の着手順・修正内容はレビュー側が決め、実装はCodexへ委譲する。
