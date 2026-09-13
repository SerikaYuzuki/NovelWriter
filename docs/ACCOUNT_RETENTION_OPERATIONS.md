# アカウント削除とバックアップの自宅サーバー運用

2026-09-14更新。Cloudflareの有料サービスは使わず、`192.168.11.5`で運用する。通常保存は端末SQLiteのまま。削除対象は明示的に予約されたremote accountだけで、実アカウントの削除予約は今回作成していない。

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

過去の手動退避・旧releaseにあるbackupは自動整理対象へ勝手に取り込まない。今回の1年保持が自動適用されるのは上記daily配下で作成するbackupである。

## 復旧

1. public trafficを遮断し、別の隔離DBを用意する。稼働DBへ直接上書きしない。
2. `backup.py --decrypt <database.enc> --key-file <key>`の出力を隔離先の`pg_restore`へ渡す。復号は全ファイルのGCM検証完了後にのみ出力する。`secrets.enc`と`configuration.enc`も同じ方法で復元するが、秘密情報を端末出力へ表示しない。
3. DB内容、role、server instance、migration、鍵との対応を照合する。現在の削除完了記録・削除予約と照合し、backup後に削除されたaccountを再公開しない。照合できない古いbackupは公開環境へ戻さない。
4. 復元先で期限を過ぎた予約を処理し、原稿保全・認証・削除済みaccount拒否を確認してからtrafficを戻す。

暗号鍵も同じ自宅サーバーにあるため、サーバー・ディスク全損にはこれだけで対応できない。別機器／別媒体へのbackupと鍵の退避先は未設定。Cloudflareは必要なく、別NASや外付け媒体も選べる。自動復元やbackupによる利用者アカウント回復は行わない。

## 2026-09-13〜14の確認結果

- **重たい検証：成功**。`Scripts/check.sh`全項目、Rust unit、専用PostgreSQLでの30日境界・取消・再送・再起動・同時worker・途中失敗のrollback・他account保持・旧principal拒否・Apple失効待ちと完了後cleanup。
- backupのround trip、改ざん／誤鍵拒否、暦年／閏日、取得失敗時の保持、管理対象だけの期限整理：成功。
- 実DBの暗号化backupを隔離DBへ復元：成功。別のrole-split隔離DBでmigration 0007→0008・runtime権限を確認：成功。
- 自宅サーバーへ反映済み。稼働imageは`sha256:c6e4ed3b3e67eb53880ee1ddf00fb4fb3e37a5b0f7922e1c8cef80cb472b1864`。切替前後の保存データfingerprintは一致、server healthy、公開Auth capabilities 200、未認証の削除API 401。
- 証跡はサーバー`releases/retention-20260913/`と最終版の`releases/retention-final-20260914/`。旧serverを保持。schema 0008は旧binaryの認識範囲外なので、単純に旧imageへ戻さない。新規予約がない場合に限る制御されたrollbackか、前進修正を行う。
- 実利用者の削除、30日の実時間経過、1年の実時間経過、Apple実credentialの失効、署名済み実機の予約／取消画面は未実施。期限境界は隔離fixtureで確認した。
