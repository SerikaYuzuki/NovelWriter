# FUMINIWA iOS / iPadOS Phase 7 実装計画

> **状態**: IOS-1〜5実装済み。D-061の作品全体local-first Work Syncに加え、D-063の単一「iCloudの作品」棚、WorkID由来の見えない作業コピー、remote-only初回download、local-first新規／取込、identity不変の`.novelpkg`書出、account／offline／kill fence、旧iOS private-copy明示recoveryをiOS / iPadOSへsource実装し、local automated GOとした。現行D-063差分はSimulator上の`IOSCloudLibraryIntegrationTests` 28 / 28件（1 suite）、先行xcresultの`FUMINIWADeviceSyncIOSTests` device cases 89 / 89件、fresh check runの同target 86 / 86 top-level（4 suites）、hosted `FUMINIWAIOSTests` 79 / 79件を通過し、`FUMINIWAIOS` generic build／build-for-testingもPASSした。fresh `./Scripts/check.sh`は`All checks passed`である。最終署名済みiOS generic Debug buildもstrict codesign validで、App ID、Development container、CloudKit、APNs `development`を成果物からread-backした。先行dynamic device casesとfresh top-level件数は集計単位が異なり、既存D-061やD-063 Mac-eraの件数を流用していない。paired native Mac↔iPhone、手動VoiceOver、実OS process-kill campaign、Production deploy、production migration／minimum-version fence、Release QAは未完了
>
> **対象**: iOS / iPadOS 17 以降
>
> **正とする上位契約**: [DESIGN.md](DESIGN.md)、[DECISIONS.md](DECISIONS.md)、[DEVICE_SYNC.md](DEVICE_SYNC.md)、[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)

## 1. 目的

macOS版で確立した`NovelCore`、`.novelpkg` v3、`NovelExport`、EditorPluginの純粋ロジックを再利用し、iPhone / iPadで安全に日本語小説を執筆できる通常版FUMINIWAを追加する。

Phase 7はmacOS UIの縮小移植ではない。作品・保存・本文編集の意味は共有しつつ、iPadでは複数列、iPhoneでは段階遷移という各端末に適したシェルを作る。製品境界は、1つの「iCloudの作品」から作品を選び、外部の`.novelpkg`はアプリ専用領域へ新WorkIDとして取り込み、見えない作業コピーを編集・保存し、利用者の明示操作でportable packageを外部へ書き出す **cloud library / app-private import / edit / export** とする。D-061／D-063のDevice Syncも外部原本を直接編集せず、作品全体snapshotをapp-private packageとpackage外Work journalへ先に保存し、別namespaceのWork wireでremote headを調停する。

AI providerは接続しない。利用者が選んだ原稿から校正用／アドバイス用のplain text promptを作り、system clipboardへ明示コピーする機能だけを通常iOS版へ含める。

### 1.1 現在地（2026-08-12）

- `FUMINIWAIOS` app / test target、iPhone / iPad対応Info.plist、D-059以前のbase 5 productだけの依存境界を実装した。現在の通常targetはDevice Sync用の`NovelSync` / `NovelSyncCloudKit`を追加している
- app-privateな新規作成／取込／revision保存／書出、Loading / Ready / Recovery、適応的な`NavigationSplitView`を実装した
- app-private作業コピーを再選択できる作品棚と、作品ホーム→作品情報／執筆→Outline→Editorの段階導線をD-057で追加した
- プロット／伏線、登場人物、世界観、資料、設定を既存domainと保存へ接続し、作品ホームとiPad Project Sidebarから選べるようにした
- `UITextView` + TextKit 2 adapterを追加し、共有`IndentRules`とD-055後のR1' / R3 / R4 / R5、IME pending確定、Undo / Redo、末尾96pt表示余白、caret revealを接続した
- iOS Editorの保存状態を上部へ移し、本文キャンバスと同じ背景のIME直上バーから`……` / `――` / `ルビ` / `傍点`をselection commandとして実行できるようにした
- 校正／アドバイス×本文選択／話／章のclipboard prompt copyを実装し、通常iOS targetに`NovelAI`、provider、network、credential、subprocessを入れていない
- generic iOS build、iPhone Simulator上のEditorKit／iOS app tests、target separation検査を`Scripts/check.sh`へ組み込み、D-063 iOS extension前の基準で全ローカルCIを通過した。現行extensionを含む再検証結果は別に確定する
- D-059のportable wire / state / force / merge、package外file journal、`NovelSyncCloudKit`のprivate CloudKit adapter、account fence、engine state recovery、local metadata bootstrap、durable pending create / bind intentをsource実装した。iOS production composition、明示binding、editor／scene lifecycle、read-only／force／fence／merge UIもsource接続済みで、iOS通常71件／Device Sync 15件を含む全ローカル回帰を通過した。normal handoffの全経路、container / signing / schemaと署名済み実機検証は未完了である
- 上記D-059状態は基準commit `508947d2`の履歴として維持する。D-060のwire protocol v1を維持したjournal schema v2、authority非依存journal、observed baseline、offline bootstrap、bounded multi-hunk automatic merge、exact head／digest／epoch takeoverはDomain source実装済みである。iOS App／UI sourceもfreeze済みで、Device Sync 42 / 42件とnative focused 2 / 2件がSimulatorで通過した。paired native Mac↔iPhone、実機IME／VoiceOver／process kill、real CloudKitは完了扱いにしない。現行v1に`HandoffRequest` recordはなく、cooperative request／grantは将来の別Decision／protocolとする
- D-061では当時の通常iOS AppをWork経路へcutoverした（履歴）。D-071はlive経路をentity recordへ切り替える契約であり、sourceは未実装である。active `UITextView`へのremote非注入は維持する
- D-063ではroot作品棚をMacと同じWorkID catalog／local registry projectionによる「iCloudの作品」へ切り替えた。remote-onlyは明示tap後にこの端末へ保存し、cached localはofflineで開く。D-071のremote-only openはentity一式をpackageへ組み立てる
- Episode／Work／Noteは別record namespaceで相互の更新を観測しない。D-071はdevelopment cutoverであり、自動migrationしない。production upgradeには別Decisionによるmigrationまたはminimum client version fenceが必要で、それまでは出荷不可とする

IOS-1〜5のコード実装は完了している。ただし、本書の完了条件に含むiPhone / iPad実機の日本語IME、VoiceOver / Dynamic Type、hardware keyboard、scene／termination、macOSとの完全round-tripは未検証であるため、Phase 7 MVPまたは一般公開準備の完了とはまだ扱わない。次はIOS-6 Parity / Release QAとして追跡する。

## 2. 製品スコープ

### 2.1 Phase 7 MVP

- iOS / iPadOS 17以降を対象にした単一の通常app targetを追加する
- 新規作品をWorkID由来のアプリ専用領域へ作成し、同領域の作業コピーを自動保存する
- private CloudKit catalogと検証済みlocal registryを1つの「iCloudの作品」へ投影し、選択した1作品を安全に開く
- remote-only作品はonline＋live account確認後にexact headをiOS private rootへmaterializeし、保存済み作品はofflineでも開く
- Files pickerで選ばれた`.novelpkg`を原本へ書き戻さず、アプリ専用領域へ取り込む
- アプリ専用領域の作品を`.novelpkg`としてFiles / share sheetへ明示的に書き出す
- 章／話の追加、選択、タイトル編集、並べ替え、本文編集、話メモ、検索、文字数、保存状態、Safe Launch / Recoveryを提供する
- `UITextView` + TextKit 2で日本語IME、Undo / Redo、R1' / R3 / R4 / R5、自動保存前の確定本文同期を成立させる
- iPadはProject Sidebar / Outline / Editorの適応的な複数列、iPhoneは`NavigationStack`によるProject / Outline / Editorの段階遷移にする
- 起点は作品棚とし、作品ホームで作品情報／執筆／書き出しを選ぶ。iPhoneは作品棚→作品ホーム→執筆Outline→Editor、iPadは同じ階層を適応的な複数列へ展開する
- 作品ホームでプロット／伏線、登場人物、世界観、資料、設定を選び、既存packageデータを追加／編集／削除／並べ替えできる
- iOS chromeは初回Darkを既定とし、システム追従／Light／Darkへ変更できる。外観設定はpackageへ保存しない
- 校正／アドバイス×本文選択／話／章の6種類のprompt copyを提供する
- Dynamic Type、VoiceOver、ハードウェアキーボード、ソフトウェアキーボード、scene非アクティブ化を検証する

### 2.2 MVPの非目標

- Files、iCloud Drive、他社File Provider上の原本を直接編集するopen-in-place
- 外部URLをrecentとして永続化するsecurity-scoped bookmark運用
- `DocumentGroup` / `UIDocument`による、現在の`DocumentSaveCoordinator`と並立する別autosave所有者
- 複数作品の同時編集、D-063を超えるattachment／snapshot履歴／非hidden未知root／端末設定のCloudKit同期、package全体mirror、共同編集
- Files / iCloud Drive / 他社File Providerを横断して常時列挙する独自ライブラリ
- Codex / OpenRouterその他のprovider、`NovelAI`、SDK、CLI、Node、sidecar、network、credential、model設定
- AI chatの自動起動／送信、応答取込、diff、Apply、履歴管理、clipboard自動消去

## 3. ターゲットと依存境界

通常iOS版は`project.yml`へ独立app targetとして追加し、同じiOS targetでiPhone / iPadへ対応する。

```text
FUMINIWAIOS
├── NovelCore
├── NovelStorage
├── NovelExport
├── NovelUI
├── EditorKit
├── NovelSync
└── NovelSyncCloudKit      (CloudKit / CKSyncEngine platform adapter)

FUMINIWAIOS ─X─ NovelAI
FUMINIWAIOS ─X─ NovelAppExperimental
FUMINIWAIOS ─X─ AI provider SDK / Node / CLI / sidecar / credential
```

D-059以前のbase targetは通常macOS版と同じ5 productだけをlinkする。現在の通常macOS / iOS targetは、Device Sync用にOS / transport非依存の`NovelSync` productとApple adapterの`NovelSyncCloudKit`を追加している。これはD-056 item 8の5-product固定をこの目的に限って置き換える。

`NovelKit`内に`NovelAI` targetやExperimental研究コードが残っていても、iOS app targetのdependency、compile source、resource、bundleへ含めない。CloudKit通信はDevice Sync adapterだけに許可し、AI provider用の`URLSession`、`Network.framework`等のcallsiteを追加しない。生成後のtarget graphとArchive内容をローカル検査で固定する。

### 3.1 共有するもの

- `NovelDocument`、Chapter / Episode、配列順、ID、空要素の意味
- `DocumentSaveCoordinator`、document operation gate、session tokenの意味
- `NovelpkgRepository`と`.novelpkg` v3の互換境界
- `NovelExport`のTXT / Markdown / EPUB 3生成
- `EditorView`のplatform-neutral公開API、`EditorCommandSession`、selection command
- `EditorNotationRules`のルビ／傍点表現、PlotCard / Flag / Character / WorldNote / Attachmentのdomain契約
- `IndentRules`、`IMEGuardPlugin`、`IndentPlugin`、UTF-16 range規約
- clipboard prompt builder、purpose / scope、snapshot・session検査、成功／失敗結果
- `NovelSync`のportable JSON、mutation / lease / CAS、state、3-way merge fixture

### 3.2 iOSへ閉じ込めるもの

- `UITextView`を包む`EditorKit/Platform/iOS/IOSTextAdapter`
- Files picker / exporter、security-scoped accessの一時的な取得と解放
- app-private作品置場、scene lifecycle、`UIPasteboard` writer、share sheet
- iPhone / iPadのnavigation shell、UIKit固有のcontext / edit menu接続
- private CloudKit account、`CKSyncEngine`、record / asset mapping、push、background fetch、binding metadataを持つ`NovelSyncCloudKit` adapter

UIKit型をNovelCore、NovelStorage、NovelExport、EditorKit、NovelSyncの公開APIへ出さない。CloudKit型もNovelSyncの公開API / wire / fixtureへ出さない。AppKitとUIKitの差を巨大な条件分岐へ集約せず、小さなprotocol adapterでAppStateへ注入する。

## 4. 文書ライフサイクル

### 4.1 取り込み

1. 利用者がFiles pickerで1つの`.novelpkg`を選ぶ。
2. 選択URLのsecurity-scoped accessを、取り込み処理の間だけ取得する。
3. 原本を変更せず、アプリ専用stagingへパッケージ全体をコピーする。
4. staging側を読み込み、必須payload、UTF-8、参照整合性など、その時点で実装済みのvalidatorを通す。
5. 読み込み成功後だけ安定したapp-private URLへinstallし、新しいdocument sessionとして採用する。
6. 失敗時は原本と現在作品を保持し、型付きエラーと再試行／別作品選択を示す。
7. security-scoped accessは成功／失敗／cancelの全経路で解放する。

取り込み成功後のrecentはapp-private URLだけを指す。外部URL、bookmark、provider固有identifier、pathを`.novelpkg`へ保存しない。取り込みの開始からinstallまでdocument operation gateで直列化し、旧作品のIME確定と最終保存、呼び出し時sessionの再検査を行う。

### 4.2 編集と保存

編集中はapp-private作業コピーだけを`DocumentSaveCoordinator`の既存revision経路で保存する。本文2秒debounce、話／作品切替、scene非アクティブ化、明示保存は同じ保存所有者へ集約し、別autosave経路を作らない。scene終了を常に受け取れるとは仮定せず、最後の確定入力を速やかにモデルへ反映し、保存失敗時はdirty状態を保持する。

### 4.3 書き出し

書き出し開始時のdocument snapshotとsessionを固定し、必要な保存完了後に一時的なexport packageを生成する。利用者が選んだ出力先へ明示的にコピーし、既存出力を置き換える場合は確認と失敗表示を行う。成功しても作業URLを外部URLへ切り替えず、以後もapp-privateコピーを正とする。

### 4.4 将来のopen-in-place

外部原本の直接編集はPhase 7 MVPに含めない。少なくとも次を完了し、別Decisionで保存所有者と競合UIを決めてから着手する。

- Package Validator Gate: duplicate ID／不正参照、symlink、resource limit、孤児payload保全、修復コピー、保存前検証
- External Change / Conflict Gate: move／delete／provider同期／他プロセス変更の検出、競合時の上書き防止と復旧
- security-scoped URL / bookmarkの寿命、file coordination / presentation、background移行を含む実機検証

app-private MVPの完成をopen-in-place、iCloud Drive原本同期、File Provider競合対応、またはD-061のDevice Sync完成とは表現しない。Device Syncが完成しても外部原本open-in-placeのGateは別に残る。

### 4.5 資料

- 資料一覧は現在のapp-private作業コピーに対して`AttachmentManaging`から取得し、App層でpackage内部pathを組み立てない
- 取り込み前に最新本文を同じ保存直列化経路で確定し、外部URLのsecurity-scoped access中だけRepositoryへ複製を依頼する
- 一覧、削除確認、共有は表示時の作品identityと資料IDを保持し、待機中に作品が変わった操作を別作品へ適用しない
- 外部原本の資料を直接編集したり、任意の外部path／bookmarkをpackageへ保存したりしない

### 4.6 D-071 Note Sync

現行iOS Appのlive同期はD-071のentity recordである。作品タイトル／あらすじ、章・話、本文／メモ、人物、プロット、伏線、世界観を同期する。資料／attachment、snapshot履歴、端末設定は含めない。画面はapp-private `.novelpkg`を正とし、`UITextView`の入力とlocal保存を通信完了で待たせない。変わったentityだけを裏で送る。同じentityが衝突したら合成せず、この端末／iCloud／両方を別作品として残す、を選ばせる。D-063の作品棚catalogは維持し、remote-only openはentity一式をpackageへ組み立てる。

確定変更は次の順に処理する。

1. `UITextView`またはformの確定値を現在の`NovelDocument`へ反映する
2. 既存の保存直列化経路でapp-private `.novelpkg`を保存する
3. 変わったentity IDをdirty setへ保存する
4. `CKSyncEngine`へpendingを登録し、次の入力とlocal保存を止めない

再接続後、片側だけ進んだentityは確認せず取り込む／送る。同じentityを両方で変えた場合だけ確認する。iPhone／iPadとも **この端末／iCloud／両方を別作品として残す** を示し、統合案は出さない。「あとで」で閉じても衝突は保持し、cloud衝突中はEditorとlocal保存を続ける。

remote callbackからactiveな`UITextView`へ本文を注入しない。編集中の話と衝突しているremoteは、話を切り替えるか利用者が選ぶまで入れない。D-061のWorkSnapshot一括転送、3-way merge、3面reviewは履歴である。詳細は[DEVICE_SYNC.md](DEVICE_SYNC.md) 0章とD-071を正とする。

D-071はdevelopment cutoverであり、Work revision／Episode leaseからの自動migrationはしない。production migration／minimum-version fenceを別Decisionで実装するまで出荷不可である。

### 4.7 D-063 iCloud作品library／bootstrap

iOS / iPadOSのroot作品棚は、private CloudKitのWork catalogとiOS端末内で検証した1 work 1 recordのregistryを`SyncWorkID`だけでmergeする。通常時は1つの「iCloudの作品」だけを表示し、package名、document ID、タイトル、構造digestによるdeduplicate／automatic bindingを行わない。path、保存場所、Files上の作業コピー、「このデバイス」と「iCloud」の二重棚を出さない。refresh失敗で検証済みlocal行を消さず、malformed remote rowはそのworkだけを隔離する。

作業コピーはiOS専用の信頼済みprivate rootへ`<SyncWorkID>.novelpkg`として置き、URLをregistryへ保存せずWorkIDから導出する。registry／packageを読み直したattestationだけをlocal openの根拠にし、memory上の予定値だけで`synced`へ昇格しない。内部path／WorkIDは通常UI、Recovery、利用者向けerror、diagnostic logへ出さない。

作品棚は次を区別する。

- exact local attestation＋account-scoped remote receipt／head一致: onlineでは「iCloudと同期済み」、offlineでは「この端末に保存済み・オフラインでも開けます」
- same-scope local pending: 「この端末に保存済み・iCloudへ反映中」または「接続後にiCloudへ同期」
- unscoped local-only: 「この端末にのみ保存済み」。後から現れたaccountへ自動uploadしない
- account-quarantined local: local open／編集は許可するが、旧scopeのtitle／binding／pendingを新accountへ送らない
- remote-only／remote pending: available時の明示tapでこの端末へのdownload／再開を行う。account未確認／mismatchでlocal packageがなければ行とtitleを隠す
- available catalogからacknowledged workが欠落: `.cloudUnavailable`としてcheckmark／open／uploadを止め、local packageを保持する
- needs review／unavailable: 原因に応じてlocal編集継続またはroot recovery gateへ進み、安全に開けると推測しない

remote-onlyを開くときは、表示時のexact catalog headを再検査し、account-scoped pending-open intentをasset fetch前にdurable化する。full revisionのWorkID、parent、digest、byte countを検証し、WorkSnapshotだけをsame-root stagingへmaterializeする。package read-back一致後にno-overwrite install、WorkID locator bind、remote-bootstrap journal、registry markの順で確定し、各checkpointから冪等resumeする。bind→registry mark間で終了しても、exact package／pending projection／outbox-free journalが一致するときだけofflineから当該workを復旧する。remoteからattachment／snapshot履歴／unknown root／端末設定を復元したとは扱わない。

新規／Files取込はCloud account、network、catalog refreshを待たず、毎回new WorkIDのprivate packageをlocal-firstで作る。作成予定snapshotのexpected attestationをreservationへ先にdurable化し、same-root stagingの完全read-back後だけno-overwrite installする。以前確認済みsame scopeの一時offlineなら同scopeのpendingだけを復旧後に再開する。`accountRequired`／unscoped／different account中に新しく作ったunbound workはlocal-onlyとして保持し、将来accountへautomatic adopt／rebind／uploadしない。旧scope由来の検証済みcopyだけをaccount-quarantinedとして保持する。local作成を許可する判断とremote publish authorityを分離する。

Files / Open Withで渡された外部packageはaccount確認中でも失わず、bootstrap完了後にdocument operation gateへ直列化して通常Importへ渡す。外部原本を変更せず、失敗時も現在作品、原本、既存finalを保持する。D-063以前のiOS private rootにだけあるpackageは自動upload／削除／rekeyせず、検証できた行に「タップして新しい作品として取り込む」と示す。明示tapで新WorkIDのportable copyを作り、new copyのinstall／read-back後も旧bytesを`legacyPreserved`として保全する。

「作品を書き出す…」はnative editor／form、package、Work journalをcurrent sessionでflushし、`PortableDocumentPackageRepository`の検証済みpackage全体copyをFiles exporterへ渡す。destinationもread-backし、plain saveへfallbackしない。現在端末のattachment／snapshot履歴／unknown rootを保持するが、active URL／session／WorkID／binding／journal／selectionを変えない。remote bootstrap由来のcopyに元端末のresourceがない場合は書出にも含まれない。

libraryのmutation／hidden retry／active open・save・switchはdocument operation gateで直列化する。local inventory、remote catalog load、両者のmergeはgate外で行い、選択後のmutationだけをgate内へ渡す。account switchでは旧scopeのpendingをquarantineし、同じscopeへ戻った場合だけexact identityを再検査して再開する。signal stormはcoalesceし、cold startupの`.checking`中はlocal／remoteのidentityを混ぜない。作品ホームから棚へ戻る操作はIME／form／packageを保存してnavigationだけを戻し、active WorkID／packageを切り替えない。

現行sourceは実装済みで、Simulator上の`IOSCloudLibraryIntegrationTests` 28 / 28件（1 suite、2.636秒、`xcodebuild` exit 0）、先行xcresultの`FUMINIWADeviceSyncIOSTests` device cases 89 / 89件、fresh check runの同target 86 / 86 top-level（4 suites）、hosted `FUMINIWAIOSTests` 79 / 79件が通過し、`FUMINIWAIOS` generic build／build-for-testingもPASSした。focused suiteはbootstrap／cold Open With、local-only new／Import、reservationとstaging／finalの終了窓復旧・mismatch保全、remote download／account復帰、stale open／needs review、legacy recovery／collision／single-flight、wrong-write、portable Export、signal coalescingを固定する。fresh `./Scripts/check.sh`も`All checks passed`である。先行dynamic device casesとfresh top-level件数は集計単位が異なり、既存D-061 56 / 56件およびMac-eraのiOS 137 / 137件を現行差分の証跡へ流用しない。実CloudKit paired Mac↔iPhone、実account switch／offline、write checkpointごとの実OS kill、手動VoiceOver／Dynamic TypeはRelease NO-GOのままである。

### 4.8 D-059／D-060 Episode本文同期（履歴）

Device Syncはapp-private package同士を対象とし、iCloud Drive上の原本やpackage内部を直接同期しない。remote `EpisodeControl`のholder / session / epochはremote headを進められる1端末を表すだけで、iPhoneのEditorへ入力してよいかを表さない。同期設定、通信不能、別端末のholder、fetch／claim失敗だけを理由に本文をread-onlyにせず、MacとiPhoneで同じ話を開いたままlocal編集できる。

確定本文が実際に変わる操作は、次の順に処理する。

1. `UITextView`が確定本文を所有し、作品／話／Editor世代を固定した通知でmodelへ反映する
2. package保存前に、作品／話／Editor世代／mutation sequence／exact本文／digestを持つfull-body markerをapp-private pre-package WALへatomic保存する
3. 既存の保存直列化経路でapp-private `.novelpkg`へ保存する
4. package保存済み本文をpackage外journal schema v2のstable detached branchへatomic保存する
5. packageとjournalのexact acknowledgement後にWALを除去し、同じlocal mutation sequenceへ到達した後だけ「この端末に保存済み」とする
6. remote fetch／claim／takeover／publishを別taskへenqueueし、upload中も次の入力とlocal保存を続ける
7. background移行時はnetwork taskを待たず、IME確定、WAL、package保存、journal保存を優先する

pre-package WALはprocess kill境界の回収用であり、portable revision、`.novelpkg` metadata、Device Sync wireではない。論理的な正はnative editor → model → package → NovelSync journalのままとし、再起動時にWAL本文をpackageへmaterializeしてjournalへexact acknowledgementできた後だけmarkerを削除する。

review用に隔離するWAL本文は最大3件とする。さらに未知／不整合なbranchが来た場合は、既存package／active WAL／隔離本文を上書きせずlocal integrity／recovery errorへfail-closedにし、本文の選択やremote mutationを行わない。これは通信、account、別holder待ちを理由とするread-onlyではなく、本文欠落を防ぐresource capである。

package外journalはpending revision最大5件、競合保持3件、materialization graph 4件、fresh-session relay込みpending 5件、JSON 80 MiBを上限とする。1 MiB control character本文を全revisionへ置いた最大状態75,506,494 bytesのencode／save／load回帰を通過しており、超過時は本文を切り詰めずlocal integrity errorへfail-closedにする。

本文入力、paste、delete、Undo、Redo、`……`、`――`、ルビ、傍点等で本文が変化した場合だけ暗黙の編集意思とする。閲覧、選択、copy、scroll、検索移動で作るobserved baselineはexplicit edit／pending revisionへ進めず、claim／takeover／publishしない。祖先不明時に本文保全のreviewとなってもauthorityは変更しない。最初の実変更をjournalへ保存してから、裏側で通常claimと必要なinternal takeoverを試す。成立しなくてもlocal本文を取り消さず、authorityのないrevisionはpublishせずdetached branchへ残す。別holder時はobserved head ID／digest／epochのexact CASを使い、古いepochからのpublishはremote側で拒否する。現行wire v1に`HandoffRequest`はなく、cooperative request／grantは将来のadditive protocolとする。

通信不能でも、最後に確認できたremote revision／digestをbaseとして`SyncWorkID`、`EpisodeID`、`LocalWorkingCopyID`、stable branch／revision ID、exact本文、replica ID、wire protocol version、remote未確認状態をjournalへ保存し、終了・再起動後も編集を続ける。account確認不能でも既存bindingのpackageとjournalへlocal保存し、live account scopeの再確認が成功するまで旧account transportへ送らず、新accountへ旧revisionを送らない。一時的なtransport／CloudKit unavailableはofflineとしてbootstrapを再試行し、no account／account変更／entitlement・設定不整合だけを設定確認とする。

再接続後はremote不変ならauthority取得後に自動publishし、同一結果はcollapse、証明済み非重複変更は2-parent revisionへ自動mergeする。同じ範囲の変更または祖先不明だけをreview対象にし、base／この端末／もう一方／確認用下書きを残す。review中もEditorとlocal保存を止めず、解決結果は2-parent revisionとする。通常UIへ「編集権」「lease」「epoch」「fencing」「fork」「強制的に続ける」「オフライン下書きを開始」を出さない。

S1は、初回binding時にordered ChapterID / EpisodeIDの構造digestが一致し、binding snapshotへ含めたepisode bodyだけを扱う。Apple adapterが示せるのはexact structure一致で絞った **明示binding候補** であり、作品棚のcloud library、package download、automatic bindingではない。後から追加した話はlocal-onlyとし、既存対象話だけを継続する。章／話構造、タイトル、作品情報、メモ、人物、プロット、伏線、世界観、資料、snapshot、attachmentを同期済みと見せない。Product Truth、merge、offline、security / privacyの詳細は[DEVICE_SYNC.md](DEVICE_SYNC.md)を正とする。

## 5. iOS本文エディタ契約

### 5.1 TextKit 2とテキスト所有権

- `UITextView`はTextKit 2を明示的に使う構築経路で生成し、`layoutManager`へ触れてTextKit 1へfallbackさせない
- 公開`EditorView` APIに`UITextView`を出さない
- 編集中本文の正は`UITextView`側とし、SwiftUI更新から本文を流し直さない
- モデル→Viewの本文反映はepisode keyが変わったときだけ行う
- `markedTextRange != nil`の間はモデル通知、plugin介入、表示属性の再適用を行わない
- 作品遷移前は旧作品のIMEを確定し、確定本文を旧sessionへ同期できなければ遷移を開始しない
- CloudKit callback、fetch完了、SwiftUI updateからactiveな`UITextView`へremote本文を流し込まない。remote changeはjournalのpending materializationとして保持し、現在のlocal本文をEditorへ残す
- external replacementは明示的な境界でだけ行い、作品／話／surface／Editor世代、expected digest、未journaled本文、`markedTextRange`、Undo／Redo中、selectionを再検査する。安全でなければ延期し、別baselineへ古いcallbackやUndo transactionを適用しない

### 5.2 R1' / R3 / R4 / R5

iOS側で字下げや鉤括弧の判定を再実装しない。共有の`IndentRules.action(for:in:range:)`と`IndentRules.postChangeAction(in:caretLocation:)`を使い、既定pipelineを`IMEGuardPlugin → IndentPlugin`の順にする。

- **R1'**: 単一改行を常に改行＋全角スペース1つへ置換する。空白行を特別扱いして字下げを消す旧R2は復活させない
- **R3**: 字下げだけの行で`「` / `『`または対応ペアを入力した場合は行頭空白を含む範囲を置換する。`「」` / `『』`の一括入力だけでなく、開閉が別々に届く通常入力を扱い、字下げの有無や文中位置にかかわらず空ペア内へキャレットを置く
- **R4**: IME変換中は一切介入せず、入力をそのまま許可して後続pluginも止める
- **R5**: IME確定後の`　「` / `　『` / `　「」` / `　『』`を対象に、行頭の全角スペースだけを正規置換で削除する。キャレットが開き括弧直後、括弧内、ペア直後の各経路を扱い、対応ペアではペア内へ移動する

UIKitのdelegate通知順をmacOSと同一とは仮定しない。`markedTextRange`が残った状態で確定入力がdelegateへ届く経路を実機で観測し、確定前のpending記録と、composition終了後に一度だけR5を適用するadapter状態として実装する。旧実装の「キャレット直前の1文字だけを見る」判定や、`textViewDidChange`のたびに無条件でR5を走らせる実装へ戻さない。

plugin置換はdelegateの正規変更経路を通し、選択、typing attributes、Undo / Redoを保つ。IME確定とR5後処理、開閉括弧が別々に届く経路、emoji前後のUTF-16 rangeを実`UITextView`統合testで固定する。

### 5.3 表示とスクロール

- 本文データへ改行や空白を加えず、本文末尾の下に96ptの表示専用執筆余白を確保する
- plugin置換、検索jump、括弧ペア内への移動後は、確定したキャレットを明示的に可視範囲へスクロールする
- software keyboard、hardware keyboard、safe area、端末回転でキャレットをkeyboard下へ残さない
- 表示設定の変更は本文を流し直さず、IME変換中ならcomposition終了後まで保留する

### 5.4 Editor chromeと執筆補助

- Editor上の重複した「本文」見出し、話タイトル入力、文字カウンターを外し、話タイトルはOutline／navigationの文脈を正とする
- 保存／同期状態は上部のnative toolbarに小さな記号一つで示し、下部status barや常設bannerを本文へ重ねない。チェックはpackageとjournalへの端末内保存完了、控えめな進行は同期中、小さなoffline表示は端末内保存済み、警告は変更の確認が必要、エラーはiCloud account／設定または端末内保存の確認が必要、を表す
- 状態の詳細は記号を選択したときだけ表示する。VoiceOverは「この端末に保存済み」「iCloudにも同期済み」「オフライン」「統合が必要」「同期設定を確認」を区別し、同期状態だけで本文操作を無効化しない
- Editor直下、software keyboard表示時はIME直上に、本文キャンバスと同じ不透明背景の執筆補助バーを置く
- `……` / `――`はselection replacement、`ルビ`はsheet確定後の`｜親文字《ルビ》`、`傍点`は非空selectionのgraphemeを`｜字《・》`へ変換する
- commandは`EditorCommandSession`からexact selection snapshotを取り、App側のBindingを直接変更せず、1回のUndo / Redoで往復できる
- IME変換中、pending command中、surface失効、作品／話のidentity不一致、stale snapshotでは置換しない。字下げ／鉤括弧のplugin pipelineへ4操作を追加しない

## 6. 適応UI

### 共通の情報階層

- 起動後はprivate CloudKit catalogと検証済みapp-private registryを1つの「iCloudの作品」として作品棚へ表示する。local／remoteの二重棚や内部package名は出さない
- Files / iCloud Drive / 他社File Providerは「作品を取り込む…」から標準pickerを開き、外部原本を変更せずnew WorkIDの作業コピーだけを作品棚へ加える
- remote-onlyはonline＋account確認後の明示tapでこの端末へ保存し、cached localはofflineでも開く。account未確認／mismatchではlocal packageのない旧scope row／titleを表示しない
- 作品を選ぶと作品ホームへ進み、実装済みの「作品情報」「執筆」「プロット」「登場人物」「世界観」「資料」「設定」「作品を書き出す」を提示する
- 「執筆」は章ごとに話を並べるOutlineへ進み、話を選んだときだけEditorを生成する。ほかの機能も一覧が必要ならOutlineから選択項目のDetailへ進む
- 読み込めない作業コピーはその行だけを警告状態にし、他の作品の利用を止めない
- 作品ホームへ出す項目は実際のdomain／Repository操作へ接続したものに限り、placeholderを出さない
- Device Syncは実際のentity送信／取得、dirty set、editor guardへ接続した状態だけを上部記号へ出し、単なるnetwork reachabilityを同期済みと見せない。同じentityが衝突した場合だけ、小さな警告からこの端末／iCloud／両方を別作品として残す、へ進める。cloud reviewを閉じてもEditorを止めない

### iPad

- 横幅が十分ならProject Sidebar / Outline / Detailの3列を基本とする。作品情報と設定だけはOutlineを持たない2列にする
- 幅が狭い場合は`NavigationSplitView`の標準collapseへ従う
- hardware keyboardの保存、検索、Undo / Redo等を標準commandへ接続する

### iPhone

- `NavigationStack`で作品棚 → 作品ホーム → 各機能のOutline → Detailへ進む。作品情報と設定は作品ホームから直接開く
- 本文編集中は本文を最優先し、章／話操作は戻る導線または明示menuへ置く
- navigation pop、scene非アクティブ化、作品切替の前にIME確定とsession検査を行う

両端末とも`loading`中や`recovery`中に編集可能なWorkbenchを生成しない。macOS固有のtoolbar、hover、Finder文言を機械的に移植せず、機能の意味とProduct Truthだけを共有する。

### 外観

- D-057により新規インストール時のiOS chromeはDarkを既定とする
- 作品棚または作品ホームの外観メニューから「システムに合わせる／ライト／ダーク」を選べる
- 表示設定から本文フォントを「ヒラギノ明朝／ヒラギノ角ゴ／システム」から選べる。選択はiOS端末内の表示設定として保持し、`.novelpkg`には保存しない
- フォント変更は同じ話の本文や`UITextView`を再生成せず表示属性だけへ反映し、IME変換中はcomposition終了後まで保留する
- `preferredColorScheme`へ写像するのはapp-privateな外観設定だけとし、本文キャンバス設定や`.novelpkg`を変更しない
- semantic color、system material、標準List／Formを使い、Lightへ切り替えても情報階層とコントラストを維持する

## 7. Clipboard prompt copy

既存のD-054と[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)をそのまま適用する。

- purposeは校正／アドバイス、scopeは本文の明示選択／1話／1章の6組合せだけ
- 本文selectionは`EditorKit`のselection command境界でIME確定済みのexact snapshotを取得する
- iOS固有実装はplain textを`UIPasteboard`へ書くadapterだけにし、prompt builderをUIKitへ依存させない
- 利用者のactivation時にsessionと対象IDを再検査し、clipboardへexact 1 writeする
- 成功／失敗表示へ本文、scope、文字数等を再掲せず、本文・モデル・`.novelpkg`・UserDefaultsを変更しない
- system clipboardは他アプリ、clipboard manager、Universal Clipboard等から読まれ得る共有境界であり、履歴非保持やsecure eraseを保証しない
- 文言は「校正用プロンプトをコピー」「アドバイス用プロンプトをコピー」とし、AI処理を実行済みに見せない

## 8. 実装PR順

1. **IOS-0 設計固定（完了）**: D-056、本書、DESIGNのPhase 7と完了条件を同期する
2. **IOS-1 Build Graph（実装済み）**: iOS 17 app / test target、Info.plist / UTType、通常5 productだけのlink、生成project検査、generic iOS buildを追加する
3. **IOS-2 Shared App Boundary（実装済み）**: 作品／保存／session処理と、file picker、lifecycle、first responder commit、clipboard等のadapter境界を分離する
4. **IOS-3 UITextView Adapter（実装済み）**: TextKit 2、所有権、selection、command session、R1' / R3 / R4 / R5、Undo / Redo、viewportを実装する
5. **IOS-4 Document MVP / Shell（実装済み）**: app-private新規／取込／保存／書出、Safe Launch / Recovery、iPhone / iPad navigationを接続する
6. **IOS-5 Clipboard Prompt（実装済み）**: 6種類のprompt copyとcontext / edit menu、VoiceOver / keyboard入口を接続する
7. **IOS-6 Parity / Release QA（進行中）**: D-058のプロット／伏線、登場人物、世界観、資料、設定、執筆補助commandと、D-063のiCloud作品棚／bootstrap／portable Exportはsource実装済み。D-063 focused 28 / 28件、Device Sync先行device cases 89 / 89件／fresh top-level 86 / 86件、hosted App 79 / 79件、generic build／build-for-testing、fresh local CIは通過済みで、残る完全round-trip、実機IME、アクセシビリティ、background／termination、性能を検証する

各PRは意味単位で小さく保ち、生成物をコミットしない。ローカル検証だけを使い、`Scripts/check.sh`へ段階的にiOS app build / test、target separation検査を追加する。

D-059／D-060のEpisode本文同期は、IOS-6と公開Release Gateを完了扱いにしない独立S1 trackとして進めた履歴である。D-059のportable wire v1、pure `NovelSync`、durable file journal、`NovelSyncCloudKit` adapter、editor／save／scene integration、明示binding、force／merge UIは基準commit `508947d2`でsource実装済み・全ローカル回帰通過の履歴として維持する。D-060は`NovelSync` 94 / 94件（local-first 33件、既存coordinator 18件）、`NovelSyncCloudKit` 48 / 48件、iOS Simulator Device Sync 42 / 42件（3 suites、20.544秒）、native focused 2 / 2件が通過した。native focusedではmarked IME確定からmodel／package／journal／WAL cleanupまでと、別writer下の実`UITextView`によるreplace／delete／Undo／Redo／paste／ルビ／傍点およびlease不変を確認した。完了報告は **source実装**、**Simulator／local fake server**、**署名済みMac＋iPhoneの実CloudKit** を分離し、paired native Mac↔iPhone、手動実機VoiceOver／process killを未実施として維持する。詳細は[DEVICE_SYNC.md](DEVICE_SYNC.md) 15章を正とする。D-059以前のbase targetが5 productであったこと、通常targetだけが`NovelSync` / `NovelSyncCloudKit`を追加し、Experimental targetへCloudKit adapterを入れないことをtarget graph検査で区別する。

D-061で現行通常iOS Appは別namespaceのwhole-work経路へcutoverした。iOS focused 56 / 56件（integration 49＋UI 7）とgeneric iOS build／build-for-testingが通過し、層別の詳細は[DEVICE_SYNC.md](DEVICE_SYNC.md) 0章を正とする。D-059／D-060の上記件数をD-061の証拠にはしない。Episode／Work mixed clientは相互観測できないため、開発CloudKit data resetと全test端末の同一D-061 buildを必須とする。production migrationまたはminimum client version fence、paired native、手動VoiceOver、実OS kill、signed real CloudKitを完了するまで出荷不可である。

D-063で作品棚／new-device bootstrapをMacだけの機能からApple版共通契約へ拡張した。iOS / iPadOSのsource実装は完了し、同じD-063 buildでfocused 28 / 28件、Device Sync先行device cases 89 / 89件／fresh top-level 86 / 86件、hosted App 79 / 79件、generic build／build-for-testing、fresh `./Scripts/check.sh`を通過したためlocal automated GOとする。Macの既存freezeやD-061 iOS件数は流用しない。

## 9. 受け入れ条件

### Build / Product Truth

- iPhone / iPad simulatorとgeneric iOS device向けにappとtestがbuildできる
- 通常iOS targetの`NovelAI`、Experimental source、AI provider SDK、Node / CLI / sidecar、AI provider用network / credential callsiteとresourceが0件である。Device Sync D-061のnetwork callsiteは`NovelSyncCloudKit`だけに閉じる
- 画面上にprovider設定、送信、生成中、応答、Apply等の未実装UIがない

### Document safety

- import中の原本を変更せず、失敗時も現在作品とrecentを別作品へ読み替えない
- macOS → iOS import / edit / export → macOSのround-tripで章／話順、本文、メモ、添付、snapshot、未知項目を失わない
- 保存失敗時にdirty状態を保持し、空作品へfallbackしない
- scene非アクティブ化、強制終了相当、最後の入力から2秒未満の各経路で確定本文を失わない
- app-private完成をopen-in-place／競合対応完成と誤表示しない
- 作品棚の行identityは`SyncWorkID`で一意になり、同じdocument ID／タイトル／構造を持つ複数importも別の作業コピーとして選べる
- hidden staging、非package、symlink、path traversalを作品棚とopen対象から除外する
- 破損した1作品を警告行へ隔離し、他作品の一覧・openを妨げない

### Device Sync D-061

- 作品タイトル／あらすじ、章・話構造／タイトル／順序、本文／メモ、人物、プロット、伏線、世界観が同じ`WorkSnapshot`として同期される。attachment／snapshot履歴／端末設定を同期済みと表示せず、D-063のcloud library／new-device bootstrap metadataをWorkSnapshotへ混ぜない
- network fetch／upload中も入力が止まらず、最初の変更をWork journalへstageし、package保存とexact confirmを終えてからremote処理を開始する
- 通信不能のまま編集、終了、再起動、再編集でき、日本語IME変換中の通信断／background／再接続でも確定本文を失わない
- paste、Undo、Redo、`……`、`――`、ルビ、傍点が同期状態に影響されず、実`UITextView`のmarked text、Undo、古いcallback、Editor世代で検証される
- expected head revision ID＋snapshot digest CASとmutation receiptでremoteを進め、非重複変更を作品全体で自動mergeする
- overlap、delete対edit／move／reorder、競合順序、祖先不明では完全な三者snapshotを保持し、この端末／iCloud／統合案の3面を示す。cloud review中の追加入力とremote進行を失わない
- remote callbackをactive `UITextView`へ注入せず、safe boundaryでpackageを保存・再読込してexact一致した場合だけmaterializationをacknowledgeする
- local recoveryが曖昧な場合は明示選択まで作品編集をgateし、通常のcloud conflict／network待ちではlocal編集を続ける
- upload中の追加入力をlocal tailとして保持し、古いresponseをobservation CASで拒否して次batchで追送する
- background移行は遅いCloudKitを待たずstage／package／journal confirmを完了し、process killの各境界からlocal／remote双方を復元できる
- account変更時は旧accountの本文を新accountへ送らず、account確認不能時もlocal編集／package／journalを継続する。旧account transportはlive scope再確認まで再開しない
- CloudKit bootstrap／entitlement確認が失敗しても既存bindingをlocal metadata／journalから復元し、remote descriptorなしでは送信せず、local package／WAL／journalを継続する
- 保存、同期中、offline、統合必要、同期設定確認を上部記号とVoiceOverで識別でき、同期状態だけで本文操作を無効化しない
- 明示binding候補をcloud library / package bootstrapと表示せず、資料、snapshot履歴、端末設定、live collaborationを同期済みと表示しない
- Episode／Work mixed clientを非対応とし、development data reset＋全test端末の同一buildを検証する。production migration／minimum-version fenceを別Decisionで実装するまで出荷しない
- development / production container、entitlement、profile、schema deployと、署名済みMac / iPhone実機を検証する。Simulatorと署名なしbuildだけで完了にしない
- app-private WAL／merge recovery rootは信頼済みancestorへanchorし、中間／最終symlinkと通常のroot identity差し替えをfail-closedにする。ただし同時にrenameする悪意あるsame-UID processへの完全耐性は主張せず、External Change / Conflict Gateを未完了として維持する

### Cloud library D-063

- root作品棚が1つの「iCloudの作品」になり、remote catalogとlocal registryをWorkIDだけでmergeする。path、package名、document ID、タイトル、構造をidentity／deduplicateへ使わない
- remote-onlyを明示tapした場合だけ、表示時headの再検査、pending-open先行保存、full revision read-back、same-root staging、no-overwrite install、bind、journal、registry markの順でこの端末へ保存する
- remote downloadの各checkpointとbind→registry mark間のprocess killからexact stateだけを冪等resumeし、既存finalが別内容なら上書きしない
- cached localはofflineで開ける。remote-onlyはoffline／account未確認で開かず、`accountRequired`／different accountではlocal packageのない旧scope row／title／pending-open identityを表示しない
- 新規／Files取込はaccount／network／catalog失敗中でもnew WorkIDのlocal packageを作って編集できる一方、remote publish authorityがない状態をupload可能と扱わない
- same-scope offline pendingだけを元scope復帰後に再開し、unscoped local-onlyやaccount-quarantined dataを新accountへautomatic adopt／rebind／uploadしない
- available catalogからacknowledged workが欠落した場合は`.cloudUnavailable`としてcheckmark／open／uploadを止め、local packageを保持する
- exact package attestationとaccount-scoped remote receipt／head一致時だけ「iCloudと同期済み」を表示し、network online、同名row、upload開始だけではcheckmarkを出さない
- D-063以前のiOS private packageは自動移行／削除せず、明示tapでnew WorkIDへ検証済みcopyし、new copy確定後も旧bytesを`legacyPreserved`として保持する
- cold Files / Open Withを`.checking`中に失わず、bootstrap完了後のImportへ直列化する。作品ホームから棚へ戻ってもactive package／WorkIDを変更しない
- `.novelpkg`書出はcurrent sessionをflushして検証済みpackage全体copyを作り、destination read-back後もactive URL／session／WorkID／binding／journal／selectionを変更しない
- remote bootstrapが同期するのはWorkSnapshotだけであり、attachment／snapshot履歴／unknown root／端末設定を完全backup／復元済みと表示しない
- library／registry／journal／packageの利用者向けerrorとdiagnostic logへapp-private path／WorkIDを出さない
- current iOS extensionのfocused 28 / 28件、Device Sync先行device cases 89 / 89件／fresh top-level 86 / 86件、hosted App 79 / 79件、generic build／build-for-testing、fresh `./Scripts/check.sh`を現行証跡として固定する。既存Mac／D-061件数を現行差分の証拠へ流用しない

### Editor

- 実`UITextView`で日本語IME変換中に本文の巻き戻りがなく、確定後だけモデルへ通知する
- R1'、R3、R4、D-055拡張後のR5を、直接入力、一括ペア、開閉別入力、IME確定、emoji前後で満たす
- plugin置換とIME後処理がUndo / Redo可能で、話切替後に別話のundo履歴を適用しない
- 末尾96pt余白とscrollは表示だけを変え、保存本文、文字数、検索、exportを変えない
- Editor上部に保存状態があり、重複した本文見出し／話タイトル入力／文字カウンターがない
- `……` / `――` / `ルビ` / `傍点`がselection snapshotから正しいUTF-16置換を行い、各操作をUndo / Redoできる
- 執筆補助バーは本文キャンバスと連続し、software keyboard表示時にIME直上から操作できる
- 本文フォント設定が端末内へ永続化され、同じ話の本文、選択、Undo履歴を流し直さず反映される。IME変換中の変更は確定後にだけ反映される

### Clipboard / Accessibility

- 2 purpose × 3 scope、Unicode／改行／空白、空選択／IME／session切替／surface失効を検証する
- clipboardへのexact 1 write以外に本文を外部へ出さず、失敗時も原稿を変更しない
- VoiceOver、Dynamic Type、software / hardware keyboardで同じ主要操作へ到達できる
- 作品棚→作品ホーム→Outline→Editorの順序をVoiceOverで理解でき、行のタイトルと章／話／文字数を読み分けられる
- System／Light／Darkの各外観、Increase Contrast、Reduce Transparencyで作品棚と作品ホームを判読できる
- プロット／伏線、登場人物、世界観、資料、設定の一覧／追加／編集／削除へVoiceOverとDynamic Typeで到達できる

## 10. Phase 7 MVP完了の定義

IOS-1〜5とD-063 iOS extensionが実装され、上記のBuild、Document safety、Cloud library、Editor、Clipboard / Accessibility条件をiPhone / iPad実機を含むローカル検証で満たした時点をPhase 7 MVP完了とする。Device Sync D-061、Cloud library D-063、IOS-6の機能parity、Package Validator / External Change / Conflict / 配布Gateはそれぞれ別に追跡し、いずれか一つの完了を他の完了へ読み替えない。MVP完了だけでiOS一般公開準備完了とは表現しない。
