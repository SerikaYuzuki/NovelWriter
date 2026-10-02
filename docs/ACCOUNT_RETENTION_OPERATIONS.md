# アカウント削除とバックアップの自宅サーバー運用

運用先は`192.168.11.5`。この処理にCloudflare有料サービスは不要。通常保存は端末SQLite、削除対象は明示予約されたremote accountだけである。以下は構成と復旧手順であり、実行時の稼働状態は`last-success.json`等で確認する。

## 有効な自動処理

| 処理 | 実装・実行条件 |
| --- | --- |
| 30日猶予 | [lifecycle v1](auth/v1/account-deletion.md)。予約DB時刻＋720時間、期限前の取消、猶予中の通常利用 |
| 削除worker | Rust serverの30秒周期、1回最大16件。失敗／再起動後はpendingを再処理。remote消去とそのmarkerは同一transaction。account削除完了はApple失効後に記録 |
| Apple失効 | 既存の永続workerを利用。成功までcredentialを保持し、成功後にidentity対応を除去 |
| バックアップ | 毎日03:17 日本時間（`TZ=Asia/Tokyo`）に実行用コンテナ`ops`のcronで実行。DBのcustom-format dump、復元用鍵、container構成をAES-256-GCMで暗号化 |
| 保持期限 | 作成から1暦年、UTCで翌年の同月同日時刻。2月29日は翌年2月28日。新しいbackupの取得・認証検証が成功した場合だけ期限切れを整理 |

保存先は`/DATA/AppData/fuminiwa-sync-v2-role-split/operational-backups/daily/`。暗号鍵は同階層のbackup directory内へ置かず、`backup-keys/backup-aes256.key`に0600で保存する。DBの中身、provider credential、暗号鍵はGitやログへ出さない。

`Scripts/operations/backup.py`が運用実装、`backup-config.json`がサーバー内の非公開設定。`daily/last-success.json`に完了時刻とbackup名を残す。実行用コンテナの実行結果はコンテナログへ出す。従来のホストcronが作成した`operational-backups/last-run.log`は過去の証跡として保持し、新しいコンテナでは更新しない。36時間以上成功がなければ失敗として調べる。バックアップ失敗時に古いbackupを削除しない。所有manifestと既知ファイルだけを期限管理し、不明ファイル・symlinkは触らない。

過去の手動退避・旧releaseにあるbackupは自動整理対象へ勝手に取り込まない。1年保持が自動適用されるのは上記daily配下で作成するbackupである。

## 再起動後も続く定期実行

2026-10-03の利用者の決定により、実行時刻を従来のサーバー現地時刻（Europe/London）から**毎日03:17 日本時間**へ変更する。ZimaOS v1.7.0では`/var/spool/cron/crontabs/`が再起動で初期化され、ユーザーcronの登録が消えた。sudoはパスワード必須で`/etc`も書けないため、ホストcronの再登録に依存せずDockerの`restart: unless-stopped`を使う。ここに記すコンテナ構成は実装手順であり、本番への反映・再起動受入の証跡ではない。

`SyncServerV2/docker-compose.ops.yml`を別project `fuminiwa-sync-v2-ops`として起動する。serviceは`ops`、imageは`fuminiwa-sync-v2-ops:local`、containerは`fuminiwa-sync-v2-ops`。既存のpostgres/server/edgeを作り直さずに単独で更新できる。将来の管理用コンテナの土台とするが、今回Web画面・公開portは持たない。対象コンテナへの操作はDocker socket経由で行い、ops自体のnetworkは`none`。

Alpineのpython3・py3-cryptography・docker-cli・supercronic・tzdataを使用する。Supercronicはコンテナ向けのcronで、環境変数・標準出力・終了signalを扱える（[公式仕様](https://github.com/aptible/supercronic)）。ソースのビルドやpipは不要。待機中はcronが次の予定まで待機する。実際のimageサイズ・CPUはビルド後に確認する。

起動時だけrootでsocketのgidを読み取り、補助グループへ追加してからgid 1000／uid 999へ永久に権限を落とす。PID 1のcronとbackup処理は非root。ホストsocketのchmod/chown、`/etc/group`編集はしない。Composeのcapabilityはこの初期化に必要な`SETUID`／`SETGID`だけ。`docker exec ... run-backup`も同じ権限移行を通す。socketへの接続権はホストDockerの管理権を持つため、このコンテナを外部利用者向けの実行環境にはしない。

umaskは077。新しいbackupのfolderは0700、暗号化ファイル・manifest・成功記録・一時設定は0600、所有者は999:1000。既存ファイルの所有者や権限は自動変更しない。鍵は0600／32 bytesでuid 999から読めること。configもuid 999から読める必要がある。cronと一時設定はtmpfsの`/run/ops`に置く。

hostの`backup-config.json`と鍵を読み取り専用、dailyを読み書き可能でマウントする。hostの設定は変更せず、呼び出し側が`backup_directory`を`/backups`、`key_file`を`/run/secrets/backup-aes256.key`へ読み替えた0600の一時設定で、image同梱の`backup.py --config ...`を呼ぶ。database、**database_user**、server_instance_idなどは既存設定を引き継ぐ。postgres/serverのcontainer名はopsのenvで指定できる。`backup.py`のロジック・形式・1暦年保持は変更しない。同じdailyをマウントするため、手動・cron・旧ホスト処理も既存の`.lock`で競合を拒否する。

`FUMINIWA_BACKUP_TZ`と`FUMINIWA_BACKUP_TIME`（24時間制`HH:MM`）で予定を変更できる。既定は`Asia/Tokyo`／`03:17`、cron式は`17 3 * * *`。起動ログにtimezoneと次回実行予定を出す。起動直後のbackup・停止中の予定の追いかけ実行は行わない。設定変更後はopsだけを再作成する。

### デプロイ（Claude側でサーバー上から実施）

変更一式を反映したサーバー上のリポジトリrootで実行する。opsのbuild contextはrootであり、Dockerfile専用ignoreによりbackup.pyとops実装だけを取り込む。ホストに退避されたbackup.pyには依存しない。

1. 非公開設定・鍵・dailyの存在と999:1000のアクセス権、設定のdatabase_user／server_instance_id、現在の対象container名を確認する。`FUMINIWA_BACKUP_DIRECTORY_HOST_PATH`は既存configのbackup_directoryと同じdailyにする。鍵を作り直したりbackup directoryを移動したりしない。
2. 生きている旧backup cronがあれば、そのbackupの1行だけを外し、ほかのcronを保持する。自動・手動処理が走っていないことを確認する。既存の`.lock`は削除しない。
3. 初回だけenvファイルを作成する。更新時は既存envを保持する。秘密の値は書かず、ファイル参照だけを設定する。

```sh
# 初回のみ。作成後、必要ならパス・container名・時刻を編集する。
umask 077
mkdir -p /DATA/AppData/fuminiwa-sync-v2-role-split/ops
cp SyncServerV2/ops/ops.env.example /DATA/AppData/fuminiwa-sync-v2-role-split/ops/ops.env
chmod 600 /DATA/AppData/fuminiwa-sync-v2-role-split/ops/ops.env
```

```sh
# 初回・更新共通。既存role-split projectへup/downしない。
ops_env=/DATA/AppData/fuminiwa-sync-v2-role-split/ops/ops.env
docker build -f SyncServerV2/ops/Dockerfile -t fuminiwa-sync-v2-ops:local .
docker image inspect fuminiwa-sync-v2-ops:local --format '{{.Size}}'
docker compose --env-file "$ops_env" -f SyncServerV2/docker-compose.ops.yml \
  -p fuminiwa-sync-v2-ops config
docker compose --env-file "$ops_env" -f SyncServerV2/docker-compose.ops.yml \
  -p fuminiwa-sync-v2-ops up -d --no-build
docker logs --tail 50 fuminiwa-sync-v2-ops
docker exec fuminiwa-sync-v2-ops sh -c 'grep -E "^(Name|State|Uid|Gid|Groups):" /proc/1/status'
docker inspect fuminiwa-sync-v2-ops --format '{{.HostConfig.RestartPolicy.Name}} {{.State.Health.Status}}'
```

`Uid`／`Gid`は999／1000、`Groups`はsocketのgidを含み、restart方針は`unless-stopped`であること。起動ログの次回予定が日本時間03:17であることを読む。Docker socketがgroupで使えない、鍵が読めない、configの必須項目がない場合は起動失敗になる。read-only configの内容差し替えはopsの再作成後に確認する。

### 手動実行・ログ・health

```sh
docker exec fuminiwa-sync-v2-ops run-backup
docker logs --since 48h fuminiwa-sync-v2-ops
docker exec fuminiwa-sync-v2-ops ops-healthcheck
docker inspect fuminiwa-sync-v2-ops --format '{{.State.Health.Status}}'
cat /DATA/AppData/fuminiwa-sync-v2-role-split/operational-backups/daily/last-success.json
docker stats --no-stream fuminiwa-sync-v2-ops
```

cronのログとbackupの標準出力・標準エラーはコンテナログへ出る。手動実行の結果はexecの出力へ返る。成功はbackup.pyの完了出力、exit 0、last-success.jsonの更新で確認する。重複実行は非zeroとなり、成功記録は更新しない。Dockerログは10MB×3に制限し、暗号鍵やconfig内容は表示しない。

healthcheckは5分ごとに、PID 1のcron（Supercronic）が非rootで生存していることと、`last-success.json`のcompleted_atが**36時間未満**であることを確認する。mtimeでは判定しない。36時間ちょうど、未来時刻、不正な記録、記録なしもunhealthy。記録がない初回は、初めて成功するまでunhealthyとなる。過去の成功はコンテナ再作成・ホスト再起動でもdailyに残るため、36時間の判定をリセットしない。`unhealthy`だけでDockerは自動再起動しない。cronの死活とbackup失敗の理由をログで調べ、必要な修正後に手動実行する。

実サーバーへの反映後は初回手動backupで暗号化成功・所有者／権限・healthを確認し、次の03:17 JSTの定期成功と、ホスト再起動後のops復帰・次回予定・36時間判定を別々に読み返す。postgres/server/edgeの再起動方針と起動順序は[SyncServerV2 README](../SyncServerV2/README.md#restart-policy-and-ops)を参照する。

## 復旧

1. public trafficを遮断し、別の隔離DBを用意する。稼働DBへ直接上書きしない。
2. `backup.py --decrypt <database.enc> --key-file <key>`の出力を隔離先の`pg_restore`へ渡す。復号は全ファイルのGCM検証完了後にのみ出力する。`secrets.enc`と`configuration.enc`も同じ方法で復元するが、秘密情報を端末出力へ表示しない。
3. DB内容、role、server instance、migration、鍵との対応を照合する。現在の削除完了記録・削除予約と照合し、backup後に削除されたaccountを再公開しない。照合できない古いbackupは公開環境へ戻さない。
4. 復元先で期限を過ぎた予約を処理し、原稿保全・認証・削除済みaccount拒否を確認してからtrafficを戻す。

暗号鍵も同じ自宅サーバーにあるため、サーバー・ディスク全損にはこれだけで対応できない。2026-09-26に、この損失を許容して外部バックアップを設けない方針を採択した。別機器／別媒体の退避先は必須の判断待ちではない。自動復元やbackupによる利用者アカウント回復は行わない。最新の隔離DB復元確認とその限界は[原稿保全・AI計画](PROTECTION_AI_PLAN.md)。

## 反映済み構成と証跡

2026-09-14の反映記録はserverの`releases/retention-final-20260914/`（途中記録は`releases/retention-20260913/`）。当時のimageは`sha256:c6e4ed3b3e67eb53880ee1ddf00fb4fb3e37a5b0f7922e1c8cef80cb472b1864`。隔離DBの期限境界・復元・migration、切替前後のデータ保持とhealthを確認した記録であり、現在の稼働image・日次成功は運用時に読み返す。

schema 0008を知らない旧binaryへ単純に戻せない。切り戻しは新規予約の有無とschemaを照合した手順か、前進修正で行う。実利用者の削除、30日／1年の実時間経過、Apple実credential失効、アプリの予約／取消画面の受入はこの記録に含まない。


2026-09-26に原稿保全とAI記録を反映した。現行imageは`sha256:f07038268fe26a9ff063bb23042448c1d8b8a46c9b62b4bf42a6d91747943901`、schema 0009。証跡は`releases/protection-ai-20260926/`の`rehearsal.json`、`live-migration.log`、`deployed.json`。更新前backupを所有者・ACL付きで別DBへ復元して8→9 migrationを確認し、本番更新後も件数・health・公開TLS・認証必須を確認した。更新後の暗号化backupも成功。詳細と端末受入の区別は[受入記録](PROTECTION_AI_ACCEPTANCE.md)。schema 0009を知らない旧binaryへの単純な切戻しは行わない。

2026-10-02（JST）にSync v2全体レビューの修正（PR #69、schema 0011・head-first/backfill download・gzip）を反映した。現行imageは`sha256:18b2f4567b7ce009c497924d7ee8c5ad18fa26f1d02b1cc9a8594260674d3170`。証跡は`releases/sync-review-20261002/`の`rehearsal.json`、`live-migration.log`、`deployed.json`、`Caddyfile.before`。最新の暗号化backupを隔離DBへ復元して10→11 migrationとrole attestationを確認し、本番でも反映直前の暗号化backup（`20261001T215249Z-356a7e49`）取得後に移行した。作品13・snapshot 2,160・object 2,162・account 2が前後で一致、health正常、未認証のdownload（通常・`mode=head`）は401。edgeはCaddyfileへgzipを追加してvalidate後にreloadし、healthを確認した。小さい未認証応答は既定の最小サイズ未満のため圧縮されない。認証付きの大きい応答の圧縮と、実端末からの同期・初回取り込みの受入は未確認。schema 0011を知らない旧binaryへの単純な切戻しは行わない（旧containerは`fuminiwa-sync-v2-role-split-server-before-sync-review-20261002`として保持）。
