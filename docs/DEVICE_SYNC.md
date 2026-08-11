# FUMINIWA Device Sync 契約

> **状態**: D-063のMac iCloud作品catalog、remote WorkSnapshot bootstrap、app-private work registry、新規／取込／identity不変のpackage書出を含む作品全体local-first同期はsource complete／local automated GOである。最終source freezeは`NovelSync` 142 / 142件（14 suites）、`NovelSyncCloudKit` 71 / 71件（19 suites）、FUMINIWA macOS xcresult device cases 208 / 208件、iOS 137 / 137件、Experimental 205 / 205件、freshな`./Scripts/check.sh`の`All checks passed`、実Mac AppのComputer Use visual／Accessibility tree PASSを通過し、安全再監査はP0／P1なしである。D-059〜D-061の既存件数は各段階の別履歴として維持する。paired native Mac↔iPhone、実account／account switch、手動VoiceOver、実OS process-kill campaign、署名済み実CloudKit、Package Validator、External Change / Conflict、production migration／minimum-version fenceはRelease NO-GOのままである
>
> **対象**: macOS 14以降、iOS / iPadOS 17以降。将来のWindows / Android実装を妨げない
>
> **正とする上位契約**: [DESIGN.md](DESIGN.md)、[DECISIONS.md](DECISIONS.md) D-059〜D-063、[IOS.md](IOS.md)、[CROSS_PLATFORM.md](CROSS_PLATFORM.md)

## 0. D-061／D-063の現行whole-work／cloud library契約

D-061以降、通常のMac／iOS Appが使うDevice Syncの単位はEpisode本文ではなく、`NovelDocument`全体のcanonical `WorkSnapshot`である。D-063はこのheadをMacのcloud libraryから列挙し、別端末へWorkSnapshotだけを初回materializeするcatalog／bootstrapを追加する。以下をcurrent contractとし、後続の1〜15章はD-059／D-060話本文trackの実装・検証履歴として残す。

### 0.1 同期対象と非対象

Work snapshot v1は、stable IDと表示順を分離して次を同期する。

- 作品タイトル、あらすじ
- 章のID／タイトル／順序
- 話のID／所属章／タイトル／順序／本文／話メモ
- 登場人物の順序と全プロフィールfield
- プロットカードの順序／内容／章参照
- 伏線の順序／内容／未回収・回収状態／章参照
- 世界観ノートの順序／タイトル／本文

次はWork snapshot v1へ含めない。

- attachment／資料binaryとその転送
- `.novelpkg`のsnapshot履歴
- アプリ外観、本文フォント等の端末設定、選択状態、window／navigation状態
- local path、bookmark、端末名、利用者名、CloudKit metadata
- cloud catalog projection／cache、account scope、binding、pending open、local work registry（これらはWorkSnapshotではなくpackage外metadataとしてD-063が扱う）
- 複数人のリアルタイム共同編集、共同cursor、逐次keystroke配信

`.novelpkg`は引き続きportable／local materialized snapshotで、v3 schemaを変更しない。D-063のremote bootstrapが取得するのも上記WorkSnapshotだけであり、資料、snapshot履歴、非hidden未知root item、端末設定を「同期済み」または「iCloudから復元済み」と表示しない。

### 0.2 local durabilityと再接続

利用者の確定変更は次の順に処理する。

1. native editor／formの確定値を`NovelDocument`へ反映する。
2. exact `WorkSnapshot`をpackage外Work journalへstaged revisionとしてatomic保存する。
3. 既存の保存直列化経路でapp-private `.novelpkg`を保存する。
4. 保存したpackageから同じ`WorkSnapshot`を確認し、staged revisionをpublish可能なlocal headへexact confirmする。
5. remote fetch／publishを別taskへenqueueする。networkはEditor入力、package保存、journal confirmを待たせない。

stageはpackage commit前のwrite-ahead intentであり、confirm前にremoteへpublishしない。stageだけが残った再起動、packageだけが先行した再起動、pending remote materializationが残った再起動を区別する。stageに失敗してもpackage保存は止めず、次回preflightでpackageのexact snapshotを新しいlocal revisionとして回収する。package保存失敗時はstageをremoteへ昇格しない。

端末内mutationはFIFO laneで直列化し、fetch／upload等のnetwork I/Oはlane外で行う。response適用時にsealed mutation／revisionと現在のjournal observationを再検査し、一致しない古い結果を捨てて最新local tailを残す。active Work recordに`lastKnownRemoteHead`があるのにfetchしたcurrent remote headがnilなら、初回publishとして扱わずtyped `remoteHeadMissing`でpublish前に停止する。local head、outbox、last-known remote head、sealed publishをmemory／journalの両方で保持し、remote head復帰後は同じlocal revisionを再送する。通信不能、一時的CloudKit failure、別端末の更新中でもlocal編集を続け、再接続後に自動reconcileする。

### 0.3 Work wire v1とCloudKit CAS

`WorkSyncWireProtocol.currentVersion = 1`は、D-059／D-060のEpisode用`SyncWireProtocol` v1とは別namespace・別互換系列である。version番号が同じでも相互decode、混在運用、automatic migrationはしない。

Apple adapterは既存private database／単一固定custom zone内で、Episode recordとは別に次を使う。

| Record type | 役割 |
| --- | --- |
| `FUMINIWAWorkControlV1` | 現在head revision IDとsnapshot digestを1つのCAS対象として保持 |
| `FUMINIWAWorkRevisionV1` | canonical whole `WorkRevision`を`CKAsset`として保持するimmutable revision |
| `FUMINIWAWorkMutationReceiptV1` | mutation ID、command digest、result headを保持しresponse loss後のretryを冪等化 |

publishは`mutationID + expected head revision ID + expected head snapshot digest`を検査し、必要なimmutable revision、receipt、更新後controlをatomicに保存する。head IDまたはdigestが変わっていればwinnerを選ばずdivergenceとして再fetchする。時計、更新日時、push到着順によるlast-write-winsは禁止する。revision assetはread-back時にrecord metadata、byte count、digest、parent、work identityを検査してからdomainへ渡す。

### 0.4 whole-work 3-way mergeと3面review

共通祖先、local head、remote headのstable ID／field／順序を比較する。片側だけの変更、または互いに独立していると証明できる変更は自動統合する。同じ本文の離れた範囲、別entity、別fieldの変更も安全性を証明できる場合は一つのproposed snapshotへまとめる。

次は自動winnerを選ばずreviewへ送る。

- 同じfieldまたは本文範囲を両側が変更した場合
- 一方のdeleteに対して他方がedit、所属移動、または基準ID間の相対順を変更した場合
- 両側が同じ一覧順を異なる形へ変更した場合
- 同じstable IDを異なる内容で追加した場合
- 共通祖先を証明できない場合、またはresource budgetを超えた場合

review画面は **この端末／iCloud／統合案** の3面を同時に示し、「この端末を採用」「iCloudを採用」「統合案を採用」を提供する。完全なbase／local／remote／proposed snapshotはjournalへ保持し、field descriptorの短い表示だけを原文の代用にしない。「あとで」で閉じても消さない。

通常のcloud conflict中はEditorとlocal保存を止めない。追加編集は新しいlocal headとなり、remoteまたはlocalが進めば最新3面を再計算する。一方、再起動時にpackage、stage、pending remoteのどれが実際にmaterialize済みか一意に判断できないlocal recoveryは、推測で本文を選ばず、同じ比較UIで明示選択されるまで作品編集をgateする。

### 0.5 native editorへの反映境界

CloudKit fetch／push callback、SwiftUI update、古いasync completionからactiveな`NSTextView.string`／`UITextView.text`や現在の`NovelDocument`を直接置き換えない。remote fast-forward、自動merge、競合解決結果はまずjournalのpending materializationへ保存する。

作品／document session／Editor surface／世代、expected snapshot／本文digest、IME composition、selection、Undo／Redo、未保存・未journaled変更を確認し、local saveを完了した安全な遷移境界だけでpackageへmaterializeする。保存後にpackageを読み直してexact `WorkSnapshot`一致を確認した場合だけremote materializationをacknowledgeし、in-memory document／Editor generationを進める。条件を満たさない間はremote版をpendingに保ち、現在の入力を巻き戻さない。

### 0.6 resource上限

| 対象 | v1上限 | 超過時 |
| --- | ---: | --- |
| canonical `WorkSnapshot` | 48 MiB | snapshotを拒否。部分同期しない |
| snapshot内の各String | 1 MiB | 文字列を切り詰めず拒否 |
| canonical `WorkRevision` | 50 MiB | revisionを拒否 |
| `FileWorkSyncJournal` record | 320 MiB | 既存journalを保持してfail-closed |
| outbox revision | 3件 | whole snapshotを安全な共通base直下へcoalesceし、必要な親を落とさない |
| journal revision store | 5件 | 上限超過状態を保存しない |
| conflict descriptor | 512件 | 最終descriptorをbudget超過表示とし、完全な三者revisionは保持 |
| descriptor内の各比較値 | UTF-8 1 KiB | prefix＋SHA-256表示へbounded化。原文snapshotは保持 |

5 revision、完全なproposed snapshot、bounded conflictsを持つ到達可能な最大構成270,439,704 bytesを保存・再読込するnear-cap回帰が通過している。320 MiBはこの構成を欠落なく保持するfile record上限であり、remote payload上限や利用者作品の推奨sizeではない。

### 0.7 cutoverと検証境界

D-061は一般配布前のdevelopment cutoverである。D-059／D-060は署名済み実CloudKitへdeploy／一般出荷していない前提で、開発CloudKit同期dataをresetし、全test端末を同じD-061 buildへ更新して検証する。Episode record／journalをWork record／journalへ自動migrationせず、旧Episode-only clientとD-061 clientを同じ作品へ同時接続した場合の収束、安全な競合検出、相互運用を主張しない。production upgradeを行う場合はminimum client version fenceまたは明示migrationを別Decisionで実装・検証する。それまでは出荷不可である。

D-061のDomain、CloudKit codec／publish planner、Mac／iOS App、3面review UIはsource実装済みで、次のlocal／Simulator／署名なしbuildが通過した。D-059／D-060の件数は流用しない。

| 境界 | D-061結果 | 証明する範囲 |
| --- | ---: | --- |
| Work Domain focused | 44 / 44件（5 suites） | snapshot／revision／journal／FIFO coordinator／merge／resource cap |
| CloudKit schema focused | 3 / 3件 | full 59 / 59件の内数。Episodeとは別のWork record namespaceとschema定数 |
| `NovelSyncCloudKit` full | 59 / 59件（15 suites） | codec／asset／publish planner／receipt／local fake transport。実CloudKitではない |
| Mac `NovelAppDeviceSyncTests` | 64 / 64件（3 suites） | integration 57＋edit-intent 4＋root 3 |
| iOS focused | 56 / 56件 | integration 49＋3面review UI 7 |
| iOS build | generic build／build-for-testing PASS | compile、link、test bundle生成。署名済み実機ではない |

Work conflict UIは既存Mac focused coverageを含め最終source監査した。上記を次の未完了項目へ読み替えない。

- Developer Program上のcontainer／App ID／profileとdevelopment／production schema deploy
- 同じiCloud accountの署名済みMac＋iPhoneによるpaired native whole-work往復
- network pause／offline restart／再接続と、実OS process killの書込み境界campaign
- 手動VoiceOver／Dynamic Type／実機IMEを含むconflict／local recovery画面の受け入れ
- mixed old／new client移行とD-063 catalog／bootstrapのproduction移行

### 0.8 Work library catalogとidentity

D-063のlibraryはprivate CloudKit上のWork headと、端末内で検証済みのworking copy inventoryを`SyncWorkID`だけでmergeする。タイトル、`NovelDocument.id`、ordered structure digest、package basenameをdeduplicate／automatic binding／削除対象判定へ使わない。exportしたpackageを再importした場合も新しいWorkIDとし、同じdocument IDを持つ別workとして扱う。

remote catalog entryは少なくとも次をexactに持つ。

- `SyncWorkID`
- UTF-8 1 KiBまでのbounded title projection、完全タイトルのSHA-256 digest、完全タイトルのUTF-8 byte count
- current head revision ID、snapshot digest、canonical revision byte count
- source document IDとordered structure digest（表示／continuity検査用。identityではない）
- headの表示日時（並び順hint。CAS／winner決定には使わない）

headがnilのcontrolを別端末で開ける作品として列挙しない。title projectionはUnicode scalar／UTF-8境界を壊さずO(n)で作り、省略時はUIとVoiceOverの両方で「…」を伝える。remote cacheは最大1,088件（binding 1,024件＋unbound pending-open最大64件を覆う）のrecent entryにbounded化し、local-bound／pending workを優先する。refresh開始時や一時失敗時にcacheを空にしない。malformed remote controlは当該rowだけをquarantineし、valid remote rowとlocal inventoryまで巻き添えにしない。以前確認済みsame account scopeの一時offlineではcached remote-only行を残してdownloadだけを無効にする。

remote catalog titleはaccount-scoped情報である。`accountRequired`／unscoped、またはlive identityが前回と異なる場合はlocal packageのないremote-only rowとtitleを表示せずquarantineする。端末内packageから検証できたlocal titleはaccountに関係なく表示／openできるが、registryだけを新accountへのupload／binding authorityにしない。

### 0.9 app-private working copy inventory

Macのactive copyは信頼済みapp-private rootの`SyncWorkingCopies-v2/<SyncWorkID>.novelpkg`へ置き、通常UIにroot／full path／Finder入口を出さない。URLはregistryへ保存せずWorkIDから導出する。canonical local locatorもpath hashではなくWorkIDを使い、旧path-derived locatorはlegacy recovery以外でD-063 workへ使わない。diagnostic logへapp-private path／WorkIDを出さず、失敗はboundedなerror categoryだけで記録する。

registryは1 work 1 atomic recordとし、少なくともWorkID、package attestation、state、acknowledged remote head、pending remote headを持つ。新規／Importのreservationでは作成予定snapshotのexpected package attestationをstaging前に同recordへdurable化し、installed package未確定の間もこのexpected値を再開authorityにする。D-063以前の`reservedForPublish`でpackage／expected attestationがnilのlegacy recordは、document ID一致だけでstaging／finalを採用せずquarantineする。単一JSON全体の破損でlibraryを失う構成にせず、registry欠損時はdeterministicなpackage scanから保全する。壊れたrecord、unreadable package、unregistered／orphan packageはwork単位で隔離し、他workの一覧とopenを維持する。registryまたはpackageが曖昧な状態を`synced`へ推測昇格しない。

local saveではpackage read-back attestationをrecordへ反映し、以前`synced`でもlocal snapshotが変わればremote exact acknowledgementまで`publishPending`へ戻す。`needsReview`は通常保存でgeneric pendingへ降格させず、明示review完了まで保持する。exact remote receiptとpackage attestationが一致したときだけ`synced`へ進める。

### 0.10 new／import／remote openのtransaction

新規／取込のlocal reserve、private package install、registry確定はnetwork／live iCloud account確認を待たず、remote catalog refresh全体が失敗していても開始する。外部`.novelpkg`はsecurity／access scope中に読み、原本へ書き戻さない。Finder / Open Withもopen-in-placeではなくImportとして新しいWorkIDを作る。旧`~/Documents/FUMINIWA`、旧recent、export済みpackageを自動移動・削除・rekey／rebindしない。

以前exactに確認したaccount scopeがmetadataへ残り、その同一scopeのlookupだけが一時的に失敗している場合は、same-scope pending creation／bindingをremote mutationなしでdurable化できる。同じscopeの復旧後だけ自動再開する。`accountRequired`／unscopedで作ったworkは検証済みlocal packageを開いて編集できるが、binding／pending remote createを作らず、後から現れたaccountへautomatic adopt／rebind／uploadしない。明示的account association UI／authorityは後続Decisionまで持たない。first account bindingはremote mutationより前にdurable化する。

新規／取込のinstall順は次とする。

1. 作成予定`WorkSnapshot`からexpected package attestationを作り、WorkIDとregistry reservationへatomic保存する。
2. finalと同じprivate rootのdeterministic stagingへ完全packageを作る。importではsource treeをportable transfer境界で検証して複製する。
3. stagingのpackage tree、`NovelDocument`、`WorkSnapshot`、digest／byte countをread-backし、reservationのexpected attestationと一致させる。
4. finalが存在しないことを確認し、no-overwriteのatomic renameでinstallする。既存finalがある場合はexact prepared stateだけをresumeし、それ以外は置換しない。
5. package attestationをregistryへ確定する。live scope確認済みならdurableなpending creation／bindingを経由してremote処理を開始する。以前確認済みのsame scopeが一時offlineならsame-scope intent／bindingだけを耐久化してremote処理を保留する。unscopedならlocal-onlyのまま編集を解放し、将来accountへの自動associationを行わない。

sourceとstaging／finalのpathが重なる場合、symlink、resource cap、pre／post treeまたはlogical read-backで検出した内容不一致、document／snapshot不一致はfail-closedにする。staging read-backが一致しなければstaging／finalを残さず破棄し、durable reserveを正常なworking copyへ推測昇格せず、再起動後も採用しない。失敗時は外部原本、既存final、active document、old registry recordを変更しない。ただしこのportable transfer境界だけでcopy中のhard-link／外部process変更を完全に防ぐTOCTOU耐性は主張しない。より強いfile coordination／descriptor-relative I/Oと外部変更検出は、未完了のPackage Validator／External Change / Conflict Gateで扱う。

remote-only openはonlineかつlive account scope確認済みの場合だけ、次のcheckpointを使う。

1. 利用者が選んだWorkIDと表示時のexact catalog headを検証する。
2. pending-open intentをasset fetchより前にatomic保存する。
3. catalogを再取得し、head revision ID／snapshot digest／byte countが表示時と一致することを確認する。
4. full revision assetを取得し、work identity、parents、canonical byte count、digestを検査する。
5. D-061 `WorkSnapshot`だけをsame-root stagingへpackageとしてmaterializeし、portable package／snapshotのread-backを行う。
6. no-overwrite renameでfinalへinstallし、canonical WorkID locatorへbindしてremote bootstrap専用Work journalを作る。
7. package／journal／registryのexact一致後にpending-open intentを完了する。

各checkpointはprocess終了後に冪等resumeする。finalが存在してexact prepared headと一致する場合だけresumeし、別内容なら`needsReview`へquarantineして上書きしない。Domain bind完了後からregistryのsynced mark前に終了した場合は、exact package、pending remote projection、outbox-free journalが一致するときだけ当該WorkIDを`synced`へ復旧する。この判断はofflineかつremote catalogが0件でもlocal durable stateだけで行える。remote bootstrapからlocal-rootをbaseにした新しいoutboxを作らず、取得したremote revisionを既知のremote headとしてjournalへ導入する。

### 0.11 startup状態とProduct Truth

Mac startupは次を区別し、local durabilityとremote acknowledgementを1 badgeへ畳み込まない。

| 行状態 | 開ける条件 | 表示の意味 |
| --- | --- | --- |
| cached exact | local package attestationとaccount-scoped remote receipt／headが一致 | onlineでは「iCloudと同期済み」、offlineでは「このMacに保存済み、オフラインでも開けます」 |
| same-scope local pending | local packageは検証済み、以前確認済みaccount scopeのremoteは未確認 | onlineでは「このMacに保存済み、iCloudへ保存中」、一時offlineでは「接続後に同期」 |
| unscoped local-only | local packageは検証済み、account binding authorityなし | 「このMacにのみ保存済み」／「iCloudとは関連付けられていません」。後から現れたaccountへ自動uploadしない |
| account-quarantined local | local packageは検証済み、以前のaccount scopeと現在scopeが不一致 | 「このMacに保存済み、iCloudアカウントが異なります」。local open／編集は許可し、旧remote title／binding／pendingをquarantineしてuploadしない |
| remote-only | exact catalog headのみ | onlineでだけ「iCloudからダウンロード」。offline／account未確認では開かない |
| remote download pending | exact remote revisionがaccount-scoped hidden journalへ準備済み | 「このMacへの保存を再開」。同じaccount scopeとexact intentだけで再開。`accountRequired`／different accountでlocal packageがなければ行自体を棚から除外 |
| cloud unavailable | local packageと過去ackはexactだが、connection availableのcurrent catalogに当該WorkIDがない | `.cloudUnavailable`。「iCloud上の作品を確認できません」。checkmark／open／uploadを止め、local packageは保持 |
| needs review | packageは読めるがremote／registry／installが曖昧 | 「このMacに保存済み、統合が必要」。通常cloud reviewはlocal編集継続、materialization曖昧時はroot gate |
| unavailable | legacy nil reservation、head欠損、package／registry破損等 | 自動で開かず、原因に応じた設定確認／Recoveryを提示 |

`checkmark.icloud`と「iCloudと同期済み」はcached exactに限る。local registryの`pending`、network online、catalogに同名行があること、直前のupload開始だけでは表示しない。connection availableのcurrent catalogからacknowledged WorkIDが欠落した場合は`.cloudUnavailable`へ降格し、過去receiptだけでcheckmark／open／uploadを再開しない。`accountRequired`／different accountではlocal packageのないApp `remoteOpenPending` rowを棚から除外し、旧accountのwork存在／titleを漏らさない。状態は文字とVoiceOver valueで伝え、remote-only offline／破損へ「接続すれば必ず開ける」と誤解させるhintを出さない。account mismatchは検証済みlocal packageの有無を区別し、local packageを開ける場合もremote upload可能とは表示しない。MVPにwork delete UI／APIを置かず、CloudKit tombstone／retentionは別Decisionへ分離する。

### 0.12 portable package exportと同期外resource

利用者が`.novelpkg`を得る操作は「書き出す…」であり、active copyを別URLへ切り替えるSave Asではない。current sessionのnative editor／form、package、Work journalをflushした後、`PortableDocumentPackageRepository`（`DocumentCopyingRepository`を含む）でsource package全体を検証済みcopyし、destinationもread-backする。capabilityがなければ`DocumentRepository.save`へfallbackしない。成功／失敗のどちらでもactive `documentURL`、document session、recent、WorkID、binding、journal、selectionを変えない。

exportは **現在のMacのpackageに存在する** attachment、snapshot履歴、非hidden未知root itemを保持する。一方、D-063 remote bootstrapが取得するのはWorkSnapshotだけであり、別端末のattachment／snapshot／unknown rootは復元しない。そのため別端末で書き出したpackageにそれらがない場合がある。Device Syncをpackage全体mirror、完全backup、資料／snapshot復元、独自E2EEとして表示しない。

### 0.13 D-063 cutover、reset、Release Gate

D-063も一般配布前のdevelopment-only cutoverとする。実CloudKitへ未配布の前提でdevelopment custom zoneと旧local sync metadata／journal／registryをresetし、全test端末を同じD-063 buildへ更新する。ただし次のいずれかがある場合はblind resetしない。

- staged revision、outbox、pending materialization、pending create／bind／open
- unresolved cloud conflict／local recovery／`needsReview`
- exact inventory／registry再構築／検証済みExportのいずれでも保全できないhidden working copy

reset前にexact schema readerで全stateと全hidden working copyを列挙・attestする。pending／reviewを解決し、各hidden packageはregistryをexactに再構築／保全するか、検証済み`.novelpkg`としてExportして回収する。attachment／snapshot／unknown rootはremote WorkSnapshotから戻らないため、remote head一致だけでpackageを削除せず、hidden working-copy root自体をmetadata resetの削除対象にしない。未知version、不整合、未到達package、Export失敗が1件でもあればresetを停止し、古いreader／buildを保持する。旧visible packageは明示Import→new WorkIDとし、外部原本を残す。

D-063のsource freeze（2026-08-12）は次の層別証跡で固定する。

| 境界 | D-063結果 | 証明する範囲 |
| --- | ---: | --- |
| `NovelSync` | 142 / 142件（14 suites） | Work domain、library projection、local-first state／mergeのpure回帰。near-cap 270,439,704 bytesを含む |
| `NovelSyncCloudKit` | 71 / 71件（19 suites） | codec／planner／metadata／libraryのlocal fake回帰。malformed catalog rowだけを隔離する1件を追加。実CloudKitではない |
| FUMINIWA macOS full xcresult | device cases 208 / 208件 | top-level 203件。hosted 124件＋unhosted 79件、dynamic casesを含む。UI test分離後のhosted `NovelAppTests`は`NovelSyncTesting`非依存 |
| focused Cloud＋store | device cases 15件／top-level 14件 | reservation attestation、account quarantine、catalog／head消失時のfail-closedを含むfocused回帰 |
| hosted Startup Cloud UI | 1 / 1件 | Product Truthを含む起動chooserのhosted UI回帰 |
| iOS full | 137 / 137件 | App 79件＋Device Sync 58件。local／Simulator回帰でありpaired nativeではない |
| Experimental | 205 / 205件 | target分離を含む既存研究回帰。D-063や通常版provider capabilityを証明しない |
| local CI | fresh `./Scripts/check.sh`: `All checks passed` | repository全体のlocal automated gate |
| 実Mac App | Computer Use visual／Accessibility tree PASS | 現行chooserのvisual／AX受け入れ。手動VoiceOver campaignではない |

macOS Cloud／store回帰は、expected package attestationをreservation前にdurable化しlegacy package／expected attestation nilを隔離すること、bind完了→registry mark前のkillをoffline／remote catalog 0件からexact package＋journalで復旧すること、新規／Importのstaging read-back不一致を破棄して再起動後も採用しないこと、remote catalog全体の失敗中もlocal-only新規を保存できること、`accountRequired`／different accountでpackageのないApp `remoteOpenPending` rowを棚から除外すること、available catalogからacknowledged workが欠落した場合に`.cloudUnavailable`でcheckmark／open／uploadを止めること、malformed remote rowとdifferent-account remote-only row／titleをそれぞれ隔離すること、app-private WorkID／pathをdiagnostic logへ出さないことを固定した。Work domain回帰は、`lastKnownRemoteHead`があるactive WorkSyncでcurrent remote headがnilならtyped `remoteHeadMissing`でpublish前に停止し、local head／outbox／last-known／sealed publishを保持してremote復帰後に同じrevisionを再送することを固定した。安全再監査はP0／P1なしである。

このmatrixによりD-063をsource complete／local automated GOとする。次は引き続きRelease NO-GOである。

- Package Validator GateとExternal Change / Conflict Gate
- Developer Program上のcontainer／App ID／profile、development／production schema deploy
- 署名済みMac＋iPhoneの同一実accountによるpaired native catalog／bootstrap／whole-work往復
- offline remote-only、cached local offline edit、実account switch quarantine、write checkpointごとの実OS kill、手動VoiceOver／Full Keyboard Accessの受け入れ
- production data migrationまたはminimum client version fence

source、署名なしbuild、Simulator、local fakeの成功をreal CloudKit、完全backup、production migration、公開準備完了へ読み替えない。

## D-059／D-060話本文track（実装・検証履歴）

以下の1〜15章は、D-059／D-060で実装したEpisode本文revision／lease／journal v2の履歴である。D-061はそのtest件数や安全上の知見を削除しないが、現行通常Appの同期payload、CAS record、merge UIは上記whole-work契約へ置き換える。

## 1. 目的と安全境界

Device Syncは、Mac／iPhone、online／offline、remote holderを利用者に意識させず、同じ話を両端末で開いたままlocal-firstに編集し、remoteで安全に合意できる版だけを1端末ずつpublishする。

保存と同期の境界は次のとおり分離する。

- app-privateな`.novelpkg`は、各端末でdurableに保存する作業コピーであり、最新同期revisionをmaterializeしたportable snapshotでもある
- `.novelpkg`自体をiCloud DriveやFile Provider上でopen-in-placeにして同期しない。package内部のファイル単位競合をDevice Syncの競合解決に流用しない
- live syncは、`.novelpkg`とは別の **話単位revision protocol** で行う。共有head、lease、mutation、revision graphをrecordとして扱う
- 編集中本文の正は引き続きnative editorである。端末内保存の正はapp-private `.novelpkg`、端末間で合意した版の正はremote episode headであり、SwiftDataや一時的なView stateをcanonical sourceにしない
- 本文変更は **native editor → model → `.novelpkg` → package外journal → remote** の順に流す。CloudKit処理はEditor入力、package保存、journal保存を待たせず、通信成功をローカル保存の代用にしない
- remote writerはEpisodeIDごとに1端末だけとするが、これはremote headを直接進められるauthorityであり、local Editorへ入力できるかを表さない。同期設定、通信状態、別端末のholderだけを理由にEditorをread-onlyにしない
- `.novelpkg` v3 schemaはS1で変更しない。sync binding、lease、remote revision ID、device ID、journalをpackageへ保存しない

これにより、外部原本のopen-in-placeを除外したD-056 / D-057の境界を維持したまま、app-private作業コピー同士を同期する独立trackを追加する。

## 2. 現在の範囲

### 2.1 S1で扱うもの

- 初回binding時に構造が完全一致し、binding snapshotの対象EpisodeIDに含まれる **1話の本文**
- remote headを一度に1端末だけが進めるsoft lease、epoch、fencing、CAS
- Mac／iPhone双方で、holderやnetworkに依存しないlocal Editor入力とdetached local branch
- 本文変更を暗黙の編集意思とする通常claim／internal takeover。authority操作やforce／lease用語を通常UIへ出さない
- 通信不能のまま編集、終了、再起動、再編集できるpackage外journal
- base / local / remoteによる3-way merge、同一結果の自動collapse、非重複の2-parent自動merge、overlapだけの確認
- mutation retry、push欠落、process終了、通信失敗からの再開

### 2.2 S1で扱わないもの

- remote workを作品棚へ常時列挙するcloud library、別端末へのpackage初回download、import不要の作品bootstrap、複数作品のsync library
- 章／話の追加・削除・タイトル・順序、作品情報、メモ、人物、プロット、伏線、世界観、資料、snapshotの同期
- attachmentやpackage全体の転送
- Files / iCloud Drive / File Provider上の原本を直接編集するopen-in-place
- 複数人のlive collaboration、CRDT、逐次keystroke配信、共同cursor。複数端末のlocal編集は扱うがkeystrokeを相互配信する共同編集ではない
- Apple以外の実transport、CloudKit Web Services、自前server

S1の初回bindingは、利用者が同期先を明示選択し、作品全体のordered ChapterID / EpisodeID digestが一致した場合だけ成立する。その時点のEpisodeID集合をpackage外のbinding snapshotへ保存する。Apple adapterがremote descriptorを読むのは、構造digestが一致する **明示binding候補** の抽出と、既存bindingの検証のためである。この候補は作品棚、cloud library、package downloadではなく、選択だけで自動bindingもしない。binding後に章や話を追加してもsnapshot内の既存話は同期を継続する一方、新しい話はremote graphへ暗黙作成せず「この端末のみ」とする。対象外の構造を推測で作成・削除・並べ替えず、出荷UIへ「全作品を同期」「別端末から作品を取得」等を出さない。

### 2.3 実装状況（D-059基準とD-060を分離）

- **D-059基準でsource実装済み**: `NovelSync`のportable ID／wire／digest／structure descriptor、lease／publish／force／fence／fork／2-parent mergeの状態機械、保守的3-way merge、決定論的fakeとfixture
- **source実装済み**: package外の`FileEpisodeSyncJournal`、atomic outbox／recovery、本文・親・pending・journal全体のresource limit、unsafe root／symlink拒否
- **source実装済み**: `NovelSyncCloudKit`のprivate database／単一固定zone、record／`CKAsset` mapping、change-tag CAS、mutation receipt、`CKSyncEngine` change tracking、account fence、engine state recovery、local metadata bootstrap、durable pending create / bind intent、copy別journal、明示create／bind／rebind／unbindとepisode allowlist
- **D-059基準でApp source接続済み・全ローカル回帰通過**: Mac / iOSのproduction composition、明示binding UI、native editor／保存／scene・終了境界、read-only／force／fence／競合解決画面。2026-08-11の`Scripts/check.sh`でMac通常114件／Device Sync 20件、iOS通常71件／Device Sync 15件を含む全検査が`All checks passed`となり、基準commit `508947d2`へ固定した
- **D-060 Domain／Apple adapter source実装済み**: Device Sync wire protocol v1を維持したjournal schema v2／v1 migration、`LocalWorkingCopyID`、authority非依存`recordLocalEdit`、observed baseline、stable detached branch、offline復元、remote不変publish、同一結果collapse、bounded multi-hunk 3-way merge、2-parent自動merge、overlap review、upload tail、2段階の競合解決materialization、exact head／digest／epoch CAS takeoverを`NovelSync`へ実装した。`NovelSync` testは94 / 94件で、内訳としてlocal-first 33件、既存coordinator 18件が通過した。一時的CloudKit unavailableとaccount／設定blockを分離したApple adapterを含む`NovelSyncCloudKit` testは48 / 48件が通過した。いずれも署名済み実CloudKit検証ではない
- **D-060 App／UI source実装・ローカル回帰通過**: Mac／iOSにfull-body pre-package WAL、native→model→package→journal、remote nonblocking化、active editorへのremote非注入、上部状態記号、nonblocking reviewを接続した。Mac Device Syncは45 / 45件（3 suites、11.932秒）とprivate-root focused 1 / 1件、iOS Simulator Device Syncは42 / 42件（3 suites、20.544秒）が通過した。さらにiOS native focused 2 / 2件で、marked IME確定からmodel／package／journal／WAL cleanupまでと、別writer下の実`UITextView`によるreplace／delete／Undo／Redo／paste／ルビ／傍点およびlease不変を確認した
- **現行v1にないもの**: D-059で構想したcooperative request／flush／grantの`HandoffRequest` recordは実装しておらず、D-060の現行v1はlocal journal保存後にexact remote head／digest／epochを検査するinternal takeoverでauthorityを移す。cooperative request／grantを追加する場合は、別Decision、互換性規則、wire protocol更新または明示的additive拡張、fixtureを同時に必要とする
- **未完了**: Developer Program / CloudKit Consoleで行うcontainer・App ID・capability・profile・schema、署名済み同一account実機、Package Validator / External Change / Conflict Gate

ここでいう`local metadata bootstrap`は、起動時にreplica、account scope、binding、engine stateをfail-closedに復元する処理であり、別端末の`.novelpkg`を取得する「作品bootstrap」ではない。source実装や署名なし／Simulator testの成功を、CloudKit development / production環境での利用可能性とは扱わない。

## 3. 層と依存方向

```text
App / AppState
├── native editor → model
├── app-private .novelpkg + DocumentSaveCoordinator
├── LocalDurabilityCoordinator → package外journal
├── native editor external replacement boundary
└── RemoteReconciliationCoordinator
    ├── NovelSync              (OS・transport非依存)
    │   ├── portable wire DTO
    │   ├── state machine / CAS command
    │   ├── journal contract
    │   └── three-way merge
    └── NovelSyncCloudKit      (Apple platform adapter)
        ├── CloudKit / CKSyncEngine
        ├── CKRecord mapping
        ├── account / push / retry
        └── binding metadata / copy別journal composition
```

`NovelSync`の公開型、error、fixtureへ`CKRecord`、`CKRecord.ID`、`CKSyncEngine`、`CKContainer`等のCloudKit型を出さない。SwiftUI、AppKit、UIKit、SwiftData型も出さない。Apple adapterはportable commandをCloudKitへ写像するだけとし、CloudKit固有のchange tagやsubscriptionをdomainへ漏らさない。

Windows版はC#、Android版はKotlin等で同じwire、state、CAS、merge fixtureを再実装する。Swift packageやCloudKit adapterを直接移植することは前提にしない。将来別backendを追加しても、時計によるlast-write-winsへ置き換えず、この契約を満たすtransactional adapterを要求する。

Swift側のtarget graphは、`NovelSync -> NovelCore`、`NovelSyncCloudKit -> NovelSync / NovelCore / CloudKit`として固定済みである。`NovelSync`から`NovelStorage`、EditorKit、SwiftUI、AppKit、UIKit、CloudKitへ依存せず、App層がnative editor、package保存、journal、remote reconciliationをこの順に調停する。test専用fakeは`NovelSyncTesting`に分離し、製品targetへlinkしない。

## 4. Identityとportable wire

### 4.1 Identity

- `syncWorkID`: remote revision graphの作品identity。app-private package名や`NovelDocument.id`から暗黙生成しない
- `episodeID`: `.novelpkg`のEpisodeIDと同じ論理ID。S1では初回binding snapshotに含めたepisodeだけを同期する
- `localWorkingCopyID`: 端末内作業コピーのstable identity。pathをremoteへ送らず、journalとbindingをscopeする
- `deviceID`: installationごとに生成するrandom opaque ID。端末名、利用者名、hardware serialを使わない
- `sessionID`: その話のremote authority試行をscopeするrandom opaque ID。app再起動や再openで再利用せず、local Editorの入力可否には使わない
- `branchID`: detached local branchごとのstable ID。再起動やnetwork retryで作り直さない
- `revisionID`: immutable revisionごとのrandom ID
- `mutationID`: 利用者操作をremoteへpublishする試行系列のidempotency key。network retryで変えず、本文を作り直した新操作では新しくする
- `leaseEpoch`: EpisodeControl上の0以上のsigned 64-bit整数。remote authorityの移動ごとにexactly 1増やし、overflow時はremote同期だけを停止する。local本文はpackage／journalへ保存し続ける

`SyncBinding`、初回binding時の対象EpisodeID集合、各IDはpackage外のapp-private metadataへ保存する。exportした`.novelpkg`だけではsync accountやremote workへ自動再接続しない。`sourceDocumentID`は候補の表示順hintと、明示binding後に同じlocal package系統であることをfail-closed確認するためだけに使い、`syncWorkID`の代用や自動bindingには使わない。

### 4.2 Wire規約

D-059基準の**Device Sync wire protocol v1**は実装・全ローカル回帰済みであり、D-060でも変更しない。detached branch、local durability、review draft等の端末内状態はpackage外のjournal schema v2へ追加し、wireへCloudKit固有値やnative editor状態を持ち込まない。`.novelpkg`の`formatVersion`も変更しない。journal schema v1はworking copy identityをbindingからfail-closedに補完したうえでv2へatomic移行し、未知schemaは拒否する。wire v1とjournal schema v2を別々のfixtureで固定する。

- protocolはversion付きUTF-8 JSONとし、BOMを付けない
- keyはlower camel case、IDはcanonicalな大文字UUID文字列、`leaseEpoch`は0以上のJSON整数とする
- 本文はJSON stringとして論理表現し、decoded stringをUTF-8へencodeしたbytesのSHA-256を`bodyDigest`とする
- 本文へNFC / NFD変換、改行変換、末尾空白除去を行わない
- 未知のminor fieldは保持または無視できるが、未知のmajor `protocolVersion`は拒否する
- 日時は診断／表示用に限り、head選択、publish可否、merge winnerの判断へ使わない
- 1 revisionの本文はUTF-8で最大1 MiB、親は最大2件、1話journalのpending revisionは最大5件、atomic publishは最大64 revision、journal JSONは最大80 MiBとする。競合時に保持するpendingは最大3件、materialization graphは最大4件で、fresh-session relayを含むとpendingは最大5件になる。上限超過を切り詰めたり部分適用したりせずblockedにする。1 MiBのJSON control character本文を全revisionへ置いたstaged／recovery最大状態は75,506,494 bytesであり、80 MiB上限でencode／save／loadできる専用回帰を固定する

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
| `SyncWork` | `syncWorkID`, `protocolVersion` | sync graphのroot。S1では利用者が明示したsync開始と、構造一致するbinding候補／既存bindingの検査にだけ使う。作品棚やpackage downloadにはしない |
| `EpisodeControl` | `syncWorkID`, `episodeID`, `headRevisionID`, `holderDeviceID`, `holderSessionID`, `leaseEpoch`, advisory lease metadata | headとremote publish authorityを1つのCAS対象にし、takeoverとpublishの競合を直列化する。local Editorの入力可否には使わない |
| `EpisodeRevision` | `syncWorkID`, `revisionID`, `episodeID`, `branchID`, `parentRevisionIDs`, `body`, `bodyDigest`, `mutationID` | immutable。detached local、通常publish、2-parent mergeを同じgraphへ残す |
| `MutationReceipt` | `syncWorkID`, `mutationID`, command digest, `resultRevisionID`, resulting head / epoch | 応答消失後のretryをexactly-once相当にする。既存IDと内容が違えば拒否する |

全recordは`syncWorkID`を検証し、EpisodeIDやrevision IDだけで別workのrecordを参照しない。固定zone内のrecord nameもwork IDをscopeに含める。

現行wire protocol v1のrecord集合に`HandoffRequest`は存在しない。別holderがいる場合も、最初のlocal editをpackage／journalへ保全した後、観測したremote head ID／digestとepochのexact CASでinternal takeoverを試す。CASが競合すれば本文を取消さずdetached branchへ残して再fetchする。旧writerへflush／grantを依頼するcooperative handoffは将来のadditive protocol候補であり、現行v1の実装済み機能として扱わない。

soft leaseの期限やheartbeatはUX上の「応答がない」判定にだけ使う。local wall clock、recordの表示日時、push到着順はpublish権限を与えない。権限の正は、最新`EpisodeControl`のholder / session / epochとremote CASだけである。

### 5.2 Apple private CloudKit

- Apple版は利用者のprivate CloudKit databaseを使い、自前serverを置かない
- S1はprivate database内にversion付きの **単一固定custom record zone** を1つ作り、全sync workのrecordを同じzoneへ置く。作品ごとにzoneを増やさず、各recordのopaque `syncWorkID` fieldと、work IDを含む衝突しないrecord nameで分離する。zone IDとrecord nameへ作品名や話タイトルを含めない
- `EpisodeControl`をCloudKitのserver record change tag付きrecordへ写像する。publish / grant / internal takeoverは`.ifServerRecordUnchanged`相当の条件付き保存を使う
- revision、mutation receipt、更新後controlは同じzoneのatomic batchで保存する。atomicityを提供できない経路ではpublish成功にしない
- `EpisodeRevision.body`はportable wire上はstringのままだが、Apple adapterは上限と大本文を考慮し、canonical UTF-8 payloadを`CKAsset`へ写像できる。metadataのdigest / byte countを検証してからinstallする
- `CKSyncEngine`はchange tracking、pending change、push後のfetch、retry token管理に使う。lease / expected head / mutationIDのdomain検査を`CKSyncEngine`任せにしない
- pushは通知契機であって配送保証ではない。起動、foreground復帰、claim／internal takeover直前にもserver changesをfetchする
- `listWorks`の結果はordered structure digestで絞った明示binding候補にだけ使う。`sourceDocumentID`一致は候補順のhintに留め、候補取得、タイトルsnapshot表示、単一候補の存在だけで自動bindingしない

mutation適用順は次のとおりとする。

1. 同じ`mutationID`のreceiptがあれば、command digestが一致する場合だけ既存resultを返す。一致しなければID再利用として停止する。
2. receiptがなければ、最新controlのheadが`expectedRemoteHeadRevisionID`、holder / session / epochがcommandと完全一致することを検査する。
3. immutable revision、receipt、更新後controlを同じ固定zoneの1 atomic transactionで保存する。
4. server acknowledgementとread-backでresultを確認した後だけoutboxを完了にする。timeoutは成功とも失敗とも決めつけず、同じ`mutationID`で照会／再試行する。

headまたはepoch不一致を、更新日時が新しい本文で上書きしない。競合としてfetch / fork / mergeへ移る。

## 6. 端末内journalと状態機械

package外のapp-private `SyncJournal`はjournal schema v2として、少なくとも次をatomicに保持する。

- `SyncWorkID`、`EpisodeID`、`LocalWorkingCopyID`、replica ID、protocol version
- stable branch ID、現在のlocal revision ID、exact本文／digest
- 最後に証明できたremote revision ID／digest／exact本文と、verified／unconfirmedのbase provenance
- 最後に観測したhead、holder / session / epoch。永続leaseは再起動後のauthorityとして使わない
- pending revision、sealed mutation、receipt確認、最新local mutation sequence
- remote acknowledgement、pending materialization
- review ID、base / local / remote、確認用下書き、解決checkpoint

journalは`.novelpkg`保存やexportの置換対象外とし、package保存に成功した本文だけを次のlocal revisionとして記録する。journal保存完了前に「この端末に保存済み」と表示しない。packageだけが先行したprocess終了は、再起動時にpackage digestとjournal local headを比較して新しいdetached revisionとして回収する。未解決本文とその親を自動削除せず、merge revisionのremote acknowledgement／read-back、package反映、journal checkpointの全てが完了するまで保持する。

app-private pre-package WALのreview用`preservedMarkers`は最大3本文とする。さらに未知／不整合なbranchが到着して上限を超える場合、既存のpackage／active WAL／preserved本文を上書き・削除せず、local integrity／recovery errorとしてfail-closedにする。その状態ではreview choiceとremote mutationを行わない。これはnetwork、別holder、account待ちを編集許可へ結合するものではなく、本文を欠落させないためのresource capである。

Editor表示時の`observeLocalBase`／`observeRemoteBase`は、現在本文を`localEditIntent = observed`、pending revision 0件として保存する。閲覧baselineをexplicit editやpublish待ちへ昇格せず、claim、takeover、publishも行わない。remote本文と一致しないうえ共通祖先を証明できない場合は本文保全の`reviewRequired`になり得るが、それもremote authorityを変更しない。実際の変更callbackだけが`recordLocalEdit`を通ってexplicit／pending revisionへ進む。いったん変更してUndoで同じdigestへ戻った場合も、実変更を受けたsequenceとしてobserved baselineをexplicitへ昇格できるため、「現在の文字列が同じ」だけで編集意思を消さない。

local durability、remote propagation、integrationを一つの編集可否enumへ畳み込まない。

| Facet | State | 意味 |
| --- | --- | --- |
| local | `dirty` / `savingPackage` / `savingJournal` / `saved` / `failed` | 最新native本文の端末内durability。`saved`はpackageとjournalが最新sequenceへ到達し、対応するpre-package WAL markerのexact acknowledgement／除去まで完了した状態 |
| remote | domainの`idle` / `pending` / `offline` / `reviewRequired`と、Appの同期中／account確認状態 | remote処理。一時的な通信／CloudKit unavailableは`offline`、no account／account変更／設定不整合は設定確認に分類する。どの状態もlocal Editorの入力を禁止しない。cooperative handoff専用stateは現行v1に持たない |
| integration | `none` / `reviewRequired` / `resolutionPending` | 同じ範囲の変更または祖先不明だけを確認対象にする。review中もlocal編集を継続する |

AppのSafe Launch／Recovery、破損package、作品切替中のdocument operation gate等は従来どおり入力を止め得るが、network、remote holder、lease、account確認、fetch／publish中という理由だけでは止めない。

## 7. Local-first保存と暗黙authority取得

native editorから確定本文の変更通知を受けるたびにlocal mutation sequenceを進める。複数の入力を保存前にcoalesceしてもよいが、最新sequenceがpackageとjournalへ到達するまで保存済みにしない。

1. native editorが確定本文を所有したまま、作品／話／Editor世代を固定したcallbackでmodelへ反映する。
2. package保存を開始する前に、作品／話／Editor世代／mutation sequence／exact本文／digestを持つfull-body edit-intent markerをapp-private pre-package WALへatomic保存する。これはprocess kill境界の回収用であり、portable revision、sync wire、`.novelpkg` metadataではない。
3. `DocumentSaveCoordinator`の既存revision直列化を使ってapp-private `.novelpkg`へ保存する。
4. package保存成功後に同じ話の最新本文を再取得し、authorityを要求せずdetached local revisionとしてNovelSync journalへ保存する。
5. packageとjournalのexact acknowledgement後にWAL markerを除去し、その除去まで確認できた最新sequenceだけlocal durabilityを`saved`へ進める。
6. remote reconciliationを別taskへenqueueする。fetch／claim／upload中も次の入力とlocal保存を続ける。
7. background／sleep／scene非activeではnetwork taskをcancelまたは切り離し、IME確定、WAL、package保存、journal保存だけを優先して待つ。

論理的な永続化順は引き続き **native editor → model → `.novelpkg` → NovelSync journal → remote** である。pre-package WALはpackage commit前の一時的なfull-body recovery guardであり、packageより新しいportable snapshotやpublish可能revisionとして扱わない。再起動時はscope、generation、digestを検査してpackageへmaterializeし、その後にNovelSync journalへ`recordLocalEdit`してexact acknowledgementできた場合だけ削除する。

本文入力、paste、delete、Undo、Redo、ルビ、傍点、`……`、`――`等のcommand結果が本文を実際に変えた場合だけ、最初のlocal edit intentを作る。選択、copy、scroll、検索移動、単なる閲覧では作らない。

holderが空または自分なら通常claim／renewを試す。別holderなら、local journal保存後の観測head ID／digest／epochを全て条件とするinternal takeoverを試す。競合時は再fetchし、旧writerの未同期本文を消さずdetached branchとして残す。現行v1は旧writerへrequest／flush／grantを送る`HandoffRequest`を持たず、cooperative handoffを必要とする場合は将来のadditive Decision／protocolとして追加する。

## 8. Remote authorityとfencing

remote writerは最新`EpisodeControl`のholder／session／epochと一致し、remote headを直接進められる1端末だけである。local Editorの入力許可とは独立させる。

1. local revisionを先にjournalへ保存してから最新control／headをfetchする。
2. holder不在ならobserved head／digest／epochを条件に通常claimする。別holderなら同じexact observationを条件にinternal takeoverを試し、その間もlocal編集を続ける。
3. claim／takeoverが成立しない場合でもlocal revisionを取消・破棄・remoteへpublishしない。現行v1にcooperative handoff requestはなく、必要なauthority移動はexact head／digest／epoch CASとして実行し、通常UIにforce操作を出さない。
4. takeoverまたはpublishが競合した場合、remote CASで一方だけを成立させる。head／epochが変わった試行は再fetchし、同じstale observationを使って繰り返さない。
5. authorityを失った端末のpublishはremote側でstale epochとして拒否する。本文はすでにpackage／journalへ保存済みであり、detached branchとしてreconcileする。
6. 別holderが残る、fetch／claimに失敗する、通信不能である場合、local編集を継続しながらremote stateを`awaitingAuthority`または`awaitingConnectivity`にする。

lease期限やheartbeatは再試行のhintに限る。local clockだけでauthorityを成立させず、authorityの正はremote CASで確定したcontrolだけとする。「編集権」「lease」「epoch」「fencing」「fork」「強制的に続ける」は通常UIへ表示しない。

## 9. Offline動作

- holderの有無にかかわらずnative editor、package、journalへ保存する。最後に証明できたremote revisionをbaseとするdetached local branchを自動作成し、remote acknowledgement前は「この端末に保存済み」と「iCloudにも同期済み」を内部で分ける
- `SyncWorkID`、`EpisodeID`、`LocalWorkingCopyID`、base revision／digest、stable branch／local revision ID、本文、replica ID、protocol version、同期未確認状態を再起動可能な形で保存する
- 共通祖先を証明できない場合も本文を保存するが、unconfirmed baseとして自動merge／publishしない
- push欠落、app suspension、process kill後はpackageとjournalからEditorを先に再開し、networkが戻った後にchange tokenとremote reconciliationを再開する。local pendingを破棄してremoteだけを採用しない
- package保存後・journal保存前にprocessが終了した場合は、再起動時にpackage本文を新しいlocal revisionとして回収する。sealed publish、acknowledgement、materializationの各境界もjournal checkpointから冪等に再開する
- WAL保存後・package保存前にprocessが終了した場合は、scope／Editor世代／sequence／digestを検査してfull-body markerをpackageへmaterializeし、journalのexact acknowledgement後までmarkerを残す
- iCloud account不明、signed out、restricted、一時的なCloudKit unavailable、account変更はremote状態として区別する。一時障害はofflineとして自動再試行し、no account／account変更／entitlement・設定不整合だけを設定確認とする。旧account scopeのbinding／journalをquarantineし、新accountへ送らない。local packageとjournalはどの分類でもそのまま編集できる

## 10. 3-way merge

merge入力は、証明済み共通祖先`base`、現在端末のdetached branch headである`local`、現在remote headの`remote`である。digestとrevision ancestryが証明できない場合は本文を保存したままreviewへ送る。

### 10.1 自動merge

- remote headがbaseから変わっていなければauthority取得後にlocal revisionを自動publishする
- localとremoteのexact本文／digestが同じなら重複revisionをremote headへcollapseし、競合を表示しない
- normalizationしないUnicode scalar列に対して、base→localとbase→remoteのedit hunkを決定論的に求める
- Myers shortest-edit-scriptで両側の全hunkを抽出し、非重複hunkを複数箇所まとめて適用する。入力は各4 MiB／1,000,000 Unicode scalar、edit distance 1,024、diff work 16,000,000を上限とし、超過時は推測せずreviewへ送る
- base上の変更区間が互いに交差せず、同一挿入点、相手の置換／削除境界、対応が曖昧な反復領域を共有しないことを **証明できる場合だけ** 自動適用する
- 自動結果は`[remote head, local head]`の順でexactly 2 parentを持つimmutable merge revisionとして、利用者操作やdialogなしにpublishする
- 算出上限、曖昧なmapping、digest不一致、親欠損、同じ箇所への両側挿入はreviewへ送る
- hunk適用順と結果をSwift / C# / Kotlinで同じfixtureへ固定する。日本語、emoji、結合文字、改行、全角空白を含める

overlapが一部だけの場合、確認用下書きにはlocal側の競合範囲を保持しつつ、証明済みの安全なremote非重複hunkを反映する。自動mergeとreview draftのどちらも同じbounded mergerを使い、native editorやUTF-16 rangeへ依存しない。

### 10.2 overlap解決

同じ範囲の変更または祖先不明時だけ、Editor上部の保存記号付近へ「変更の確認が必要です」という小さな警告を出す。自動でmodalを開かず、警告を選択したときに少なくとも次を提示する。

- この端末の本文
- もう一方の端末の本文
- 共通祖先
- 自動統合できる部分を反映し、未解決範囲はこの端末側を保持した確認用下書き
- 「この端末を採用」「もう一方を採用」「手動で統合」

review中もEditorとlocal保存を止めず、追加編集でlocal headを進める。どの選択も片方のrevisionを削除する操作ではなく、確認済み本文から **2-parent merge revision** を新規作成する。親はその時点の`[remoteHead, localHead]`とし、採用結果が片側と同じ本文でもmerge revisionを省略しない。確認後にlocalまたはremoteが進んだ場合、確認済み下書きをjournalへ残して最新3面へ再評価する。新headへのpublishは現在のlease epochとexpected remote headでCASし、両親とmutation receiptの存在をread-backする。

元のbase / local / remote revisionとjournalは、remote publish／read-back、解決本文のpackage反映、journal上の解決checkpointが全て成功するまで削除しない。確認画面を閉じる、appを終了する、別話へ移る操作でも保持する。

## 11. Native editorとの統合

- 本文入力、paste、delete、Undo、Redo、ルビ、傍点等の変更はnative editorが先に成立させ、確定全文callbackからmodel／package／journalへ流す。IME marked text中は従来どおりmodel／pluginへ確定本文として通知しない
- remote fetch／publish callbackからSwiftUI Binding、`NSTextView.string`、`UITextView.text`を直接変更しない。remote本文はまずjournalへstaged revision／pending materializationとして保存する
- external replacementは、作品／話／document session、Editor surface／世代、expected本文digestが一致し、marked textがなく、Undo／Redo実行中でなく、非空selectionがなく、未journaled local mutationがないことをnative adapterが同じtransactionで再検査した場合だけ行う
- 条件を満たさないremote本文は、IME確定、選択解除、Editor command完了、foreground復帰、話の再mount等の安全な境界まで延期する。現在端末の本文を取消・巻戻ししない
- external replacement成立時だけselection／scrollを安全な範囲へ調整し、必要ならその話のUndo／Redo baselineを更新する。別baselineへ旧transactionや古いcallbackを適用しない
- remote本文が現在のnative本文と同じdigestなら全置換を省略し、remote head／receiptだけを進める

### 11.1 保存状態の表示

通常はMac／iPhoneともEditor上部の小さな記号一つを使う。常設の同期banner、remote writerの説明、force／offline draft開始buttonは置かない。

| 表示 | 条件 | VoiceOver |
| --- | --- | --- |
| チェック | 最新本文がpackageとjournalへ保存され、対応WAL markerのexact acknowledgement／除去も完了 | この端末に保存済み。remoteも一致する場合はiCloudにも同期済み |
| 控えめな進行表示 | local保存済みでfetch／claim／takeover／publish中 | 同期中。この端末には保存済み |
| 小さなoffline表示 | local保存済みでnetwork待ち | オフライン。この端末に保存済み |
| 警告 | overlapまたは祖先不明のreviewあり | 統合が必要 |
| エラー | no account／account変更／entitlement・設定不整合、またはlocal durabilityの確認が必要 | 同期設定を確認、またはこの端末への保存を確認 |

最新sequenceのjournal保存前にチェックへしない。詳細は記号を選択したときだけ「この端末に保存済み」「iCloudにも同期済み」「オフライン」「統合が必要」「同期設定を確認」を表示する。通常の自動merge／同期成功ではdialogや通知を出さない。

## 12. Security / Privacy

- private CloudKit databaseはApple IDに紐づくFUMINIWAのprivate領域であり、公開databaseやCloudKit sharingをS1で使わない
- FUMINIWA運営者の自前serverは不要だが、話本文、作品タイトルの初回discovery label、revision、opaque ID、必要な診断metadataはAppleのCloudKitへ送られる。タイトルは候補表示用snapshotであり、作品情報の双方向同期ではない。clipboard機能とは別の明示的なcloud境界として説明する
- transport／保存時暗号化をApple platformへ依存することと、FUMINIWA独自のend-to-end encryptionは同義ではない。E2EEを実装・検証するまでその表示をしない
- 作品名、話タイトル、端末名、利用者名、local path、bookmark、hardware identifierをrecord name、zone name、診断logへ入れない
- 本文、fork、asset URL、CloudKit error payloadを通常log、analytics、crash breadcrumbへ記録しない。診断はopaque ID、状態分類、byte count等のcontent-free値に限定する
- remote payloadのdigest、size、protocol version、parent、episode / work bindingを検証してからpackageまたはEditorへinstallする
- account確認不能、CloudKit bootstrap失敗、entitlement未成立でも、既存bindingをapp-private local metadata／journal resolverから復元してpackage、WAL、local revision保存を継続する。remote descriptorがない間はtransport mutationを送らず、旧account transportへはlive account scopeの再確認が成功するまで送信しない。一時的なtransport／bootstrap unavailableはofflineへ分類してbootstrapを再試行し、no account／account変更／設定不整合は設定確認へ分類する。account変更時は旧accountのbinding／journalをquarantineして新accountへuploadしない
- package外journal、pre-package WAL、merge recovery recordも原稿を含む。現行Mac／iOS sourceは信頼済みapp-private ancestorへrootをanchorし、各下位componentのsymlink、final symlink、rootのdevice／inode差し替えを通常の各操作前後でfail-closedに拒否し、atomic file replacementを行う
- このpathname／root identity検査は、静的なsymlinkや通常のroot差し替え事故を検出する境界であり、同じ利用者権限を持つ悪意あるprocessが1操作中にrenameを競合させるsame-UID adversaryへの完全なTOCTOU耐性を主張しない。外部process／provider変更の検出、file coordination、open-in-place、より強いdescriptor-relative I/Oは未完了のExternal Change / Conflict Gateで扱う
- 端末backupとmerge後retention / purgeの製品方針は未決定のままとする

## 13. Apple capabilityと外部Gate

Apple版はprivate CloudKit + `CKSyncEngine`を採用し、SwiftDataはcanonical storeにしない。最低OSは現行のmacOS 14 / iOS 17と一致する。

macOS / iOSはbundle IDが別でも、同じTeamのApp IDへ同じiCloud containerを割り当てれば同じprivate databaseを利用できる。S1のcontainer identifierは **`iCloud.dev.serikayuzuki.fuminiwa.sync`** に固定し、adapterはdefault container推測に依存せず`CKContainer(identifier:)`へ明示する。両targetの署名済みentitlementには少なくともCloudKit serviceと同じcontainer identifier、Push Notifications環境が必要で、iOSのInfoには`UIBackgroundModes = remote-notification`が必要になる。source上のentitlement追加はportal上のcontainer作成、App ID割当、profile発行、schema deployの完了を意味しない。

実装・検証には、コードだけでは完了できない次の外部作業が必要である。

1. Apple Developer Program上で、固定済みidentifier `iCloud.dev.serikayuzuki.fuminiwa.sync` のcontainerを作成する
2. macOSとiOSの別App IDを同じTeamで管理し、同じCloudKit containerを両方へ割り当てる
3. 両targetへiCloud / CloudKitとPush Notifications capabilityを付け、同じcontainer entitlementを署名profileへ含める
4. iOSへBackground Modesのremote notificationsを付ける。macOSはpush entitlementを持つが、iOSのBackground Modes設定を機械的に流用しない
5. development schemaを作成し、index / record typeを検査してからproductionへ明示deployする
6. 同じiCloud accountで署名済みMac実機とiPhone / iPad実機を使い、foreground、background、push欠落、offline、account変更を検証する
7. Developer ID配布用macOS buildとiOS配布profileの両方でentitlement / container environmentをread-backする

macOSはD-011どおり非Sandboxの直接配布を維持する。CloudKitのために`com.apple.security.app-sandbox`を追加せず、CloudKit / container / pushに必要なentitlementだけを署名済みtargetへ付ける。iOSの`remote-notification` Background ModeをmacOS設定へ機械的に追加せず、macOSはpush entitlementと起動／foreground fetchで取りこぼしを回収する。iOS targetがSandboxであることをmacOS配布判断へ逆流させない。

container作成、App IDへの割当、capability有効化、profile再発行、production schema deploy、実機account状態はAccount Holder / Admin等の権限とApple Developer portal / CloudKit Consoleを要する外部Gateである。署名なしbuild、Simulator、mock transport、`CODE_SIGNING_ALLOWED=NO`のローカルCIだけではCloudKit同期完了を証明しない。

進捗報告は、(1) source実装とunit／integration test、(2) Simulator／local fake server、(3) 署名済みMac＋iPhoneの実CloudKit、の3区分を混ぜずに行う。前段の成功を後段の完了へ読み替えない。

Package Validator GateとExternal Change / Conflict Gateも未完了のままである。Device Syncはapp-private packageに対する別protocolであり、これらを完了扱いにせず、外部原本open-in-placeの許可根拠にも使わない。

D-063のdevelopment cutoverでは、development custom zoneだけでなく旧local sync metadata／journal／registryも対象versionを確認してresetする。staged revision、outbox、pending materialization／create／bind／open、未解決reviewがあればresetを止めてexact readerで解決する。全hidden packageを列挙・attestし、registry再構築／保全または検証済みpackage Exportで回収できないpackageがあればresetを停止する。attachment／snapshot／unknown rootはremoteから戻らないためhidden root自体を削除しない。全test端末を同じD-063 buildへ揃えるまでcatalog／publishを再開しない。production環境へ同じreset手順を流用せず、migrationまたはminimum client version fenceを別Decisionで実装する。

## 14. Test計画

### 14.1 Pure / fixture

- wire protocol v1のcanonical encode／decode維持、journal schema v1→v2 migration、未知version／schema、UTF-8、UUID、resource cap、digest、parent順
- authorityを持たない最初の本文変更がstable detached branchへ保存され、offline restart後も同じbranchから再編集できる
- remote不変の自動publish、同一結果のcollapse、非重複変更の2-parent自動merge、overlap／祖先不明だけのreview
- review中の追加編集、確認後のlocal／remote再進行、merge publish途中のprocess終了でもbase／local／remote／確認済み下書きを保持する
- mutationID retry、応答消失、同じIDの異なるcommand、expected head mismatch、duplicate／reordered change、push欠落
- stale holder／session／epochからの遅延publishを拒否し、新しいremote headを巻き戻さない。fetch開始後に同clientが新headをpublishした場合も古いsnapshotを適用しない
- upload中に1回を超えて追加された本文をdurable tailへ残し、最初のacknowledgement後の次batchで必ず送る
- 日本語、全角空白、`「」`、`『』`、emoji、ZWJ、結合文字、CR / LF、空本文、大本文
- Swiftのgolden fixtureを将来のC#／Kotlin実装でも読み、state、digest、merge、CAS commandを一致させる

### 14.2 App / editor integration

- Mac／iPhoneで同じ話を開いたまま交互に入力でき、別端末がremote writerでもEditorと執筆補助commandが無効にならない
- fetch／uploadを意図的に停止しても入力callback、model反映、package、journalが先に完了し、networkを待たない
- 通信不能のまま編集、終了、再起動、再編集し、package-ahead／sealed outbox／pending materializationの各境界から復元する
- full-body WALだけが先行したprocess kill、package保存後、journal ack後、WAL除去失敗の各境界でexact本文を回収し、未ack markerを保存済み表示やremote publishへ早期昇格しない
- review用WALが3本文の上限へ達した後の未知／不整合branchで、既存package／active WAL／preserved本文を保持し、choice／remote mutation 0件のlocal integrity errorへfail-closedにする
- background移行時は遅いCloudKit taskを待たず、IME commit、native capture、package、journalを優先する
- account確認不能でも既存bindingのjournalへ保存し、旧account scope再確認前および新accountへtransport mutationを送らない
- paste、delete、Undo、Redo、ルビ、傍点、`……`、`――`は本文変更としてlocal intentを作り、選択、copy、scrollは作らない
- 実`NSTextView`／`UITextView`でmarked text、Undo／Redo中、非空selection中のexternal replacementを拒否し、安全なnative transactionだけで反映する
- 話／作品／document session／Editor世代切替中のlate callbackと古いselection snapshotを別対象へ適用しない
- review警告中も追加編集をpackage／journalへ保存し、自動sheetや同期bannerでEditorを塞がない
- VoiceOverで端末内保存、iCloud同期、同期中、offline、統合必要、設定確認を区別する
- 初回bindでは構造digest完全一致を要求し、その後の構造追加ではbinding snapshot内の既存EpisodeIDだけを継続する。追加話をremoteへ暗黙作成せず、削除済み話を復活させない

### 14.3 CloudKit / 実機

- Simulator／local fake serverで決定論的なMac／iPhone 2端末testを行い、交互編集、network pause、claim／takeover、CAS競合、background、process再開を検証する
- development containerでrecord mapping、atomic modify、change token、retry、zone deleteを検証する
- 署名済みMac + iPhone / iPadを同じiCloud accountで使い、同じ話を開いたまま交互に編集する
- Mac／iPhoneをそれぞれofflineにしてlocal編集し、再接続後のcollapse、2-parent自動merge、overlap review、stale epoch拒否を検証する
- app kill、background、push無効／欠落、network切替、account sign-out / switch、容量不足を検証する
- production schema deploy後、production entitlementの配布候補buildで再検証する

実機で一度成功しただけでは完了にしない。各mutation、head、epoch、journal stateをcontent-free traceで照合し、旧本文とremote本文がrevision graphまたはjournalのどちらかに必ず残ることを確認する。

### 14.4 D-060必須scenarioの受け入れmatrix

次の表は、同じ「通過」を異なる検証層で読み替えないための証跡表である。`Domain fake`はmacOS host上の`InMemoryEpisodeSyncServer`／決定論的fake、`native`は実`NSTextView`またはSimulator上の実`UITextView`、`real CloudKit`は署名済みMac＋iPhoneと実containerを意味する。test sourceが存在するだけでは通過にしない。

| # | 必須scenario | 現在の自動検証 | 残る受け入れ |
| --- | --- | --- | --- |
| 1 | MacとiPhoneで同じ話を開いたまま交互編集 | Domain fakeで、別replica／session／journalの2 coordinatorを閉じずにMac→iPhone→Macと往復し、各local journalとremote本文の収束を確認済み | paired native Mac／iPhoneまたは2 Simulatorの同話往復は未実施 |
| 2 | fetch／upload中も入力が止まらない | Domainでupload中のtailと再同期を確認済み。停止transportを使う回帰を含むMac 45 / 45件とiOS Simulator 42 / 42件が通過 | paired native操作とreal CloudKitの遅延通信で確認する |
| 3 | 別端末がwriterでも最初の入力をlocal branchへ保存 | Domain fake往復で、各claim／takeover前の`recordLocalEdit` receiptとjournal durabilityを確認済み。iOS native focusedで別writer下の最初の変更をjournalへ保存しlease不変を確認済み | paired native Mac／iPhoneで確認する |
| 4 | offline編集、終了、再起動、再編集 | Domainでoffline edit→新coordinator再起動→再編集を確認済み。Mac／iOS App回帰でWAL／package checkpoint／journal復元を確認済み | 実process終了／再起動を含むnative campaignは未実施 |
| 5 | 日本語IME変換中の通信断、background、再接続 | macOS hostの実`NSTextView`回帰とiOS native focusedでmarked text確定からmodel／package／journal／WAL cleanupまでを確認し、Mac／iOS Appの停止transport＋background回帰も通過 | 実機の通信断→background→再接続を実施する |
| 6 | paste、Undo、Redo、ルビ、傍点が同期状態に依存しない | macOS hostの実`NSTextView`回帰に加え、iOS native focusedで実`UITextView`のreplace／delete／Undo／Redo／paste／ルビ／傍点とlease不変を確認済み | paired nativeの手動command往復を確認する |
| 7 | remote不変なら操作なしで同期完了 | local-first Domain suiteで自動claim／publishとexact remote headを確認済み | paired native／real CloudKitで確認する |
| 8 | 非重複変更を操作なしで3-way merge | local-first Domain suiteでbounded multi-hunk 2-parent auto mergeを確認済み | paired native／real CloudKitで確認する |
| 9 | 同一範囲変更は両本文を保持し警告だけ表示 | Domainでbase／local／remote／review draft保持を確認済み。Mac／iOS Appのnonblocking警告回帰も通過 | paired native画面とreal CloudKitで確認する |
| 10 | 競合中の追加入力を失わない | Domainでreview中の新local headと解決後tailを確認済み。Mac／iOS Appのreview中local保存回帰も通過 | paired native操作で確認する |
| 11 | merge途中でremoteが再度進んでも確認済み本文を失わない | Domainでclaim中のremote advanceを再reviewに戻し、両sourceと確認済みdraftを保持することを確認済み | paired native／real CloudKitで確認する |
| 12 | 古いepochの遅延publishを拒否 | Domain fake往復で旧Mac epochのraw delayed publishをremoteが拒否し、head不変を確認済み | real CloudKit atomic CASで確認する |
| 13 | upload中の追加入力を次batchで送る | Domainで複数tailを同じ同期runからdrainする回帰を確認済み。Mac／iOS Appのsealed batch後tail回帰も通過 | real CloudKitの遅延uploadで確認する |
| 14 | background時に遅いCloudKitを待たずpackage／journalを保存 | Mac／iOS Appのpaused publish中background flush回帰が通過 | 署名済み実機backgroundで確認する |
| 15 | account変更時に旧本文を新accountへ送らない | `NovelSyncCloudKit`のaccount fence／in-flight cancel／local fallback回帰を含む48 / 48件がhostで通過 | 署名済み実機のsign-out／account switchは未実施 |
| 16 | process killの全境界からlocal／remoteを復元 | Domainでjournal／materialization／merge checkpointを確認済み。Mac／iOS AppのWAL→package→journal境界とkill／relaunch模擬回帰も通過 | 実OS killを各write境界へ注入するcampaignは未実施 |
| 17 | 実`NSTextView`／`UITextView`でIME、marked text、Undo、古いcallback、Editor世代を検証 | macOS hostの実`NSTextView`回帰はlocal-first 4件、committed capture 5件、adapter integration 37件が通過。iOS Simulator full 42 / 42件とnative focused 2 / 2件も通過 | actual device IMEは未実施 |
| 18 | VoiceOverで保存、同期中、offline、統合必要を識別 | iOS Simulator full 42 / 42件に状態／accessibility label回帰を含めて通過 | Mac／iPhone実機の手動VoiceOver操作確認は未実施 |

Domain全体の実測は`NovelSync` 94 / 94件（local-first 33件、既存coordinator 18件）、Apple adapterは`NovelSyncCloudKit` 48 / 48件である。App層はMac Device Sync 45 / 45件（3 suites、11.932秒）とprivate-root focused 1 / 1件、iOS Simulator Device Sync 42 / 42件（3 suites、20.544秒）とnative focused 2 / 2件が通過した。これはhost／Simulator上のunit、integration、local fake、native editor証跡であり、paired native Mac↔iPhone、署名済み実CloudKit、手動VoiceOver、実OS process-kill campaignの代用ではない。

## 15. 実装順と進捗

### 15.1 D-059安全化基準（履歴）

- [x] **S1-0〜S1-4 source基盤**: protocol v1、pure `NovelSync`、file journal、CloudKit adapter、Mac／iOS App接続を実装した
- [x] **既存ローカル回帰**: 2026-08-11の`Scripts/check.sh`でMac通常114件／Device Sync 20件、iOS通常71件／Device Sync 15件を含む全検査を通過し、commit `508947d2`へ固定した
- [ ] **D-059 cooperative handoff／外部Gate**: request／grant全経路はD-059で完結せず、D-060現行v1には引き継がない。将来のadditive Decision／protocol、container、署名済み実機は未完了である

### 15.2 D-060 local-first実装

- [x] **LF-1 Decision / Portable contract**: D-060、指定設計文書、wire protocol v1維持／journal schema v2、v1 migration、golden fixtureを固定した
- [x] **LF-2 Detached Journal**: authority非依存`recordLocalEdit`、observed baseline、stable branch、offline bootstrap、account／CloudKit確認不能時の既存binding local journal fallbackを実装した
- [x] **LF-3 Reconciliation / Merge**: remote不変、collapse、bounded multi-hunk非重複2-parent auto merge、overlap review、upload tail、process再開、2段階競合解決をpure domainへ実装した
- [x] **LF-4 Authority / Transport**: local journal後のclaimとexact head／digest／epoch internal takeover、stale fencing、CloudKit/account transport fenceを実装した。現行v1に`HandoffRequest`は追加しておらず、cooperative request／grantは将来の別Decision／protocolである
- [x] **LF-5 App Local Durability**: Mac／iOSでfull-body pre-package WALとnative→model→package→journalをremote taskから分離し、background／account変更／古いcallbackを処理するsourceとApp回帰を実装した。Mac Device Sync 45 / 45件、private-root focused 1 / 1件、iOS Simulator Device Sync 42 / 42件が通過した
- [x] **LF-6 Editor / UI / Accessibility**: syncによるread-only撤去、external replacement guard、上部状態記号、nonblocking review、VoiceOverを実装した。iOS native focused 2 / 2件でmarked IME確定、実`UITextView`の編集command、local durability、lease不変を確認し、iOS full suiteの状態／accessibility label回帰も通過した
- [ ] **LF-7 Simulator / Local Fake Server（一部通過）**: host上の2 coordinator in-memory local fake往復、Mac Device Sync 45 / 45件、iOS Simulator Device Sync 42 / 42件、iOS native focused 2 / 2件は通過した。paired native Mac↔iPhoneでnetwork pause、offline restart、IME、Undo／Redo、merge raceを一続きにした受け入れは未実施である
- [ ] **LF-8 Signed Real CloudKit**: container／App ID／profile／schemaを設定し、署名済みMac＋iPhoneの同一accountで実CloudKitを検証する

LF-1〜4のDomain検証は`NovelSync` 94 / 94件（local-first 33件、既存coordinator 18件）、Apple adapter検証は`NovelSyncCloudKit` 48 / 48件がローカルで通過した。LF-5／6のApp検証はMac 45 / 45件とprivate-root 1 / 1件、iOS Simulator 42 / 42件とnative focused 2 / 2件が通過した。各段階は未実装の操作をUIへ出さない。Domain／adapter source完了、App回帰、Simulator／local fake server、署名済み実CloudKitを別々に報告し、paired native Mac↔iPhone、手動VoiceOver、実OS process-kill、signed real CloudKitを完了扱いにしない。Windows / Android transportはwire v1／journal schema v2／state・merge fixture確定後の独立trackとする。
