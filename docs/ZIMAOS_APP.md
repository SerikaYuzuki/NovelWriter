# ZimaOSのふみにわ同期アプリ

この手順はサーバー上でClaudeが実施する。実装worktreeは`codex/zimaos-app`。本書の追加は本番への反映・移行成功の証跡ではない。Codexは本番へ接続しない。

## 構成と確認済みの制約

アプリはpostgres／server／edge／opsの4サービス。既存のDB・Caddy volumeをexternalで引き継ぎ、コンテナ名は変えない。migrator／provisionは含めない。schemaを変える更新では、[従来のCLI移行契約](sync/v2/deployment.md)でbackup・隔離DBでの試験・migratorを別途実行する。

| 要素 | 場所・役割 |
| --- | --- |
| 管理画面 | `SyncServerV2/ops/ops_web.py`。Python標準ライブラリ、既定8790。cronは引き続きSupercronic／PID 1 |
| アプリ雛形 | `SyncServerV2/zimaos/app-compose.template.yml`。JSON互換のYAML、4サービスとexternal volume／ネットワーク／x-casaos |
| 生成 | `SyncServerV2/zimaos/render_app_compose.py`。旧コンテナとimageのinspect、具体値の埋込、`docker compose config -q` |
| 準備 | `SyncServerV2/zimaos/prepare.sh`。opsだけをbuild、稼働serverのimage IDをtag／push、compose生成 |
| レジストリ | アプリ外の`fuminiwa-registry`。`registry:2`、`127.0.0.1:5000:5000`、volume `fuminiwa-registry-data`、restart unless-stopped |

2026-10-03にClaudeがZimaOS **v1.7.0**で確認した条件（利用者からの引継ぎ）：

- UIインポートは常にpullし、`pull_policy: never`を無視する。ローカルのみのimageは使えない。loopbackレジストリからのpullは成功済み。
- file-backed top-level secrets（実際にはbind）、external volume、service_healthy依存、unless-stoppedは試験済み。
- top-level nameは無視され、project名はランダムになる。全サービスにcontainer_nameを指定する。
- `.env`は読まれない。生成物には具体値を入れる。Composeの`$`は`$$`にescapeして、元の値を保存する。
- 保存先は`/var/lib/casaos/apps/<random>/docker-compose.yml`（root 0600）。インストール・更新・削除はZimaOS UIで行う。そこへ直接書き込まない。
- reckyは999:1000、dockerグループ、sudo不可。既存secretをホストから読まず、必要な新しいコピーだけrootの一時コンテナで作成する。

レジストリは既設なので作り直さない。以下は将来の復旧時の構成例であり、移行コマンドには含めない：

```sh
docker run -d --name fuminiwa-registry --restart unless-stopped \
  -p 127.0.0.1:5000:5000 -v fuminiwa-registry-data:/var/lib/registry registry:2
```

レジストリvolumeはimageの保存先で、DB・原稿のbackupではない。アプリ削除や片付けに巻き込まない。

## 管理画面の境界

日本語・ライト／ダーク・スマホ幅に対応する。5コンテナの状態／health／restart／起動時刻、最後の成功と次回予定、直近20件の完了backup名・サイズ、server／opsの直近100行を表示する。表示はリクエスト時のみ更新し、polling・外部CDN・追加pip／apkは使わない。待機CPUの実測は反映後に`docker stats --no-stream`で確認する。

変更操作は「今すぐバックアップ」だけ。cron・CLIと同じ`backup.py`を使い、既存の`daily/.lock`を取得して、同じopen file descriptorを子へ渡す。Web間、Webとcron／CLIの重複は拒否する。backup形式・暗号化・保持期限は従来どおり。停止・削除・設定変更・任意コマンド・backupダウンロードのHTTP入口はない。停止・更新前にはWebからのbackupも完了を待つ。Webの子プロセスはcron jobではないため、Supercronicの終了待ちや5分のstop graceだけに完了を委ねない。

Basic認証は`admin`固定。passwordは`/run/secrets/ops-ui-password`のみから読み、hashを定数時間比較する。16〜1024 bytes（末尾改行可）、mode 0400／0600で999から読めること。未設定・読取不可・不正なpassword／portではUIを起動せず、cronは動かす。passwordファイルがあるのにUIを起動できなかった場合、または起動済みUIが停止した場合はops healthも失敗する。unhealthyだけでは自動再起動しない。POSTはhttp OriginのauthorityとHostの一致、およびランダムなフォームトークンを両方要求する。password変更はファイル差替え後、ZimaOS UIからopsを再作成して読み返す。

ops専用bridgeに8790だけを公開し、同期用bridgeには接続しない。UI・backupのコードに外向き通信はない。通常のbridge自体は外向き通信の禁止を保証しない。`internal: true`は別ネットワークからの到達も制約するので、LAN管理画面のため採用していない（[Docker network create](https://docs.docker.com/reference/cli/docker/network/create/#internal)）。Basic認証はHTTPなので信頼するLAN内で使用し、Tunnel／routerから8790を公開しない。公開同期の8443とは別の入口である。

環境変数・inspect全文・healthcheckの出力・Dockerエラー本文・secretファイル内容をHTTPへ出さない。ログはANSIを除去し、inspectから得た環境値とUI passwordを伏せ、credentialらしい行や長いtokenも伏せる。原稿や任意の秘密文字列をログに書いてよい仕組みではない。server側の「生tokenやkeyをログに出さない」契約は引き続き必要。

Docker socketへの権限はホスト管理権限である。HTTPに任意実行を足さない。read_only、cap_drop、no-new-privileges、tmpfs、healthcheckは旧inspectから引き継ぎ、想定外のmountや不足は生成失敗にする。

## 準備（まだ旧コンテナを止めない）

サーバー上でこの変更を取り込んだリポジトリrootから実行する。手元worktreeから本番へSSHする手順ではない。

```sh
umask 077
base=/DATA/AppData/fuminiwa-sync-v2-role-split
export DOCKER_CONFIG="$base/ops/docker-config"
mkdir -p "$DOCKER_CONFIG" "$base/ops" /DATA/AppData/fuminiwa-sync/config
chmod 700 "$DOCKER_CONFIG"
docker compose version
docker buildx version
docker inspect fuminiwa-registry --format '{{.State.Running}} {{json .HostConfig.PortBindings}}'
```

新しいDOCKER_CONFIGとsystem plugin検索でcompose／buildxが使えることを先に確認する。見つからなければ既存のsystem pluginの場所を調べ、書込可能な`$DOCKER_CONFIG/cli-plugins`へsymlinkする。rootの`/DATA/.docker`を読み出す／chmodする必要はない。registryはrunningかつhost bindingが127.0.0.1:5000であること。

### 新しい参照先を用意する

既存のgoogle secret（release配下）とCaddyfile（source配下）を、新しい参照先へコピーする。元ファイル・既存runtime keyは変更しない。`test ! -e`で既存コピーの上書きを拒否する。既に準備済みなら、そのコピーとの一致・owner／modeをrootコンテナで確認してこの段だけを省略する。値を端末へ表示しない。

```sh
docker run --rm --network none --user 0:0 --entrypoint sh \
  --mount type=bind,src="$base/releases/browser-auth-20260927/google-client-secret",dst=/from/google-client-secret,readonly \
  --mount type=bind,src="$base/runtime-secrets",dst=/to \
  postgres:16 -c 'set -eu; test ! -e /to/google-client-secret; cp /from/google-client-secret /to/google-client-secret; chown 10001:10001 /to/google-client-secret; chmod 400 /to/google-client-secret'
docker run --rm --network none --user 0:0 --entrypoint sh \
  --mount type=bind,src="$base/source/Caddyfile",dst=/from/Caddyfile,readonly \
  --mount type=bind,src=/DATA/AppData/fuminiwa-sync/config,dst=/to \
  postgres:16 -c 'set -eu; test ! -e /to/Caddyfile; cp /from/Caddyfile /to/Caddyfile; chmod 644 /to/Caddyfile'
```

コピー元は現在のinspectのMounts.Sourceと一致することを確認する。上の値は引継ぎ済み現行配置であり、変わっていたら実際のパスを使う。生成スクリプトは6つのruntime secretの親directoryからgoogleの新参照先を決める。Caddyfileの既定の新参照先は`/DATA/AppData/fuminiwa-sync/config/Caddyfile`。

UI passwordはreckyのTTYで非表示入力する。値はコマンド引数・compose・env・ログへ入れない。新しいファイルを排他的に作る（既存passwordを上書きしない）：

```sh
python3 - <<'PY'
import getpass, os
from pathlib import Path
path = Path('/DATA/AppData/fuminiwa-sync-v2-role-split/ops/ops-ui-password')
first = getpass.getpass('ops UI password (16+ bytes): ').encode()
if not 16 <= len(first) <= 1024 or b'\n' in first or b'\r' in first:
    raise SystemExit('Invalid password length/content')
if first != getpass.getpass('Repeat: ').encode():
    raise SystemExit('Mismatch')
with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as out:
    out.write(first + b'\n')
PY
```

### build・push・生成

旧4コンテナがrunningのまま実施する。prepareはコンテナの停止／rename／更新を行わない。タグは更新ごとに変える。serverのbuildは行わず、**稼働中のimage IDそのもの**をタグ付けする。

```sh
SyncServerV2/zimaos/prepare.sh role-split-20261003 ops-ui-20261003 \
  "$base/ops/zimaos-app-compose.yml"
docker compose --env-file /dev/null -f "$base/ops/zimaos-app-compose.yml" config -q
```

出力は0600。server環境（imageの既定値も含む）・secretのホストパス・既存volumeをinspectから取得し、postgres／caddyは稼働imageのRepoDigestで固定する。serverのタグが旧image IDと一致しない、inline credential、secret mount／必須設定／health／安全設定の欠落、想定外のmount、Compose検証失敗では出力を置換しない。secret内容と`.env`は読まない。既存出力は検証成功時のみatomicに置換する。

生成物には非公開の配置・認証client ID等が含まれる。Gitへ入れず、UIインポートにだけ使う。UI用port等を変える場合は直接生成スクリプトの`--ui-port`／`--ui-host`／`--ui-password-file`／`--caddyfile`を指定する。

## 移行（Claudeと利用者）

準備が成功した後、利用者がZimaOS UIを操作できる時間に行う。同じ名前の旧コンテナが残ったままのインポートは失敗する。

1. 旧opsでbackupを取得し、exit 0と`last-success.json`更新を確認する。
2. opsを最初に停止して定期backupを抑止する。その後edge→server→postgresを停止する。稼働中のbackupがある場合は終了を待つ。
3. 旧4コンテナを`-legacy`へrenameし、削除せず残す。旧ops projectはこの停止で停止済み。旧composeの`up`を実行しない（同じ名前を再作成するため）。
4. 利用者がZimaOSのカスタムアプリ画面から生成composeをインポートする。インストールでimageがpullされ、random project名で新4コンテナが作られる。
5. 次節の検証が完了するまでlegacy・旧compose・旧secret・旧Caddyfileを保持する。

```sh
docker exec fuminiwa-sync-v2-ops run-backup
# 成功時刻を確認。内容は時刻とbackup名のみ。
cat "$base/operational-backups/daily/last-success.json"
# 以下はbackupの終了・上のread-back成功後だけ。
docker stop --time 300 fuminiwa-sync-v2-ops
docker stop fuminiwa-sync-v2-role-split-edge fuminiwa-sync-v2-role-split-server fuminiwa-sync-v2-role-split-postgres
docker rename fuminiwa-sync-v2-role-split-postgres fuminiwa-sync-v2-role-split-postgres-legacy
docker rename fuminiwa-sync-v2-role-split-server fuminiwa-sync-v2-role-split-server-legacy
docker rename fuminiwa-sync-v2-role-split-edge fuminiwa-sync-v2-role-split-edge-legacy
docker rename fuminiwa-sync-v2-ops fuminiwa-sync-v2-ops-legacy
# ここで利用者がZimaOS UIからインポート。
```

`-legacy`が既にあればrename前に停止し、前回作業の状態を確認する。旧ops projectへの`down`は旧containerを削除するので使わない。migratorは今回実行しない。移行は同じserver binary・同じDBで、schemaを変更しない。

## 反映後の検証

```sh
for name in fuminiwa-sync-v2-role-split-postgres fuminiwa-sync-v2-role-split-server fuminiwa-sync-v2-role-split-edge fuminiwa-sync-v2-ops; do
  docker inspect "$name" --format '{{.Name}} {{.State.Status}} {{.State.Health.Status}} {{.HostConfig.RestartPolicy.Name}}'
done
curl --fail --silent --show-error --output /dev/null --write-out '%{http_code}\n' \
  -H 'x-fuminiwa-client-version: 0.1.0' https://sync.serika.work/v1/auth/capabilities
# <CA.pem>を実際に信頼するCaddy CAの公開証明書へ置き換える。-kで代用しない。
curl --fail --silent --show-error --cacert '<CA.pem>' --output /dev/null --write-out '%{http_code}\n' \
  -H 'x-fuminiwa-client-version: 0.1.0' https://192.168.11.5:8443/v1/auth/capabilities
curl --silent --output /dev/null --write-out '%{http_code}\n' http://192.168.11.5:8790/
# admin passwordはcurlのプロンプトで入力。
curl --fail --silent --show-error --user admin --output /dev/null --write-out '%{http_code}\n' http://192.168.11.5:8790/
docker exec fuminiwa-sync-v2-ops sh -c 'grep -E "^(Name|State|Uid|Gid|Groups):" /proc/1/status'
docker logs --tail 100 fuminiwa-sync-v2-ops
docker stats --no-stream fuminiwa-sync-v2-ops
```

4コンテナはrunning／healthy／unless-stopped。旧imageとのID一致・external volumeの名前・secretとCaddyfileの新参照先も読む。capabilitiesの2経路はともに**200**、UI未認証は401、正しいBasicで200。画面から「今すぐバックアップ」を1回実行し、実行中のボタン無効・二重POST拒否、完了後のlast-success・新backup名／サイズ、opsログexit 0を確認する。UIやhealthの成功は原稿・account isolationの実機受入を代替しない。

次の03:17 JSTの定期成功、ホスト再起動後の4コンテナ／registry復帰とhealth、UI、次回予定は別の受入として確認する。停止中の予定は追いかけ実行しない。ops healthは非rootのPID 1 cron・起動済みUIの生存・36時間未満のbackup成功を判定する。

## ロールバック

この構成移行の失敗に対する切戻し。schema変更を伴う将来の更新にそのまま使わない。

1. 利用者がZimaOS UIから新アプリを停止・削除する。**external volume／データを削除する選択はしない**。4つの元のcontainer名が空いたことを確認する。中途半端なインストールもUIで処理する。
2. legacyを元の名前へ戻す。registryは止めない。
3. postgresを開始してhealthyを待ち、server、edge、opsの順で開始する。healthと両capabilities、CLI backupを再確認する。

```sh
# UI削除後。元の名前に新containerが残っていたらここで止める。
docker rename fuminiwa-sync-v2-role-split-postgres-legacy fuminiwa-sync-v2-role-split-postgres
docker rename fuminiwa-sync-v2-role-split-server-legacy fuminiwa-sync-v2-role-split-server
docker rename fuminiwa-sync-v2-role-split-edge-legacy fuminiwa-sync-v2-role-split-edge
docker rename fuminiwa-sync-v2-ops-legacy fuminiwa-sync-v2-ops
docker start fuminiwa-sync-v2-role-split-postgres
# healthyをread-backしてから次の行。
docker inspect fuminiwa-sync-v2-role-split-postgres --format '{{.State.Health.Status}}'
docker start fuminiwa-sync-v2-role-split-server
# server healthyを確認してからedge／ops。
docker inspect fuminiwa-sync-v2-role-split-server --format '{{.State.Health.Status}}'
docker start fuminiwa-sync-v2-role-split-edge fuminiwa-sync-v2-ops
# 「反映後の検証」の2経路とhealth、次を確認。
docker exec fuminiwa-sync-v2-ops run-backup
```

旧ops imageにはUIがないのでUI検証は対象外。rename／startは旧コンテナの環境・マウントを保持する。旧serverは元のrelease secret、旧edgeは元のCaddyfileを参照し続ける。

## 更新と片付け

更新時は最初にbackupと変更範囲を確認する。opsだけの更新は新しいタグでbuild／pushし、現在のapp composeのops imageだけを差し替える。移行後にprepareを再実行するとserverはその時点の稼働imageを再タグ付けするだけであり、新server binaryは作らない。server更新は従来のbuild・migration契約に従い、新imageをregistryへpushして更新する。

ZimaOS UIで次のどちらが可能かは**Claudeが実機で検証する**。repositoryからCasaOS保存ファイルを直接編集しない。

- 推奨候補：アプリのcompose編集／更新UIでimageを新タグへ変更し、pull・再作成する。image ID、他サービスの再作成範囲、container_nameとexternal volume維持を確認する。
- 別候補：同タグを再pushしてUIの再pull／再作成操作を使う。操作の有無とcacheを使わず新IDになることを確認する。変更内容をタグで追跡しにくいので、通常は新タグを使う。

UIで部分更新できなければ、backup→アプリ停止→UIで再インポートの方式を検証する。必ず既存volumeをexternalで引き継ぐ。schema移行を伴う更新は、旧binaryが新schemaを扱えるという根拠なしに切り戻さない。

成功後の片付けは**利用者の確認後**。対象は停止した4つの`-legacy`コンテナと不要な旧image／releaseコピーを個別に列挙し、旧runtime／Caddyfile参照がなくなったことを確認してから行う。DB・Caddy・registry volume、backup鍵、daily、現行secretは残す。`down -v`／volume rm／system pruneは使わない。現時点の作業に片付けは含まない。

## ローカル検証と未実施の境界

```sh
# cryptographyがあるPython環境。UIと生成処理自身は標準ライブラリだけ。
python3 -m unittest discover -s Scripts/operations -p 'test_*.py' -v
# Dockerがある環境のみ。稼働サーバーを使うローカル検証ではない。
docker build -f SyncServerV2/ops/Dockerfile -t fuminiwa-sync-v2-ops:test .
```

fake Dockerテストは認証、CSRF、操作の限定、秘密の非表示、Web／CLIの排他、inspect生成、欠落拒否、秘密を読まないこと、volume／digest／container_name、config検証前のatomic置換、prepareの操作範囲を扱う。2026-10-03のローカル検証では既存backup／opsを含む31テストと`./Scripts/check.sh`全段が成功した。ローカルにDocker CLIがないため実imageのbuildと実Composeのconfig検証は未実施。fake CLIによるconfig呼出の確認とは区別する。ZimaOS UIインポート、LAN到達、待機CPU、停止時の処理、実backup／翌日の定期成功／再起動は別途Claude側で実施する。
