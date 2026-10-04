# 現在の設計決定

現行の制約をまとめる。IDはコードからの参照を保つために残す。置換済みの全文・実験・時系列はGit履歴にあり、現行の実装指示には使わない。

## 編集・保存・互換

| ID | 現在の決定 |
| --- | --- |
| D-001 / D-005 / D-006 | SwiftUI＋platform adapter、EditorKitが本文を所有。TextKit 2、IME中のモデル反映・plugin介入禁止、公開APIへtext viewを出さない |
| D-002 / D-003 / D-018 / D-036 / D-090 | `.novelpkg`は明示Import / Exportの互換形式。通常保存の正本ではない。内部配置・format versionはNovelStorageと[互換契約](CROSS_PLATFORM.md) |
| D-004 / D-028 | Chapter→Episode、順序は配列だけ。本文・話メモはEpisodeへ置く |
| D-009 / D-010 | portable repositoryはURL＋async。アプリが作品選択を管理し、DocumentGroupを使わない |
| D-016 / D-017 / D-023 / D-026 | 通常保存・履歴はSQLite。作品を切り替える前に保存し、復元は現在の編集を保全してから行う |
| D-022 / D-027 / D-037 | 原稿出力は独立module。TXT / Markdown / EPUB 3。PDF未実装。代表データで性能を確認する。[出力](EXPORT.md) |
| D-030 / D-033 / D-034 / D-055 | 明示置換はEditor command。字下げと鉤括弧処理はIME確定を守る。傍点は`｜字《・》`。末尾余白は表示専用 |
| D-031 | あらすじはadditive metadata。企画という独立機能は置かない |
| D-038 | 製品名はふみにわ／FUMINIWA。packageと必要な既存設定の読取互換を維持する |
| D-039 / D-041 | Loading / Ready / Recovery、読込失敗を空作品に置換しない。IME確定→保存→install、WorkID/session/account/gateを完了時にも照合 |
| D-064 / D-080 | 前景編集・local durability・remote workerを分離。端末SQLiteを唯一の正本とし、Snapshot Sync v2だけを通常同期へ使う |
| D-084 | account transitionをowner付きで停止・保存・再計画する。古い非同期完了を別accountへ適用しない |
| D-091 | 明示同期は最新checkpointの送受信確認まで要求する。保存だけを同期完了と表示しない |
| D-092 | 同期作品の削除は一覧から隠しserver graphを1暦年保管する。端末の未送信checkpointは救出用に保持し、新IDのローカル作品へ取り出せる。未同期作品は従来の削除。削除前のIME確定と保存を守る |
| D-093 | 初回同期は検証済み履歴の最新checkpointを公開し、古い履歴の途中をheadにしない |

## 画面・AI

| ID | 現在の決定 |
| --- | --- |
| D-019〜D-021 / D-024 / D-029 / D-032 / D-035 / D-040 / D-044 / D-045 / D-057 | 実装済み操作だけを表示する。[STYLE](STYLE.md)、[TOOLBAR](TOOLBAR.md)、[IOS](IOS.md)が現在の画面規約 |
| D-025 | 別名保存はCmd+Shift+S、明示snapshotはCmd+Option+S。保存先とscopeを明確にする |
| D-062 / D-066〜D-068 / D-070 | 作品選択から開始する。macOSはAIが右、プロットカードが本文下。プロット編集の右下に伏線。toolbarのカスタマイズ所有は一箇所 |
| D-089 | 校正は現在の1話、感想は選択した話を全文preview後に明示送信する。旧アドバイスはD-098の会話へ移行。HTTP・キー・設定を本文保存から分離。[AI支援](WRITING_ASSISTANT.md) |
| D-098 | 会話・共通と作品別の指示を本文とは独立して同期。依頼ごとの指定範囲へ直接編集し、変更記録から取り消せる。MacのMCPは初回登録した接続を信頼し、申告範囲を機械的に制限する |
| D-094 | 原稿コピーは明示scopeのplain text。AI向け指示を付けない |

## 認証・運用・開発

| ID | 現在の決定 |
| --- | --- |
| D-007 / D-008 / D-013 / D-015 / D-056 / D-058 | macOS 14 / iOS 17、Swift 6、NovelKit。XcodeGenの`project.yml`がprojectの正本 |
| D-011 / D-014 | 直接配布を前提とし、検証はローカル。GitHub Actionsを導入しない。署名・公開の完了は別途確認する |
| D-012 | 縦書きは未対応 |
| D-042 | 通常の開発依頼は実装・品質改善。価格・法務・販促は明示依頼の範囲。必要なデプロイは対象・backup・反映後を確認して進める |
| D-114 | 話ごとの本文履歴と単話復元を共有層に実装し、復元前checkpointは手動保存として記録する |
| D-111 | 共通App層をNovelWorkspace／NovelWorkspaceUIへ段階移設し、両OSの意味差は明示判断して統合する |
| D-115 | 認証のaccount transitionをiOSモデルの共通Coordinatorへ統合し、12差分を明示解決する |
| D-076 | 責務別の構造、Swift 6境界、swift-testing。Swift sourceは400行で確認、600行で警告、800行超は分割する |
| D-078 | 現行Auth v1はApple-only、opaque AccountID/session/Fence。内容保護はserverReadableV1、E2EEではない。[AUTH](AUTH.md) |
| D-081〜D-083 / D-085 | PostgreSQLの初期化・bootstrap・migration owner・runtimeを分離。runtimeにDDLを与えず、sequenceはUSAGEのみ。既存migrationと対象識別を保つ |
| D-086 | 検証なし／軽い／中ぐらい／重たいを影響で選ぶ。利用者の明示指定を優先し、マージだけでは段階を上げない |
| D-087 / D-096 | 現行Auth v1はApple以外の回復なし。明示削除予約から720時間、期限前の取消、猶予中の通常利用。remote消去のmarkerはatomic、削除完了はApple失効成功後。[自動運用](ACCOUNT_RETENTION_OPERATIONS.md) |
| D-088 | Windows 11、WinUI 3＋C#/.NET、MSI等のinstallerを計画。Windows実装は未完了 |
| D-095 | 添付250 MiB、8 MiB分割。自宅サーバーで再構成・digest確認。Cloudflare有料サービスを暗黙に追加しない |
| D-096 | 日次暗号化backupを作成から1暦年保持。2/29は翌年2/28。新backup成功後だけ期限切れを整理する |
| D-097 | 現行のコード・契約・運用に集約。廃止実装と過去資料はGit履歴へ移し、旧同期専用の検証を通常checkから外す。DB migration・現行Auth v1・互換fixture・原稿は保持する |

D-043、D-046〜D-054、D-059〜D-061、D-063、D-065、D-069、D-071〜D-075、D-077、D-079の旧provider・旧同期・置換作業は完了または廃止済み。必要な編集安全・local-first原則は上表の現行境界へ集約している。

名称のv2表記とXcodeBuildMCPの利用方針は[OWNER_DECISIONS](OWNER_DECISIONS.md)。新しい番号を付けるためだけに、既決事項や作業記録を増やさない。


## D-098: AI会話・指示の独立同期と依頼単位の編集（2026-09-26）

[原稿保全・AI計画](PROTECTION_AI_PLAN.md)の採択事項を実装する。本文snapshotとAI記録の同期を分離し、共通・作品プロンプトはrevision比較で競合を残す。端末AI SQLiteは本文保存を成立させる条件にしない。チャットの明示送信と依頼ごとの編集範囲を守り、EditorKitのIME/Undoとwork/session/accountを保持する。MCPは初回登録した外部clientを信頼するMac上のloopback接続とし、同じ編集サービスを使う。[契約](sync/v2/assistant.md)にwire・機械的範囲制限・中断・復元・削除を定義した。ローカル検証・稼働反映・実端末受入の結果は作業の証跡へ別記する。

## D-099: Mac DMG配布と認証方法（2026-09-27）

協力者に直接渡すMac版はDeveloper ID署名・公証済みDMGとし、同期を維持する。Developer IDで使えないnative Sign in with Appleに代えて、Mac配布版はブラウザ経由のApple認証を使い、Google認証も追加する。1つのFUMINIWA AccountIDはAppleかGoogleの片方だけで認証し、メール一致による統合とprovider連携は行わない。現行Auth v1のnative clientは実装が置き換わるまで維持する。詳細と未完了の受入は[Mac DMG配布](MAC_DMG_DISTRIBUTION.md)に記す。

## D-100: iOSのGoogleログイン（2026-09-27）

iPhone / iPadにもGoogleログインを追加する。GoogleはMacと同じサーバー上のブラウザ認証をシステムブラウザで使い、同じGoogle identityを同じFUMINIWA AccountIDへ対応させる。iOSのAppleログインは現行native flowを維持する。両provider間の連携・自動統合は行わず、account切替時は既存の端末作品保全を通す。[Auth v2](auth/v2/README.md)に共通契約を記す。

## D-101: 初回取り込みの一括読取（2026-10-01）

履歴が多い作品の初回取り込みは、Snapshot Sync v2の読取専用ページでmanifestと重複排除した小さなobjectをまとめて取得する。履歴の件数制限や削除で速くせず、既存のdigest・graph・Inbox・編集境界の検証を維持する。ページは取得開始時のSnapshot IDへ固定し、account/fence/workに束縛する。旧serverは初回404/405に限り既存の個別読取へ戻る。DB schema、保存方式、通常編集を変更しない。[一括読取契約](sync/v2/download.md)に上限と互換境界を定める。

## D-102: remote-only初回取り込みを単一transactionで確定（2026-10-01）

未取得作品（work行なし、またはgeneration 0・current NULL）でeditor session・conflict・未処理intentがない場合、graphの全文検証後、単一のBEGIN IMMEDIATEで全履歴とcurrentをinstallする。COMMIT前の中断・失敗は全体をrollbackする。COMMIT後の取消し・account変更では表示を拒否し、元のbindingに属する完成済み作品を保持する。digest・graph・anchor・scope・CASの検証を維持し、通常同期と競合解決は永続Inboxのstage/verify/adoptを継続する。既存の未完了Inboxと履歴・証跡は削除しない。SQLite schemaとv2名称は変更しない。


## D-103: 自動保存は端末内の葉、公開時点だけ登録（2026-10-01）

利用者が[同期レビュー D-01](SYNC_REVIEW.md#判断結果2026-10-01利用者)を採用した。2秒ごとの自動保存は直前の昇格済みcheckpointを親とする端末内の葉とし、SQLiteで本文・current・履歴を確定するが同期intentは作らない。別端末へ見せる履歴は公開時点単位になる。1作品で約1日に1,467世代（自動保存1,465件）の線形履歴が増えていたため、初回取り込み、祖先判定、通信往復の増加を抑える。

明示保存、画面・作品切替、終了・background、明示同期、最終変更から60秒の待機、連続編集の5分上限で最新の葉を昇格する。起動・openでは中断時の葉を回収する。remote headの変化を照合する経路と同じaccountの再計画も、送信する葉を先に保護する。昇格は既存snapshotの保護付き履歴とintentを同一transactionで確定し、本文をeditorへ再installしない。タイマーは両OS共通の定数と差替え可能な時計を使う。

新しい葉だけをhistory occurrenceの`reason=autosaveLeaf, pinned=0`で区別する。昇格時は同じsnapshotへ`promotion`（または保護理由）のpinned occurrenceを追加する。旧`autosave`、取り込み済みhead、復元・競合解決は従来の安定点として扱うため、SQLite schemaの追加・移行、wire、server変更は不要。旧履歴と未採用の葉は削除・書換えしない。復元・競合の3択、WorkID/session/account/IME境界とpublish CASを維持する。具体的な規範は[§4](SNAPSHOT_SYNC_V2.md#4-snapshot-and-checkpoint-schema)と[state machine](sync/v2/state-machine.md)。

## D-104: サムネイル（作品・人物・世界観）（2026-10-01）

作品の表紙・人物・WorldNoteだけに設定する。表紙は2:3、人物は円、世界観は角丸正方形。縮小・切り抜き・sRGB再描画済みJPEGだけを予約名attachmentとして保存し、元画像・EXIF・GPSを保持しない。上限は表紙1024 px／他768 px、200 KiB。所有者との紐付けはUUID入りの名前で行い、NovelCoreモデル・wire・schema・package形式を変えない。owner削除と画像削除を同一checkpointへまとめ、既存の孤立画像は通常資料として残す。アプリ内AIへは公開せず、MCPの通常添付書き戻しでも除外画像を保全する。削除は確認後に行い、復旧は作品履歴を使う。[契約](sync/v2/thumbnails.md)に詳細を定める。

2026-10-03: MCPに限り読取・設定・取消を許可。アプリ内AIへは渡さない。専用ツールだけで扱い、通常の`edit_work`から予約画像に触れることは引き続き拒否する。保存形式・予約名・寸法・同期契約は不変。

## D-105: 取り込み総量の明示要求と手動の端末取り込み（2026-10-02）

U-05・U-10の利用者判断に従い、初回downloadに`include=totals`を付けた場合だけ総件数・raw byte総量を返す。閉じたkey集合を検証する旧clientには既存応答を維持する。旧serverの400/404/405（旧実装のschemaViolation/422を含む）では総量指定なしで一度再要求し、総量不明の取り込みも継続する。詳細は[download契約](sync/v2/download.md)。schema・fixture・server/clientを同時に更新し、SQLite schemaは変更しない。

棚に受信・確認・保存・開くの進捗、中止、作品別の失敗・再試行を表示する。「この端末に取り込む」は手動だけとし、開く処理と作品単位で合流するがeditorは開かない。取消しの境界はD-102のまま維持し、COMMIT済み作品を取消しのために削除しない。

## D-106: head-first openと履歴backfill（2026-10-02、実装済み）

状態: owner承認済みの[設計](sync/v2/shallow-history-design.md)に基づくStep 1〜3を実装済み。server契約、clientのhead install・履歴backfill、優先取得・復元導線・競合待機表示を含む。実機受入・稼働反映は別段階とする。[検証範囲と制約](sync/v2/shallow-history-verification.md)を参照する。

未取得作品を開くときは、固定した最新snapshot Hのmanifestと参照objectを先に取得し、検証・端末保存後にeditorを開く。H以前の履歴は同じHに固定してbackgroundで補完する。履歴を削除・間引きせず、v2名称、digest・graph・anchor・scope・CAS検証、ローカルで完結する編集・自動保存・IME・Undo・終了、WorkID/session/account/generationの境界を維持する。失敗時は原稿と未送信intentを保持する。

Step 1では`mode=head`と`mode=backfill`を追加した。[download契約](sync/v2/download.md#head-first-and-backfill-d-106)に、最長深さの降順で子を親より先に送る順序、snapshot単位のobject→manifestグループ、Hと先行グループに対する重複排除、2種のcursorと安全な再開位置、mode別の明示要求totalsを定める。backfillは専用1 permitで制限し、飽和時は503＋Retry-After。30秒cacheには不変metadataだけを置き、各ページのDB可視性・所有権・利用可能状態を再確認する。`mode`なしのD-101/D-105応答bytesと`/v2/capabilities`は変えない。server DB schemaの変更はない。

Step 2ではSQLiteへappend-only migrationで`shallow_boundaries`と`history_backfills`を追加する。各manifestの親は既存parent辺かboundaryのどちらか一方に必ず存在し、boundaryは検証済みのserver由来snapshotだけに作る。親の到着時には同一transactionで辺へ置換する。HのinstallはD-102の単一transaction・generation 0/current NULL CAS・binding再照合を維持する。backfillもdigest・entity・document anchor・Hへの祖先証明を検証し、保存とresume cursorを同一transactionで確定する。部分履歴を「共通祖先なし」と誤認せず、深い祖先が必要な操作は`historyIncomplete`で待機する。通常編集・公開、取得済み履歴のpreview/restore、exportは継続する。旧serverの初回400/404/405/422ではmodeなしへ一度戻り、D-101/D-102の完全取り込みを行う。

Step 2で作品別／全体1本のworker、constrained networkでの停止、再起動再開、履歴項目ごとの取得状態を追加した。Step 3で「オンラインで取得」、未取得版の復元・深いmerge/競合の優先取得、停止理由の表示を実装した。優先要求は全体1本の取得レーンの先頭へ移し、他作品の取得は保存済みcursorから再開する。Inboxとsealed commandを保持し、祖先のcommit通知で通常のworkerを再実行する。未取得版の復元待ちはeditor gateを保持せず、到着後に明示確認して通常のローカル復元へ進む。通信中断は再試行でき、検証エラーは自動再試行せず、識別子や内部エラーを出さない詳細を表示する。offline・Low Data Mode・constrained・expensiveでは自動取得を停止する。従量接続の明示確認は取得要求ごとに扱い、offlineで解除する。通常回線での手動開始だけでは従量接続の許可としない。対象は利用者が開いた／明示取り込みした作品だけとする（U-10）。同じHから再開し、新しいheadは通常Inboxで受ける。同一accountのfence変更ではcursorを捨てて再検証、別accountではpark、削除・認証失効ではsuspendして端末原稿を残す。両OSの履歴・棚は共通の状態と文言を使い、状態変更と取得後の復元可能状態をアクセシビリティへ通知する。

2026-10-04: 公開ごとの端末名をヘッダで任意送信、opt-inで返す。history occurrenceに保存し、canonical bytesとsnapshot IDを変えない。既定は端末種類、変更は端末内だけ。詳細は[wire契約](sync/v2/wire.md#保存した端末名2026-10-04)。

## D-107: 旧unexpected隔離の一度だけの自動復旧（2026-10-02）

HTTP edge応答の旧分類で止まったコマンドは、既存の追加型SQLite migrationで`legacy_command_recovery`へ候補を記録する。更新時に存在し、`command:unexpected`かつ応答・receipt・upload transfer・証拠bytesがないコマンドだけを対象にする。新規DBや更新後の失敗は候補にしない。自動・明示の解除と候補消費を同じtransactionで確定し、再隔離は再起動後も自動解除しない。plannerはbindingごとに起動中一度だけ走査する。明示同期による従来の手動復旧と、応答未保存コマンドの明示再試行は維持する。v2名称・wire・server schemaは維持し、原稿・送信ID・bytes・intentを変更しない。[状態遷移](sync/v2/state-machine.md#recovery-of-response-less-command-quarantines)に範囲を定める。

## D-108: publish祖先応答と内容同値を分離（2026-10-02）

`publish/noChanges`は候補がheadの祖先でも成功する。acknowledged headは更新するが、内容同値表は受領headとintentのsnapshotが一致するときだけ記録する。`resolveDevice`はdecision snapshot、`restore`は復元結果snapshotを照合する。既存の同値対応を異なるremote snapshotへ上書きする受領はtransaction全体を拒否する。

追加型SQLite migrationはcompleted・検証済みのcanonical responseを根拠に、誤った同値行を内容一致の受領世代へ戻す。一致の受領がなく祖先noChangesしかない行は削除する。本文、添付、current、acknowledged head、受領履歴は保持し、v2名称・wire・server schemaは変えない。

受領済みのcurrentには明示同期・自動同期・起動時promotionで新規checkpoint intentを作らない。変更したserver headは完全なgraphの読取で取得し、内容一致の既受領current、account scope、local generation、祖先関係を検証したInboxから既存のdocument gateで適用する。明示同期の読取も非同期に開始し、保存や画面遷移をnetwork待ちにしない。旧clientが作った祖先noChangesのsealed publish／Inboxは従来の受領検証経路で回復できる。

両OSでopen／安全適用の失敗を利用者へ表示し、棚を操作可能なまま保持する。受領済み表示には古い遅延時刻の「未同期の変更があります」を併記しない。実データへの適用、配布・実機受入はローカル回帰検証とは別段階とする。


## D-109: 競合の2択化、多重解決の拒否と一度だけの修復（2026-10-04）

競合の選択肢はmacOS・iOSとも「この端末の版を使う」「サーバーの版を使う」の2つとする。「両方を残す」は新規UIから外し、keepBoth／cloneWorkのkernel・store・wireは既存データ処理と互換のため残す。選ばなかった版は履歴へ保全し、必要なら復元する。

押下直後に再選択を無効にし、applicationは解決をqueueした競合を選択画面から外す。storeは同じ候補に解決intent・keepBoth予約・2親の決定snapshotが既にある場合、transaction内で2回目の準備を拒否する。plannerは候補と同じ世代のintent／未確定予約からserver・cloneを区別し、2親の決定intentはdevice解決として扱う。後続編集のcheckpointから解決種別を推測しない。

解決済み競合とfinalized keepBothに、同じ候補のlocal／remoteを親とする未送信の決定intentが余り、受領headと一致するverified Inboxが残った状態だけを自動修復する。現account binding、cloneWorkの検証済み完了、世代と両親を照合し、sealed commandのあるintentは対象外とする。既存intentのpending→parkedと両版の履歴保全を同じtransactionで行い、再起動後も同じintentを自動解除しない。保留中はplannerとcheckpoint intent作成を止める。schemaとcanonical bytesは変更しない。

サーバー側では競合が既に解決済みなので、古い競合の再開・再送は行わない。「サーバーの版を反映」の明示操作と既存document gateで、現在の保存済み世代を照合してInboxのサーバー版を採用できる状態にする。修復だけではcurrentを切り替えず、複製作品には触らない。履歴から別の版を明示復元した場合は同じcommitで未使用の修復Inboxを閉じ、新しい世代のrestoreを送る。余った決定intentは保留のままとする。snapshot・objectは削除せず、端末版の決定snapshotを含め履歴から復元できる。

持続する失敗は同期欄に表示し、同じWork・reasonのalertを再提示しない。自動採用はaccount・Work・Inbox単位で一度だけ試し、失敗後は明示操作に任せる。作品単位の読込失敗はその棚の行に表示し、作品一覧全体を操作不能にしない。実DBの一時コピーでの検証、稼働アプリへの反映、実機受入は別段階として報告する。

## D-110 macOS toolbarの同期状態

macOS toolbarの同期状態は形と色で示し、状態名はhelpとaccessibility labelへ残す。標準の「アイコンとテキスト」表示にも対応する。STYLE §5の「記号＋文字」に対するtoolbar限定の例外とし、iOSと作品一覧のStatusLabelは変更しない。

同期ボタンは他の項目と同じ標準のtoolbar背景を使う（背景を外すと浮いて見えたため）。同期中は15以降でrotate（14はpulse）、記号変更はreplace、同期済みへの遷移は一度bounceし、Reduce Motion時はアニメーションしない。標準カスタマイズとoverflowを維持する。

## D-111: 共通App層の段階移設（2026-10-04）

共通処理をNovelKitの`NovelWorkspace`（非UI、@MainActorのservice／port）と`NovelWorkspaceUI`（共有SwiftUI）へ移す。`AppState`／`IOSDocumentStore`は`WorkspaceHost` portを介する薄いadapterへ段階的に整理する。P1は移設・公開範囲・import・compositionの接続だけを変更し、挙動と既存テストを維持する。

`NovelWorkspace`の依存許可はNovelCore、NovelSyncV2、NovelSyncV2Application、NovelAuth、NovelAuthApple、EditorKit、NovelWritingSupport、NovelWritingProgress、NovelTextAnalysis、NovelThumbnail、NovelTiming。必要なものだけを宣言し、NovelSyncV2Runtime、NovelSyncV2Store、NovelSyncV2PortableBridge、NovelStorageには依存しない。`NovelWorkspaceUI`はNovelWorkspace、NovelUI、NovelSyncV2Application、NovelExportへ依存する。compositionと明示Import／Export、AppKit／UIKit、scene／window／終了、background task、pasteboard／panel、MCP、MacSyncV2DocumentGate／ProductionDocumentGate、IOSPrivateWorkingCopyLocationはAppに残す。

P2完了：SyncPresentation、HistoryFetchControls／ConnectivityRecovery、WorkSearch／TextCheckの共有View、AssistantFeedbackDetail、AssistantScopeSelector／MarkdownViewとapp非依存のAI値・request／decode処理をNovelWorkspaceUIへ移設し、純粋テストをpackageへ移した。

P3完了：認証表示とローカル保存状態をNovelWorkspaceの共通値型へ統合（既存名はtypealias、iOSのdirtyはunsavedの互換名）。作品棚の文言とpreview fixtureをNovelWorkspaceUIへ、local projection＋remote catalog＋削除待ち／削除済みIDのmergeをNovelWorkspaceへ移した。D6により、macOSでも通常projectionから外れた削除待ち作品を最後の棚から保持し、「削除待ち・接続時に再試行」を表示して削除を再試行できる。削除済み作品はlocal行も一覧から消え、catalogや古い保持行で再表示しない。別account保留行、競合表示、タイトル自然順とWorkID同名順を維持する。refreshSnapshotLibraryのstartupStateはawait前の値で決めず、書込時の現在値で作品選択の表示を判断する。認証flow、checkpoint、conflict choice、identity tokenは変更しない。

P4完了：app側のdocument sessionを`WorkspaceSessionToken { generation, workID, documentID }`へ統合し、iOSのdocumentIDはinstall済みdocumentから取得する。iOSの棚・ナビゲーション用IDはWorkIDから導出し、packageNameをtoken equalityに含めない。`NovelSyncV2Application.DocumentSessionToken`はgate固有のまま維持する。account scopeを全5fieldの`WorkspaceAccountScope`へ統合し、両OSの無効化ごとにgenerationを増やす（D1解決）。`SyncSessionController`のsession／account genericを除去し、共通`WorkspaceOperationContext`でWorkID／session／account／編集世代を照合する。remote taskの戻り値だけはOSごとのgenericを維持する。MacのAuthOperationGate、認証flow、各OSの取消policy、ローカル保存とdocument gateは変更しない。

P5完了：最小の`WorkspaceHost` portと`ProjectFeatureCommands`へ人物／プロット／伏線／世界観ノートのCRUD・移動・session／章／move検査を集約し、両Appは既存APIのadapterにした。owner削除はthumbnail cleanup＋install後に保存通知する。D9は`.flushNow`／`.debounced`のpolicy parameterで解決し、Macの入力中debounceと操作・編集確定時flush、iOSのdebounceを維持する。選択・新規ノートタイトル・伏線の初期章はAppに残し、純粋テストはFakeWorkspaceHostへ移した。

P6完了：`WorkspaceAttachmentSet`と`WorkspaceAttachmentCommands`へ添付の追加・改名・削除・一意名、画像設定とowner削除を集約（D11解決）。読込順を保持、追加は末尾、改名は同じ位置、画像置換は末尾とする（両OSの既存表示順）。重複名のMac ` (2)`／iOS `-2`はparameterで維持。candidate checkpoint後のWorkID／session／account・対象照合を通ってからlive setへ反映し、owner削除は同期的に画像とinstallする。Macのsave／editor排他とpreview URL、iOSのinline gate・IME取得・Files／Photos UI、AI／MCPの画像除外はAppに残す。

P7完了：`WritingAssistantHostFactory`／`WorkReplacementHostFactory`でWorkspaceHostの能力portからhostを生成し、本文capture・範囲検査・編集claim／checkpoint／永続Undoと感想保存の共通処理を集約（D10解決）。Macの注入closureとiOSのEditorCommandSession取得は`captureCommittedText()`を通す。OS別の保存・遷移gate、選択修復、MCP画像hook、iOS背景時間、HTTP／Keychain／設定とpanelはAppに残し、既存挙動を維持する。

P8a完了：棚のSQLite読取・削除ID・merge、account付きcatalog paging、取り込み監視／取消／端末取得、改名・削除の手順を`LibraryCoordinator`へ集約。`WorkspaceLibraryHost`は既存のOS別IME・保存・document gateと退役を注入し、削除は保存後に編集世代を固定してdurable intentを作り、gate解放後に通信する。MacのstartupState書込時判断、catalog順と削除待ち表示の時機、iOS背景時間を維持。共通の照合・順序テストはfake hostへ移し、SQLite／IME／表示のadapter smokeを残す。open／install・checkpoint・adoption・conflict・authは後続phaseのまま。

P8b完了：`CheckpointCoordinator`へhost document／`WorkspaceOperationContext`からのcheckpoint要求作成、await後のWorkID／installed session／account全field照合、worker wake、明示同期のローカル保存→remote要求、継続state観測を集約。`WorkspaceSyncProjection`はlocal durability→saveStateと履歴待ち通知・認証・失敗の重複抑制を共有する。D2はiOSの意味を採用し、Macも旧work／session／accountのcheckpoint成功・失敗をUIへ反映せず、公開document操作はfalseで返す。`WorkspaceSaveEventProjection`はautosaveの終端通知も照合する。確定済みSQLiteのrevisionはUIの採否と分けて記帳し、Macのaccount reconciliationは保存済みの旧revisionを切替先vaultで再保存しない。編集世代の増加だけではcheckpointを棄却しない。通常保存はApplicationのCOMMIT後worker schedulingだけを使い、追加wake・同期用コピー・network待ちを加えない。IME／document gate、Macの終了とpending revoke、iOSの背景時間・flush・parked lane／adoption／reprojection所有権はApp hookへ残す。純粋な照合・順序・投影はpackageのfake hostで検証し、両adapterにSQLite確定後の遅延完了テストを置く。bootstrap／open／installとsafe adoption／reprojectionはP8c、conflict choice／authの統合は後続phaseとする。

P8c完了：`WorkOpenCoordinator`へlocal open、gate外のremote-only downloadとopening進捗、準備済み境界でのexpected WorkID／SQLite local version／session確認・install・再投影を集約。`AdoptionCoordinator`はpending Inboxと同一workのready projectionを照合し、automatic／explicit adoptionのsession取得→arm→token→SQLite apply→disarm→install→再投影、および30秒deadline付きreprojectionを共有する。両経路とも取得・各await完了でWorkID／installed session／account全field／準備済み編集世代を再確認し、旧成功・旧失敗を別作品へ適用しない。remote取得中の編集は許容し、IME確定→ローカル保存後の世代をinstall境界で固定する。本文なしのopen結果は検証失敗として保持し、bootstrapのfresh workへのfallbackはApplicationが返すworkNotFoundだけに限定する。

D7は`WorkspaceAdoptionPort`のsession／arm／disarmへ注入して解決し、`MacSyncV2DocumentGate`とiOSの`ProductionDocumentGate`は統合しない。document operation gate、IME／保存、背景時間、task owner、automatic attemptの再試行方針、選択保持とportable payload検証はApp adapterに残す。Macの同一内容adoptionでは本文・Undoを再installしない。Mac startupStateの書込時判断、startInLibrary、workNotFound→fresh workはAppに残し、保存済み作品の起動openだけ共有処理を呼ぶ。requested WorkIDの純粋テストをpackageへ移し、fake hostで順序・遅延完了・失敗時原稿保持・再投影を検証する。両OS固有のadoption restart／install validation／transition／library refresh／bootstrapテストはAppに保持する。

P8d完了：`ConflictCoordinator`へ表示時projectionと編集世代を固定した競合選択、keep-bothのwrite freeze→SQLite準備→返却clone install→transport再開、作品全体の保存→復元→再open→install、およびConflict Undoを集約。D3はMacを採用し、iOSもgate内でIME確定した未保存本文をローカル保存・履歴保全してから全体復元する。D4はiOSを採用してMacにも元作品のwrite freezeを追加し、handoffできない場合は書込み保留を残し、「もう一度開く」で同じ複製を再installできる。「作品一覧に戻る」や別作品openでは元作品のcheckpointを省略して離脱し、一覧への退役または検証済みinstall後に保留を解除する。D5は表示時projectionと編集世代の完全一致を両OSで必須とし、gate内で別のprojectionを読み直して選択を流用しない。各await完了でWorkID／installed session／account全field／保存後の編集世代を再確認し、旧結果・読込失敗では表示原稿を保持する。IME／document gate、platform sessionとpayload検証、worker／reprojectionの所有権はadapterへ残す。単話復元（EpisodeRestoreSession、D-114）は別の共通編集・永続Undo経路を維持する。純粋な選択・順序・照合テストをpackageへ移し、Macのfreeze／古い選択とiOSの未保存全体復元にadapterテストを置く。

P9完了：`OutlineCommands`へ章／話の追加・改名・削除・配列順の移動と選択修復、`EpisodeTransition`へgate内の離脱準備→ローカル保存→WorkID／session／account照合→選択／操作を集約。macOSの`AfterTransition`とiOSの`AfterDeviceSyncDeparture`は既存APIを保ち、IME確定・resumeとnavigation departure hook、保存policyをApp portへ残す。Macも旧話の保存成功後に切り替え、保存失敗時は選択を保つ。Macの空章追加／第N話／隣接話への削除修復、iOSの初話付き章追加／最初の話の既定タイトル／先頭話への修復をparameterで維持し、offset移動はawait前後の配列順を検査する。

`ManuscriptCopyCommand`と本文を持たない共通notice／resultへ範囲の再解決・Editor確定本文優先・plain text生成・失敗対応を集約。pasteboard書込はportからAppのNSPasteboard／UIPasteboardへ委譲し、Macの5秒通知とiOSの短い文言・promptを維持する。Macはコピーでmodelを書かず、iOSは話／章のコピー時に既存の確定本文同期を維持する。iOSの選択コピーもIME変換中は拒否する安全側へ揃える（非active Editorからの明示選択コピーは従来どおり許可）。共通のCRUD・順序・遷移失敗／旧scope・copyテストをfake hostへ移し、Appには選択・本文・SQLite／native editing position・離脱ID・改名dialog・copy adapterテストを残す。EditorKit実装、本文編集／Undo経路とwire／schemaは変更しない。

P10完了：`AuthComposition`に続き、`AccountTransitionCoordinator`へrequest window、remote suspension lease、abandon recovery、復元／Apple・Google sign-in／sign-out／A→B／refresh／revoke journal retry／旧epoch fail-closedを統合した。両AppはIME・SQLite checkpoint、document gate、UI投影とOS別providerのadapterを持つ。Macのinteractive countは共通Coordinatorの短い準備／transition状態から導出する。18シナリオのfakeと両Appは、Apple入口のcompositionを除き同じ期待値を使う。D8と12差分の判断は[D-115](#d-115-認証account-transitionの統合2026-10-04)、現在の安全境界と検証入口は[AUTH](AUTH.md)へ集約した。

P11完了、D-111のP1〜P11移設完了：`@MainActor @Observable WorkspaceModel`へ両OSのdocument／章・話選択、session／account generation、添付、保存・同期projection、棚・catalog・取り込み、keep-both保留とAI依頼センターを集約した。AppState／IOSDocumentStoreは一つのmodelを持ち、既存名のforwarderと各coordinatorへのOS adapterを維持する。AI依頼センターと必要な値型は非UIのNovelWorkspaceへ移し、NovelWorkspaceUIからの型名を互換aliasで保つ。呼出元のない旧helperと不要なruntime判定を削除した。Macの起動画面用棚の表示identity／availability・機能選択、iOSの画面内選択とstartup／OS lifecycle／gateの意味差は保持し、wire／schema／保存・入力挙動を変更しない。稼働反映・実機受入・公開完了とは別の構造整理である。

以下は各phaseで採用した統合方針。移設だけで片方の意味を暗黙に採用しない。

| 差 | 現状 | 推奨・判断 |
| --- | --- | --- |
| D1 | P4で解決。旧iOSはaccountGenerationが増えず、同一bindingでの無効化前completionをaccount scopeだけで拒否できなかった | 全5field（accountID／fence／serverInstanceID／protocolEpoch／generation）を照合し、両OSで無効化ごとにgenerationを増やす |
| D2 | P8bで解決。Macもcheckpoint完了後にWorkID／session／accountを再検証する | iOSを採用。旧成功・失敗は現在のsaveState／sync projectionへ反映しない |
| D3 | P8dで解決。両OSの作品全体復元はgate内で未保存本文を保存してから復元 | Macを採用（2026-10-04オーナー決定）。現在版を履歴に残す |
| D4 | P8dで解決。両OSで元作品をwrite freezeし、clone install後にtransport再開 | iOSを採用。handoff失敗時は書込み保留を維持し、保存なしの一覧退避と同じ複製への再試行を許可 |
| D5 | P8dで解決。表示時projectionと編集世代が変わった選択は両OSで拒否 | 厳しいiOSを採用し、編集世代の照合も完全一致に揃える |
| D6 | 棚mergeでpending-deletion行を保持し、削除済みlocal行を落とすのはiOSだけ | iOSを採用（2026-10-04オーナー決定、P3）。NovelWorkspaceのpure functionへ統合し、削除待ち行を保持、削除済みIDはlocal／remote／保持行から除外する |
| D7 | P8cで解決。safe-adoption gateの意味差を保持する | `WorkspaceAdoptionPort`へ各OSのsession／arm／disarmを注入。gate実装は統合しない |
| D8 | P10で解決。両OSが共通AccountTransitionCoordinatorを使用する | iOSのrequest window＋lease＋abandon recovery＋journal retryを採用。12差分はD-115 |
| D9 | P5で解決。Macは操作時flush／入力中debounce、iOSはdebounce | 操作ごとのsave policy parameterで既存挙動を維持 |
| D10 | P7で解決。committed-text取得をWorkspaceEditorHostのメソッドへ統合 | Macの注入closure／iOSのEditorCommandSessionはadapterで維持 |
| D11 | P6で解決。両OSのpayloadを共通のordered・fileName一意setへ統合 | 表示順とOS別一意名を維持、保存境界を注入 |

## D-112: AI校正のチェック項目・理由と感想（2026-10-04）

owner承認済み。機械的な表記チェックと端末内の無視設定使用を廃止し、作品全体検索・置換と人物登場検出を維持する。校正は選択したチェック項目を基底指示の後に展開し、人物名チェック時だけ登録名・読みを参考情報として送る。選択は既存assistant prompt laneの`校正チェック`（`{"checks":["typo",…]}`）へ共通初期値／作品別上書きとして保存し、schema・server・fixtureは変更しない。

校正のAI応答は`changes`（before／after／reason／check）とし、一意な完全一致・重ならない提案だけで本文を構成する。不一致・曖昧・重なりは「適用できなかった提案」へ分ける。送信本文・作品／話／session／accountを照合し、既存EditorKit適用を1回だけ呼びnative Undo・着色を保つ。感想の初期指示は熱心な読者の自然な口語に変更し、作品名・あらすじ／人物名・役割／話の位置を選択式の引用参考情報にする。本文・実効指示・参考情報をpreviewして明示送信する。

指示画面は校正・感想・アドバイスとチェック項目ごとに、確認後に現行コード初期値を保存する操作を持つ。既存指示の自動上書きはしない。保存一覧名は「感想」とし、新規は感想だけを保存する。既存アドバイス添付は引き続き読める。新規アドバイスは既存チャットだけにし、感想添付へ保存しない。


## D-113 AI依頼の継続とチャット（2026-10-04）

AI依頼をアプリ単位のセンターが所有し、パネル・用途・話の切替では取り消さない。SSEは生存確認・段階・受信文字数と最終回答の組立にだけ使い、途中本文は表示／適用しない。停止の疑いは待つ／中止／再送、用途別の制限時間超過は失敗とする。作品と用途、チャットは会話ごとに1件だけ実行する。実行中の再送はメモリの入力を使い、再起動後は現在のデータから準備し直す。account切替・作品削除は該当依頼を中断する。

記録の保存先を送信時の作品へ固定する。校正は同じsession・話・送信本文の一致時だけ共通編集サービス＋永続Undoで反映し、それ以外は未反映結果として確認後に扱う。チャットの編集もsession/account/許可を照合し、不一致なら会話に変更案を残す。送信入力は同期記録へ保存しない。終了状態は既存requestへ、チャット返信・編集は会話へ、感想は保存リストへ残す。校正の変更一覧と照合用ハッシュは端末内だけに保存し、全文の変更前後は既存のローカルUndo journalだけに置く。再起動後の校正・感想は通常の送信前プレビューを再表示する。wire/schemaを変えない。従来の感想attachmentも保持する。中断の自動再送はしない。

「アドバイス」のキーは維持してUIを「チャット」とし、相談だけはMarkdownで返す。編集許可は同じ会話中は維持し、会話切替・新規会話では相談だけへ戻す。会話の名称変更は既存conversationのrevision、削除は端末内の非表示とする。

## D-114: 話ごとのスナップショット履歴と復元（2026-10-04）

owner承認済み。執筆中の履歴popoverは「第N話「タイトル」の履歴」とし、対象話の本文object IDが連続して同じ版をまとめ、新しい順に表示する。話未選択・執筆画面外では従来の作品全体履歴を使う。macOSのFile menuに「スナップショット…」、iOSの執筆menuに「この話の履歴」を置き、作品全体履歴への入口も保つ。

SQLiteのsnapshot_entriesとsnapshots、および同じaccount bindingの検証済みInboxを1本のmetadata queryで読む。未取得版は末尾の取得行にまとめる。最初のローカル100件をオンライン応答より先に表示し、古い履歴はキャンセル可能な画面所有taskで順次追加する。オンライン取得後は先頭の暫定ページを日時順の統合ページへ置き換え、以降はページ境界の同じ本文もまとめる。閉じる・話/Work/session/account切替で読み込みを中止する。作品全体のmacOS履歴も同じ段階取得APIを使う。字数は表示行だけで既存の本文previewから計算し、Work/object IDでcacheする。日付Section、自動保存のまとめ、前の異なる本文との差分・半減警告・現在本文との一致を両OS共通のEpisodeHistoryListで表示する。

単話復元はNovelWorkspaceのEpisodeRestoreSessionで、既存WorkReplacementHostのdocument gate → IME確定とローカル保存 → 確認時本文との一致 → explicit checkpoint → 共通WritingEdit検査・永続Undo journal → 1つのEpisodeTextChangeをEditorKitへ適用 → ローカル保存、の順に実行する。checkpoint失敗時は本文を変えない。native Undoを1回にし、他の話は変更しない。競合未解決・IME変換中・話削除・Work/session/account変更では拒否する。話が存在しなければ作品全体履歴へ案内する。作品全体のrestore経路は呼ばない。

新しいreasonは追加せず、復元前checkpointは「手動保存」と表示する。schema/wire/fixtureは変更しない。history_occurrencesのWork別indexは現行schemaの厳密なattestationに影響するため、今回は追加しない。


## D-115: 認証account transitionの統合（2026-10-04）

D-111 P10のオーナー決定。`NovelWorkspace.AccountTransitionCoordinator`を両OSの唯一の認証transition coreとし、iOSのrequest window、lease、abandon recovery、revoke journal retry、旧epoch fail-closedを採用する。Appはprovider compositionとIME／SQLite／document gate／画面投影を担当する。

| # | 決定 | 理由 |
| --- | --- | --- |
| 1 | AppleはMac production browser、iOS nativeを維持する | 配布・OSの認証入口はcompositionの値であり、統合対象のflowではない |
| 2 | 両OSともiOSのpreflight→旧scope退役→destination反映を使う | vault交換前に確定本文を旧scopeへ保存する |
| 3 | 同一scopeのtoken refreshはgenerationとwork／AI requestを保つ | 通常のtoken更新で進行中の処理を取消しない |
| 4 | 未ログインからのexchange失敗は理由付きfailedを表示する | 認証画面自身が理由を示し、別noticeを重ねない |
| 5 | 未ログインからの取消はsignedOutへ戻す | 利用者の取消をエラーにしない |
| 6 | sessionを復元できたexchange失敗も理由を残す | 回復成功で失敗理由を隠さない |
| 7 | exchange中のsign-outは終了後にqueue実行する | 利用者のsign-out意思を落とさない |
| 8 | revokeは独立taskで実行し、callerとleaseを解放する | 遅い通信やofflineでローカル操作を止めない |
| 9 | pending revokeはjournalだけをretryし、新しいBを保つ | Aの再送で後続sessionを消さない |
| 10 | 旧epochの直接transitionはpark後failed、戻り値falseとする | callerが成功としてremoteを再開しない |
| 11 | 旧epochのlaunch restoreはpark後に旧vault sessionを除く | 使用不能なsessionを次回起動へ残さない |
| 12 | restore時のApple credential revoked／notFound／transferredはsignedOutとする | Appleの失効を尊重する。照合の一時失敗は有効sessionを退役させない |

leaseは最初のIME／dirty checkpointより先に取得し、拒否・取消・回復・失敗を含む各経路で解放する。認証UIへsessionをpublishするのはdurable account boundary後だけ。同一scopeのrefreshはこの境界を開かない。取消後のcleanupは取得時のrequest ownerに限定し、後続requestを解放しない。

sign-outはネットワーク待ちの前に既存vaultのrevoke journalを確定し、独立taskは`resumePendingRevoke()`だけを使う。新しいsessionへのsign-out再帰を避け、vault formatの変更も行わない。ブラウザ由来sessionにはnative Apple credential-state照合を適用しない。
