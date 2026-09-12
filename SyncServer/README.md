# FUMINIWA Snapshot Sync v1（履歴）

このディレクトリはD-078のserver-readable v1を実装した旧Rust/Axumサーバーです。D-080以降の通常Appはv2だけを使います。現在の開発・起動手順は[SyncServerV2/README.md](../SyncServerV2/README.md)、契約は[SNAPSHOT_SYNC_V2.md](../docs/SNAPSHOT_SYNC_V2.md)、実装状況は[v2 handoff](../docs/SNAPSHOT_SYNC_V2_HANDOFF.md)を参照してください。

以下はv1の構成・検証方法を調べるための記録です。この手順でv1を新たに配置したり、既存DB／volumeをv2へ転用したりしないでください。v2の現行実装や移行手順には使いません。

v1では、macOS／iOS側のSQLiteを正本とし、サーバーがimmutable snapshot、CAS object、headのCAS、競合記録、Sign in with Appleから発行したFUMINIWA sessionを扱っていました。

## v1のDocker手順（履歴）

```sh
cp .env.example .env
docker compose up --build
```

`FUMINIWA_DEV_TOKEN` は開発時だけ有効な bearer です。Apple の本番設定
（`APPLE_CLIENT_IDS`、`APPLE_TEAM_ID`、`APPLE_KEY_ID`、`APPLE_PRIVATE_KEY_PEM`、
`FUMINIWA_VAULT_KEY_B64`）は `.env` や secret store から注入し、リポジトリへ保存しません。
`.env`へPEMを直接書く場合は、改行をリテラルの`\\n`として1行にし、`BEGIN/END PRIVATE KEY`を含めます。

開発用の疎通確認:

```sh
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:8080/v1/auth/capabilities
```

## v1で実装した範囲

- Postgres は migration と durable receipt/session の保存に使用します。
- CAS bytes は現在 Postgres の `BYTEA` に置いています。MinIO/S3 への分離は、
  object create/upload/finalize の receipt と read-back barrier を実装する R4 の次の作業です。
- `persist_state` は R4 の開発用リカバリ実装で、状態全体を transaction で再書込みします。
  本番化する前に row-level repository と head CAS の PostgreSQL transaction へ置き換えます。
- Apple credential exchange は server 側で検証し、クライアントへ Apple refresh token を返しません。
  クライアントには短命 access token と rotation 付き FUMINIWA refresh token だけを返します。

### アカウント境界と既存DBの移行

同期データ（work、snapshot、objectのpresence、head、conflict、operation receipt）は
すべて AccountID の複合スコープです。同じIDのデータを別アカウントが持てます。
object本体はSHA-256で物理的に重複排除できますが、`object_access` の所有者行がない
限り読み書きできません。

`0004_account_scoped_sync.sql` は、旧スキーマに残る作品・snapshot・objectを、DBに
実在アカウントがちょうど1件ある場合だけそのアカウントへ移します。アカウントが0件
または2件以上で所有者を決められない場合は migration 全体を fail closed で中断し、
推測による割当を行いません。Apple exchange のようにAccount確定前のreceiptは専用の
`auth_operations`へ分離されます。開発bearerを有効にしたDBでは、必要な場合だけ
`dev-account`という明示的なsynthetic accountを作成して外部キーを満たします。

## v1のリモート開発計画（履歴）

192.168.11.5 には、既存サービスと衝突しない専用 Docker network/container/volume を作ります。
既存の 8080 利用サービスを避けるため、手動 smoke 環境ではホストの 18080 を使います。
資格情報はホスト上の専用環境ファイルだけに置き、ログや Git へ出しません。
