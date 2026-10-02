# ZimaOSのふみにわ同期アプリ

この手順はサーバー上でClaudeが実施する。実装worktreeは`codex/zimaos-app`。本書の追加は本番への反映・移行成功の証跡ではない。Codexは本番へ接続しない。

## 構成と確認済みの制約

アプリはpostgres／server／edge／opsの4サービス。既存のDB・Caddy volumeをexternalで引き継ぎ、コンテナ名は変えない。migrator／provisionは含めない。schemaを変える更新では、[従来のCLI移行契約](sync/v2/deployment.md)でbackup・隔離DBでの試験・migratorを別途実行する。

| 要素 | 場所・役割 |
| --- | --- |
| 管理画面 | `SyncServerV2/ops/ops_web.py`。Python標準ライブラリ、既定8790。cronは引き続きSupercronic／PID 1 |
| アプリ雛形 | `SyncServerV2/zimaos/app-compose.template.yml`。内部読込用のJSON、4サービスとexternal volume／ネットワーク／x-casaos |
| 生成 | `SyncServerV2/zimaos/render_app_compose.py`。旧コンテナとimageのinspect、具体値の埋込、文字列をクォートしたblock YAML出力、volume自己検査、`docker compose config -q` |
| 準備 | `SyncServerV2/zimaos/prepare.sh`。opsだけをbuild、稼働serverのimage IDをtag／push、compose生成 |
| API操作 | `SyncServerV2/zimaos/zimaos_app.py`。host python3、loopback限定、非表示入力・token更新・install／apply／uninstall |
| 自動移行 | `SyncServerV2/zimaos/migrate.sh`／`migrate_app.py`。事前確認・backup・退避・受入・失敗時の切戻し |
| レジストリ | アプリ外の`fuminiwa-registry`。`registry:2`、`127.0.0.1:5000:5000`、volume `fuminiwa-registry-data`、restart unless-stopped |

2026-10-03にClaudeがZimaOS **v1.7.0**で確認した条件（利用者からの引継ぎ）：

- UIインポートは常にpullし、`pull_policy: never`を無視する。ローカルのみのimageは使えない。loopbackレジストリからのpullは成功済み。
- file-backed top-level secrets（実際にはbind）、短い書式のexternal volume、service_healthy依存、unless-stoppedは試験済み。長い書式のnamed volumeは以下の本番試験で失敗した。
- top-level nameは無視され、project名はランダムになる。全サービスにcontainer_nameを指定する。
- `.env`は読まれない。生成物には具体値を入れる。2重展開があるためシェル変数参照を禁止し、healthcheckのコマンド置換だけを`$$(...)`で出力する。変数を使わずに意味を保てない設定は生成失敗にする。
- 保存先は`/var/lib/casaos/apps/<random>/docker-compose.yml`（root 0600）。インストール・更新・削除はUIまたは下記APIクライアントで行う。保存ファイルへ直接書き込まない。
- reckyは999:1000、dockerグループ、sudo不可。既存secretをホストから読まず、必要な新しいコピーだけrootの一時コンテナで作成する。

### 本番インポートで判明したvolumeの書換え

2026-10-03の利用者報告による実測。JSON形式の生成composeでnamed volumeを長い書式（`type: volume`／`source: db`等）にすると、ZimaOSがbindへ書き換えた。

| 対象 | インポート後のbind先 | 結果 |
| --- | --- | --- |
| postgresの`db` | `/tmp/casaos-compose-app-<n>/db` | 空のdirectoryを参照し、postgresが初期化できず再起動ループ |
| edgeの`caddy-data` | `/tmp/casaos-compose-app-<n>/caddy-data` | 既存Caddy volumeを参照しなかった |
| edgeの`caddy-config` | `/DATA/AppData/postgres/config` | 既存Caddy volumeを参照しなかった |

長い書式の`type: bind`（secret、Caddyfile、opsの各bind）とtop-level `secrets: file:`は正しく扱われた。一方、事前のYAML試験アプリでは`probe-data:/data:ro`と`external: true`／`name: fuminiwa-casaos-probe-data`の組合せで、既存volumeがそのままマウントされた。この比較だけでは、JSON形式と長い書式それぞれの影響を切り分けられない。今回の修正では両方を変更する。

インポート用composeはblock YAMLにし、named volumeを短い書式に限定する。top-level volumesのkeyとnameは既存の外部volume名そのものに揃える。文字列はすべてdouble quoteで囲み、改行・引用符・非表示文字をescapeする。healthcheck時間は`5s`／`5m`等で表し、nsの精度は小数表記で保つ。

```yaml
"services":
  "postgres":
    "volumes":
      - "fuminiwa-sync-v2-role-split-data:/var/lib/postgresql/data"
"volumes":
  "fuminiwa-sync-v2-role-split-data":
    "name": "fuminiwa-sync-v2-role-split-data"
    "external": true
```

生成物の自己検査で、長い書式のnamed volume、名前の不一致、named volumeのbindへの置換・欠落を拒否する。`docker compose config -q`の成功だけではZimaOSがインポート後にどう書き換えるかを保証できない。現在の再インポート後の確認先は、postgresの`/var/lib/postgresql/data`、edgeの`/data`／`/caddy-config`。**Typeがvolume、Nameが期待する既存volume名**であることを先に確認する。bindになっていたら新構成を成功扱いにしない。

### 2回目の本番インポート：2重展開と/config書換え

利用者が2回目の本番インポートで確認した結果。短い書式への修正でpostgresの`fuminiwa-sync-v2-role-split-data`とedgeの`/data`（caddy-data）は既存volumeのまま正しくマウントされた。次の2点が残った。

- **composeの変数展開が2回行われる。** YAMLのserver healthcheckは`code="$$(curl ...)"; test "$$code" = 200`だったが、実際のコンテナでは`code="$(curl ...)"; test "" = 200`になった。serverは常にunhealthyで、service_healthy依存のedgeが起動しなかった。`$$(`は2回展開後も`$(`として残り、コマンド置換は動いた。
- **ターゲット/configが予約されたbind先へ書き換えられる。** caddy-configは短い書式でも`/DATA/AppData/postgres/config`へのbindになった。今回の最初のservice名はpostgres。利用者の報告では置換先の形式は`/DATA/AppData/<最初のservice名>/config`。

healthcheckは既存のHTTPコード比較の形を認識して、curlのオプションと`|| true`を保ったまま直接比較に変換する。認識できないシェル変数参照を勝手に書き換えない。生成した構造とYAML全体に対し、`$$`の後が英字・`_`・`{`となる箇所、`${`、その他の変数参照があれば拒否する。環境値やパスに同じ形式が含まれる場合も失敗する。

```yaml
"healthcheck":
  "test":
    - "CMD-SHELL"
    - "test \"$$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --header 'x-fuminiwa-client-version: 0.1.0' http://127.0.0.1:8092/v1/auth/capabilities || true)\" = 200"
```

caddy-configの同じ外部volumeを`/caddy-config`へマウントし、edgeの`XDG_CONFIG_HOME`を`/caddy-config`へ上書きする。Caddyの保存先は[XDG_CONFIG_HOME配下のcaddy directory](https://caddyserver.com/docs/conventions#configuration-directory)なので、volume内の`caddy/autosave.json`等の相対位置は変わらない。中身のコピー・移動・初期化はしない。`/data`と明示的なCaddyfile参照（`/etc/caddy/Caddyfile`）も引き継ぐ。

```yaml
"environment":
  "XDG_CONFIG_HOME": "/caddy-config"
"volumes":
  - "fuminiwa-sync-v2-role-split-caddy-config:/caddy-config"
```

全サービスのvolume／bindターゲットに`/config`がないことも自己検査する。インポート後はedgeの新しいvolume名、XDG_CONFIG_HOME、autosave先を確認する。旧コンテナのinspectでは従来の`/config`の既存volumeを取得し、出力では新しいターゲットを使用する。

### 2回のロールバック実績

利用者報告により、1回目・2回目の失敗はいずれも旧コンテナを`-legacy`から元の名前へ戻し、数分で復旧した。両回ともデータは無傷。復旧後のhealth・公開／LAN capabilities・backupについての個別の実測値や完了時刻は今回の報告には含まれていないため、追加の成功証跡は作らない。Codexは本番へ接続していない。この2回の構成移行の切戻し実績を、schema変更を伴う更新の安全性へ一般化しない。

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

出力は0600のblock YAML。server環境（imageの既定値も含む）・secretのホストパス・既存volumeをinspectから取得し、postgres／caddyは稼働imageのRepoDigestで固定する。named volumeの短い書式はinspectのRWも引き継ぎ、読み取り専用なら`:ro`を付ける。serverのタグが旧image IDと一致しない、inline credential、secret mount／必須設定／health／安全設定の欠落、想定外のmount、volume自己検査・Compose検証失敗では出力を置換しない。secret内容と`.env`は読まない。既存出力は検証成功時のみatomicに置換する。

生成物には非公開の配置・認証client ID等が含まれる。Gitへ入れず、ZimaOSへの取り込みにだけ使う。UI用port等を変える場合は直接生成スクリプトの`--ui-port`／`--ui-host`／`--ui-password-file`／`--caddyfile`を指定する。

## 自動化：最初のloginとAPI操作

利用者の決定（案A）に従い、ログインは利用者がサーバーの端末で行う。repository rootからの1行：

```sh
python3 SyncServerV2/zimaos/zimaos_app.py login
```

ユーザー名を入力し、passwordは`getpass`で非表示入力する。成功出力は「保存しました」だけ。Claudeが先に置いた`ops/zimaos_login.py`で既にログイン済みなら、再ログインは不要。既存の`/DATA/AppData/fuminiwa-sync-v2-role-split/ops/zimaos-token.json`をそのまま使い、今後はrepository版へ置き換えられる。

保存形式は`access_token`／`refresh_token`／`expires_at`（unix秒）／`saved_at`（unix秒）／`username`。passwordは保存しない。ファイルは本人所有の0600、親directoryは本人所有・他者書込不可。symlinkは拒否する。値を`cat`・ログ・コマンド引数・Gitへ出さない。Claudeはファイルの内容を表示せず、スクリプトを実行する。`--token-file <path>`はサブコマンドの前に指定できる。

access tokenは期限の5分前まで再利用し、以降はrefreshする。新しいrefresh tokenを含む組をfsyncして原子的に置換し、CLI間のlockでローテーション競合を防ぐ。refresh／新tokenの保存に失敗したら非0で終了し、`zimaos_app.py login`を案内する。通信途中でrefreshが成功し、応答や保存だけ失敗すると古いrefresh tokenは無効になり得る。その場合も利用者が再ログインする。tokenをバックアップから戻して再利用しない。

APIはhostの`http://127.0.0.1`（既定80）のみ。別ホスト、localhost、IPv6、URL内の認証情報、redirectを拒否し、環境のHTTP proxyも使わない。Authorizationは接頭辞なしを既定とし、401の場合だけ`Bearer `を付けて1回再試行する。APIの本文や例外の詳細は表示しない。エラーはHTTP状態コードと既知の安全なmessageだけを表示し、任意のmessageは伏せる。`status`も環境変数・compose・healthcheck出力ではなく、選んだ状態項目だけを表示する。

Claudeがサーバー上で実行する操作例：

```sh
python3 SyncServerV2/zimaos/zimaos_app.py list
python3 SyncServerV2/zimaos/zimaos_app.py find --container fuminiwa-sync-v2-role-split-server
# 元のcontainer_nameが空いている場合だけ。dry-run成功後に本実行する。
python3 SyncServerV2/zimaos/zimaos_app.py install "$base/ops/zimaos-app-compose.yml" --dry-run
python3 SyncServerV2/zimaos/zimaos_app.py install "$base/ops/zimaos-app-compose.yml"
# 実際にfindで得たidを設定する。表示されるのはidだけ。
app_id=$(python3 SyncServerV2/zimaos/zimaos_app.py find --container fuminiwa-sync-v2-role-split-server)
python3 SyncServerV2/zimaos/zimaos_app.py status "$app_id"
python3 SyncServerV2/zimaos/zimaos_app.py apply "$app_id" "$base/ops/zimaos-app-compose.yml"
# アプリ停止・削除の操作。設定folderは保持し、delete_config_folder=falseを必ず送る。
python3 SyncServerV2/zimaos/zimaos_app.py uninstall "$app_id"
```

`find`は一致がなければexit 3、複数一致や一覧取得失敗はexit 1。installは`dry_run=true&check_port_conflict=true`に成功したときだけ`dry_run=false&check_port_conflict=true`を送る。`--dry-run`なら前半だけ。applyはPUT、uninstallはDELETEで`delete_config_folder=false`を固定する。これらの操作例を一括で順に実行しない。初回移行は次のmigrateを使い、二重にinstallしない。

入口の存在と未認証401は利用者報告により確認済み。認証済みAPIの正確な応答形、dry-runの挙動、PUTのpull／再作成範囲、DELETE完了までの時間はClaudeが実機で確認する。パースは`data`／`token`の包みや一覧のmap／配列を受け入れるが、分からない応答は秘密を表示せず失敗する。Codexはログイン・実APIリクエストをしていない。

## 自動移行（Claudeがサーバー上で実行）

新しいsecret／Caddyfileの参照先は前述の準備で作る。旧4コンテナが稼働中、legacyや同名アプリがない状態で、repository rootから実行する：

```sh
base=/DATA/AppData/fuminiwa-sync-v2-role-split
# serverは稼働中imageをそのままtag。opsだけbuild。タグは更新ごとに変える。
./SyncServerV2/zimaos/prepare.sh role-split-20261003-api1 ops-ui-20261003-api1 "$base/ops/zimaos-app-compose.yml"
python3 SyncServerV2/zimaos/zimaos_app.py list
./SyncServerV2/zimaos/migrate.sh "$base/ops/zimaos-app-compose.yml"
```

migrate.shは書込可能な`DOCKER_CONFIG`を設定し、host python3の`migrate_app.py`を呼ぶ。処理は次の順序：

1. レジストリ稼働、compose config -qとJSON正規化、token、旧4コンテナ稼働、legacy／failed退避名なし、同名containerを持つアプリなしを確認する。normalized composeから期待するvolume・bind・secretのホストパス／RWを作る。検証・installは同じ0600の一時composeを使う。
2. 旧opsで`run-backup`を実行し、exit 0、`last-success.json`の更新・新しい成功時刻・backup名を確認する。失敗時は旧コンテナを止めない。
3. ops→edge→serverを各30秒、postgresを120秒の猶予で停止する。restartをnoへ変更し、4コンテナを`-legacy`へrenameする。旧ops projectは停止したまま残し、旧composeのup／downを実行しない。
4. APIでdry-run→installする。移行用portは8443／8790を要求し、別portのcomposeは停止前に拒否する。新4コンテナの出現を待ち、DB／Caddyの既存volume名、全bindとsecretのSource／Destination／RWを照合する。`/tmp/casaos-compose-app-*`、`/DATA/AppData/<service>/config`、`/config` target、余計なmount、RWの変化は拒否する。server image IDも旧コンテナと同じであることを確認する。
5. 4コンテナのhealthyを最大5分待つ。loopback HTTPSは`-k`、公開HTTPSは証明書検証ありでcapabilitiesを確認し、両方にclient version 0.1.0のheaderを付けて200を要求する。ops UIは未認証401、icon.svgは200・SVG Content-Typeを要求する。

成功時はlegacyを削除せず残す。正しいBasic認証、Webの「今すぐバックアップ」、翌日の定期実行、ホスト再起動の受入は次節のとおり別途行う。schema／server binaryを変える更新にはこの移行スクリプトを使わない。

移行のlockと0600の`ops/zimaos-migration.json`に、旧container ID、composeのhash、phase、アプリidを記録する。tokenやsecret内容は含めない。成功後に同じcomposeで再実行した場合は受入だけ行う。中断した移行では旧IDを照合して切戻す。SIGINT／SIGTERM／SIGHUPも切戻し対象だが、SIGKILL／停電は次回実行時に復旧する。既存legacyのID不一致、旧コンテナ消失、複数アプリなどでは安全側に停止する。

2026-10-03の本番実行では、前提確認後のbackup前の成功記録読み取りがPermission deniedで失敗した。旧コンテナは何も停止していない。原因は、cap_drop ALLのrootにはDAC_OVERRIDEがなく、999所有・0600の記録を直接catできなかったこと。backup前後の読み取りを`docker exec --user 999:1000 ... cat /backups/last-success.json`へ修正した。`run-backup`／`ops-healthcheck`はops.pyが補助グループ設定後に999:1000へ落としてから処理するので、呼出は変更しない。Webも権限移行後に読み取る。修正後の本番再実行結果は未確認。

### 自動ロールバック

backup後の停止／rename／install／mount／health／HTTP受入の失敗は、非0で終了する前に切戻す。新アプリidをfindで特定し、設定folderを保持してuninstallする。DELETEの成功応答だけで完了とは扱わず、一覧からの消滅も確認する。新コンテナの消滅を待ち、残った場合はrestart no・停止後に`-zimaos-failed`へrenameして保持する。legacyは元名へ戻しrestart unless-stopped、postgres→serverのhealthy待ち→edge／opsの順で起動し、4healthと公開200を確認する。registryとDB／Caddy volumeは削除しない。

旧コンテナを復旧し始めた後に処理が中断しても、再実行時に元の名前でAPI削除を繰り返さない。旧IDで復旧を続ける。API削除が確認できない場合は旧構成が復旧していても`rollback-incomplete`・非0とし、Claudeが残ったアプリ管理を確認する。復旧失敗は成功扱いにしない。

切戻し済み記録がある場合は、新たな移行を自動で再開しない。原因、アプリ残存、failed退避、元4コンテナのhealthを確認し、必要な退避コンテナの扱いを利用者と確定する。再試行を決めた後に記録を別名へ退避する：

```sh
# rolled-backかつ残存アプリ／failed退避名の確認が済んだ場合だけ。
# tokenファイルは表示・退避・削除しない。
mv "$base/ops/zimaos-migration.json" "$base/ops/zimaos-migration.$(date +%Y%m%d-%H%M%S).json"
./SyncServerV2/zimaos/migrate.sh "$base/ops/zimaos-app-compose.yml"
```

## 反映後の検証

```sh
for name in fuminiwa-sync-v2-role-split-postgres fuminiwa-sync-v2-role-split-server fuminiwa-sync-v2-role-split-edge fuminiwa-sync-v2-ops; do
  docker inspect "$name" --format '{{.Name}} {{.State.Status}} {{.State.Health.Status}} {{.HostConfig.RestartPolicy.Name}}'
done
# named volumeがbindへ書き換えられていないことを先に確認。
docker inspect fuminiwa-sync-v2-role-split-postgres fuminiwa-sync-v2-role-split-edge \
  --format '{{.Name}}{{range .Mounts}}{{printf "\n"}}{{.Destination}} {{.Type}} {{.Name}}{{end}}'
curl --fail --silent --show-error --output /dev/null --write-out '%{http_code}\n' \
  -H 'x-fuminiwa-client-version: 0.1.0' https://sync.serika.work/v1/auth/capabilities
# <CA.pem>を実際に信頼するCaddy CAの公開証明書へ置き換える。-kで代用しない。
curl --fail --silent --show-error --cacert '<CA.pem>' --output /dev/null --write-out '%{http_code}\n' \
  -H 'x-fuminiwa-client-version: 0.1.0' https://192.168.11.5:8443/v1/auth/capabilities
curl --silent --output /dev/null --write-out '%{http_code}\n' http://192.168.11.5:8790/
# admin passwordはcurlのプロンプトで入力。
curl --fail --silent --show-error --user admin --output /dev/null --write-out '%{http_code}\n' http://192.168.11.5:8790/
docker exec --user 999:1000 fuminiwa-sync-v2-ops sh -c 'grep -E "^(Name|State|Uid|Gid|Groups):" /proc/1/status'
docker logs --tail 100 fuminiwa-sync-v2-ops
docker stats --no-stream fuminiwa-sync-v2-ops
```

4コンテナはrunning／healthy／unless-stopped。旧imageとのID一致・external volumeの名前・secretとCaddyfileの新参照先も読む。edgeの`/caddy-config`が既存caddy-config volumeであり、XDG_CONFIG_HOMEも`/caddy-config`であることを確認する。serverの実際のhealthcheckに空の比較や変数参照が残っていないこと、edgeのautosave先が`/caddy-config/caddy/autosave.json`であることも読む。capabilitiesの2経路はともに**200**、UI未認証は401、正しいBasicで200。画面から「今すぐバックアップ」を1回実行し、実行中のボタン無効・二重POST拒否、完了後のlast-success・新backup名／サイズ、opsログexit 0を確認する。UIやhealthの成功は原稿・account isolationの実機受入を代替しない。

次の03:17 JSTの定期成功、ホスト再起動後の4コンテナ／registry復帰とhealth、UI、次回予定は別の受入として確認する。停止中の予定は追いかけ実行しない。ops healthは非rootのPID 1 cron・起動済みUIの生存・36時間未満のbackup成功を判定する。

## ロールバック

この構成移行の失敗に対する切戻し。schema変更を伴う将来の更新にそのまま使わない。

以下は自動切戻しが完了しない場合の手動復旧。移行記録とcontainer IDを照合してから行う。

1. APIのuninstallまたはZimaOS UIから新アプリを停止・削除する。**external volume／データを削除する選択はしない**。4つの元のcontainer名が空いたことを確認する。中途半端なインストールもUIで処理する。
2. legacyを元の名前へ戻す。registryは止めない。
3. postgresを開始してhealthyを待ち、server、edge、opsの順で開始する。healthと両capabilities、CLI backupを再確認する。

```sh
# API／UI削除後。元の名前に新containerが残っていたらここで止める。
docker rename fuminiwa-sync-v2-role-split-postgres-legacy fuminiwa-sync-v2-role-split-postgres
docker rename fuminiwa-sync-v2-role-split-server-legacy fuminiwa-sync-v2-role-split-server
docker rename fuminiwa-sync-v2-role-split-edge-legacy fuminiwa-sync-v2-role-split-edge
docker rename fuminiwa-sync-v2-ops-legacy fuminiwa-sync-v2-ops
docker update --restart unless-stopped fuminiwa-sync-v2-role-split-postgres fuminiwa-sync-v2-role-split-server fuminiwa-sync-v2-role-split-edge fuminiwa-sync-v2-ops
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

生成composeのimageを新しいタグへ変更し、`zimaos_app.py apply <id> <compose>`で適用する。PUTがpull・再作成する範囲、image ID、container_name、external volume維持をClaudeが実機で確認する。apply自体は初回移行の自動backup／切戻しを行わないため、適用前のbackupと旧composeの保管、適用後の受入が必要。registryへpush済みの新タグを使い、同タグ再push／再pullのcache挙動には依存しない。repositoryからCasaOS保存ファイルを直接編集しない。

API更新が利用できない場合の候補はUIでのcompose更新、またはbackup→アプリ削除→再インストール。実機で挙動を確認するまで自動更新成功とは扱わない。必ず既存volumeをexternalで引き継ぐ。schema移行を伴う更新は、旧binaryが新schemaを扱えるという根拠なしに切り戻さない。

成功後の片付けは**利用者の確認後**。対象は停止した4つの`-legacy`コンテナと不要な旧image／releaseコピーを個別に列挙し、旧runtime／Caddyfile参照がなくなったことを確認してから行う。IDと停止状態を照合したlegacyだけを`docker rm <確認したID>`で個別に削除する。DB・Caddy・registry volume、backup鍵、daily、現行secret、tokenファイルは残す。`down -v`／volume rm／system pruneは使わない。現時点の作業に片付けは含まない。

## ローカル検証と未実施の境界

```sh
# cryptographyがあるPython環境。UIと生成処理自身は標準ライブラリだけ。
python3 -m unittest discover -s Scripts/operations -p 'test_*.py' -v
# Dockerがある環境のみ。稼働サーバーを使うローカル検証ではない。
docker build -f SyncServerV2/ops/Dockerfile -t fuminiwa-sync-v2-ops:test .
```

fake Dockerテストは認証、CSRF、操作の限定、秘密の非表示、Web／CLIの排他、inspect生成、欠落拒否、秘密を読まないこと、volume／digest／container_name、config検証前のatomic置換、prepareの操作範囲を扱う。初回実装のローカル検証では既存backup／opsを含む31テストと`./Scripts/check.sh`全段が成功した。

1回目の本番インポート後のvolume修正では、YAML出力・短い書式・外部名とkeyの一致・クォート・時間表記・自己検査の拒否ケースを追加し、既存分を含む35テストが成功した。生成compose全体と特殊文字を独立したYAMLパーサーでも読めることを確認した。この追加確認にだけ一時的なPyYAML環境を使い、生成スクリプト・単体テスト・imageへの依存追加は行っていない。

2回目の修正では39テストが成功した。2重展開を模擬したあと、fake curlを使って元のhealthcheckと修正版を実際のshellで実行し、200／401／500／通信失敗の終了判定が一致することを確認した。変換不能な参照・生成物の変数参照・全サービスの/configターゲットの拒否、Caddy volume名と内部の相対位置の維持も検証した。今回`check.sh`は再実行せず、指定されたPythonテスト全件を検証範囲とした。

API／移行の自動化では、既存分を含むoperationsの62テストとlocal recoveryの3テスト（合計65件）が成功した。fake HTTPで既存token形式、0600／symlink拒否、期限余裕、refreshローテーション、Bearer fallback、出力へのcredential非表示、loopback限定、dry-run、DELETEの設定保持を確認。fake Dockerで2回のmount書換え、停止順序、backup失敗、health／公開失敗、中途install、残存コンテナの退避、API削除未完了、中断復旧、旧ID不一致、再実行時のAPI削除抑止を確認した。shell構文とdiff検査も成功。今回の検証範囲はPythonテスト全件で、`check.sh`は未実施。

直接読み取りのUID修正では、fake Hostがrootのcatを拒否するテストを追加し、前後の読み取りだけに`--user 999:1000`が付くこと、run-backupの呼出を維持することを確認した。既存分を含むoperations 63件とlocal recovery 3件（合計66件）が成功。今回もPythonテスト全件を検証範囲とし、`check.sh`は未実施。

ローカルにDocker CLIがないため実imageのbuildと実Composeのconfig検証は未実施。fake CLIによるconfig呼出の確認とは区別する。認証済み実APIの応答・install／apply／uninstall・自動移行と切戻し、volume名のinspect、LAN到達、待機CPU、停止時の処理、実backup／翌日の定期成功／再起動は別途Claude側で実施する。
