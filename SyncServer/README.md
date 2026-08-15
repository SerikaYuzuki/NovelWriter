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

## リモート開発機

192.168.11.5 には、既存サービスと衝突しない専用 Docker network/container/volume を作ります。
既存の 8080 利用サービスを避けるため、手動 smoke 環境ではホストの 18080 を使います。
資格情報はホスト上の専用環境ファイルだけに置き、ログや Git へ出しません。
