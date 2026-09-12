# 明示同期とLANサーバー検証 — 2026-09-12

土台`ec8a42625`、作業branch`codex/explicit-sync-20260912`。利用者は明示同期ボタン、同期実態の確認、不足実装の修正を依頼し、続いて192.168.11.5のSSH操作・必要な修正を許可した。D-091へ判断を記録した。

## 判明したこと

- 送信worker、sealed command、receipt検証、SQLite保存、再試行・競合処理は存在した。一方、明示syncはpending処理再開だけで、outboxが空ならサーバーに接続せずnoChangesを返していた。
- `publish/noChanges`で届くremote descendantは検証保存されても、通常のdocument gate経由の反映待ちとして接続されていなかった。
- Macの実DBを読み取り専用で集計した結果、作品1件、account binding 0、unbound pending intent 1、command/receipt/Inbox 0。本文・タイトル・credentialは読んでいない。この作品は実際にサーバーへ送られていない。
- LANのrole-split構成はedge/server/PostgreSQLともhealthy、restart count 0。SSHログイン成功。auth capabilitiesはTLS経由で成功し、Auth epoch 1 / Sync epoch 2を確認。
- 稼働サーバーのsourceの主要Rust実装・Cargo.lock・Dockerfileは手元とSHA-256一致。DB集計は作品1、Snapshot 0、createWork receipt 1、upload 0、account object 0、conflict 0。過去の作品作成が本文同期完了の証拠ではない。原因をサーバー停止と決めつけない。

## 変更

- Macの「今すぐ同期」を文字付き・常設化。iOS本文画面にも追加し、作品ホームと共通部品にした。
- サインイン／unbound作品のaccount追加への導線を追加。追加時は原本を残すcloneで、確認対象のsession/accountを固定する。利用者の既存作品を今回自動送信していない。
- 両OSの明示syncでIME確定→document gate内local保存→scope再確認→worker再開の順を守る。Macの握り潰した開始エラーを表示し、iOSの開始失敗を一律offline扱いしない。
- 明示syncは未変更でもcheckpoint intentを要求し、既存のsealed publish経路で最新headを照合する。pending/sealed intentがあれば再利用し、再起動後も同じ作業を続ける。unboundは認証要求として拒否する。
- 完了publish receiptとverified Inboxをscope/source generationで結び、安全なfast-forward反映待ちをDBから導出する。反映前にpending intent／local generation／競合を再検査し、既存の消費型document gateからだけinstallする。反映前版を履歴へ保護し、portable resourceもAppへの返り値へ保持する。
- Plannerのcommand payloadを分離し、kernel/workerの責務をextensionへ整理した。wire/DB schemaは変えていない。

## 検証（重たい）

| 対象 | 今回の結果 |
| --- | --- |
| Swift package | 成功、470 tests。変更なし送受信のproduction composition統合test、再起動、二重要求、未接続拒否、receiptなし反映拒否、反映前の追加入力保護を含む |
| macOS app | 成功、142 tests / 30 suites |
| iOS app | 成功、110 tests / 22 suites |
| 通常macOS / generic iOS build | 成功、署名なし |
| Python/Swift conformance | 成功、Python 60 vectors / Swift 6 tests |
| 全体check.sh | MacにcargoがなくRust開始で停止。単一スクリプトの全通し成功とはしない |
| Rust | LANホストのrust:1.93-bookwormで79 tests成功 |
| 実PostgreSQL/HTTP | 新規の隔離DB `fuminiwa_v2_test`でintegration_gateを明示実行し成功。既存DBへtest URLを向けていない |
| 構造・依存境界・network/AI/v2境界・lint | 成功。既存の警告は残る |
| 実アカウント・署名済みMac/iPhone間の往復 | 未実施。実Appleサインインと新ビルドでの受入が必要 |

LANで作成した専用testコンテナ・ネットワーク・cache volume・source一時directoryは終了後に削除。稼働中のserver/config/DB、既存の他test環境、原稿・credentialは変更していない。今回の証拠ではサーバーのデプロイ修正は不要だった。

## 利用時の確認

新ビルドで「今すぐ同期」→必要ならAppleサインイン→もう一度「今すぐ同期」→「アカウントへ追加して同期」。原本を残した同期用作品が開く。その後MacとiPhone双方で同じアカウントを使い、編集→同期→相手側同期で本文を照合する。テスト成功をこの実機受入の代わりにはしない。

GitHub push/PR/mergeは行っていない。週間残高は確認時56%、下限40%を維持した。

## ツールバーoverflowからの設定案内（追補）

macOS通常版のプロット画面で、標準overflow内の「今すぐ同期」を選んでも設定案内が出ず、メニューだけ閉じる状態を再現した。ボタン自身の`confirmationDialog`と一時状態を、作品画面が所有する`ExplicitSyncPresentation`とalertへ移した。作品／account切替による取消と、追加直前のscope照合は維持する。

検証は中ぐらい。変更後のmacOS build成功、macOSアプリテスト142件成功。更新した通常版の画面確認と、Apple認証を含む端末間同期の受入は未実施。サーバー／DB／wireの変更はない。

## 実サーバー受領記録との接続（追補）

通常版でアカウント追加後、サーバーは`createWork`を完了した一方、端末では同コマンドが`quarantined`、受領記録0件となり、snapshot送信前に停止することを確認した。HTTP adapterがPOSTの応答本文を、そのままStoreの`canonicalReceiptEnvelope`へ渡していた。Storeは既存wire契約どおりGET受領記録のenvelopeを要求するため、この組み合わせは受理されなかった。

- POST応答の後に`GET /v2/receipts/{commandId}`を取得し、元応答の正確なbytes、command／work／digest／status／result／全read-back述語を照合してからStoreへ渡す。Store自身の厳密検証も維持する。
- 初回createが隔離されたままなら自動workerは別IDのcreateを増やさない。「今すぐ同期」に限り、同一bound scopeでcreateだけが隔離されている初期状態から、最古の同一command／bytesを再試行する。別account／fence、他種コマンド、完了済みcreateには適用しない。
- PostgreSQL由来の小数秒付きRFC 3339 `expiresAt`を、応答検証・転送復元・plannerで一貫して読む。秒単位の既存形式も受け入れる。

HTTP adapterから実SQLiteへの作成受領テスト、応答bytes不一致拒否、restart後の初回create同一ID再試行と異account拒否を追加した。既存の転送fixtureも実サーバー同様の小数秒付き期限に変更した。fake remoteだけのテストでは今回の応答形式の取り違えを検出できていなかった。

検証段階は重たい検証。Swift package全474テスト成功（期限fixture更新後は関連136テストを再実行し成功）。Macアプリ142件／iOSアプリ110件成功は受領記録修正時点、期限修正後のMac／iOS build成功。`./Scripts/check.sh`はPython 60 vectors／Swift conformance 6件成功後、ローカルにcargoがないため停止した。サーバーコード・schema・実DBの直接編集は行っていない。実端末の再送・相手端末への反映は別途受入確認が必要。

## upload後のfinalize順序（追補）

実端末の再送でcreate／prepareの受領確認は通過したが、`finalizeObject`が一度も実行されず`registerSnapshot`が拒否される次の停止点を確認した。plannerがPUT uploadのacknowledgementを「利用可能なremote object」としてcacheへ入れていたため、finalizeを省略していた。

アップロード済みとfinalize済みを分離し、保存済み転送記録のupload IDを再起動後にも復元してfinalizeへ渡す。remote objectの存在cacheはprepareの`noChanges`による確認に限る。端末DBやサーバーDBの直接補修は行わず、既存のアップロード記録から再開する。

検証は中ぐらい。関連Application 66件成功、各操作ごとにplannerを作り直して全uploadがfinalizeを通る追加テスト1件成功、Mac／iOS build、baseline lint成功。既存テストでfinalize一覧が空でも通っていた条件も、upload ID一覧との一致を要求するよう修正した。実サーバーの作品登録・publish成功は、更新版での再送後に確認する。

## 初回publishと一時診断（追補）

利用者から「同期を開始できませんでした」の報告後、端末ではfinalize 9件／registerSnapshot 1件が完了し、publishコマンド作成前に止まる状態を確認した。`PublishPayload`の合成Encodableがnilの`expectedRemoteHead`キーを省略していたため、初回publishの必須nullを明示するencodeへ修正した。新規作品のテストをregister到達で終えず、初回publishのnull検査・受領・pending intent解消まで延長した。

利用者の依頼によりDebug build限定の一時診断を追加した。Macの停止メッセージ末尾とOS log（subsystem `dev.serikayuzuki.fuminiwa`、category `sync-debug`）へ、同期段階・Error型・enum case名を出す。Errorのassociated value、原稿、DBエラー本文、URL、account／work ID、認証情報は含めない。Release buildでは診断文字列を生成・表示しない。調査終了後にこの一時表示を撤去する。

検証は中ぐらい。Application 68件、Macアプリ142件成功。診断の秘密値除外・初回publish完了テストを再実行して成功、Mac／iOS build成功。実端末のpublish成功は更新版の再送後に確認する。

## ⌘S・見える同期状態（2026-09-12）

既存の⌘Sはdirtyな保存からworkerを起動していたが、変更のない作品ではremote確認を要求しなかった。メニューを「保存して同期」とし、既存の入力確定→local保存→同期要求へ接続した。端末内だけの作品は保存に留める。認証操作等でtransition gateが閉じている間も、従来のlocal保存は利用できる。

同期操作と状態を一つの文字付きボタンへ統合し、全sectionのprimaryActionへ配置した。macOS 26.1以降はnative visibility priorityをhighに設定する。旧OSではprimaryAction配置と⌘Sの入口を使う。未保存・保存中・同期中・同期済み・通信待ち・失敗を区別し、未確認のidleや端末内作品を同期済みとしない。競合／受信適用の入口は同ボタンに維持する。

applicationの状態変更をcoalesced AsyncStreamで通知し、Workbenchのsession／accountに結び付いたtaskが最新状態を再取得する。toolbar overflowへ購読を所有させず、window終了や作品／account変更で解除する。以前はworker完了後のUI更新が明示refresh頼みだったため、この購読を追加した。

検証は中ぐらい。Macアプリ146件成功、最終の関連6テスト成功、共有Application 68件成功、Mac／iOS build、baseline lint成功。未変更の⌘Sでもremote要求が出ること、unboundが送信されないこと、背景処理後に通信待ちへ自動更新することを確認した。native toolbarの560pt幅で実際にoverflowが発生しても同期項目がvisibleItemsに残ることを検証した。極端に狭い340pt幅ではOSが高優先度項目も隠すため、全幅での常時表示を保証するものではない。

## finalizeObject の期限切れ回復（2026-09-12）

実サーバーの集計で、uploaded のまま期限切れとなった capability が1件あり、finalizeObject の完了 receipt は増えていなかった。クライアントには二つの問題があった。

- ACK 済み transfer は期限切れでも再利用していた。期限判定を ACK 済みにも適用し、未確定 object は次の試行で prepare からやり直す。完了済み finalize の記録は引き続き尊重する。
- サーバーの事前拒否は `error` 項目の応答だが、finalize は receipt として読んで receiptMismatch にしていた。409 の typed upload error を読み、uploadExpired の sealed command は隔離して同じ期限切れ command の無限再送を防ぐ。応答喪失など、成否不明の場合の同一 command 再送は維持する。

検証は中ぐらい。実 SQLite を使い、各操作で planner を再生成し、ACK 直後の期限切れから再準備・finalize・register・publish まで進むケースを追加した。サーバーと同じ期限切れ応答の判別も確認した。関連68テスト、Mac/iOS Debug build、既存 baseline を使った lint は成功。実データの変更やサーバーの変更は行っていない。更新版での実同期完了は未確認。

## オフライン保存後の初回同期（2026-09-12）

iPhoneの旧失敗状態ではcreateWork 10件が隔離されていた。最初の1件はサーバーに同一requestの成功receiptがあり、既存の明示再試行で受領を完了した。その後registerSnapshotが拒否された原因は、最新checkpointだけを転送し、未登録の親Snapshotを送っていなかったことだった。

送信対象の親を先に登録し、履歴の実際のsource generationをcommandに使う。完了register receiptまたは同scopeのverified Inboxで登録済みと確認できる祖先は再転送しない。最終intentは最新checkpointのまま保持する。UIとworkerの計画要求も作品単位でまとめ、publish intentの二重sealを防ぐ。実機ではこの修正で6世代の登録が完了したが、初回publishのサーバーroot限定条件による拒否が続いた。

D-093により公開headがnullの作品に限り、検証済み親closureを持つ最新checkpointの初回公開を許可する。公開済み作品のnull-base、expected-head、祖先、競合の条件は維持する。失敗publishの明示再試行は元のcommand ID・canonical bytes・sealed intentを再利用する。通常の背景処理は隔離済みpublishを勝手に再送しない。

検証は重たい。Swift package 484テスト、変更途中のMac 152／iOS 116テストと最終の関連iOS 25テストが成功。新規回帰は、オフライン3世代の親順登録、各操作でのplanner再生成、最新だけのpublish、並行要求20件の単一seal、隔離publishの同一内容再試行。ビルドと並行した全package実行では既存2秒待機のタイムアウトが出たが、単独実行で成功した。Python conformance 61 vectors、Swift conformanceも実行。`check.sh`はMacにcargoがないためRust段階で停止した。Rustは隔離Docker/PostgreSQLのopt-in HTTP/DB gateを含む79テストが成功。全体script完走や公開配布の完了とは区別する。
