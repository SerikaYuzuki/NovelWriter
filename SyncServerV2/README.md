# FUMINIWA Snapshot Sync v2 server

This is the isolated v2 server namespace selected by D-080. It uses Axum,
SQLx/PostgreSQL and `sync_v2` tables; object bytes are initially PostgreSQL
`BYTEA` behind the `ObjectStore` trait. The v1 `SyncServer/` directory,
database, Docker project and volumes are never read or mounted.

## Local development

```sh
export FUMINIWA_SYNC_V2_POSTGRES_PASSWORD='use-a-local-secret'
docker compose -f SyncServerV2/docker-compose.yml -p fuminiwa-sync-v2 up --build
```

The only Compose volume is `fuminiwa_sync_v2_pgdata`; the only project and
containers are `fuminiwa-sync-v2-*`. Production mode fails closed without the
Auth v1 principal boundary. Fixture Bearer tokens are available only with
`FUMINIWA_RUNTIME_MODE=test` or `preview`.

## Verification

```sh
cargo fmt --check
cargo test --offline
cargo clippy --offline --all-targets -- -D warnings
```

The PostgreSQL integration gate is opt-in. Set
`FUMINIWA_V2_TEST_DATABASE_URL` to an explicitly provisioned empty v2 test
database; the test creates and drops a UUID-named temporary schema. Without
the variable, unit and canonical-fixture gates continue and no network or
fixed LAN endpoint is contacted. Never point it at v1 or a production volume.
