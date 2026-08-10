# FUMINIWA iOS / iPadOS Phase 7 実装計画

> **状態**: IOS-1〜5実装済み。D-057の作品棚-first導線とD-058の作品機能／執筆補助parityを追加。D-059は`NovelSync`／file journal／durable pending create / bind intentを含む`NovelSyncCloudKit` adapterをsource実装し、iOS Appのproduction composition、明示binding、editor／scene、force／merge UIもsource接続済み・全ローカル回帰通過。通常handoffの完結、Accessibility、CloudKit外部Gate、署名済み実機、Release QAは未完了
>
> **対象**: iOS / iPadOS 17 以降
>
> **正とする上位契約**: [DESIGN.md](DESIGN.md)、[DECISIONS.md](DECISIONS.md)、[DEVICE_SYNC.md](DEVICE_SYNC.md)、[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)

## 1. 目的

macOS版で確立した`NovelCore`、`.novelpkg` v3、`NovelExport`、EditorPluginの純粋ロジックを再利用し、iPhone / iPadで安全に日本語小説を執筆できる通常版FUMINIWAを追加する。

Phase 7はmacOS UIの縮小移植ではない。作品・保存・本文編集の意味は共有しつつ、iPadでは複数列、iPhoneでは段階遷移という各端末に適したシェルを作る。最初の製品境界は、外部の`.novelpkg`をアプリ専用領域へ取り込み、その作業コピーを編集・保存し、利用者の明示操作で外部へ書き出す **app-private import / edit / export** とする。D-059のDevice Syncも外部原本を直接編集せず、app-private packageへ話本文revisionをmaterializeする別protocolとして追加する。

AI providerは接続しない。利用者が選んだ原稿から校正用／アドバイス用のplain text promptを作り、system clipboardへ明示コピーする機能だけを通常iOS版へ含める。

### 1.1 現在地（2026-08-11）

- `FUMINIWAIOS` app / test target、iPhone / iPad対応Info.plist、D-059以前のbase 5 productだけの依存境界を実装した。現在の通常targetはDevice Sync用の`NovelSync` / `NovelSyncCloudKit`を追加している
- app-privateな新規作成／取込／revision保存／書出、Loading / Ready / Recovery、適応的な`NavigationSplitView`を実装した
- app-private作業コピーを再選択できる作品棚と、作品ホーム→作品情報／執筆→Outline→Editorの段階導線をD-057で追加した
- プロット／伏線、登場人物、世界観、資料、設定を既存domainと保存へ接続し、作品ホームとiPad Project Sidebarから選べるようにした
- `UITextView` + TextKit 2 adapterを追加し、共有`IndentRules`とD-055後のR1' / R3 / R4 / R5、IME pending確定、Undo / Redo、末尾96pt表示余白、caret revealを接続した
- iOS Editorの保存状態を上部へ移し、本文キャンバスと同じ背景のIME直上バーから`……` / `――` / `ルビ` / `傍点`をselection commandとして実行できるようにした
- 校正／アドバイス×本文選択／話／章のclipboard prompt copyを実装し、通常iOS targetに`NovelAI`、provider、network、credential、subprocessを入れていない
- generic iOS build、iPhone Simulator上のEditorKit／iOS app tests、target separation検査を`Scripts/check.sh`へ組み込み、全ローカルCIを通過した
- D-059のportable wire / state / force / merge、package外file journal、`NovelSyncCloudKit`のprivate CloudKit adapter、account fence、engine state recovery、local metadata bootstrap、durable pending create / bind intentをsource実装した。iOS production composition、明示binding、editor／scene lifecycle、read-only／force／fence／merge UIもsource接続済みで、iOS通常71件／Device Sync 15件を含む全ローカル回帰を通過した。normal handoffの全経路、container / signing / schemaと署名済み実機検証は未完了である

IOS-1〜5のコード実装は完了している。ただし、本書の完了条件に含むiPhone / iPad実機の日本語IME、VoiceOver / Dynamic Type、hardware keyboard、scene／termination、macOSとの完全round-tripは未検証であるため、Phase 7 MVPまたは一般公開準備の完了とはまだ扱わない。次はIOS-6 Parity / Release QAとして追跡する。

## 2. 製品スコープ

### 2.1 Phase 7 MVP

- iOS / iPadOS 17以降を対象にした単一の通常app targetを追加する
- 新規作品をアプリ専用領域へ作成し、同領域の作業コピーを自動保存する
- アプリ専用領域の複数の作業コピーを作品棚へ一覧表示し、選択した1作品を安全に開く
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
- 複数作品の同時編集、Device Sync S1を超える作品cloud library / package bootstrap／構造／補助data／資料同期、共同編集
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

app-private MVPの完成をopen-in-place、iCloud Drive原本同期、File Provider競合対応、またはD-059のDevice Sync完成とは表現しない。Device Sync S1が完了しても外部原本open-in-placeのGateは別に残る。

### 4.5 資料

- 資料一覧は現在のapp-private作業コピーに対して`AttachmentManaging`から取得し、App層でpackage内部pathを組み立てない
- 取り込み前に最新本文を同じ保存直列化経路で確定し、外部URLのsecurity-scoped access中だけRepositoryへ複製を依頼する
- 一覧、削除確認、共有は表示時の作品identityと資料IDを保持し、待機中に作品が変わった操作を別作品へ適用しない
- 外部原本の資料を直接編集したり、任意の外部path／bookmarkをpackageへ保存したりしない

### 4.6 Device Sync S1

Device Syncはapp-private package同士を対象とし、iCloud Drive上の原本やpackage内部を直接同期しない。iPhoneで同じ話を開くときは、remote `EpisodeControl`のholder / session / epochを確認し、writerでなければ本文をread-onlyにする。

通常handoffは次の順序を崩さない。

1. iPhoneが最新head / epochをfetchしてhandoffを要求する
2. 旧writerがIMEをcommitし、native editorの全文をcaptureする
3. 旧writerがapp-private packageとpackage外journalへlocal saveする
4. pending本文をmutationID / expected head / lease epochでremote flushする
5. flush確認後にだけiPhoneのfresh sessionへgrantし、epochを増やす
6. iPhoneがgrant後のheadをfetch / verifyし、packageへ保存してから`UITextView`へinstallする
7. remote install時にその話のUndo / Redoを破棄し、新しいbaselineからwriterを開始する

旧writerが応答しない場合、iPhoneは未同期本文が別端末に残る可能性を示してから「強制的に続ける」を実行できる。forceはonlineで最新controlをfetchし、remote CASでepochをexactly 1増やす。通信不能、fetch失敗、CAS競合時はread-onlyを維持し、成功後も最新remote headをinstallするまでwriterにしない。旧writerの本文は再接続時にfenceしてbase / local / remote forkとしてpackage外journalへ保全し、時計LWWで上書きしない。offline forkは通信断前にauthorityを持っていたwriter、またはforceをまだ観測していない旧writerの継続本文だけを指し、非holderのiPhoneがofflineで開始する編集modeにはしない。

S1は、初回binding時にordered ChapterID / EpisodeIDの構造digestが一致し、binding snapshotへ含めたepisode bodyだけを扱う。Apple adapterが示せるのはexact structure一致で絞った **明示binding候補** であり、作品棚のcloud library、package download、automatic bindingではない。後から追加した話はlocal-onlyとし、既存対象話だけを継続する。章／話構造、タイトル、作品情報、メモ、人物、プロット、伏線、世界観、資料、snapshot、attachmentを同期済みと見せない。Product Truth、merge、offline、security / privacyの詳細は[DEVICE_SYNC.md](DEVICE_SYNC.md)を正とする。

## 5. iOS本文エディタ契約

### 5.1 TextKit 2とテキスト所有権

- `UITextView`はTextKit 2を明示的に使う構築経路で生成し、`layoutManager`へ触れてTextKit 1へfallbackさせない
- 公開`EditorView` APIに`UITextView`を出さない
- 編集中本文の正は`UITextView`側とし、SwiftUI更新から本文を流し直さない
- モデル→Viewの本文反映はepisode keyが変わったときだけ行う
- `markedTextRange != nil`の間はモデル通知、plugin介入、表示属性の再適用を行わない
- 作品遷移前は旧作品のIMEを確定し、確定本文を旧sessionへ同期できなければ遷移を開始しない
- handoff / force / remote changeでも`markedTextRange != nil`の間は外部本文を書き込まず、pending remoteとして保持する。確定後にnative全文をcaptureしてpackage / journalへ保存してからfenceまたはinstallする
- remote headのinstallは明示的なexternal replacement境界だけで行い、その話のUndo / Redo historyを破棄する。別remote baselineへ旧transactionを適用しない

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
- 保存チェック／保存状態は上部のnative toolbarへ移し、下部status barを本文へ重ねない
- Editor直下、software keyboard表示時はIME直上に、本文キャンバスと同じ不透明背景の執筆補助バーを置く
- `……` / `――`はselection replacement、`ルビ`はsheet確定後の`｜親文字《ルビ》`、`傍点`は非空selectionのgraphemeを`｜字《・》`へ変換する
- commandは`EditorCommandSession`からexact selection snapshotを取り、App側のBindingを直接変更せず、1回のUndo / Redoで往復できる
- IME変換中、pending command中、surface失効、作品／話のidentity不一致、stale snapshotでは置換しない。字下げ／鉤括弧のplugin pipelineへ4操作を追加しない

## 6. 適応UI

### 共通の情報階層

- 起動後はapp-private作業コピーを「このデバイスの作品」として作品棚へ表示する
- Files / iCloud Drive / 他社File Providerは「取り込む…」から標準pickerを開き、選択後の作業コピーだけを作品棚へ加える
- 作品を選ぶと作品ホームへ進み、実装済みの「作品情報」「執筆」「プロット」「登場人物」「世界観」「資料」「設定」「作品を書き出す」を提示する
- 「執筆」は章ごとに話を並べるOutlineへ進み、話を選んだときだけEditorを生成する。ほかの機能も一覧が必要ならOutlineから選択項目のDetailへ進む
- 読み込めない作業コピーはその行だけを警告状態にし、他の作品の利用を止めない
- 作品ホームへ出す項目は実際のdomain／Repository操作へ接続したものに限り、placeholderを出さない
- Device Syncの状態／handoff／force／merge操作も実際の`NovelSyncCloudKit`、journal、editor fencingまで接続した段階だけ出す。「この端末に保存」「送信待ち」「同期済み」「別端末で編集中」を区別し、単なるnetwork reachabilityを同期済みと見せない

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
7. **IOS-6 Parity / Release QA（進行中）**: D-058のプロット／伏線、登場人物、世界観、資料、設定、執筆補助commandは実装済み。残るmacOS機能、完全round-trip、実機IME、アクセシビリティ、background／termination、性能を検証する

各PRは意味単位で小さく保ち、生成物をコミットしない。ローカル検証だけを使い、`Scripts/check.sh`へ段階的にiOS app build / test、target separation検査を追加する。

Device SyncはIOS-6と公開Release Gateを完了扱いにしない独立S1 trackとして進める。portable contract / fixture、pure `NovelSync`、durable file journal、durable pending create / bind intentを含む`NovelSyncCloudKit` adapterはsource実装済みで、editor / save / scene integration、明示binding、iPhone force / merge UIもAppへsource接続済み・全ローカル回帰通過である。normal handoffの全経路、外部設定・署名済み実機QAは未完了であり、詳細なチェック進捗は[DEVICE_SYNC.md](DEVICE_SYNC.md) 15章を正とする。D-059以前のbase targetが5 productであったこと、通常targetだけが`NovelSync` / `NovelSyncCloudKit`を追加し、Experimental targetへCloudKit adapterを入れないことをtarget graph検査で区別する。

## 9. 受け入れ条件

### Build / Product Truth

- iPhone / iPad simulatorとgeneric iOS device向けにappとtestがbuildできる
- 通常iOS targetの`NovelAI`、Experimental source、AI provider SDK、Node / CLI / sidecar、AI provider用network / credential callsiteとresourceが0件である。Device Sync S1のnetwork callsiteは`NovelSyncCloudKit`だけに閉じる
- 画面上にprovider設定、送信、生成中、応答、Apply等の未実装UIがない

### Document safety

- import中の原本を変更せず、失敗時も現在作品とrecentを別作品へ読み替えない
- macOS → iOS import / edit / export → macOSのround-tripで章／話順、本文、メモ、添付、snapshot、未知項目を失わない
- 保存失敗時にdirty状態を保持し、空作品へfallbackしない
- scene非アクティブ化、強制終了相当、最後の入力から2秒未満の各経路で確定本文を失わない
- app-private完成をopen-in-place／競合対応完成と誤表示しない
- 作品棚の行identityはpackage名で一意になり、同じdocument IDを持つ複数importも別の作業コピーとして選べる
- hidden staging、非package、symlink、path traversalを作品棚とopen対象から除外する
- 破損した1作品を警告行へ隔離し、他作品の一覧・openを妨げない

### Device Sync S1

- 同じ話はremote holder / session / epochと一致する1端末だけがwriterになり、他端末はread-onlyになる
- 通常handoffがIME commit / capture / local save / remote flush / grant / fetch / installの順で完了し、途中失敗で新端末へ書込権を渡さない
- iPhone forceと旧Mac publishのraceでremote CASが一方だけを成立させ、旧epoch本文をbase / local / remote forkとしてpackage外journalへ残す
- non-overlapを証明できる場合だけauto mergeし、overlapのmanual / keep local / keep remoteがすべて2-parent merge revisionを作る
- marked text中にremote installせず、確定後のcapture / durable saveを完了してからinstallし、その話のUndo / Redoを破棄する
- offline、push欠落、app kill、account switch、mutation応答消失から再開してもlocal / remoteのどちらも黙って失わない
- 明示binding候補をcloud library / package bootstrapと表示せず、構造、補助data、資料、live collaborationを同期済みと表示しない
- development / production container、entitlement、profile、schema deployと、署名済みMac / iPhone実機を検証する。Simulatorと署名なしbuildだけで完了にしない

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

IOS-1〜5が実装され、上記のBuild、Document safety、Editor、Clipboard / Accessibility条件をiPhone / iPad実機を含むローカル検証で満たした時点をPhase 7 MVP完了とする。Device Sync S1の受け入れ条件、IOS-6の機能parity、Package Validator / External Change / Conflict / 配布Gateはそれぞれ別に追跡し、いずれか一つの完了を他の完了へ読み替えない。MVP完了だけでiOS一般公開準備完了とは表現しない。
