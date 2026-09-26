# アカウント削除とバックアップの自宅サーバー運用

運用先は`192.168.11.5`。この処理にCloudflare有料サービスは不要。通常保存は端末SQLite、削除対象は明示予約されたremote accountだけである。以下は構成と復旧手順であり、実行時の稼働状態は`last-success.json`等で確認する。

## 有効な自動処理

| 処理 | 実装・実行条件 |
| --- | --- |
| 30日猶予 | [lifecycle v1](auth/v1/account-deletion.md)。予約DB時刻＋720時間、期限前の取消、猶予中の通常利用 |
| 削除worker | Rust serverの30秒周期、1回最大16件。失敗／再起動後はpendingを再処理。remote消去とそのmarkerは同一transaction。account削除完了はApple失効後に記録 |
| Apple失効 | 既存の永続workerを利用。成功までcredentialを保持し、成功後にidentity対応を除去 |
| バックアップ | 毎日サーバー現地時刻03:17にユーザーcron（稼働daemon: dcron）で実行。DBのcustom-format dump、復元用鍵、container構成をAES-256-GCMで暗号化 |
| 保持期限 | 作成から1暦年、UTCで翌年の同月同日時刻。2月29日は翌年2月28日。新しいbackupの取得・認証検証が成功した場合だけ期限切れを整理 |

保存先は`/DATA/AppData/fuminiwa-sync-v2-role-split/operational-backups/daily/`。暗号鍵は同階層のbackup directory内へ置かず、`backup-keys/backup-aes256.key`に0600で保存する。DBの中身、provider credential、暗号鍵はGitやログへ出さない。

`Scripts/operations/backup.py`が運用実装、`backup-config.json`がサーバー内の非公開設定。`last-success.json`に完了時刻とbackup名、`last-run.log`に直近の実行結果を残す。36時間以上成功がなければ失敗として調べる。バックアップ失敗時に古いbackupを削除しない。所有manifestと既知ファイルだけを期限管理し、不明ファイル・symlinkは触らない。

過去の手動退避・旧releaseにあるbackupは自動整理対象へ勝手に取り込まない。1年保持が自動適用されるのは上記daily配下で作成するbackupである。

## 復旧

1. public trafficを遮断し、別の隔離DBを用意する。稼働DBへ直接上書きしない。
2. `backup.py --decrypt <database.enc> --key-file <key>`の出力を隔離先の`pg_restore`へ渡す。復号は全ファイルのGCM検証完了後にのみ出力する。`secrets.enc`と`configuration.enc`も同じ方法で復元するが、秘密情報を端末出力へ表示しない。
3. DB内容、role、server instance、migration、鍵との対応を照合する。現在の削除完了記録・削除予約と照合し、backup後に削除されたaccountを再公開しない。照合できない古いbackupは公開環境へ戻さない。
4. 復元先で期限を過ぎた予約を処理し、原稿保全・認証・削除済みaccount拒否を確認してからtrafficを戻す。

暗号鍵も同じ自宅サーバーにあるため、サーバー・ディスク全損にはこれだけで対応できない。2026-09-26に、この損失を許容して外部バックアップを設けない方針を採択した。別機器／別媒体の退避先は必須の判断待ちではない。自動復元やbackupによる利用者アカウント回復は行わない。最新の隔離DB復元確認とその限界は[原稿保全・AI計画](PROTECTION_AI_PLAN.md)。

## 反映済み構成と証跡

2026-09-14の反映記録はserverの`releases/retention-final-20260914/`（途中記録は`releases/retention-20260913/`）。当時のimageは`sha256:c6e4ed3b3e67eb53880ee1ddf00fb4fb3e37a5b0f7922e1c8cef80cb472b1864`。隔離DBの期限境界・復元・migration、切替前後のデータ保持とhealthを確認した記録であり、現在の稼働image・日次成功は運用時に読み返す。

schema 0008を知らない旧binaryへ単純に戻せない。切り戻しは新規予約の有無とschemaを照合した手順か、前進修正で行う。実利用者の削除、30日／1年の実時間経過、Apple実credential失効、アプリの予約／取消画面の受入はこの記録に含まない。
