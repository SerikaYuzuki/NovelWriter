# FUMINIWA Snapshot Sync v2 server

This is the isolated v2 server namespace selected by D-080. It uses Axum,
SQLx/PostgreSQL and `sync_v2` tables; object bytes are initially PostgreSQL
`BYTEA` behind the `ObjectStore` trait. Mutating `ObjectStore` operations use
the caller's SQLx transaction; object bytes, upload state, ownership and the
command receipt cannot commit independently. The v1 `SyncServer/` directory,
database, Docker project and volumes are never read or mounted.

## Local development

```sh
export FUMINIWA_SYNC_V2_POSTGRES_PASSWORD_FILE=/secure/path/postgres-password
docker compose -f SyncServerV2/docker-compose.yml -p fuminiwa-sync-v2 up --build
```

The only database volume is `fuminiwa_sync_v2_pgdata`; Caddy also has two
edge-state volumes (`fuminiwa_sync_v2_caddy_data` and
`fuminiwa_sync_v2_caddy_config`). The only project and containers are
`fuminiwa-sync-v2-*`. Copy `.env.example` outside version
control and point the `*_HOST_PATH` values at separately managed secret files.
The server binary is Production-only and fails closed before opening
PostgreSQL when any Auth v1 key or Apple configuration is absent. Test and
preview authentication are dependency-injected in process tests; the binary
has no fixture-token startup mode.

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

## Production Sign in with Apple authority

The adapter uses only Apple's fixed issuer, JWKS, and token endpoints. It
follows Apple's primary documentation for
[authenticating users](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple),
[token generation and validation](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens),
[client-secret creation](https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret),
and [JWKS retrieval](https://developer.apple.com/documentation/signinwithapplerestapi/fetch-apple%27s-public-key-for-verifying-token-signature).
No private key, provider token, or real identity fixture belongs in this
repository.

## Staging TLS and health read-back

The included Caddy edge uses `tls internal` only for a LAN staging deployment.
The generated local CA must be explicitly trusted on each test device; it is
not a production certificate. Production requires a separately managed,
publicly trusted TLS edge and must not expose the Axum listener directly.
Before device testing, verify the edge health response and certificate chain
from the same network path used by the app, then read back the authenticated
capabilities response and a newly created v2 work. A successful container
healthcheck alone is not a TLS or account-isolation read-back.
