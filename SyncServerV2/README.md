# FUMINIWA Snapshot Sync v2 server

This is the isolated v2 server namespace selected by D-080. It uses Axum,
SQLx/PostgreSQL and `sync_v2` tables; object bytes are initially PostgreSQL
`BYTEA` behind the `ObjectStore` trait. Mutating `ObjectStore` operations use
the caller's SQLx transaction; object bytes, upload state, ownership and the
command receipt cannot commit independently. The v1 `SyncServer/` directory,
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
`FUMINIWA_V2_TEST_DATABASE_URL` to an externally provisioned, newly-created
empty database whose name is `fuminiwa_v2_test` or begins with
`fuminiwa_v2_test_`. The runner does not create or drop a database, schema,
container, or volume. It applies the checked-in migrations to that database,
runs repository scenarios, and leaves its synthetic rows intact. Test-only
setup directly forces upload expiry, a migration-marker mismatch, and a
catalog tombstone/race; these writes are not production API paths.

The operator must discard the entire disposable database after the run. Use a
second fresh database for the HTTP integration gate because each gate refuses
an initialized database:

```sh
FUMINIWA_V2_TEST_DATABASE_URL='postgres://.../fuminiwa_v2_test_repository_<uuid>' \
  cargo run --bin sync_v2_scenario_runner
FUMINIWA_V2_TEST_DATABASE_URL='postgres://.../fuminiwa_v2_test_http_<uuid>' \
  cargo test --test integration_gate postgres_and_http_scenarios_are_opt_in \
  -- --exact --nocapture
```

Without the variable, ordinary tests emit an explicit integration skip and no
network or fixed LAN endpoint is contacted. The guard rejects private-LAN
hosts, legacy/production/staging database names, names without the test marker,
and any database that already has non-system tables. Never point it at v1, a
development/staging authority, or a production volume.
