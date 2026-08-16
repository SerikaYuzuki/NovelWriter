# FUMINIWA Snapshot Sync（開発用）

このディレクトリは D-078 の server-readable v1 を実装する Rust/Axum サーバーです。
ローカルの正本は macOS/iOS 側の SQLite で、サーバーは immutable snapshot、CAS object、head の CAS、競合記録、Sign in with Apple から発行した FUMINIWA session を扱います。

## Docker

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

## 現在の実装範囲

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

## リモート開発機

192.168.11.5 には、既存サービスと衝突しない専用 Docker network/container/volume を作ります。
既存の 8080 利用サービスを避けるため、手動 smoke 環境ではホストの 18080 を使います。
資格情報はホスト上の専用環境ファイルだけに置き、ログや Git へ出しません。
