# 明示アカウント削除 lifecycle v1

サーバー実装と自宅サーバーへの反映記録がある。Auth v1への追加APIで、`lifecycleVersion=1`を使う。通常のAppleログイン以外の回復は追加しない。実装・運用証跡は[自動運用](../../ACCOUNT_RETENTION_OPERATIONS.md)。

## 予約と取消

- 認証済みの利用者による明示要求だけが削除予約になる。Apple通知の`account-deleted`／`deletionPending`、最終アクセス日時、サインアウトは予約に変換しない。
- 起算は予約transactionのDB時刻（UTC）。期限はそこから**720時間（30日）**。サーバーが`requestedAt`と`deleteAfter`をRFC 3339で返す。端末の時計で期限を決めない。
- 猶予中は通常のAppleログイン・編集・同期を維持する。取消はDB時刻が期限より前のときだけ可能。期限と同秒以後はworker未実行でも取消できない。
- 予約IDは小文字UUID。同一IDの再送は期限を延ばさず、取消済み予約を復活させない。取消も同じ予約IDへ繰り返せる。別IDでpendingを重複作成しない。別アカウントのIDは拒否する。
- account行で予約／取消／確定を直列化し、認証取得後のepoch/fence変更も再検査する。終了・失敗時はtransactionをrollbackし、次回workerで再試行する。

## API

`GET /v1/auth/account-deletion`は現在の状態を取得する。`POST`は以下のexact JCS（余分な空白・改行なし）を受ける。両方ともFUMINIWA access tokenと`X-Fuminiwa-Client-Version`が必要。POSTはAuth media type、最大1,024 bytes。account IDを入力させず、bearerから導出する。

```json
{"action":"request","lifecycleVersion":1,"requestId":"11111111-1111-4111-8111-111111111111"}
```

取消は`action`を`cancel`にし、取り消す予約IDを使う。成功200は`lifecycleVersion`、`state`（`none`／`pending`／`cancelled`／`deleted`）を返し、予約があれば`requestId`、`requestedAt`、`deleteAfter`を含む。期限を過ぎて削除されたaccountの古いtokenは401となるため、`deleted`の完了確認は運用側の永続記録で行う。応答は`no-store`。

このAPIのIDは削除予約そのものを識別する。Authのログイン／refreshのreceiptに使う`operationId`とは別であり、再送時は最新の予約状態を返す。

## 確定処理

workerは30秒ごと、1回最大16 accountを処理する。停止中に期限を過ぎたものは再開時に実行する。各accountについて、identity → account → sync scopeの順でlockし、再度期限とpending状態を確認する。

remoteの作品・履歴・snapshot・添付・未公開upload・accountに結び付いたmigration stagingを一transactionで削除する。他accountに参照がある共通objectは保持する。旧tokenは失効し、sync scopeに旧要求を拒否する永久markerを残す。端末内原稿・端末履歴・Exportは削除しない。

remote消去時にaccountを`deleted`へ固定するが、削除予約の`state`はApple失効待ちの間`pending`に残す（期限後なので取消不可）。すべてのApple失効とidentity除去が成功してから予約を`deleted`にし、`deleted_at`へ完了時刻を記録する。原稿だけ消えた状態をアカウント削除完了としない。

Apple credentialは永続revoke retryへ移す。Appleへの失効完了後にcredentialとidentity対応を削除する。その後の同じAppleアカウントのloginは新規FUMINIWA accountとなり、旧原稿を復活させない。失効応答を捏造して確認済みにしない。削除済みopaque account／scopeと完了時刻等は遅延要求の拒否・監査に保持する。

バックアップ内の過去データは、そのバックアップの作成から1暦年まで残る。これはアカウント回復サービスではない。復元時は削除済みaccountを公開環境へ戻さない手順が必要。

予約・取消のサーバーAPIは利用可能。macOS／iOSの利用者向け予約・取消画面はまだ追加していない。運用者が本人の要求なしに予約を登録する手順は提供しない。
