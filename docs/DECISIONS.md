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

## D-107: 旧unexpected隔離の一度だけの自動復旧（2026-10-02）

HTTP edge応答の旧分類で止まったコマンドは、既存の追加型SQLite migrationで`legacy_command_recovery`へ候補を記録する。更新時に存在し、`command:unexpected`かつ応答・receipt・upload transfer・証拠bytesがないコマンドだけを対象にする。新規DBや更新後の失敗は候補にしない。自動・明示の解除と候補消費を同じtransactionで確定し、再隔離は再起動後も自動解除しない。plannerはbindingごとに起動中一度だけ走査する。明示同期による従来の手動復旧と、応答未保存コマンドの明示再試行は維持する。v2名称・wire・server schemaは維持し、原稿・送信ID・bytes・intentを変更しない。[状態遷移](sync/v2/state-machine.md#recovery-of-response-less-command-quarantines)に範囲を定める。

## D-108: publish祖先応答と内容同値を分離（2026-10-02）

`publish/noChanges`は候補がheadの祖先でも成功する。acknowledged headは更新するが、内容同値表は受領headとintentのsnapshotが一致するときだけ記録する。`resolveDevice`はdecision snapshot、`restore`は復元結果snapshotを照合する。既存の同値対応を異なるremote snapshotへ上書きする受領はtransaction全体を拒否する。

追加型SQLite migrationはcompleted・検証済みのcanonical responseを根拠に、誤った同値行を内容一致の受領世代へ戻す。一致の受領がなく祖先noChangesしかない行は削除する。本文、添付、current、acknowledged head、受領履歴は保持し、v2名称・wire・server schemaは変えない。

受領済みのcurrentには明示同期・自動同期・起動時promotionで新規checkpoint intentを作らない。変更したserver headは完全なgraphの読取で取得し、内容一致の既受領current、account scope、local generation、祖先関係を検証したInboxから既存のdocument gateで適用する。明示同期の読取も非同期に開始し、保存や画面遷移をnetwork待ちにしない。旧clientが作った祖先noChangesのsealed publish／Inboxは従来の受領検証経路で回復できる。

両OSでopen／安全適用の失敗を利用者へ表示し、棚を操作可能なまま保持する。受領済み表示には古い遅延時刻の「未同期の変更があります」を併記しない。実データへの適用、配布・実機受入はローカル回帰検証とは別段階とする。
